-- =============================================================================
-- Test helpers — installed into the LOCAL test database only.
-- -----------------------------------------------------------------------------
-- `supabase test db` runs files in alphabetical order. The statements below run
-- outside any transaction so the `tests` schema persists for the following
-- files. They are idempotent and are NEVER part of a migration, so they never
-- reach staging/production.
--
-- Usage in a test file:
--   select tests.create_user('alice@test.local');
--   select tests.authenticate_as(tests.get_user_id('alice@test.local'));
--   ... assertions run as `authenticated` with auth.uid() = alice ...
--   select tests.authenticate_as_anon();
--   select tests.clear_authentication();   -- back to postgres
-- =============================================================================

create extension if not exists pgtap with schema extensions;

create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Creates a confirmed e-mail user in auth.users and returns its id.
create or replace function tests.create_user(p_email text, p_full_name text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    p_email, '', now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', coalesce(p_full_name, split_part(p_email, '@', 1))),
    now(), now()
  );
  return v_id;
end;
$$;

-- Returns the id of a test user by e-mail (raises if missing).
create or replace function tests.get_user_id(p_email text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  if v_id is null then
    raise exception 'tests.get_user_id: no user with email %', p_email;
  end if;
  return v_id;
end;
$$;

-- Impersonates a user exactly as PostgREST does: role `authenticated` + JWT claims.
-- Scoped to the current transaction (set local).
create or replace function tests.authenticate_as(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end;
$$;

create or replace function tests.authenticate_as_anon()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end;
$$;

create or replace function tests.clear_authentication()
returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- Tenancy fixtures
-- -----------------------------------------------------------------------------
-- Creates a business through the real RPC, as the given user (who becomes OWNER).
-- Leaves the session unauthenticated (postgres) afterwards.
create or replace function tests.create_business_as(p_email text, p_name text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  perform tests.authenticate_as(tests.get_user_id(p_email));
  v_id := public.create_business(p_name);
  perform tests.clear_authentication();
  return v_id;
end;
$$;

-- Adds an ACTIVE member directly (fixture shortcut, bypasses the invitation flow).
create or replace function tests.add_member(p_business_id uuid, p_email text, p_role_code text)
returns uuid
language sql
security definer
set search_path = ''
as $$
  insert into public.business_members (business_id, user_id, role_id, status, joined_at)
  select p_business_id, tests.get_user_id(p_email), r.id, 'ACTIVE', now()
    from public.roles r
   where r.business_id is null and r.code = p_role_code
  returning id;
$$;

-- Standard two-tenant fixture used by security tests:
--   Business A: owner_a, admin_a, manager_a, cashier_a, stock_a, multi (MANAGER)
--   Business B: owner_b, multi (CASHIER)
--   outsider: no business
create or replace function tests.setup_two_tenants()
returns void
language plpgsql
as $$
declare
  v_a uuid;
  v_b uuid;
begin
  perform tests.create_user(e) from unnest(array[
    'owner_a@test.local', 'admin_a@test.local', 'manager_a@test.local',
    'cashier_a@test.local', 'stock_a@test.local',
    'owner_b@test.local', 'multi@test.local', 'outsider@test.local']) e;

  v_a := tests.create_business_as('owner_a@test.local', 'Business A');
  v_b := tests.create_business_as('owner_b@test.local', 'Business B');

  perform tests.add_member(v_a, 'admin_a@test.local',   'ADMIN');
  perform tests.add_member(v_a, 'manager_a@test.local', 'MANAGER');
  perform tests.add_member(v_a, 'cashier_a@test.local', 'CASHIER');
  perform tests.add_member(v_a, 'stock_a@test.local',   'STOCK_MANAGER');
  perform tests.add_member(v_a, 'multi@test.local',     'MANAGER');
  perform tests.add_member(v_b, 'multi@test.local',     'CASHIER');
end;
$$;

create or replace function tests.business_id(p_name text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.businesses where name = p_name;
$$;

-- Shorthand: authenticate by e-mail.
create or replace function tests.login(p_email text)
returns void
language sql
as $$
  select tests.authenticate_as(tests.get_user_id(p_email));
$$;

-- Same as login, with an aal2 session (second factor verified, as after a TOTP check).
create or replace function tests.login_mfa(p_email text)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.get_user_id(p_email), 'role', 'authenticated', 'aal', 'aal2')::text, true);
  execute 'set local role authenticated';
end;
$$;

-- Marks a user as having a verified TOTP factor (fixture; the real flow goes through Auth).
create or replace function tests.add_verified_totp(p_email text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at, secret)
  values (gen_random_uuid(), tests.get_user_id(p_email), 'test', 'totp', 'verified', now(), now(), 'JBSWY3DPEHPK3PXP');
$$;

grant execute on all functions in schema tests to anon, authenticated, service_role;

begin;
select plan(1);
select ok(true, 'test helpers installed');
select * from finish();
rollback;
