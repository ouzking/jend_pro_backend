-- =============================================================================
-- JËND PRO — Subscriptions, plan limits, restricted mode (Phase 11)
-- -----------------------------------------------------------------------------
-- * subscription_plans (global) and subscriptions (per business). Written only
--   by the platform (service_role / Edge Functions after payment). Audited.
-- * Every new business starts with a 14-day PRO trial (backfilled).
-- * Good standing is computed from dates (no cron): trial not ended, or period
--   not ended (+ 7 days grace). Otherwise the business is RESTRICTED:
--   read-only, but the checkout stays open. Enforced in ONE place —
--   private.businesses_with_permission() — through permissions.allowed_when_restricted.
-- * Plan limits (members, products, locations) are enforced by triggers on
--   creation / reactivation; they never block reading or selling.
-- Prices and limits are PROVISIONAL (change them with a migration).
-- =============================================================================

create type public.billing_period as enum ('MONTHLY', 'YEARLY');
create type public.subscription_status as enum ('TRIALING', 'ACTIVE', 'PAST_DUE', 'CANCELLED', 'EXPIRED');

-- -----------------------------------------------------------------------------
-- subscription_plans (global reference data)
-- -----------------------------------------------------------------------------
create table public.subscription_plans (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z][A-Z_]{1,29}$'),
  name           text not null,
  description    text,
  price_amount   bigint not null default 0 check (price_amount >= 0),
  currency_code  char(3) not null default 'XOF',
  billing_period public.billing_period not null default 'MONTHLY',
  -- {"max_members": int|null, "max_products": int|null, "max_locations": int|null}; null = unlimited.
  limits         jsonb not null default '{}'::jsonb check (jsonb_typeof(limits) = 'object'),
  features       jsonb not null default '{}'::jsonb check (jsonb_typeof(features) = 'object'),
  is_public      boolean not null default true,
  sort_order     int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table public.subscription_plans is 'Plan catalog. Managed by migrations only.';

create trigger set_updated_at
  before update on public.subscription_plans
  for each row execute function private.set_updated_at();

insert into public.subscription_plans (code, name, description, price_amount, limits, is_public, sort_order) values
  ('FREE',       'Gratuit',    'Pour démarrer',                 0,     '{"max_members": 2,  "max_products": 100,  "max_locations": 1}',  true,  1),
  ('STARTER',    'Starter',    'Petit commerce',                5000,  '{"max_members": 3,  "max_products": 500,  "max_locations": 1}',  true,  2),
  ('PRO',        'Pro',        'Commerce établi',               10000, '{"max_members": 10, "max_products": 5000, "max_locations": 3}',  true,  3),
  ('BUSINESS',   'Business',   'PME multi-boutiques',           25000, '{"max_members": 30, "max_products": null, "max_locations": 10}', true,  4),
  ('ENTERPRISE', 'Entreprise', 'Sur devis',                     0,     '{"max_members": null, "max_products": null, "max_locations": null}', false, 5);

-- -----------------------------------------------------------------------------
-- subscriptions
-- -----------------------------------------------------------------------------
create table public.subscriptions (
  id                   uuid primary key default gen_random_uuid(),
  business_id          uuid not null references public.businesses (id) on delete cascade,
  plan_id              uuid not null references public.subscription_plans (id),
  status               public.subscription_status not null,
  trial_ends_at        timestamptz,
  current_period_start timestamptz,
  -- NULL = no end (e.g. FREE plan).
  current_period_end   timestamptz,
  cancel_at_period_end boolean not null default false,
  ended_at             timestamptz,
  -- Payment provider reference (Wave / Orange Money / invoice).
  external_reference   text check (char_length(external_reference) <= 120),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint subscriptions_trial_check check (status <> 'TRIALING' or trial_ends_at is not null),
  constraint subscriptions_ended_check check ((status in ('CANCELLED', 'EXPIRED')) = (ended_at is not null))
);

