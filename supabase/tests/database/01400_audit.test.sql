-- Audit: coverage of new events, actor role, immutability, journal API.
begin;
select plan(21);

select tests.setup_two_tenants();
update public.profiles set full_name = 'Awa Admin' where id = tests.get_user_id('admin_a@test.local');

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated, service_role;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on all functions in schema pg_temp to authenticated, service_role;
insert into ids values ('a', tests.business_id('Business A')), ('b', tests.business_id('Business B'));

-- =============================================================================
-- New events
-- =============================================================================
select tests.login('admin_a@test.local');
with l as (insert into public.locations (business_id, name) values (pg_temp.k('a'), 'Boutique Thiès') returning id)
insert into ids select 'loc', id from l;
update public.locations set name = 'Boutique Thiès Centre' where id = pg_temp.k('loc');
update public.locations set status = 'ARCHIVED' where id = pg_temp.k('loc');

with c as (insert into public.customers (business_id, name) values (pg_temp.k('a'), 'Client') returning id)
insert into ids select 'cust', id from c;
update public.customers set status = 'ARCHIVED' where id = pg_temp.k('cust');
update public.customers set phone = '770000000' where id = pg_temp.k('cust');

with s as (insert into public.suppliers (business_id, name) values (pg_temp.k('a'), 'Fournisseur') returning id)
insert into ids select 'sup', id from s;
update public.suppliers set status = 'ARCHIVED' where id = pg_temp.k('sup');

with p as (insert into public.products (business_id, name, sale_price) values (pg_temp.k('a'), 'Thé Ataya', 1000) returning id)
insert into ids select 'prod', id from p;
select tests.clear_authentication();

select is((select string_agg(action, ',' order by action) from public.audit_logs where resource_id = pg_temp.k('loc')),
  'location.create,location.status_change,location.update', 'location creation, rename and archiving are audited');
select is((select metadata -> 'changes' -> 'name' ->> 'new' from public.audit_logs
            where resource_id = pg_temp.k('loc') and action = 'location.update'),
  'Boutique Thiès Centre', 'a location change records old/new values');
select is((select string_agg(action, ',') from public.audit_logs where resource_id = pg_temp.k('cust')),
  'customer.status_change', 'customer archiving is audited (contact edits are not)');
select is((select action from public.audit_logs where resource_id = pg_temp.k('sup')),
  'supplier.status_change', 'supplier archiving is audited');
select is((select metadata -> 'new' ->> 'name' from public.audit_logs where resource_id = pg_temp.k('prod') and action = 'product.create'),
  'Thé Ataya', 'product creation is audited');
select is((select actor_role || '/' || (actor_id = tests.get_user_id('admin_a@test.local'))::text
             from public.audit_logs where resource_id = pg_temp.k('prod') and action = 'product.create'),
  'authenticated/true', 'user actions record the actor and the authenticated role');

-- Platform action (service_role, e.g. payment webhook): no actor, role recorded.
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
update public.subscriptions set status = 'ACTIVE', current_period_end = now() + interval '30 days'
 where business_id = pg_temp.k('a');
reset role;
select set_config('request.jwt.claims', '', true);
select is((select coalesce(actor_id::text, 'null') || '/' || actor_role from public.audit_logs
            where business_id = pg_temp.k('a') and action = 'subscription.change' and metadata ->> 'status' = 'ACTIVE'),
  'null/service_role', 'platform actions are attributed to service_role');

-- =============================================================================
-- get_audit_log
-- =============================================================================
select tests.login('owner_a@test.local');
select ok((select count(*) from public.get_audit_log(pg_temp.k('a'))) >= 10, 'OWNER can read the journal');
select is((select actor_name from public.get_audit_log(pg_temp.k('a'), 1, null, null, 'product.create')),
  'Awa Admin', 'entries carry the actor name');
select is((select count(*)::int from public.get_audit_log(pg_temp.k('a'), 50, null, null, 'location') where action not like 'location.%'), 0,
  'action filter accepts a prefix (location.*)');
select ok((select count(*) from public.get_audit_log(pg_temp.k('a'), 50, null, null, 'location')) >= 4,
  'prefix filter returns all location events (incl. the default location)');
select is((select count(*)::int from public.get_audit_log(pg_temp.k('a'), 50, null, null, null, null, pg_temp.k('loc'))), 3,
  'resource filter returns the history of one resource');

select is((select count(*)::int from public.get_audit_log(pg_temp.k('a'), 3)), 3, 'limit is applied');
select is((with p1 as (select * from public.get_audit_log(pg_temp.k('a'), 3)),
                last as (select created_at, id from p1 order by created_at, id limit 1)
           select count(*)::int from public.get_audit_log(pg_temp.k('a'), 3, (select created_at from last), (select id from last)) x
            where x.id in (select id from p1)), 0,
  'keyset pagination returns the next page without overlap');
select is((select count(*)::int from public.get_audit_log(pg_temp.k('a'), 0)), 1, 'limit is clamped to at least 1');

select tests.login('manager_a@test.local');
select throws_ok(format($$ select * from public.get_audit_log(%L) $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'MANAGER (no audit.read) cannot read the journal');
select tests.login('owner_b@test.local');
select throws_ok(format($$ select * from public.get_audit_log(%L) $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'B cannot read A journal');
select throws_ok($$ select private.log_audit(null, 'fake.event', 'x', null) $$,
  '42501', null, 'clients cannot write audit entries');
select tests.clear_authentication();

-- =============================================================================
-- Immutability
-- =============================================================================
select throws_ok($$ update public.audit_logs set action = 'tampered.event' $$, 'P0001', 'APPEND_ONLY',
  'audit entries cannot be modified, even by privileged roles');
select throws_ok(format($$ delete from public.audit_logs where business_id = %L $$, pg_temp.k('a')), 'P0001', 'APPEND_ONLY',
  'audit entries cannot be deleted, even by privileged roles');

set local jendpro.allow_audit_purge = 'on';
select lives_ok(format($$ delete from public.audit_logs where business_id = %L and action = 'business.update' $$, pg_temp.k('a')),
  'an explicit platform purge is possible');
set local jendpro.allow_audit_purge = 'off';

select * from finish();
rollback;
