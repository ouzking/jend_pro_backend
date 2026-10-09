-- =============================================================================
-- JËND PRO — Platform administration (Phase 16)
-- -----------------------------------------------------------------------------
-- Back-office of the JËND PRO team (not merchants). Until now, cross-tenant
-- operations were reserved to service_role (platform_* RPCs). The back-office
-- is a browser app and must never hold service_role: platform staff therefore
-- authenticate as normal users and are authorized by a separate, platform-level
-- RBAC that is completely independent from business_members.
--
-- * platform_admins (user × platform role), platform_permissions,
--   platform_role_permissions. Written by migrations / RPC (admins.manage).
-- * Helpers: private.has_platform_permission(), private.require_platform_permission().
-- * Reads: SECURITY DEFINER `admin_*` RPCs only. NO policy is added to tenant
--   tables: merchant isolation (RLS) is untouched, and every cross-tenant read
--   goes through an explicit, permission-checked, paginated function (which
--   also maps 1:1 to future Laravel endpoints).
-- * Writes: business suspension, manual (offline) subscription payment,
--   platform admin management. All audited.
-- Bootstrap of the first SUPER_ADMIN (SQL editor / service_role only):
--   insert into public.platform_admins (user_id, role)
--   select id, 'SUPER_ADMIN' from auth.users where email = '<email>';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------
create type public.platform_role as enum ('SUPER_ADMIN', 'OPERATIONS', 'SUPPORT', 'FINANCE', 'ANALYST');
create type public.platform_admin_status as enum ('ACTIVE', 'SUSPENDED');

-- -----------------------------------------------------------------------------
-- Platform RBAC catalog
-- -----------------------------------------------------------------------------
create table public.platform_permissions (
  code        text primary key check (code ~ '^[a-z_]+\.[a-z_]+$'),
  description text not null,
  created_at  timestamptz not null default now()
);

comment on table public.platform_permissions is
  'Permission catalog of the JËND PRO back-office (platform staff). Managed by migrations only.';

create table public.platform_role_permissions (
  role            public.platform_role not null,
  -- CASCADE: a grant has no meaning without its permission.
  permission_code text not null references public.platform_permissions (code) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (role, permission_code)
);

create table public.platform_admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  role       public.platform_role not null,
  status     public.platform_admin_status not null default 'ACTIVE',
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.platform_admins is
  'JËND PRO staff with back-office access. Independent from business_members. Written by RPC / migrations only.';

create trigger set_updated_at
  before update on public.platform_admins
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Helpers (private). Only ACTIVE admins have permissions.
-- -----------------------------------------------------------------------------
create or replace function private.has_platform_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.platform_admins a
      join public.platform_role_permissions rp on rp.role = a.role
     where a.user_id = (select auth.uid())
       and a.status = 'ACTIVE'
       and rp.permission_code = p_permission);
$$;

