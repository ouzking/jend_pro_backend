-- Subscriptions: trial, plan limits, restricted mode (read-only + checkout), grace period.
begin;
select plan(37);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('b', tests.business_id('Business B')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default)),
  ('sub_a', (select id from public.subscriptions where business_id = tests.business_id('Business A')));

with p as (
  insert into public.products (business_id, name, sale_price) values (pg_temp.k('a'), 'Savon', 300) returning id)
insert into ids select 'savon', id from p;
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('savon'), pg_temp.k('a_main'), 'INITIAL', 50);
with c as (insert into public.customers (business_id, name, credit_limit) values (pg_temp.k('a'), 'Client', null) returning id)
insert into ids select 'client', id from c;

-- =============================================================================
-- Trial
-- =============================================================================
select is((select p.code || '/' || s.status from public.subscriptions s join public.subscription_plans p on p.id = s.plan_id
            where s.business_id = pg_temp.k('a')),
  'PRO/TRIALING', 'a new business starts with a PRO trial');
select ok((select trial_ends_at between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour'
             from public.subscriptions where id = pg_temp.k('sub_a')),
  'the trial lasts 14 days');
select ok(private.subscription_in_good_standing(pg_temp.k('a')), 'a trialing business is in good standing');

select tests.login('cashier_a@test.local');
select is((select plan_code || '/' || is_restricted::text || '/' || (usage ->> 'members')
             from public.get_subscription_status(pg_temp.k('a'))),
  'PRO/false/6', 'any member can read the subscription status and usage');
select is((select count(*)::int from public.subscriptions), 1, 'members can read their business subscription');
select throws_ok(format($$ update public.subscriptions set status = 'ACTIVE' where id = %L $$, pg_temp.k('sub_a')),
  '42501', null, 'clients cannot change a subscription');
select throws_ok(format($$ insert into public.subscriptions (business_id, plan_id, status) select %L, id, 'ACTIVE' from public.subscription_plans where code = 'ENTERPRISE' $$,
                        pg_temp.k('a')),
  '42501', null, 'clients cannot grant themselves a plan');

select tests.login('owner_b@test.local');
select is((select count(*)::int from public.subscriptions where business_id = pg_temp.k('a')), 0,
  'B cannot see A subscription');
select throws_ok(format($$ select * from public.get_subscription_status(%L) $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'B cannot read A subscription status');
select tests.clear_authentication();

select ok(exists (select 1 from public.audit_logs where business_id = pg_temp.k('a') and action = 'subscription.change'),
  'subscription creation is audited');

-- =============================================================================
-- Plan limits (tiny test plan)
-- =============================================================================
insert into public.subscription_plans (code, name, limits, is_public)
values ('TEST_TINY', 'Test', '{"max_members": 7, "max_products": 2, "max_locations": 1}', false);
update public.subscriptions set plan_id = (select id from public.subscription_plans where code = 'TEST_TINY')
 where id = pg_temp.k('sub_a');

select tests.login('owner_a@test.local');
select lives_ok(format($$ insert into public.products (business_id, name) values (%L, 'Deuxième') $$, pg_temp.k('a')),
  'creation within the plan limit works');
select throws_ok(format($$ insert into public.products (business_id, name) values (%L, 'Troisième') $$, pg_temp.k('a')),
  'P0001', 'PLAN_LIMIT_REACHED', 'creation beyond max_products is refused');
select lives_ok(format($$ select public.set_product_status(%L, 'ARCHIVED') $$, pg_temp.k('savon')),
  'archiving frees a slot');
select lives_ok(format($$ insert into public.products (business_id, name) values (%L, 'Troisième') $$, pg_temp.k('a')),
  '... which can be reused');
select throws_ok(format($$ select public.set_product_status(%L, 'ACTIVE') $$, pg_temp.k('savon')),
  'P0001', 'PLAN_LIMIT_REACHED', 'reactivation beyond the limit is refused');
select throws_ok(format($$ insert into public.locations (business_id, name) values (%L, 'Boutique 2') $$, pg_temp.k('a')),
  'P0001', 'PLAN_LIMIT_REACHED', 'creation beyond max_locations is refused');
select tests.create_user('extra1@test.local');
select tests.create_user('extra2@test.local');
select tests.login('owner_a@test.local');
select lives_ok(format($$ select public.invite_member(%L, 'extra1@test.local', 'CASHIER') $$, pg_temp.k('a')),
  'inviting within max_members works (pending invitations count)');
select throws_ok(format($$ select public.invite_member(%L, 'extra2@test.local', 'CASHIER') $$, pg_temp.k('a')),
  'P0001', 'PLAN_LIMIT_REACHED', 'inviting beyond max_members is refused');

select tests.clear_authentication();
update public.subscriptions set plan_id = (select id from public.subscription_plans where code = 'PRO')
 where id = pg_temp.k('sub_a');
update public.products set status = 'ACTIVE' where id = pg_temp.k('savon');

-- =============================================================================
-- Restricted mode: trial over
-- =============================================================================
update public.subscriptions set trial_ends_at = now() - interval '1 day' where id = pg_temp.k('sub_a');
select ok(not private.subscription_in_good_standing(pg_temp.k('a')), 'an ended trial is not in good standing');

select tests.login('cashier_a@test.local');
select ok((select is_restricted from public.get_subscription_status(pg_temp.k('a'))), 'the UI can see the restricted state');
select lives_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[{"method":"CASH","amount":600}]') $$,
                       pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('savon'), 'quantity', 2))),
  'restricted: the checkout stays open (cash sale)');