comment on table public.subscriptions is
  'Subscription history per business. At most one current (TRIALING/ACTIVE/PAST_DUE). Written by service_role only.';

create unique index subscriptions_one_current_per_business_key
  on public.subscriptions (business_id) where status in ('TRIALING', 'ACTIVE', 'PAST_DUE');

create trigger set_updated_at
  before update on public.subscriptions
  for each row execute function private.set_updated_at();

create or replace function private.audit_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_audit(new.business_id, 'subscription.change', 'subscription', new.id,
    jsonb_build_object(
      'plan', (select code from public.subscription_plans where id = new.plan_id),
      'status', new.status,
      'old_plan', case when tg_op = 'UPDATE' then (select code from public.subscription_plans where id = old.plan_id) end,
      'old_status', case when tg_op = 'UPDATE' then old.status end,
      'current_period_end', new.current_period_end,
      'trial_ends_at', new.trial_ends_at));
  return null;
end;
$$;

create trigger audit_subscription
  after insert or update on public.subscriptions
  for each row execute function private.audit_subscription();

-- -----------------------------------------------------------------------------
-- Trial on business creation (+ backfill)
-- -----------------------------------------------------------------------------
create or replace function private.start_trial(p_business_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.subscriptions (business_id, plan_id, status, trial_ends_at, current_period_start)
  select p_business_id, p.id, 'TRIALING', now() + interval '14 days', now()
    from public.subscription_plans p
   where p.code = 'PRO'
     and not exists (select 1 from public.subscriptions s where s.business_id = p_business_id);
$$;

create or replace function private.on_business_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.create_default_expense_categories(new.id);
  perform private.start_trial(new.id);
  return null;
end;
$$;

select private.start_trial(id) from public.businesses;

-- -----------------------------------------------------------------------------
-- Good standing / restricted mode
-- -----------------------------------------------------------------------------
create or replace function private.subscription_in_good_standing(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.subscriptions s
     where s.business_id = p_business_id
       and (   (s.status = 'TRIALING' and now() < s.trial_ends_at)
            or (s.status in ('ACTIVE', 'PAST_DUE')
                and (s.current_period_end is null or now() < s.current_period_end + interval '7 days'))));
$$;

alter table public.permissions
  add column allowed_when_restricted boolean not null default false;

comment on column public.permissions.allowed_when_restricted is
  'Still granted when the business subscription is not in good standing (read-only + checkout).';

update public.permissions set allowed_when_restricted = true
 where code like '%.read' or code in ('sales.read_own', 'products.read_cost', 'sales.create', 'sales.credit',
                                      'sales.discount', 'customers.create', 'customers.payments',
                                      'subscription.manage');

-- Central permission resolver: now subscription-aware (signature unchanged,
-- so every existing policy / RPC inherits the rule).
create or replace function private.businesses_with_permission(p_permission text)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.business_id
    from public.business_members m
    join public.businesses b on b.id = m.business_id
    join public.role_permissions rp on rp.role_id = m.role_id
    join public.permissions p on p.code = rp.permission_code
   where m.user_id = (select auth.uid())
     and m.status = 'ACTIVE'
     and b.status = 'ACTIVE'
     and rp.permission_code = p_permission
     and (p.allowed_when_restricted or private.subscription_in_good_standing(m.business_id));
$$;

create or replace function public.get_my_permissions(p_business_id uuid)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select rp.permission_code
    from public.business_members m
    join public.businesses b on b.id = m.business_id
    join public.role_permissions rp on rp.role_id = m.role_id
    join public.permissions p on p.code = rp.permission_code
   where m.business_id = p_business_id
     and m.user_id = (select auth.uid())
     and m.status = 'ACTIVE'
     and b.status = 'ACTIVE'
     and (p.allowed_when_restricted or private.subscription_in_good_standing(m.business_id))
   order by 1;
$$;

-- -----------------------------------------------------------------------------
-- Plan limits
-- -----------------------------------------------------------------------------
create or replace function private.plan_limit(p_business_id uuid, p_limit text)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  -- Current subscription (most recent); no subscription => no limit enforcement here
  -- (restricted mode already blocks writes).
  select (p.limits ->> p_limit)::int
    from public.subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
   where s.business_id = p_business_id
   order by (s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE')) desc, s.created_at desc
   limit 1;
$$;

create or replace function private.enforce_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit_name text := tg_argv[0];
  v_limit      int;
  v_count      int;
begin
  -- Only when a row becomes counted (insert, or reactivation).
  if tg_op = 'UPDATE' and not (
       -- ::text: the status enum type differs per table.
       (tg_table_name = 'business_members' and old.status::text = 'SUSPENDED' and new.status::text = 'ACTIVE')
    or (tg_table_name <> 'business_members' and old.status::text = 'ARCHIVED' and new.status::text = 'ACTIVE')) then
    return new;
  end if;

  v_limit := private.plan_limit(new.business_id, v_limit_name);
  if v_limit is null then
    return new;
  end if;

  -- Serialize concurrent creations for the same business.
  perform 1 from public.businesses where id = new.business_id for update;

  if tg_table_name = 'business_members' then
    select count(*) into v_count from public.business_members
     where business_id = new.business_id and status in ('ACTIVE', 'INVITED');
  elsif tg_table_name = 'products' then
    select count(*) into v_count from public.products where business_id = new.business_id and status = 'ACTIVE';
  else
    select count(*) into v_count from public.locations where business_id = new.business_id and status = 'ACTIVE';
  end if;

  if v_count >= v_limit then
    raise exception 'PLAN_LIMIT_REACHED' using errcode = 'P0001',
      detail = json_build_object('limit', v_limit_name, 'max', v_limit, 'current', v_count)::text;
  end if;
  return new;
end;
$$;

create trigger enforce_plan_limit
  before insert or update of status on public.business_members
  for each row execute function private.enforce_plan_limit('max_members');
create trigger enforce_plan_limit
  before insert or update of status on public.products
  for each row execute function private.enforce_plan_limit('max_products');
create trigger enforce_plan_limit
  before insert or update of status on public.locations
  for each row execute function private.enforce_plan_limit('max_locations');

-- -----------------------------------------------------------------------------
-- Status for the UI (any active member, even when restricted)
-- -----------------------------------------------------------------------------
create or replace function public.get_subscription_status(p_business_id uuid)
returns table (
  plan_code          text,
  plan_name          text,
  status             public.subscription_status,
  trial_ends_at      timestamptz,
  current_period_end timestamptz,
  is_restricted      boolean,
  limits             jsonb,
  usage              jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_member(p_business_id) then
    raise exception 'PERMISSION_DENIED' using errcode = '42501';
  end if;

  return query
  select p.code, p.name, s.status, s.trial_ends_at, s.current_period_end,
         not private.subscription_in_good_standing(p_business_id),
         p.limits,
         jsonb_build_object(
           'members',   (select count(*) from public.business_members m
                          where m.business_id = p_business_id and m.status in ('ACTIVE', 'INVITED')),
           'products',  (select count(*) from public.products x
                          where x.business_id = p_business_id and x.status = 'ACTIVE'),
           'locations', (select count(*) from public.locations l
                          where l.business_id = p_business_id and l.status = 'ACTIVE'))
    from public.subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
   where s.business_id = p_business_id
   order by (s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE')) desc, s.created_at desc
   limit 1;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges + RLS: read-only for clients.
-- -----------------------------------------------------------------------------
alter table public.subscription_plans enable row level security;
alter table public.subscriptions      enable row level security;

grant select on public.subscription_plans, public.subscriptions to authenticated;

create policy "authenticated users can select plans"
  on public.subscription_plans for select to authenticated
  using (true);

create policy "members can select their business subscriptions"
  on public.subscriptions for select to authenticated
  using (business_id in (select private.member_business_ids()));

revoke all on function public.get_subscription_status(uuid) from public, anon;
grant execute on function public.get_subscription_status(uuid) to authenticated;