-- Guard used as the first statement of every admin_* RPC.
create or replace function private.require_platform_permission(p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if not private.has_platform_permission(p_permission) then
    raise exception 'PERMISSION_DENIED' using errcode = '42501', detail = p_permission;
  end if;
end;
$$;

-- Needed by RLS policies (support tables); the guard is internal only.
grant execute on function private.has_platform_permission(text) to authenticated;

-- Platform reporting days are Dakar days (UTC+0, no DST), range <= 366 days.
create or replace function private.platform_bounds(p_from date, p_to date, out from_ts timestamptz, out to_ts timestamptz)
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_DATE_RANGE' using errcode = '22023';
  end if;
  if p_to - p_from > 366 then
    raise exception 'DATE_RANGE_TOO_LARGE' using errcode = '22023', detail = 'max 366 days';
  end if;
  from_ts := p_from::timestamp at time zone 'Africa/Dakar';
  to_ts   := (p_to + 1)::timestamp at time zone 'Africa/Dakar';
end;
$$;

-- Clamps client paging parameters.
create or replace function private.page_limit(p_limit int, p_default int default 25)
returns int
language sql
immutable
set search_path = ''
as $$
  select least(greatest(coalesce(p_limit, p_default), 1), 100);
$$;

-- Escapes LIKE wildcards of a user search term.
create or replace function private.like_pattern(p_search text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when nullif(btrim(p_search), '') is null then null
              else '%' || replace(replace(replace(btrim(p_search), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
$$;

-- Invariant: the platform always keeps at least one ACTIVE SUPER_ADMIN.
create or replace function private.ensure_platform_has_super_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'SUPER_ADMIN' and old.status = 'ACTIVE'
     and not exists (select 1 from public.platform_admins
                      where role = 'SUPER_ADMIN' and status = 'ACTIVE') then
    raise exception 'LAST_SUPER_ADMIN' using errcode = 'P0001',
      detail = 'The platform must keep at least one active super admin.';
  end if;
  return null;
end;
$$;

create trigger ensure_platform_has_super_admin
  after update or delete on public.platform_admins
  for each row execute function private.ensure_platform_has_super_admin();

-- -----------------------------------------------------------------------------
-- Privileges + RLS: catalog readable by staff; admins table read-only.
-- -----------------------------------------------------------------------------
alter table public.platform_permissions      enable row level security;
alter table public.platform_role_permissions enable row level security;
alter table public.platform_admins           enable row level security;

grant select on public.platform_permissions, public.platform_role_permissions, public.platform_admins to authenticated;

create policy "platform admins can select platform permissions"
  on public.platform_permissions for select to authenticated
  using (exists (select 1 from public.platform_admins a where a.user_id = (select auth.uid()) and a.status = 'ACTIVE'));

create policy "platform admins can select platform role grants"
  on public.platform_role_permissions for select to authenticated
  using (exists (select 1 from public.platform_admins a where a.user_id = (select auth.uid()) and a.status = 'ACTIVE'));

create policy "users can select their own platform access"
  on public.platform_admins for select to authenticated
  using (user_id = (select auth.uid()));

create policy "platform admins with admins.manage can select admins"
  on public.platform_admins for select to authenticated
  using ((select private.has_platform_permission('admins.manage')));

-- -----------------------------------------------------------------------------
-- Seed: platform permission catalog + role matrix (docs/roles-and-permissions.md §6)
-- -----------------------------------------------------------------------------
insert into public.platform_permissions (code, description) values
  ('businesses.read',      'Voir les entreprises, leurs membres et statistiques'),
  ('businesses.manage',    'Suspendre / réactiver une entreprise'),
  ('users.read',           'Voir les utilisateurs et leurs appartenances'),
  ('subscriptions.read',   'Voir les plans et abonnements'),
  ('billing.read',         'Voir les paiements d''abonnement'),
  ('billing.manage',       'Enregistrer un paiement d''abonnement hors ligne'),
  ('support.read',         'Voir les tickets de support'),
  ('support.manage',       'Répondre, assigner et changer le statut des tickets'),
  ('announcements.read',   'Voir les annonces plateforme'),
  ('announcements.manage', 'Créer et envoyer des annonces'),
  ('audit.read',           'Consulter le journal d''audit de toute la plateforme'),
  ('analytics.read',       'Voir les indicateurs plateforme (MRR, croissance…)'),
  ('admins.manage',        'Gérer les administrateurs plateforme');

insert into public.platform_role_permissions (role, permission_code)
select r.role::public.platform_role, p.code
  from (values ('SUPER_ADMIN'), ('OPERATIONS'), ('SUPPORT'), ('FINANCE'), ('ANALYST')) r(role)
  cross join public.platform_permissions p
 where r.role = 'SUPER_ADMIN'
    or (r.role = 'OPERATIONS' and p.code <> all (array['admins.manage', 'billing.manage']))
    or (r.role = 'SUPPORT' and p.code = any (array[
         'businesses.read', 'users.read', 'subscriptions.read', 'support.read', 'support.manage',
         'announcements.read']))
    or (r.role = 'FINANCE' and p.code = any (array[
         'businesses.read', 'subscriptions.read', 'billing.read', 'billing.manage', 'analytics.read',
         'audit.read']))
    or (r.role = 'ANALYST' and p.code = any (array[
         'businesses.read', 'subscriptions.read', 'billing.read', 'analytics.read']));

-- =============================================================================
-- RPC — access
-- =============================================================================
-- Self-scoped: what the caller can do in the back-office (empty when not staff).
create or replace function public.get_my_platform_access()
returns table (
  role        public.platform_role,
  status      public.platform_admin_status,
  permissions text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.role, a.status,
         case when a.status = 'ACTIVE'
              then coalesce((select array_agg(rp.permission_code order by rp.permission_code)
                               from public.platform_role_permissions rp where rp.role = a.role), '{}')
              else '{}' end
    from public.platform_admins a
   where a.user_id = (select auth.uid());
$$;

-- =============================================================================
-- RPC — businesses
-- =============================================================================
create or replace function public.admin_list_businesses(
  p_search              text default null,
  p_status              public.business_status default null,
  p_plan_code           text default null,
  p_subscription_status public.subscription_status default null,
  p_created_from        date default null,
  p_created_to          date default null,
  p_sort                text default 'created_at_desc',
  p_limit               int default 25,
  p_offset              int default 0
)
returns table (
  id                  uuid,
  name                text,
  city                text,
  country_code        text,
  phone               text,
  email               text,
  status              public.business_status,
  created_at          timestamptz,
  owner_name          text,
  owner_email         text,
  members_count       int,
  plan_code           text,
  plan_name           text,
  subscription_status public.subscription_status,
  trial_ends_at       timestamptz,
  current_period_end  timestamptz,
  last_sale_at        timestamptz,
  total_count         bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.like_pattern(p_search);
begin
  perform private.require_platform_permission('businesses.read');

  if coalesce(p_sort, 'created_at_desc') not in ('created_at_desc', 'created_at_asc', 'name_asc', 'last_sale_desc') then
    raise exception 'INVALID_SORT' using errcode = '22023';
  end if;

  return query
  with base as (
    select b.*, sub.plan_code, sub.plan_name, sub.sub_status, sub.trial_ends_at as sub_trial_ends_at,
           sub.current_period_end as sub_period_end
      from public.businesses b
      left join lateral (
        select p.code as plan_code, p.name as plan_name, s.status as sub_status, s.trial_ends_at, s.current_period_end
          from public.subscriptions s
          join public.subscription_plans p on p.id = s.plan_id
         where s.business_id = b.id
         order by (s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE')) desc, s.created_at desc
         limit 1) sub on true
     where (p_status is null or b.status = p_status)
       and (p_plan_code is null or sub.plan_code = p_plan_code)
       and (p_subscription_status is null or sub.sub_status = p_subscription_status)
       and (p_created_from is null or b.created_at >= p_created_from::timestamp at time zone 'Africa/Dakar')
       and (p_created_to is null or b.created_at < (p_created_to + 1)::timestamp at time zone 'Africa/Dakar')
       and (v_pattern is null or b.name ilike v_pattern or b.city ilike v_pattern
            or b.phone ilike v_pattern or b.email ilike v_pattern or b.id::text = btrim(p_search))
  ),
  counted as (
    select base.*, count(*) over () as total,
           (select max(sa.sold_at) from public.sales sa where sa.business_id = base.id) as last_sale
      from base
  )
  select c.id, c.name, c.city, c.country_code::text, c.phone, c.email, c.status, c.created_at,
         o.full_name, o.email::text,
         (select count(*)::int from public.business_members m where m.business_id = c.id and m.status = 'ACTIVE'),
         c.plan_code, c.plan_name, c.sub_status, c.sub_trial_ends_at, c.sub_period_end,
         c.last_sale, c.total
    from counted c
    left join lateral (
      select pr.full_name, u.email
        from public.business_members m
        join public.roles r on r.id = m.role_id and r.business_id is null and r.code = 'OWNER'
        join auth.users u on u.id = m.user_id
        left join public.profiles pr on pr.id = m.user_id
       where m.business_id = c.id and m.status = 'ACTIVE'
       order by m.joined_at
       limit 1) o on true
   order by
     case when coalesce(p_sort, 'created_at_desc') = 'created_at_desc' then c.created_at end desc,
     case when p_sort = 'created_at_asc' then c.created_at end asc,
     case when p_sort = 'name_asc' then lower(c.name) end asc,
     case when p_sort = 'last_sale_desc' then c.last_sale end desc nulls last,
     c.id
   limit private.page_limit(p_limit) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create or replace function public.admin_get_business(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_business public.businesses;
  v_since    timestamptz := now() - interval '30 days';
begin
  perform private.require_platform_permission('businesses.read');

  select * into v_business from public.businesses where id = p_business_id;
  if not found then
    raise exception 'BUSINESS_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'business', to_jsonb(v_business),
    'counts', jsonb_build_object(
      'members',   (select count(*) from public.business_members where business_id = p_business_id and status = 'ACTIVE'),
      'invited',   (select count(*) from public.business_members where business_id = p_business_id and status = 'INVITED'),
      'locations', (select count(*) from public.locations where business_id = p_business_id and status = 'ACTIVE'),
      'products',  (select count(*) from public.products where business_id = p_business_id and status = 'ACTIVE'),
      'customers', (select count(*) from public.customers where business_id = p_business_id and status = 'ACTIVE')),
    'activity', jsonb_build_object(
      'sales_count_30d',   (select count(*) from public.sales
                             where business_id = p_business_id and status = 'COMPLETED' and sold_at >= v_since),
      'revenue_30d',       (select coalesce(sum(total_amount), 0) from public.sales
                             where business_id = p_business_id and status = 'COMPLETED' and sold_at >= v_since),
      'sales_count_total', (select count(*) from public.sales where business_id = p_business_id and status = 'COMPLETED'),
      'last_sale_at',      (select max(sold_at) from public.sales where business_id = p_business_id)),
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'plan_code', p.code, 'plan_name', p.name, 'status', s.status,
               'trial_ends_at', s.trial_ends_at, 'current_period_start', s.current_period_start,
               'current_period_end', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
               'ended_at', s.ended_at, 'external_reference', s.external_reference, 'created_at', s.created_at)
             order by (s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE')) desc, s.created_at desc)
        from public.subscriptions s
        join public.subscription_plans p on p.id = s.plan_id
       where s.business_id = p_business_id), '[]'::jsonb),
    'is_restricted', not private.subscription_in_good_standing(p_business_id),
    'usage', jsonb_build_object(
      'members',   (select count(*) from public.business_members where business_id = p_business_id and status in ('ACTIVE', 'INVITED')),
      'products',  (select count(*) from public.products where business_id = p_business_id and status = 'ACTIVE'),
      'locations', (select count(*) from public.locations where business_id = p_business_id and status = 'ACTIVE')));
end;
$$;

create or replace function public.admin_list_business_members(p_business_id uuid)
returns table (
  member_id       uuid,
  user_id         uuid,
  full_name       text,
  email           text,
  phone           text,
  role_code       text,
  role_name       text,
  status          public.member_status,
  joined_at       timestamptz,
  created_at      timestamptz,
  last_sign_in_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('businesses.read');

  return query
  select m.id, m.user_id, p.full_name, u.email::text, p.phone, r.code, r.name, m.status, m.joined_at,
         m.created_at, u.last_sign_in_at
    from public.business_members m
    join public.roles r on r.id = m.role_id
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
   where m.business_id = p_business_id
   order by (m.status = 'ACTIVE') desc, m.joined_at nulls last, m.created_at
   limit 500;
end;
$$;

-- Suspension cuts every member's access immediately (helpers only consider
-- ACTIVE businesses). Owners are notified (notifications stay readable).
create or replace function public.admin_set_business_status(
  p_business_id uuid,
  p_status      public.business_status,
  p_reason      text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.business_status;
begin
  perform private.require_platform_permission('businesses.manage');

  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  select status into v_old from public.businesses where id = p_business_id for update;
  if not found then
    raise exception 'BUSINESS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_old = p_status then
    return;
  end if;

  update public.businesses set status = p_status where id = p_business_id;

  perform private.log_audit(p_business_id, 'business.status_change', 'business', p_business_id,
    jsonb_build_object('old', v_old, 'new', p_status, 'reason', btrim(p_reason), 'by_platform', true));

  perform private.notify_members(p_business_id, 'subscription.manage', 'SYSTEM',
    case when p_status = 'SUSPENDED' then 'Votre entreprise a été suspendue'
         else 'Votre entreprise a été réactivée' end,
    case when p_status = 'SUSPENDED'
         then 'L''accès à votre entreprise est suspendu. Contactez le support JËND PRO.'
         else 'L''accès à votre entreprise est rétabli.' end,
    jsonb_build_object('kind', 'BUSINESS_STATUS', 'status', p_status),
    'business', p_business_id);
end;
$$;

-- =============================================================================
-- RPC — users
-- =============================================================================
create or replace function public.admin_list_users(
  p_search text default null,
  p_limit  int default 25,
  p_offset int default 0
)
returns table (
  id                uuid,
  email             text,
  phone             text,
  full_name         text,
  created_at        timestamptz,
  last_sign_in_at   timestamptz,
  email_confirmed   boolean,
  businesses_count  int,
  platform_role     public.platform_role,
  total_count       bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.like_pattern(p_search);
begin
  perform private.require_platform_permission('users.read');

  return query
  select u.id, u.email::text, coalesce(p.phone, u.phone::text), p.full_name, u.created_at, u.last_sign_in_at,
         u.email_confirmed_at is not null,
         (select count(*)::int from public.business_members m where m.user_id = u.id and m.status = 'ACTIVE'),
         a.role,
         count(*) over ()
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join public.platform_admins a on a.user_id = u.id
   where v_pattern is null or u.email ilike v_pattern or p.full_name ilike v_pattern
      or p.phone ilike v_pattern or u.id::text = btrim(p_search)
   order by u.created_at desc, u.id
   limit private.page_limit(p_limit) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create or replace function public.admin_get_user(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user jsonb;
begin
  perform private.require_platform_permission('users.read');

  select jsonb_build_object(
           'id', u.id, 'email', u.email, 'phone', coalesce(p.phone, u.phone::text), 'full_name', p.full_name,
           'locale', p.locale, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
           'email_confirmed', u.email_confirmed_at is not null, 'banned_until', u.banned_until,
           'platform_role', a.role, 'platform_status', a.status)
    into v_user
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join public.platform_admins a on a.user_id = u.id
   where u.id = p_user_id;

  if v_user is null then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
  end if;

  return v_user || jsonb_build_object('memberships', coalesce((
    select jsonb_agg(jsonb_build_object(
             'business_id', b.id, 'business_name', b.name, 'business_status', b.status,
             'role_code', r.code, 'role_name', r.name, 'status', m.status,
             'joined_at', m.joined_at, 'created_at', m.created_at)
           order by m.created_at)
      from public.business_members m
      join public.businesses b on b.id = m.business_id
      join public.roles r on r.id = m.role_id
     where m.user_id = p_user_id), '[]'::jsonb));
end;
$$;

-- =============================================================================
-- RPC — subscriptions and billing
-- =============================================================================
create or replace function public.admin_list_subscriptions(
  p_status                public.subscription_status default null,
  p_plan_code             text default null,
  p_search                text default null,
  p_ending_within_days    int default null,
  p_current_only          boolean default true,
  p_limit                 int default 25,
  p_offset                int default 0
)
returns table (
  id                   uuid,
  business_id          uuid,
  business_name        text,
  business_status      public.business_status,
  plan_code            text,
  plan_name            text,
  price_amount         bigint,
  billing_period       public.billing_period,
  status               public.subscription_status,
  trial_ends_at        timestamptz,
  current_period_start timestamptz,
  current_period_end   timestamptz,
  cancel_at_period_end boolean,
  ended_at             timestamptz,
  external_reference   text,
  created_at           timestamptz,
  total_count          bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.like_pattern(p_search);
begin
  perform private.require_platform_permission('subscriptions.read');

  return query
  select s.id, b.id, b.name, b.status, p.code, p.name, p.price_amount, p.billing_period, s.status,
         s.trial_ends_at, s.current_period_start, s.current_period_end, s.cancel_at_period_end, s.ended_at,
         s.external_reference, s.created_at, count(*) over ()
    from public.subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
    join public.businesses b on b.id = s.business_id
   where (not coalesce(p_current_only, true) or s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE'))
     and (p_status is null or s.status = p_status)
     and (p_plan_code is null or p.code = p_plan_code)
     and (v_pattern is null or b.name ilike v_pattern)
     and (p_ending_within_days is null
          or coalesce(case when s.status = 'TRIALING' then s.trial_ends_at else s.current_period_end end, 'infinity')
             <= now() + make_interval(days => p_ending_within_days))
   order by coalesce(case when s.status = 'TRIALING' then s.trial_ends_at else s.current_period_end end, 'infinity') asc,
            s.id
   limit private.page_limit(p_limit) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- billing_events = payments CONFIRMED by a provider (webhook) or recorded
-- manually by finance. There is no pending / failed payment state in V1.
create or replace function public.admin_list_billing_events(
  p_search   text default null,
  p_provider text default null,
  p_from     date default null,
  p_to       date default null,
  p_limit    int default 25,
  p_offset   int default 0
)
returns table (
  id            uuid,
  provider      text,
  event_id      text,
  business_id   uuid,
  business_name text,
  plan_code     text,
  months        int,
  amount        bigint,
  processed_at  timestamptz,
  total_count   bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.like_pattern(p_search);
begin
  perform private.require_platform_permission('billing.read');

  return query
  select e.id, e.provider, e.event_id, b.id, b.name, e.plan_code, e.months, e.amount, e.processed_at,
         count(*) over ()
    from public.billing_events e
    join public.businesses b on b.id = e.business_id
   where (p_provider is null or e.provider = p_provider)
     and (p_from is null or e.processed_at >= p_from::timestamp at time zone 'Africa/Dakar')
     and (p_to is null or e.processed_at < (p_to + 1)::timestamp at time zone 'Africa/Dakar')
     and (v_pattern is null or b.name ilike v_pattern or e.event_id ilike v_pattern)
   order by e.processed_at desc, e.id
   limit private.page_limit(p_limit) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create index billing_events_processed_at_idx on public.billing_events (processed_at desc);
create index billing_events_business_id_idx on public.billing_events (business_id);

-- Offline payment (cash, bank transfer, invoice) confirmed by the finance team:
-- same activation rules as the webhook (idempotency, amount check, renewal).
create or replace function public.admin_record_manual_payment(
  p_business_id uuid,
  p_plan_code   text,
  p_months      int,
  p_amount      bigint,
  p_reference   text,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform private.require_platform_permission('billing.manage');

  if char_length(btrim(coalesce(p_reference, ''))) not between 3 and 120 then
    raise exception 'REFERENCE_REQUIRED' using errcode = '22023';
  end if;

  v_result := public.platform_activate_subscription('MANUAL', btrim(p_reference), p_business_id, p_plan_code,
                                                     p_months, p_amount);

  if not (v_result ->> 'duplicate')::boolean then
    perform private.log_audit(p_business_id, 'billing.manual_payment', 'subscription',
      (v_result ->> 'subscription_id')::uuid,
      jsonb_build_object('plan', p_plan_code, 'months', p_months, 'amount', p_amount,
                         'reference', btrim(p_reference), 'note', left(nullif(btrim(p_note), ''), 500)));
  end if;
  return v_result;
end;
$$;

-- =============================================================================
-- RPC — audit (whole platform)
-- =============================================================================
create index audit_logs_created_at_idx on public.audit_logs (created_at desc, id desc);
create index audit_logs_actor_id_idx on public.audit_logs (actor_id, created_at desc) where actor_id is not null;

create or replace function public.admin_get_audit_log(
  p_limit         int default 50,
  p_before        timestamptz default null,
  p_before_id     uuid default null,
  p_business_id   uuid default null,
  p_action        text default null,
  p_resource_type text default null,
  p_actor_id      uuid default null,
  p_from          date default null,
  p_to            date default null
)
returns table (
  id            uuid,
  created_at    timestamptz,
  business_id   uuid,
  business_name text,
  action        text,
  resource_type text,
  resource_id   uuid,
  actor_id      uuid,
  actor_name    text,
  actor_email   text,
  actor_role    text,
  metadata      jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('audit.read');

  return query
  select a.id, a.created_at, a.business_id, b.name, a.action, a.resource_type, a.resource_id, a.actor_id,
         p.full_name, u.email::text, a.actor_role, a.metadata
    from public.audit_logs a
    left join public.businesses b on b.id = a.business_id
    left join public.profiles p on p.id = a.actor_id
    left join auth.users u on u.id = a.actor_id
   where (p_before is null or (a.created_at, a.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
     and (p_business_id is null or a.business_id = p_business_id)
     and (p_action is null or a.action = p_action or a.action like p_action || '.%')
     and (p_resource_type is null or a.resource_type = p_resource_type)
     and (p_actor_id is null or a.actor_id = p_actor_id)
     and (p_from is null or a.created_at >= p_from::timestamp at time zone 'Africa/Dakar')
     and (p_to is null or a.created_at < (p_to + 1)::timestamp at time zone 'Africa/Dakar')
   order by a.created_at desc, a.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;

-- =============================================================================
-- RPC — analytics (platform-wide, Dakar days)
-- -----------------------------------------------------------------------------
-- Definitions (docs/business-rules.md §14):
--   MRR       Σ catalog monthly price of current paid subscriptions (ACTIVE /
--             PAST_DUE in good standing); YEARLY plans count price / 12.
--             Custom-priced plans (price 0, e.g. ENTERPRISE) count 0.
--   paying    businesses with such a subscription.  ARPU = MRR / paying.
--   churned   paid subscriptions (external_reference set) that ended in the period.
--   trial_expired  trials that ended in the period without payment.
--   active businesses  businesses with >= 1 completed sale in the period.
--   activation  new businesses of the period with >= 1 completed sale.
--   collected  Σ billing_events.amount processed in the period.
-- Sales amounts are summed for XOF businesses only (single currency in V1).
-- =============================================================================
create or replace function public.admin_get_overview(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from timestamptz;
  v_to   timestamptz;
  v_mrr  bigint;
  v_paying int;
begin
  perform private.require_platform_permission('analytics.read');
  select from_ts, to_ts into v_from, v_to from private.platform_bounds(p_from, p_to);

  select coalesce(sum(case when p.billing_period = 'YEARLY' then p.price_amount / 12 else p.price_amount end), 0),
         count(distinct s.business_id)
    into v_mrr, v_paying
    from public.subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
   where s.status in ('ACTIVE', 'PAST_DUE')
     and s.external_reference is not null
     and (s.current_period_end is null or now() < s.current_period_end + interval '7 days');

  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'businesses', jsonb_build_object(
      'total',     (select count(*) from public.businesses),
      'active',    (select count(*) from public.businesses where status = 'ACTIVE'),
      'suspended', (select count(*) from public.businesses where status = 'SUSPENDED'),
      'new',       (select count(*) from public.businesses where created_at >= v_from and created_at < v_to),
      'with_sales', (select count(distinct business_id) from public.sales
                      where status = 'COMPLETED' and sold_at >= v_from and sold_at < v_to),
      'new_activated', (select count(*) from public.businesses b
                         where b.created_at >= v_from and b.created_at < v_to
                           and exists (select 1 from public.sales s where s.business_id = b.id and s.status = 'COMPLETED'))),
    'users', jsonb_build_object(
      'total',  (select count(*) from auth.users),
      'new',    (select count(*) from auth.users where created_at >= v_from and created_at < v_to),
      'signed_in', (select count(*) from auth.users where last_sign_in_at >= v_from and last_sign_in_at < v_to)),
    'subscriptions', jsonb_build_object(
      'by_status', coalesce((select jsonb_object_agg(status, n) from (
                     select s.status, count(*) n from public.subscriptions s
                      where s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE') group by s.status) x), '{}'::jsonb),
      'by_plan', coalesce((select jsonb_object_agg(code, n) from (
                   select p.code, count(*) n from public.subscriptions s
                     join public.subscription_plans p on p.id = s.plan_id
                    where s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE') group by p.code) x), '{}'::jsonb),
      'churned', (select count(*) from public.subscriptions
                   where ended_at >= v_from and ended_at < v_to and external_reference is not null),
      'trial_expired', (select count(*) from public.subscriptions
                         where ended_at >= v_from and ended_at < v_to and external_reference is null),
      'trials_ending_7d', (select count(*) from public.subscriptions
                            where status = 'TRIALING' and trial_ends_at > now() and trial_ends_at <= now() + interval '7 days')),
    'revenue', jsonb_build_object(
      'mrr', v_mrr,
      'arr', v_mrr * 12,
      'paying_businesses', v_paying,
      'arpu', case when v_paying > 0 then v_mrr / v_paying end,
      'collected', (select coalesce(sum(amount), 0) from public.billing_events
                     where processed_at >= v_from and processed_at < v_to),
      'payments_count', (select count(*) from public.billing_events
                          where processed_at >= v_from and processed_at < v_to)),
    'activity', jsonb_build_object(
      'sales_count', (select count(*) from public.sales
                       where status = 'COMPLETED' and sold_at >= v_from and sold_at < v_to),
      'gmv', (select coalesce(sum(s.total_amount), 0) from public.sales s
                join public.businesses b on b.id = s.business_id and b.currency_code = 'XOF'
               where s.status = 'COMPLETED' and s.sold_at >= v_from and s.sold_at < v_to)));
end;
$$;

create or replace function public.admin_get_timeseries(p_from date, p_to date, p_granularity text default 'day')
returns table (
  bucket          date,
  new_businesses  int,
  new_users       int,
  active_businesses int,
  sales_count     int,
  gmv             bigint,
  collected       bigint,
  payments_count  int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from timestamptz;
  v_to   timestamptz;
begin
  perform private.require_platform_permission('analytics.read');
  if coalesce(p_granularity, 'day') not in ('day', 'week', 'month') then
    raise exception 'INVALID_GRANULARITY' using errcode = '22023';
  end if;
  select from_ts, to_ts into v_from, v_to from private.platform_bounds(p_from, p_to);

  return query
  with buckets as (
    select distinct date_trunc(coalesce(p_granularity, 'day'), d)::date as b
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ),
  sales as (
    select date_trunc(coalesce(p_granularity, 'day'), s.sold_at at time zone 'Africa/Dakar')::date as b,
           count(*)::int as n, count(distinct s.business_id)::int as active,
           coalesce(sum(s.total_amount) filter (where bz.currency_code = 'XOF'), 0)::bigint as gmv
      from public.sales s
      join public.businesses bz on bz.id = s.business_id
     where s.status = 'COMPLETED' and s.sold_at >= v_from and s.sold_at < v_to
     group by 1
  ),
  biz as (
    select date_trunc(coalesce(p_granularity, 'day'), created_at at time zone 'Africa/Dakar')::date as b, count(*)::int as n
      from public.businesses where created_at >= v_from and created_at < v_to group by 1
  ),
  usr as (
    select date_trunc(coalesce(p_granularity, 'day'), created_at at time zone 'Africa/Dakar')::date as b, count(*)::int as n
      from auth.users where created_at >= v_from and created_at < v_to group by 1
  ),
  bill as (
    select date_trunc(coalesce(p_granularity, 'day'), processed_at at time zone 'Africa/Dakar')::date as b,
           sum(amount)::bigint as amount, count(*)::int as n
      from public.billing_events where processed_at >= v_from and processed_at < v_to group by 1
  )
  select bk.b, coalesce(biz.n, 0), coalesce(usr.n, 0), coalesce(sales.active, 0), coalesce(sales.n, 0),
         coalesce(sales.gmv, 0), coalesce(bill.amount, 0), coalesce(bill.n, 0)
    from buckets bk
    left join sales on sales.b = bk.b
    left join biz on biz.b = bk.b
    left join usr on usr.b = bk.b
    left join bill on bill.b = bk.b
   order by bk.b;
end;
$$;

create index businesses_created_at_idx on public.businesses (created_at desc);
create index subscriptions_ended_at_idx on public.subscriptions (ended_at) where ended_at is not null;
create index sales_sold_at_idx on public.sales (sold_at) where status = 'COMPLETED';

-- =============================================================================
-- RPC — platform admins (SUPER_ADMIN only: admins.manage)
-- =============================================================================
create or replace function public.admin_list_admins()
returns table (
  user_id         uuid,
  email           text,
  full_name       text,
  role            public.platform_role,
  status          public.platform_admin_status,
  created_at      timestamptz,
  last_sign_in_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('admins.manage');

  return query
  select a.user_id, u.email::text, p.full_name, a.role, a.status, a.created_at, u.last_sign_in_at
    from public.platform_admins a
    join auth.users u on u.id = a.user_id
    left join public.profiles p on p.id = a.user_id
   order by (a.status = 'ACTIVE') desc, a.created_at;
end;
$$;

-- Grants (or changes) the platform role of an existing account, by e-mail.
create or replace function public.admin_grant_platform_role(p_email text, p_role public.platform_role)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_old  public.platform_role;
begin
  perform private.require_platform_permission('admins.manage');

  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_user = (select auth.uid()) then
    raise exception 'CANNOT_CHANGE_SELF' using errcode = 'P0001';
  end if;

  select role into v_old from public.platform_admins where user_id = v_user for update;

  insert into public.platform_admins (user_id, role, created_by)
  values (v_user, p_role, (select auth.uid()))
  on conflict (user_id) do update set role = excluded.role;

  perform private.log_audit(null, 'platform_admin.grant', 'platform_admin', v_user,
    jsonb_build_object('role', p_role, 'old_role', v_old));
  return v_user;
end;
$$;

create or replace function public.admin_set_admin_status(p_user_id uuid, p_status public.platform_admin_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.platform_admin_status;
begin
  perform private.require_platform_permission('admins.manage');

  if p_user_id = (select auth.uid()) then
    raise exception 'CANNOT_CHANGE_SELF' using errcode = 'P0001';
  end if;

  select status into v_old from public.platform_admins where user_id = p_user_id for update;
  if not found then
    raise exception 'ADMIN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_old = p_status then
    return;
  end if;

  update public.platform_admins set status = p_status where user_id = p_user_id;
  perform private.log_audit(null, 'platform_admin.status_change', 'platform_admin', p_user_id,
    jsonb_build_object('old', v_old, 'new', p_status));
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants: every admin_* RPC checks its platform permission first.
-- -----------------------------------------------------------------------------
revoke all on function
  public.get_my_platform_access(),
  public.admin_list_businesses(text, public.business_status, text, public.subscription_status, date, date, text, int, int),
  public.admin_get_business(uuid),
  public.admin_list_business_members(uuid),
  public.admin_set_business_status(uuid, public.business_status, text),
  public.admin_list_users(text, int, int),
  public.admin_get_user(uuid),
  public.admin_list_subscriptions(public.subscription_status, text, text, int, boolean, int, int),
  public.admin_list_billing_events(text, text, date, date, int, int),
  public.admin_record_manual_payment(uuid, text, int, bigint, text, text),
  public.admin_get_audit_log(int, timestamptz, uuid, uuid, text, text, uuid, date, date),
  public.admin_get_overview(date, date),
  public.admin_get_timeseries(date, date, text),
  public.admin_list_admins(),
  public.admin_grant_platform_role(text, public.platform_role),
  public.admin_set_admin_status(uuid, public.platform_admin_status)
from public, anon;

grant execute on function
  public.get_my_platform_access(),
  public.admin_list_businesses(text, public.business_status, text, public.subscription_status, date, date, text, int, int),
  public.admin_get_business(uuid),
  public.admin_list_business_members(uuid),
  public.admin_set_business_status(uuid, public.business_status, text),
  public.admin_list_users(text, int, int),
  public.admin_get_user(uuid),
  public.admin_list_subscriptions(public.subscription_status, text, text, int, boolean, int, int),
  public.admin_list_billing_events(text, text, date, date, int, int),
  public.admin_record_manual_payment(uuid, text, int, bigint, text, text),
  public.admin_get_audit_log(int, timestamptz, uuid, uuid, text, text, uuid, date, date),
  public.admin_get_overview(date, date),
  public.admin_get_timeseries(date, date, text),
  public.admin_list_admins(),
  public.admin_grant_platform_role(text, public.platform_role),
  public.admin_set_admin_status(uuid, public.platform_admin_status)
to authenticated;
