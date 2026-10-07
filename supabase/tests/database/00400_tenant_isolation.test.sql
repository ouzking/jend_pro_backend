-- Tenant isolation: every cross-tenant read/write path must fail.
-- Fixture: tests.setup_two_tenants() (Business A with every role, Business B).
begin;
select plan(34);

select tests.setup_two_tenants();

-- Some audit activity in B, to prove it stays invisible to A.
select tests.login('owner_b@test.local');
update public.businesses set city = 'Thiès' where id = tests.business_id('Business B');
select tests.clear_authentication();

-- =============================================================================
-- OWNER of A probing B
-- =============================================================================
select tests.login('owner_a@test.local');

select is((select count(*)::int from public.businesses), 1, 'owner A sees exactly one business');
select is((select id from public.businesses), tests.business_id('Business A'), '... and it is A');
select is_empty(format($$ select 1 from public.locations where business_id = %L $$, tests.business_id('Business B')),
  'owner A cannot read B locations');
select is_empty(format($$ select 1 from public.business_members where business_id = %L $$, tests.business_id('Business B')),
  'owner A cannot read B memberships');
select is_empty(format($$ select 1 from public.audit_logs where business_id = %L $$, tests.business_id('Business B')),
  'owner A cannot read B audit logs');
select is_empty(format($$ select public.get_my_permissions(%L) $$, tests.business_id('Business B')),
  'owner A has no permission in B');

update public.businesses set name = 'pwned' where id = tests.business_id('Business B');
update public.locations set name = 'pwned' where business_id = tests.business_id('Business B');

select throws_ok(format($$ insert into public.locations (business_id, name) values (%L, 'Intrusion') $$,
                        tests.business_id('Business B')),
  '42501', null, 'owner A cannot create a location in B');
select throws_ok(format($$ update public.locations set business_id = %L $$, tests.business_id('Business B')),
  '42501', null, 'business_id of a location is not updatable (cannot move rows across tenants)');
select throws_ok(format($$ select * from public.list_business_members(%L) $$, tests.business_id('Business B')),
  '42501', 'PERMISSION_DENIED', 'owner A cannot list B members');
select throws_ok(format($$ select public.invite_member(%L, 'outsider@test.local', 'CASHIER') $$,
                        tests.business_id('Business B')),
  '42501', 'PERMISSION_DENIED', 'owner A cannot invite into B');
select throws_ok(format($$ select public.change_member_role(%L, %L, 'CASHIER') $$,
                        tests.business_id('Business B'), tests.get_user_id('owner_b@test.local')),
  '42501', 'PERMISSION_DENIED', 'owner A cannot change roles in B');
select throws_ok(format($$ select public.remove_member(%L, %L) $$,
                        tests.business_id('Business B'), tests.get_user_id('owner_b@test.local')),
  '42501', 'PERMISSION_DENIED', 'owner A cannot remove B members');
select throws_ok($$ insert into public.businesses (name) values ('Direct insert') $$,
  '42501', null, 'businesses cannot be inserted directly (RPC only)');
select throws_ok($$ delete from public.businesses $$,
  '42501', null, 'businesses cannot be deleted by clients');
select throws_ok($$ insert into public.roles (code, name, is_system) values ('GOD', 'God', true) $$,
  '42501', null, 'roles cannot be created by clients');
select throws_ok(format($$ insert into public.role_permissions (role_id, permission_code)
                           select id, 'subscription.manage' from public.roles where code = 'CASHIER' $$),
  '42501', null, 'role permissions cannot be altered by clients');
select throws_ok($$ insert into public.audit_logs (action, resource_type) values ('fake.entry', 'x') $$,
  '42501', null, 'audit logs cannot be forged by clients');

select tests.clear_authentication();
select is((select name from public.businesses where id = tests.business_id('Business B')),
  'Business B', 'cross-tenant business update had no effect');
select is_empty(format($$ select 1 from public.locations where business_id = %L and name = 'pwned' $$,
                       tests.business_id('Business B')),
  'cross-tenant location update had no effect');

-- =============================================================================
-- Roles inside A
-- =============================================================================
select tests.login('cashier_a@test.local');
update public.businesses set name = 'Cashier rename' where id = tests.business_id('Business A');
select throws_ok(format($$ insert into public.locations (business_id, name) values (%L, 'Dépôt') $$,
                        tests.business_id('Business A')),
  '42501', null, 'CASHIER cannot create locations');
select is((select count(*)::int from public.business_members), 1,
  'CASHIER only sees their own membership (no members.read)');
select is((select count(*)::int from public.audit_logs), 0, 'CASHIER cannot read the audit log');
select is((select count(*)::int from public.list_business_members(tests.business_id('Business A'))), 6,
  'CASHIER can see the directory of active co-workers');
select is((select count(*)::int from public.list_business_members(tests.business_id('Business A')) where email is not null), 0,
  '... without their contact details');

select tests.login('manager_a@test.local');
update public.businesses set name = 'Manager rename' where id = tests.business_id('Business A');

select tests.clear_authentication();
select is((select name from public.businesses where id = tests.business_id('Business A')),
  'Business A', 'CASHIER and MANAGER cannot change business settings');

select tests.login('admin_a@test.local');
select lives_ok(format($$ update public.businesses set allow_negative_stock = true where id = %L $$,
                       tests.business_id('Business A')),
  'ADMIN can change business settings');
select lives_ok(format($$ insert into public.locations (business_id, name, type) values (%L, 'Dépôt Pikine', 'WAREHOUSE') $$,
                       tests.business_id('Business A')),
  'ADMIN can create a location');
select ok(exists (select 1 from public.audit_logs
                   where business_id = tests.business_id('Business A') and action = 'business.update'
                     and metadata -> 'changes' ? 'allow_negative_stock'),
  'settings change is audited with the changed field');

-- =============================================================================
-- Multi-business user, outsider, anon
-- =============================================================================
select tests.login('multi@test.local');
select is((select count(*)::int from public.businesses), 2, 'a user member of A and B sees both');

select tests.login('outsider@test.local');
select is((select count(*)::int from public.businesses) + (select count(*)::int from public.locations)
          + (select count(*)::int from public.business_members) + (select count(*)::int from public.audit_logs),
  0, 'a user without business sees no tenant data');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.businesses $$, '42501', null, 'anon cannot read businesses');
select throws_ok($$ select * from public.roles $$, '42501', null, 'anon cannot read roles');

-- =============================================================================
-- Suspensions
-- =============================================================================
select tests.clear_authentication();
update public.business_members set status = 'SUSPENDED'
 where business_id = tests.business_id('Business A') and user_id = tests.get_user_id('multi@test.local');
select tests.login('multi@test.local');
select is((select id from public.businesses), tests.business_id('Business B'),
  'a suspended member immediately loses access to that business only');

select tests.clear_authentication();
update public.businesses set status = 'SUSPENDED' where id = tests.business_id('Business B');
select tests.login('owner_b@test.local');
select is((select count(*)::int from public.businesses), 0,
  'members of a suspended business lose access');

select tests.clear_authentication();
select * from finish();
rollback;