select lives_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[]', %L) $$,
                       pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('savon'), 'quantity', 1)),
                       pg_temp.k('client')),
  'restricted: credit sales still work');
select lives_ok(format($$ select public.record_customer_payment(%L, 300, 'CASH', %L) $$, pg_temp.k('client'), pg_temp.k('a_main')),
  'restricted: debt settlements still work');
select ok((select count(*) from public.products) > 0, 'restricted: data stays readable');

select tests.login('stock_a@test.local');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'ADJUSTMENT', 1, 'x') $$,
                        pg_temp.k('a'), pg_temp.k('savon'), pg_temp.k('a_main')),
  '42501', 'PERMISSION_DENIED', 'restricted: stock adjustments are blocked');
select throws_ok(format($$ insert into public.products (business_id, name) values (%L, 'Nouveau') $$, pg_temp.k('a')),
  '42501', null, 'restricted: product creation is blocked');

select tests.login('owner_a@test.local');
select ok('sales.create' = any (array(select public.get_my_permissions(pg_temp.k('a'))))
          and not ('inventory.adjust' = any (array(select public.get_my_permissions(pg_temp.k('a')))))
          and 'subscription.manage' = any (array(select public.get_my_permissions(pg_temp.k('a')))),
  'restricted: get_my_permissions keeps reads/checkout/subscription and drops the rest');
update public.businesses set name = 'Renamed' where id = pg_temp.k('a');
select throws_ok(format($$ select public.invite_member(%L, 'extra2@test.local', 'CASHIER') $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'restricted: member management is blocked');
select tests.clear_authentication();
select is((select name from public.businesses where id = pg_temp.k('a')), 'Business A', 'restricted: settings are read-only');

select tests.login('owner_b@test.local');
select lives_ok(format($$ insert into public.products (business_id, name) values (%L, 'Produit B') $$, pg_temp.k('b')),
  'another business in good standing is not affected');
select tests.clear_authentication();

-- =============================================================================
-- Paid period, grace, expiry
-- =============================================================================
update public.subscriptions set status = 'ACTIVE', current_period_start = now(), current_period_end = now() + interval '30 days'
 where id = pg_temp.k('sub_a');
select tests.login('stock_a@test.local');
select lives_ok(format($$ select public.adjust_stock(%L, %L, %L, 'ADJUSTMENT', 1, 'x') $$,
                       pg_temp.k('a'), pg_temp.k('savon'), pg_temp.k('a_main')),
  'after payment (ACTIVE), writes are allowed again');
select tests.clear_authentication();

update public.subscriptions set status = 'PAST_DUE', current_period_end = now() - interval '3 days' where id = pg_temp.k('sub_a');
select ok(private.subscription_in_good_standing(pg_temp.k('a')), 'PAST_DUE within the 7-day grace period is still in good standing');
update public.subscriptions set current_period_end = now() - interval '8 days' where id = pg_temp.k('sub_a');
select ok(not private.subscription_in_good_standing(pg_temp.k('a')), 'beyond the grace period the business is restricted');
update public.subscriptions set status = 'EXPIRED', ended_at = now() where id = pg_temp.k('sub_a');
select ok(not private.subscription_in_good_standing(pg_temp.k('a')), 'an EXPIRED subscription is restricted');
select throws_ok(format($$ update public.subscriptions set status = 'ACTIVE' where id = %L $$, pg_temp.k('sub_a')),
  '23514', null, 'status and ended_at must stay consistent (a running subscription has no end date)');

select is((select count(*)::int from public.audit_logs where resource_id = pg_temp.k('sub_a') and action = 'subscription.change') >= 5,
  true, 'every subscription change is audited');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.subscription_plans $$, '42501', null, 'anon cannot read plans');
select tests.clear_authentication();

select * from finish();
rollback;
