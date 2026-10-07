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

grant execute on all functions in schema tests to anon, authenticated, service_role;

begin;
select plan(1);
select ok(true, 'test helpers installed');
select * from finish();
rollback;
