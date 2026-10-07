-- Platform: billing activation (service_role only, idempotent), daily maintenance job.
begin;
select plan(25);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select on ids to authenticated, service_role;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
create function pg_temp.sub(text) returns public.subscriptions language sql as
  $$ select * from public.subscriptions where business_id = pg_temp.k($1) and status in ('TRIALING', 'ACTIVE', 'PAST_DUE') $$;
grant execute on all functions in schema pg_temp to authenticated, service_role;
insert into ids values ('a', tests.business_id('Business A')), ('b', tests.business_id('Business B'));

-- Runs a statement as the service_role (what the Edge Function uses).
create function pg_temp.as_service(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
  execute p_sql into v;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return v;
end $$;

-- =============================================================================
-- Access
-- =============================================================================
select tests.login('owner_a@test.local');
select throws_ok(format($$ select public.platform_activate_subscription('test', 'evt-x', %L, 'ENTERPRISE', 12, 0) $$, pg_temp.k('a')),
  '42501', null, 'a business owner cannot activate a subscription themselves');
select throws_ok($$ select count(*) from public.billing_events $$, '42501', null, 'billing events are not readable by users');
select tests.clear_authentication();

-- =============================================================================
-- Activation
-- =============================================================================
select is(pg_temp.as_service(format($$ select public.platform_activate_subscription('wave', 'evt-1', %L, 'PRO', 1, 10000) $$, pg_temp.k('a'))) ->> 'duplicate',
  'false', 'service_role can activate a paid subscription');
select is((select p.code || '/' || s.status from public.subscriptions s join public.subscription_plans p on p.id = s.plan_id
            where s.id = (pg_temp.sub('a')).id), 'PRO/ACTIVE', 'the trial becomes an ACTIVE PRO subscription');
select ok(((pg_temp.sub('a')).current_period_end - now()) between interval '27 days' and interval '32 days',
  'the paid period lasts one month');
create temp table end1 as select (pg_temp.sub('a')).current_period_end e;

select is(pg_temp.as_service(format($$ select public.platform_activate_subscription('wave', 'evt-1', %L, 'PRO', 1, 10000) $$, pg_temp.k('a'))) ->> 'duplicate',
  'true', 'the same payment event is ignored the second time');
select is((pg_temp.sub('a')).current_period_end, (select e from end1), '... and does not extend the period twice');
select is((select count(*)::int from public.billing_events where business_id = pg_temp.k('a')), 1, 'one billing event recorded');

select lives_ok(format($$ select pg_temp.as_service('select public.platform_activate_subscription(''wave'', ''evt-2'', ''%s'', ''PRO'', 1, 10000)') $$, pg_temp.k('a')),
  'a renewal is processed');
select ok((pg_temp.sub('a')).current_period_end > (select e from end1) + interval '27 days',
  'a renewal of the same plan extends from the current end date');

select throws_ok(format($$ select pg_temp.as_service('select public.platform_activate_subscription(''wave'', ''evt-3'', ''%s'', ''PRO'', 2, 10000)') $$, pg_temp.k('a')),
  'P0001', 'AMOUNT_MISMATCH', 'an amount below plan price x months is refused');
select throws_ok(format($$ select pg_temp.as_service('select public.platform_activate_subscription(''wave'', ''evt-4'', ''%s'', ''GOLD'', 1, 10000)') $$, pg_temp.k('a')),
  'P0002', 'PLAN_NOT_FOUND', 'unknown plans are refused');
select throws_ok(format($$ select pg_temp.as_service('select public.platform_activate_subscription(''wave'', ''evt-5'', ''%s'', ''PRO'', 0, 0)') $$, pg_temp.k('a')),
  '22023', 'INVALID_PERIOD', 'the period must be 1 to 36 months');
select throws_ok($$ select pg_temp.as_service('select public.platform_activate_subscription(''wave'', ''evt-6'', ''00000000-0000-0000-0000-000000000000'', ''PRO'', 1, 10000)') $$,
  'P0002', 'BUSINESS_NOT_FOUND', 'unknown businesses are refused');

select lives_ok(format($$ select pg_temp.as_service('select public.platform_activate_subscription(''orange_money'', ''evt-7'', ''%s'', ''BUSINESS'', 1, 25000)') $$, pg_temp.k('a')),
  'a plan change is processed');
select is((select p.code from public.subscription_plans p where p.id = (pg_temp.sub('a')).plan_id), 'BUSINESS',
  'the plan is changed');
select is((select actor_role from public.audit_logs where business_id = pg_temp.k('a') and action = 'subscription.change'
            and metadata ->> 'plan' = 'BUSINESS'), 'service_role', 'activations are audited as platform actions');

-- Restricted business recovers after payment.
update public.subscriptions set trial_ends_at = now() - interval '1 day' where business_id = pg_temp.k('b');
select ok(not private.subscription_in_good_standing(pg_temp.k('b')), 'B is restricted after its trial');
select pg_temp.as_service(format($$ select public.platform_activate_subscription('wave', 'evt-b1', %L, 'STARTER', 1, 5000) $$, pg_temp.k('b')));
select ok(private.subscription_in_good_standing(pg_temp.k('b')), 'B is back in good standing after payment');

-- =============================================================================
-- Daily maintenance
-- =============================================================================
select tests.create_user('trial@test.local');
insert into ids values ('c', tests.create_business_as('trial@test.local', 'Business C'));
update public.subscriptions set trial_ends_at = now() + interval '2 days' where business_id = pg_temp.k('c');
select private.daily_maintenance();
select is((select count(*)::int from public.notifications where business_id = pg_temp.k('c') and data ->> 'kind' = 'TRIAL_ENDING'), 1,
  'owners get a reminder 3 days before the trial ends');
select private.daily_maintenance();
select is((select count(*)::int from public.notifications where business_id = pg_temp.k('c') and data ->> 'kind' = 'TRIAL_ENDING'), 1,
  'the reminder is sent only once');

update public.subscriptions set trial_ends_at = now() - interval '1 minute' where business_id = pg_temp.k('c');
select private.daily_maintenance();
select is((select status from public.subscriptions where business_id = pg_temp.k('c')), 'EXPIRED'::public.subscription_status,
  'an ended trial becomes EXPIRED');
select ok(exists (select 1 from public.notifications where business_id = pg_temp.k('c') and title = 'Abonnement expiré'),
  'owners are notified of the expiry');

insert into public.notifications (business_id, user_id, type, title, read_at, created_at)
values (pg_temp.k('c'), tests.get_user_id('trial@test.local'), 'SYSTEM', 'old', now() - interval '100 days', now() - interval '100 days');
select is((private.daily_maintenance() ->> 'notifications_purged')::int, 1, 'old read notifications are purged');

select is((select schedule from cron.job where jobname = 'jendpro-daily-maintenance'), '0 6 * * *',
  'the maintenance job is scheduled daily at 06:00 UTC (Dakar time)');

select * from finish();
rollback;
