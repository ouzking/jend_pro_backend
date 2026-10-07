-- =============================================================================
-- JËND PRO — Audit hardening (Phase 13)
-- -----------------------------------------------------------------------------
-- * actor_role: distinguishes user actions (authenticated) from platform actions
--   (service_role: payment webhooks, back-office), where actor_id is NULL.
-- * audit_logs becomes truly immutable: DELETE is refused for every role unless
--   the platform explicitly opts in for a purge (business erasure) with
--   `set local jendpro.allow_audit_purge = 'on'`.
-- * Missing events: locations (create / changes), customer & supplier status
--   changes, product creation.
-- * get_audit_log(): keyset-paginated journal with actor names (profiles are
--   private, so clients cannot resolve names themselves).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- actor_role
-- -----------------------------------------------------------------------------
alter table public.audit_logs
  add column actor_role text check (char_length(actor_role) <= 50);

comment on column public.audit_logs.actor_role is
  'Role of the caller (authenticated, service_role, postgres for migrations/maintenance).';

create or replace function private.log_audit(
  p_business_id   uuid,
  p_action        text,
  p_resource_type text,
  p_resource_id   uuid,
  p_metadata      jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_logs (business_id, actor_id, actor_role, action, resource_type, resource_id, metadata)
  values (p_business_id, (select auth.uid()),
          coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', session_user::text),
          p_action, p_resource_type, p_resource_id, coalesce(p_metadata, '{}'::jsonb));
$$;

-- -----------------------------------------------------------------------------
-- Immutability: no DELETE without explicit platform purge flag.
-- -----------------------------------------------------------------------------
create or replace function private.prevent_audit_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(current_setting('jendpro.allow_audit_purge', true), '') <> 'on' then
    raise exception 'APPEND_ONLY' using errcode = 'P0001',
      detail = 'Audit logs cannot be deleted (platform purge requires jendpro.allow_audit_purge).';
  end if;
  return old;
end;
$$;

create trigger prevent_delete
  before delete on public.audit_logs
  for each row execute function private.prevent_audit_delete();

-- -----------------------------------------------------------------------------
-- Additional events
-- -----------------------------------------------------------------------------
-- Generic: audits the changed columns of an UPDATE (or the row of an INSERT).
-- tg_argv[0] = action prefix (e.g. 'location'), tg_argv[1] = resource type.
create or replace function private.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changes jsonb;
begin
  if tg_op = 'INSERT' then
    perform private.log_audit(new.business_id, tg_argv[0] || '.create', tg_argv[1], new.id,
                              jsonb_build_object('new', to_jsonb(new) - 'created_at' - 'updated_at'));
    return null;
  end if;

  select jsonb_object_agg(n.key, jsonb_build_object('old', o.value, 'new', n.value))
    into v_changes
    from jsonb_each(to_jsonb(new)) n
    join jsonb_each(to_jsonb(old)) o on o.key = n.key
   where n.value is distinct from o.value
     and n.key not in ('updated_at');

  if v_changes is not null then
    perform private.log_audit(new.business_id,
      tg_argv[0] || case when v_changes ? 'status' then '.status_change' else '.update' end,
      tg_argv[1], new.id, jsonb_build_object('changes', v_changes));
  end if;
  return null;
end;
$$;

-- Locations: every creation and change (settings).
create trigger audit_location
  after insert or update on public.locations
  for each row execute function private.audit_row_change('location', 'location');

-- Customers and suppliers: archive / reactivation only (frequent contact edits are not audited).
create trigger audit_customer_status
  after update of status on public.customers
  for each row when (old.status is distinct from new.status)
  execute function private.audit_row_change('customer', 'customer');

create trigger audit_supplier_status
  after update of status on public.suppliers
  for each row when (old.status is distinct from new.status)
  execute function private.audit_row_change('supplier', 'supplier');

-- Product creation (price changes and status changes are already audited).
create trigger audit_product_create
  after insert on public.products
  for each row execute function private.audit_row_change('product', 'product');

-- -----------------------------------------------------------------------------
-- get_audit_log: keyset pagination (p_before = created_at of the last row seen,
-- p_before_id = its id), optional filters. Requires audit.read.
-- -----------------------------------------------------------------------------
create or replace function public.get_audit_log(
  p_business_id   uuid,
  p_limit         int default 50,
  p_before        timestamptz default null,
  p_before_id     uuid default null,
  p_action        text default null,
  p_resource_type text default null,
  p_resource_id   uuid default null,
  p_actor_id      uuid default null
)
returns table (
  id            uuid,
  created_at    timestamptz,
  action        text,
  resource_type text,
  resource_id   uuid,
  actor_id      uuid,
  actor_name    text,
  actor_role    text,
  metadata      jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_permission(p_business_id, 'audit.read');

  return query
  select a.id, a.created_at, a.action, a.resource_type, a.resource_id, a.actor_id,
         p.full_name, a.actor_role, a.metadata
    from public.audit_logs a
    left join public.profiles p on p.id = a.actor_id
   where a.business_id = p_business_id
     and (p_before is null or (a.created_at, a.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
     and (p_action is null or a.action = p_action or a.action like p_action || '.%')
     and (p_resource_type is null or a.resource_type = p_resource_type)
     and (p_resource_id is null or a.resource_id = p_resource_id)
     and (p_actor_id is null or a.actor_id = p_actor_id)
   order by a.created_at desc, a.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;

-- Keyset order (created_at desc, id desc) within a business.
drop index public.audit_logs_business_id_created_at_idx;
create index audit_logs_business_id_created_at_idx on public.audit_logs (business_id, created_at desc, id desc);

revoke all on function public.get_audit_log(uuid, int, timestamptz, uuid, text, text, uuid, uuid) from public, anon;
grant execute on function public.get_audit_log(uuid, int, timestamptz, uuid, text, text, uuid, uuid) to authenticated;
