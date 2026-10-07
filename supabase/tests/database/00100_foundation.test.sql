-- Foundation: schema isolation, default privileges, global security invariants.
-- The "global invariant" assertions (RLS everywhere, nothing for anon) are
-- re-evaluated on every run, so they also guard all future migrations.
begin;
select plan(13);

-- -----------------------------------------------------------------------------
-- Global invariants (must hold for every table/function ever added)
-- -----------------------------------------------------------------------------
select is_empty(
  $$ select c.relname
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'p')
        and not c.relrowsecurity $$,
  'every table in public has RLS enabled'
);

select is_empty(
  $$ select table_name, privilege_type
       from information_schema.role_table_grants
      where grantee = 'anon' and table_schema = 'public' $$,
  'anon has no privilege on any public table'
);

select is_empty(
  $$ select n.nspname || '.' || p.proname
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private')
        and has_function_privilege('anon', p.oid, 'EXECUTE') $$,
  'anon cannot execute any function in public/private'
);

select is_empty(
  $$ select n.nspname || '.' || p.proname
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private')
        and p.prosecdef
        and not exists (
          select 1 from unnest(coalesce(p.proconfig, '{}')) cfg
           where cfg like 'search_path=%') $$,
  'every SECURITY DEFINER function pins its search_path'
);

-- -----------------------------------------------------------------------------
-- Schema `private`
-- -----------------------------------------------------------------------------
select has_schema('private', 'schema private exists');
select ok(not has_schema_privilege('anon', 'private', 'USAGE'),
  'anon has no USAGE on private');

-- -----------------------------------------------------------------------------
-- Default privileges apply to future objects
-- -----------------------------------------------------------------------------
create table public.__privilege_probe (id int);
select ok(not has_table_privilege('anon', 'public.__privilege_probe', 'SELECT'),
  'new table: anon gets no default privilege');
select ok(not has_table_privilege('authenticated', 'public.__privilege_probe', 'SELECT'),
  'new table: authenticated gets no default privilege');
select ok(has_table_privilege('service_role', 'public.__privilege_probe', 'SELECT'),
  'new table: service_role keeps its default privileges');

create function public.__privilege_probe_fn() returns int language sql as 'select 1';
select ok(not has_function_privilege('anon', 'public.__privilege_probe_fn()', 'EXECUTE'),
  'new function: anon gets no default EXECUTE');
select ok(not has_function_privilege('authenticated', 'public.__privilege_probe_fn()', 'EXECUTE'),
  'new function: authenticated gets no default EXECUTE');

-- -----------------------------------------------------------------------------
-- private.set_updated_at()
-- -----------------------------------------------------------------------------
create temp table updated_at_probe (id int, updated_at timestamptz not null);
create trigger set_updated_at before update on updated_at_probe
  for each row execute function private.set_updated_at();
insert into updated_at_probe values (1, '2000-01-01');
update updated_at_probe set id = 2;
select is((select updated_at from updated_at_probe), now(),
  'set_updated_at sets updated_at to the transaction timestamp');

-- -----------------------------------------------------------------------------
-- Test harness: impersonation behaves like PostgREST
-- -----------------------------------------------------------------------------
select tests.create_user('foundation@test.local');
select tests.authenticate_as(tests.get_user_id('foundation@test.local'));
select is(auth.uid(), tests.get_user_id('foundation@test.local'),
  'tests.authenticate_as sets auth.uid()');
select tests.clear_authentication();

select * from finish();
rollback;
