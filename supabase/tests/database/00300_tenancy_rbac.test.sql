-- Business creation, RBAC seed and permission resolution.
begin;
select plan(24);

select tests.setup_two_tenants();

-- -----------------------------------------------------------------------------
-- create_business
-- -----------------------------------------------------------------------------
select is((select count(*)::int from public.locations
            where business_id = tests.business_id('Business A') and is_default),
  1, 'create_business creates exactly one default location');

select is((select r.code from public.business_members m join public.roles r on r.id = m.role_id
            where m.business_id = tests.business_id('Business A')
              and m.user_id = tests.get_user_id('owner_a@test.local')),
  'OWNER', 'creator becomes OWNER');

select is((select status from public.business_members
            where business_id = tests.business_id('Business A')
              and user_id = tests.get_user_id('owner_a@test.local')),
  'ACTIVE'::public.member_status, 'creator membership is ACTIVE');

select is((select created_by from public.businesses where id = tests.business_id('Business A')),
  tests.get_user_id('owner_a@test.local'), 'created_by is set server-side');

select ok(exists (select 1 from public.audit_logs
                   where business_id = tests.business_id('Business A')
                     and action = 'business.create'
                     and actor_id = tests.get_user_id('owner_a@test.local')),
  'business creation is audited with the actor');

select tests.authenticate_as_anon();
select throws_ok($$ select public.create_business('Anon shop') $$, '42501', null,
  'anon cannot create a business');
select tests.clear_authentication();

select throws_ok($$ select public.create_business('No session') $$, '42501', 'NOT_AUTHENTICATED',
  'create_business requires a signed-in user');

select tests.login('outsider@test.local');
select throws_ok($$ select public.create_business(' ') $$, '23514', null,
  'business name is validated');
do $$ begin for i in 1..10 loop perform public.create_business('Shop ' || i); end loop; end $$;
select throws_ok($$ select public.create_business('Shop 11') $$, 'P0001', 'BUSINESS_LIMIT_REACHED',
  'a user cannot own more than 10 businesses');
select tests.clear_authentication();

-- -----------------------------------------------------------------------------
-- RBAC seed
-- -----------------------------------------------------------------------------
select set_eq($$ select code from public.roles where business_id is null $$,
  array['OWNER', 'ADMIN', 'MANAGER', 'CASHIER', 'STOCK_MANAGER'],
  'the five system roles exist');

select is((select count(*) from public.role_permissions rp join public.roles r on r.id = rp.role_id
            where r.code = 'OWNER' and r.business_id is null),
  (select count(*) from public.permissions), 'OWNER has every permission');

-- -----------------------------------------------------------------------------
-- get_my_permissions: spot checks of the matrix
-- -----------------------------------------------------------------------------
select tests.login('admin_a@test.local');
select ok(not ('subscription.manage' = any (array(select public.get_my_permissions(tests.business_id('Business A'))))),
  'ADMIN does not have subscription.manage');
select ok('members.manage' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'ADMIN has members.manage');

select tests.login('manager_a@test.local');
select ok(not ('members.manage' = any (array(select public.get_my_permissions(tests.business_id('Business A'))))),
  'MANAGER does not have members.manage');
select ok('sales.cancel' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'MANAGER has sales.cancel');

select tests.login('cashier_a@test.local');
select ok('sales.create' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'CASHIER has sales.create');
select ok('sales.credit' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'CASHIER has sales.credit');
select ok(not ('sales.cancel' = any (array(select public.get_my_permissions(tests.business_id('Business A'))))),
  'CASHIER does not have sales.cancel');
select ok(not ('products.read_cost' = any (array(select public.get_my_permissions(tests.business_id('Business A'))))),
  'CASHIER cannot see costs');

select tests.login('stock_a@test.local');
select ok(not ('sales.create' = any (array(select public.get_my_permissions(tests.business_id('Business A'))))),
  'STOCK_MANAGER cannot sell');
select ok('purchases.receive' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'STOCK_MANAGER can receive purchases');

-- Same user, different role per business.
select tests.login('multi@test.local');
select ok('sales.cancel' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'multi-business user is MANAGER in A');
select ok(not ('sales.cancel' = any (array(select public.get_my_permissions(tests.business_id('Business B'))))),
  'multi-business user is only CASHIER in B');

-- -----------------------------------------------------------------------------
-- Timezone validation
-- -----------------------------------------------------------------------------
select tests.login('owner_a@test.local');
select throws_ok(format($$ update public.businesses set timezone = 'Mars/Olympus' where id = %L $$,
                        tests.business_id('Business A')),
  '22023', 'INVALID_TIMEZONE', 'invalid timezone is rejected');
select tests.clear_authentication();

select * from finish();
rollback;
