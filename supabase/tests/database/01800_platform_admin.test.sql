-- Platform back-office (Phase 16): platform RBAC, cross-tenant reads, business
-- suspension, manual payments, analytics, platform audit, admin management.
begin;
select plan(56);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into ids values ('a', tests.business_id('Business A')), ('b', tests.business_id('Business B'));

-- Platform staff, one per role.
select tests.create_user(e) from unnest(array['super@jendpro.test', 'ops@jendpro.test', 'support@jendpro.test',
  'finance@jendpro.test', 'analyst@jendpro.test']) e;
insert into public.platform_admins (user_id, role) values
  (tests.get_user_id('super@jendpro.test'),   'SUPER_ADMIN'),
  (tests.get_user_id('ops@jendpro.test'),     'OPERATIONS'),
  (tests.get_user_id('support@jendpro.test'), 'SUPPORT'),
  (tests.get_user_id('finance@jendpro.test'), 'FINANCE'),
  (tests.get_user_id('analyst@jendpro.test'), 'ANALYST');

-- =============================================================================
-- Access
-- =============================================================================
select tests.login('outsider@test.local');
select is((select count(*)::int from public.get_my_platform_access()), 0, 'a regular user has no platform access');
select throws_ok($$ select * from public.admin_list_businesses() $$, '42501', 'PERMISSION_DENIED',
  'a regular user cannot list businesses');
select is((select count(*)::int from public.platform_admins), 0, 'a regular user cannot see platform admins');
select throws_ok($$ insert into public.platform_admins (user_id, role) values (auth.uid(), 'SUPER_ADMIN') $$, '42501', null,
  'nobody can grant themselves platform access');

select tests.login('owner_a@test.local');
select throws_ok($$ select public.admin_get_business(pg_temp.k('a')) $$, '42501', 'PERMISSION_DENIED',
  'a business owner cannot use the back-office, even on their own business');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.admin_list_businesses() $$, '42501', null, 'anon cannot call admin RPCs');
select tests.clear_authentication();

select tests.login_mfa('super@jendpro.test');
select is((select role::text from public.get_my_platform_access()), 'SUPER_ADMIN', 'staff read their own platform role');
select ok((select 'admins.manage' = any (permissions) from public.get_my_platform_access()),
  'a super admin holds admins.manage');
select is((select count(*)::int from public.platform_permissions), 13, 'staff can read the platform permission catalog');

select tests.login_mfa('support@jendpro.test');
select throws_ok($$ select public.admin_get_overview(current_date - 6, current_date) $$, '42501', 'PERMISSION_DENIED',
  'SUPPORT has no analytics access');
select ok((select not ('admins.manage' = any (permissions)) from public.get_my_platform_access()),
  'SUPPORT cannot manage admins');

select tests.login_mfa('analyst@jendpro.test');
select throws_ok($$ select * from public.admin_list_users() $$, '42501', 'PERMISSION_DENIED', 'ANALYST cannot list users');
select tests.clear_authentication();

-- =============================================================================
-- Businesses
-- =============================================================================
select tests.login_mfa('analyst@jendpro.test');
select is((select count(*)::int from public.admin_list_businesses(p_search => 'Business ')), 2,
  'staff see businesses of every tenant');
select is((select max(total_count)::int from public.admin_list_businesses(p_search => 'Business ', p_limit => 1)), 2,
  'total_count reports the full match count when paginating');
select is((select count(*)::int from public.admin_list_businesses(p_search => 'Business ', p_limit => 1)), 1,
  'the page size is applied');
select is((select owner_email from public.admin_list_businesses(p_search => 'Business A')), 'owner_a@test.local',
  'the owner of each business is resolved');
select is((select plan_code || '/' || subscription_status from public.admin_list_businesses(p_search => 'Business B')),
  'PRO/TRIALING', 'the current subscription is shown');
select is((select count(*)::int from public.admin_list_businesses(p_search => 'Business ', p_plan_code => 'STARTER')), 0,
  'the plan filter applies');
select throws_ok($$ select * from public.admin_list_businesses(p_sort => 'drop table') $$, '22023', 'INVALID_SORT',
  'unknown sort keys are refused');
select is((public.admin_get_business(pg_temp.k('a')) -> 'counts' ->> 'members')::int, 6, 'business detail: member count');
select throws_ok($$ select public.admin_get_business(gen_random_uuid()) $$, 'P0002', 'BUSINESS_NOT_FOUND',
  'unknown business');
select is((select count(*)::int from public.admin_list_business_members(pg_temp.k('a'))), 6,
  'staff can list the members of any business');
select tests.clear_authentication();

-- =============================================================================
-- Suspension
-- =============================================================================
select tests.login_mfa('support@jendpro.test');
select throws_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'SUSPENDED', 'Fraude suspectée') $$,
  '42501', 'PERMISSION_DENIED', 'SUPPORT cannot suspend a business');

select tests.login_mfa('ops@jendpro.test');
select throws_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'SUSPENDED', ' ') $$,
  '22023', 'REASON_REQUIRED', 'a reason is required');
select lives_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'SUSPENDED', 'Fraude suspectée') $$,
  'OPERATIONS can suspend a business');
select tests.clear_authentication();

select is((select status::text from public.businesses where id = pg_temp.k('a')), 'SUSPENDED', 'the business is suspended');
select is((select metadata ->> 'reason' from public.audit_logs
            where business_id = pg_temp.k('a') and action = 'business.status_change'), 'Fraude suspectée',
  'the suspension is audited with its reason');

select tests.login('owner_a@test.local');
select is((select count(*)::int from public.businesses where id = pg_temp.k('a')), 0,
  'members of a suspended business lose access immediately');
select is((select count(*)::int from public.notifications where data ->> 'kind' = 'BUSINESS_STATUS'), 1,
  'the owner is notified of the suspension');

