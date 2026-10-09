-- Platform MFA (Phase 17): aal2 for sensitive permissions, and for everything
-- once a staff member enrolled a second factor.
begin;
select plan(16);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into ids values ('a', tests.business_id('Business A'));

select tests.create_user(e) from unnest(array['ops@jendpro.test', 'support@jendpro.test']) e;
insert into public.platform_admins (user_id, role) values
  (tests.get_user_id('ops@jendpro.test'), 'OPERATIONS'),
  (tests.get_user_id('support@jendpro.test'), 'SUPPORT');

select tests.login('owner_a@test.local');
insert into ids select 't', public.create_support_ticket('Question', 'Bonjour', pg_temp.k('a'));
select tests.clear_authentication();

select set_eq($$ select code from public.platform_permissions where requires_mfa $$,
  array['admins.manage', 'announcements.manage', 'billing.manage', 'businesses.manage'],
  'the sensitive permissions are exactly the reviewed ones');

-- =============================================================================
-- Staff without a second factor
-- =============================================================================
select tests.login('ops@jendpro.test');
select lives_ok($$ select * from public.admin_list_businesses() $$, 'without MFA, a password session reads (non-sensitive)');
select throws_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'SUSPENDED', 'Contrôle') $$, '42501', 'MFA_REQUIRED',
  'a sensitive action requires a verified second factor');
select is((select aal || '/' || mfa_enrolled from public.get_my_platform_access()), 'aal1/false', 'the UI learns the session level');
select ok((select 'businesses.manage' = any (mfa_permissions) from public.get_my_platform_access()), 'the UI learns which permissions need MFA');
select ok((select 'businesses.manage' = any (permissions) from public.get_my_platform_access()), 'role permissions are still listed (MFA is a separate condition)');

select tests.login_mfa('ops@jendpro.test');
select lives_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'SUSPENDED', 'Contrôle') $$, 'an aal2 session can perform it');
select lives_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'ACTIVE', 'Contrôle terminé') $$, '... and revert it');

select tests.login_mfa('support@jendpro.test');
select throws_ok($$ select public.admin_set_business_status(pg_temp.k('a'), 'SUSPENDED', 'Contrôle') $$, '42501', 'PERMISSION_DENIED',
  'MFA never grants what the role does not');

select tests.login_mfa('owner_a@test.local');
select throws_ok($$ select * from public.admin_list_businesses() $$, '42501', 'PERMISSION_DENIED', 'nor does it turn a merchant into staff');
select tests.clear_authentication();

-- =============================================================================
-- Staff with an enrolled second factor: no password-only access at all
-- =============================================================================
select tests.add_verified_totp('ops@jendpro.test');

select tests.login('ops@jendpro.test');
select throws_ok($$ select * from public.admin_list_businesses() $$, '42501', 'MFA_REQUIRED',
  'once enrolled, a password-only session reads nothing');
select is((select count(*)::int from public.support_tickets where id = pg_temp.k('t')), 0,
  'staff RLS policies apply the same rule');
select is((select mfa_enrolled from public.get_my_platform_access()), true, 'the UI knows a challenge is needed');

select tests.login_mfa('ops@jendpro.test');
select lives_ok($$ select * from public.admin_list_businesses() $$, 'after the TOTP check, access is restored');
select is((select count(*)::int from public.support_tickets where id = pg_temp.k('t')), 1, '... including through RLS');
select is((select aal from public.get_my_platform_access()), 'aal2', 'the session level is reported');
select tests.clear_authentication();

select * from finish();
rollback;
