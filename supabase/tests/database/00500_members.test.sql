-- Membership lifecycle and role-escalation guards.
begin;
select plan(30);

select tests.setup_two_tenants();
select tests.create_user('newbie@test.local');

-- -----------------------------------------------------------------------------
-- Invitations
-- -----------------------------------------------------------------------------
select tests.login('manager_a@test.local');
select throws_ok(format($$ select public.invite_member(%L, 'newbie@test.local', 'CASHIER') $$,
                        tests.business_id('Business A')),
  '42501', 'PERMISSION_DENIED', 'MANAGER cannot invite (no members.manage)');

select tests.login('admin_a@test.local');
select throws_ok(format($$ select public.invite_member(%L, 'newbie@test.local', 'OWNER') $$,
                        tests.business_id('Business A')),
  '42501', 'ROLE_ABOVE_CALLER', 'ADMIN cannot invite an OWNER');
select throws_ok(format($$ select public.invite_member(%L, 'nobody@test.local', 'CASHIER') $$,
                        tests.business_id('Business A')),
  'P0002', 'USER_NOT_FOUND', 'inviting an unknown e-mail fails');
select throws_ok(format($$ select public.invite_member(%L, 'newbie@test.local', 'SUPERUSER') $$,
                        tests.business_id('Business A')),
  'P0002', 'ROLE_NOT_FOUND', 'inviting with an unknown role fails');
select lives_ok(format($$ select public.invite_member(%L, 'NewBie@test.local', 'CASHIER') $$,
                       tests.business_id('Business A')),
  'ADMIN can invite a CASHIER (e-mail match is case-insensitive)');
select throws_ok(format($$ select public.invite_member(%L, 'newbie@test.local', 'CASHIER') $$,
                        tests.business_id('Business A')),
  'P0001', 'ALREADY_MEMBER', 'a user cannot be invited twice');

select tests.login('newbie@test.local');
select is((select count(*)::int from public.businesses), 0, 'an invited user has no access yet');
select is_empty(format($$ select public.get_my_permissions(%L) $$, tests.business_id('Business A')),
  'an invited user has no permission yet');
select is((select business_name from public.list_my_invitations()), 'Business A',
  'the invited user sees the pending invitation');
select lives_ok(format($$ select public.accept_invitation(%L) $$, tests.business_id('Business A')),
  'the invited user can accept');
select is((select count(*)::int from public.businesses), 1, 'after acceptance the business is visible');
select ok('sales.create' = any (array(select public.get_my_permissions(tests.business_id('Business A')))),
  'after acceptance the role permissions apply');
select throws_ok(format($$ select public.accept_invitation(%L) $$, tests.business_id('Business A')),
  'P0002', 'INVITATION_NOT_FOUND', 'an invitation cannot be accepted twice');
select throws_ok(format($$ select public.accept_invitation(%L) $$, tests.business_id('Business B')),
  'P0002', 'INVITATION_NOT_FOUND', 'a user cannot join a business without invitation');

-- -----------------------------------------------------------------------------
-- Role changes and escalation
-- -----------------------------------------------------------------------------
select tests.login('cashier_a@test.local');
select throws_ok(format($$ select public.change_member_role(%L, %L, 'OWNER') $$,
                        tests.business_id('Business A'), tests.get_user_id('cashier_a@test.local')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot promote themselves');
select throws_ok(format($$ update public.business_members set role_id = %L where user_id = auth.uid() $$,
                        (select id from public.roles where code = 'OWNER')),
  '42501', null, 'memberships cannot be updated directly');
select throws_ok(format($$ insert into public.business_members (business_id, user_id, role_id, status, joined_at)
                           values (%L, auth.uid(), %L, 'ACTIVE', now()) $$,
                        tests.business_id('Business B'), (select id from public.roles where code = 'OWNER')),
  '42501', null, 'memberships cannot be inserted directly');

select tests.login('admin_a@test.local');
select throws_ok(format($$ select public.change_member_role(%L, %L, 'MANAGER') $$,
                        tests.business_id('Business A'), tests.get_user_id('admin_a@test.local')),
  '42501', 'CANNOT_MODIFY_SELF', 'nobody can change their own role');
select throws_ok(format($$ select public.change_member_role(%L, %L, 'CASHIER') $$,
                        tests.business_id('Business A'), tests.get_user_id('owner_a@test.local')),
  '42501', 'ROLE_ABOVE_CALLER', 'ADMIN cannot demote the OWNER');
select throws_ok(format($$ select public.set_member_status(%L, %L, 'SUSPENDED') $$,
                        tests.business_id('Business A'), tests.get_user_id('owner_a@test.local')),
  '42501', 'ROLE_ABOVE_CALLER', 'ADMIN cannot suspend the OWNER');
select throws_ok(format($$ select public.remove_member(%L, %L) $$,
                        tests.business_id('Business A'), tests.get_user_id('owner_a@test.local')),
  '42501', 'ROLE_ABOVE_CALLER', 'ADMIN cannot remove the OWNER');
select lives_ok(format($$ select public.change_member_role(%L, %L, 'MANAGER') $$,
                       tests.business_id('Business A'), tests.get_user_id('cashier_a@test.local')),
  'ADMIN can promote a CASHIER to MANAGER');
select lives_ok(format($$ select public.set_member_status(%L, %L, 'SUSPENDED') $$,
                       tests.business_id('Business A'), tests.get_user_id('stock_a@test.local')),
  'ADMIN can suspend a STOCK_MANAGER');
select lives_ok(format($$ select public.remove_member(%L, %L) $$,
                       tests.business_id('Business A'), tests.get_user_id('manager_a@test.local')),
  'ADMIN can remove a MANAGER');

select tests.clear_authentication();
select ok(exists (select 1 from public.audit_logs
                   where business_id = tests.business_id('Business A') and action = 'member.role_change'
                     and metadata ->> 'from' = 'CASHIER' and metadata ->> 'to' = 'MANAGER'
                     and actor_id = tests.get_user_id('admin_a@test.local')),
  'role changes are audited (actor, from, to)');

select tests.login('stock_a@test.local');
select is((select count(*)::int from public.businesses), 0, 'a suspended member loses access');

-- -----------------------------------------------------------------------------
-- Last OWNER protection and ownership transfer
-- -----------------------------------------------------------------------------
select tests.login('owner_a@test.local');
select throws_ok(format($$ select public.leave_business(%L) $$, tests.business_id('Business A')),
  'P0001', 'LAST_OWNER', 'the last OWNER cannot leave');
select lives_ok(format($$ select public.change_member_role(%L, %L, 'OWNER') $$,
                       tests.business_id('Business A'), tests.get_user_id('admin_a@test.local')),
  'an OWNER can promote another member to OWNER');
select lives_ok(format($$ select public.leave_business(%L) $$, tests.business_id('Business A')),
  'once another OWNER exists, the former OWNER can leave');

select tests.clear_authentication();
select throws_ok(format($$ delete from public.business_members where business_id = %L $$,
                        tests.business_id('Business B')),
  'P0001', 'LAST_OWNER', 'the last-owner invariant holds even for privileged roles');

select * from finish();
rollback;