select tests.login_mfa('ops@jendpro.test');
select lives_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'ACTIVE', 'Vérification terminée') $$,
  'the business can be reactivated');
select tests.login('owner_a@test.local');
select is((select count(*)::int from public.businesses where id = pg_temp.k('a')), 1, 'access is restored');
select tests.clear_authentication();

-- =============================================================================
-- Users
-- =============================================================================
select tests.login_mfa('support@jendpro.test');
select is((select businesses_count from public.admin_list_users(p_search => 'multi@test')), 2,
  'users are listed with their number of businesses');
select is(jsonb_array_length(public.admin_get_user(tests.get_user_id('multi@test.local')) -> 'memberships'), 2,
  'user detail lists every membership');
select is((select platform_role::text from public.admin_list_users(p_search => 'super@jendpro')), 'SUPER_ADMIN',
  'staff accounts are flagged');
select is((select count(*)::int from public.admin_list_users(p_search => '%')), 0,
  'LIKE wildcards in the search are escaped');
select tests.clear_authentication();

-- =============================================================================
-- Subscriptions and manual payments
-- =============================================================================
select tests.login_mfa('support@jendpro.test');
select is((select status::text from public.admin_list_subscriptions(p_search => 'Business A')), 'TRIALING',
  'staff list current subscriptions');
select throws_ok($$ select public.admin_record_manual_payment(pg_temp.k('a'), 'PRO', 1, 10000, 'VIR-001') $$,
  '42501', 'PERMISSION_DENIED', 'SUPPORT cannot record a payment');

select tests.login_mfa('finance@jendpro.test');
select throws_ok($$ select public.admin_record_manual_payment(pg_temp.k('a'), 'PRO', 1, 10000, ' ') $$,
  '22023', 'REFERENCE_REQUIRED', 'a payment reference is required');
select throws_ok($$ select public.admin_record_manual_payment(pg_temp.k('a'), 'PRO', 1, 5000, 'VIR-001') $$,
  'P0001', 'AMOUNT_MISMATCH', 'the amount must cover the plan price (same rule as the webhook)');
select is(public.admin_record_manual_payment(pg_temp.k('a'), 'PRO', 1, 10000, 'VIR-001', 'Virement CBAO') ->> 'duplicate',
  'false', 'FINANCE records an offline payment');
select is(public.admin_record_manual_payment(pg_temp.k('a'), 'PRO', 1, 10000, 'VIR-001') ->> 'duplicate',
  'true', 'the same reference is processed once');
select is((select status::text from public.admin_list_subscriptions(p_search => 'Business A')), 'ACTIVE',
  'the subscription becomes ACTIVE');
select is((select provider || ':' || amount from public.admin_list_billing_events(p_search => 'Business A')), 'MANUAL:10000',
  'the payment appears in the billing history');
select tests.clear_authentication();

select is((select count(*)::int from public.audit_logs where action = 'billing.manual_payment' and business_id = pg_temp.k('a')
            and actor_id = tests.get_user_id('finance@jendpro.test')), 1, 'manual payments are audited with their author');

-- =============================================================================
-- Analytics
-- =============================================================================
select tests.login_mfa('analyst@jendpro.test');
select is((public.admin_get_overview(current_date - 6, current_date) -> 'revenue' ->> 'mrr')::bigint, 10000::bigint,
  'MRR counts current paid subscriptions at catalog price');
select ok((public.admin_get_overview(current_date - 6, current_date) -> 'businesses' ->> 'new')::int >= 2,
  'new businesses of the period are counted');
select throws_ok($$ select public.admin_get_overview(current_date, current_date - 1) $$, '22023', 'INVALID_DATE_RANGE',
  'inverted ranges are refused');
select is((select count(*)::int from public.admin_get_timeseries(current_date - 6, current_date, 'day')), 7,
  'the time series has one bucket per day');
select throws_ok($$ select * from public.admin_get_timeseries(current_date - 6, current_date, 'hour') $$, '22023',
  'INVALID_GRANULARITY', 'unknown granularity');
select tests.clear_authentication();

-- =============================================================================
-- Platform audit
-- =============================================================================
select tests.login_mfa('finance@jendpro.test');
select is((select count(distinct business_name)::int from public.admin_get_audit_log(p_limit => 200)
            where business_name in ('Business A', 'Business B')), 2, 'the platform journal spans every tenant');
select tests.clear_authentication();

-- =============================================================================
-- Admin management
-- =============================================================================
select tests.login_mfa('ops@jendpro.test');
select throws_ok($$ select * from public.admin_list_admins() $$, '42501', 'PERMISSION_DENIED',
  'only super admins manage platform staff');

select tests.login_mfa('super@jendpro.test');
select throws_ok($$ select public.admin_grant_platform_role('super@jendpro.test', 'ANALYST') $$, 'P0001', 'CANNOT_CHANGE_SELF',
  'a super admin cannot change their own role');
select lives_ok($$ select public.admin_grant_platform_role('OUTSIDER@test.local', 'SUPPORT') $$,
  'a super admin grants a platform role by e-mail');
select lives_ok($$ select public.admin_set_admin_status(tests.get_user_id('support@jendpro.test'), 'SUSPENDED') $$,
  'a super admin suspends a staff member');
select tests.login_mfa('support@jendpro.test');
select throws_ok($$ select * from public.admin_list_users() $$, '42501', 'PERMISSION_DENIED',
  'a suspended staff member loses every permission');
select tests.clear_authentication();

select throws_ok($$ update public.platform_admins set status = 'SUSPENDED' where role = 'SUPER_ADMIN' $$,
  'P0001', 'LAST_SUPER_ADMIN', 'the platform always keeps one active super admin');

select * from finish();
rollback;
