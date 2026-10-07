-- =============================================================================
-- JËND PRO — Audit log (Phase 4, enriched in Phase 13)
-- -----------------------------------------------------------------------------
-- Append-only trail of sensitive operations. Written only through
-- private.log_audit() (called by SECURITY DEFINER RPCs and triggers); clients
-- can never insert, update or delete. Metadata must stay minimal and must
-- never contain secrets, tokens or full payment instrument data.
-- =============================================================================

create table public.audit_logs (
  id            uuid primary key default gen_random_uuid(),
  -- NULL for platform-level events. CASCADE: a business erased by the platform
  -- takes its trail with it (data deletion request).
  business_id   uuid references public.businesses (id) on delete cascade,
  actor_id      uuid references auth.users (id) on delete set null,
  action        text not null check (action ~ '^[a-z_]+\.[a-z_]+$'),
  resource_type text not null check (char_length(resource_type) <= 50),
  resource_id   uuid,
  metadata      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

comment on table public.audit_logs is
  'Append-only audit trail. Written only by private.log_audit().';

-- Journal listing per business (most recent first) and history of one resource.
create index audit_logs_business_id_created_at_idx
  on public.audit_logs (business_id, created_at desc);
create index audit_logs_business_id_resource_idx
  on public.audit_logs (business_id, resource_type, resource_id);

-- Append-only, including for privileged roles.
create or replace function private.prevent_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'APPEND_ONLY' using errcode = 'P0001',
    detail = format('%I.%I rows cannot be updated', tg_table_schema, tg_table_name);
end;
$$;

create trigger prevent_update
  before update on public.audit_logs
  for each row execute function private.prevent_update();

alter table public.audit_logs enable row level security;

grant select on public.audit_logs to authenticated;

create policy "members with audit.read can select audit logs"
  on public.audit_logs for select to authenticated
  using (business_id in (select private.businesses_with_permission('audit.read')));

-- -----------------------------------------------------------------------------
-- Writer. Not granted to any API role: only callable from functions owned by
-- the migration role (SECURITY DEFINER RPCs / triggers).
-- -----------------------------------------------------------------------------
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
  insert into public.audit_logs (business_id, actor_id, action, resource_type, resource_id, metadata)
  values (p_business_id, (select auth.uid()), p_action, p_resource_type, p_resource_id,
          coalesce(p_metadata, '{}'::jsonb));
$$;

-- -----------------------------------------------------------------------------
-- Business settings are updated directly through PostgREST: audit every change.
-- -----------------------------------------------------------------------------
create or replace function private.audit_business_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changes jsonb;
begin
  select jsonb_object_agg(n.key, jsonb_build_object('old', o.value, 'new', n.value))
    into v_changes
    from jsonb_each(to_jsonb(new)) n
    join jsonb_each(to_jsonb(old)) o on o.key = n.key
   where n.value is distinct from o.value
     and n.key <> 'updated_at';

  if v_changes is not null then
    perform private.log_audit(new.id, 'business.update', 'business', new.id,
                              jsonb_build_object('changes', v_changes));
  end if;
  return null;
end;
$$;

create trigger audit_business_update
  after update on public.businesses
  for each row execute function private.audit_business_update();
