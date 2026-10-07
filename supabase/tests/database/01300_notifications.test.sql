-- Notifications: server-generated events, recipients, own-only access, Realtime.
begin;
select plan(25);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
create function pg_temp.notif_count(text, text) returns int language sql as
  $$ select count(*)::int from public.notifications where user_id = tests.get_user_id($1) and type::text = $2 $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default));

with p as (
  insert into public.products (business_id, name, unit, sale_price, min_stock_level)
  values (pg_temp.k('a'), 'Lait en poudre', 'boîte', 2500, 5) returning id)
insert into ids select 'lait', id from p;
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('lait'), pg_temp.k('a_main'), 'INITIAL', 8);

-- =============================================================================
-- LOW_STOCK
-- =============================================================================
select tests.login('cashier_a@test.local');
select public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('lait'), 'quantity', 2)),
  '[{"method":"CASH","amount":5000}]');
select tests.clear_authentication();
select is(pg_temp.notif_count('stock_a@test.local', 'LOW_STOCK'), 0, 'no alert while stock stays above the threshold (8 -> 6)');

select tests.login('cashier_a@test.local');
select public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('lait'), 'quantity', 2)),
  '[{"method":"CASH","amount":5000}]');
select tests.clear_authentication();
select is(pg_temp.notif_count('stock_a@test.local', 'LOW_STOCK'), 1, 'crossing the threshold (6 -> 4) alerts the stock manager');
select is((select title from public.notifications where user_id = tests.get_user_id('stock_a@test.local') and type = 'LOW_STOCK'),
  'Stock faible : Lait en poudre', 'the alert names the product');
select is((select (data ->> 'quantity')::numeric from public.notifications
            where user_id = tests.get_user_id('stock_a@test.local') and type = 'LOW_STOCK'), 4.000,
  'the alert carries the remaining quantity');
select set_eq($$ select u.email::text from public.notifications n join auth.users u on u.id = n.user_id where n.type = 'LOW_STOCK' $$,
  array['owner_a@test.local', 'admin_a@test.local', 'manager_a@test.local', 'stock_a@test.local', 'multi@test.local'],
  'every active member with inventory.adjust is alerted (not the cashier, not B)');

select tests.login('cashier_a@test.local');
select public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('lait'), 'quantity', 1)),
  '[{"method":"CASH","amount":2500}]');
select tests.clear_authentication();
select is(pg_temp.notif_count('stock_a@test.local', 'LOW_STOCK'), 1, 'no repeated alert while stock stays low (4 -> 3)');

select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('lait'), pg_temp.k('a_main'), 'ADJUSTMENT', 10, null, 'adjustment', null, null, 'réassort');
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('lait'), pg_temp.k('a_main'), 'LOSS', -9, null, 'adjustment', null, null, 'casse');
select is(pg_temp.notif_count('stock_a@test.local', 'LOW_STOCK'), 2, 'after restocking, a new crossing alerts again (13 -> 4)');

-- =============================================================================
-- LARGE_SALE
-- =============================================================================
update public.businesses set large_sale_threshold = 10000 where id = pg_temp.k('a');
select tests.login('cashier_a@test.local');
select public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('lait'), 'quantity', 3)),
  '[{"method":"CASH","amount":7500}]');
select tests.clear_authentication();
select is(pg_temp.notif_count('owner_a@test.local', 'LARGE_SALE'), 0, 'sales below the threshold do not notify');

select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('lait'), pg_temp.k('a_main'), 'ADJUSTMENT', 20, null, 'adjustment', null, null, 'réassort');
select tests.login('cashier_a@test.local');
select public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.k('lait'), 'quantity', 4)),
  '[{"method":"CASH","amount":10000}]');
select tests.clear_authentication();
select is(pg_temp.notif_count('owner_a@test.local', 'LARGE_SALE'), 1, 'a sale at or above the threshold notifies the owner');
select is(pg_temp.notif_count('cashier_a@test.local', 'LARGE_SALE'), 0, 'the cashier (no reports.read) is not notified');
select is(pg_temp.notif_count('stock_a@test.local', 'LARGE_SALE'), 0, 'the stock manager (no reports.read) is not notified');

-- =============================================================================
-- MEMBER_INVITED
-- =============================================================================
select tests.create_user('newbie@test.local');
select tests.login('admin_a@test.local');
select public.invite_member(pg_temp.k('a'), 'newbie@test.local', 'CASHIER');
select tests.clear_authentication();
select is((select title from public.notifications where user_id = tests.get_user_id('newbie@test.local')),
  'Invitation : Business A', 'the invitee is notified (even before joining)');

-- =============================================================================
-- SUBSCRIPTION
-- =============================================================================
update public.subscriptions set status = 'PAST_DUE', current_period_end = now()
 where business_id = pg_temp.k('a');
select is(pg_temp.notif_count('owner_a@test.local', 'SUBSCRIPTION'), 1, 'payment issues notify the owner (subscription.manage)');
select is(pg_temp.notif_count('admin_a@test.local', 'SUBSCRIPTION'), 0, 'ADMIN (no subscription.manage) is not notified');

-- =============================================================================
-- Access: own notifications only
-- =============================================================================
select tests.login('stock_a@test.local');
select is((select count(*)::int from public.notifications), 2, 'a user sees only their own notifications');
select lives_ok($$ update public.notifications set read_at = now() where id = (select id from public.notifications order by id limit 1) $$,
  'a user can mark a notification as read');
select throws_ok($$ update public.notifications set title = 'hacked' $$, '42501', null, 'only read_at is writable');
select throws_ok(format($$ insert into public.notifications (business_id, user_id, type, title) values (%L, %L, 'SYSTEM', 'fake') $$,
                        pg_temp.k('a'), tests.get_user_id('owner_a@test.local')),
  '42501', null, 'clients cannot create notifications (no spoofing)');
select is(public.mark_all_notifications_read(pg_temp.k('a')), 1, 'mark_all_notifications_read marks the remaining unread ones');

select tests.login('owner_a@test.local');
update public.notifications set read_at = now() where user_id = tests.get_user_id('stock_a@test.local');
delete from public.notifications where user_id = tests.get_user_id('stock_a@test.local');
select tests.clear_authentication();
select is(pg_temp.notif_count('stock_a@test.local', 'LOW_STOCK'), 2, 'nobody can delete another user''s notifications');

select tests.login('stock_a@test.local');
select lives_ok($$ delete from public.notifications where type = 'LOW_STOCK' $$, 'a user can delete their own notifications');
select tests.clear_authentication();
select is(pg_temp.notif_count('stock_a@test.local', 'LOW_STOCK'), 0, '... and they are gone');

select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'notifications'),
  'notifications are published to Realtime');
select is((select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'), 1,
  'no other public table is published to Realtime');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.notifications $$, '42501', null, 'anon cannot read notifications');
select tests.clear_authentication();

select * from finish();
rollback;
