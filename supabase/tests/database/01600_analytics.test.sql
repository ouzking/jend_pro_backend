-- Analytics RPCs: exact figures on a hand-computed dataset, margin visibility,
-- timezone, validation, permissions.
begin;
select plan(25);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
create function pg_temp.item(text, numeric) returns jsonb language sql as
  $$ select jsonb_build_object('product_id', pg_temp.k($1), 'quantity', $2) $$;
-- Moves a sale and all its payments to a given UTC timestamp.
create function pg_temp.at(text, timestamptz) returns void language sql as $$
  update public.sales set sold_at = $2 where id = pg_temp.k($1);
  update public.payments set paid_at = $2 where sale_id = pg_temp.k($1);
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default));
with l as (insert into public.locations (business_id, name) values (pg_temp.k('a'), 'Boutique 2') returning id)
insert into ids select 'a_2', id from l;
with p as (
  insert into public.products (business_id, name, unit, sale_price, allows_fractional_quantity)
  values (pg_temp.k('a'), 'Riz', 'kg', 500, true), (pg_temp.k('a'), 'Huile', 'bouteille', 1500, false)
  returning id, name)
insert into ids select lower(name), id from p;
update public.product_costs set cost_price = 400 where product_id = pg_temp.k('riz');
update public.product_costs set cost_price = 1000 where product_id = pg_temp.k('huile');
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), 'INITIAL', 1000);
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('huile'), pg_temp.k('a_main'), 'INITIAL', 1000);
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('huile'), pg_temp.k('a_2'), 'INITIAL', 10);
with c as (insert into public.customers (business_id, name, credit_limit) values (pg_temp.k('a'), 'Client', null) returning id)
insert into ids select 'client', id from c;

-- Dataset (Africa/Dakar = UTC):
--  S1 2026-09-01 riz 10            = 5 000 cash          margin 1 000
--  S2 2026-09-01 huile 2           = 3 000 (2 000 cash + 1 000 credit)  margin 1 000
--  S3 2026-09-02 huile 1           = 1 500 cash          margin   500
--  S4 2026-09-02 riz 2             = 1 000 cash, CANCELLED (refund 1 000)
--  S5 2026-09-03 huile 2 - 500     = 2 500 cash (manager, global discount)  margin 500
--  S6 2026-09-03 huile 1 @ Boutique 2 = 1 500 cash      margin   500
--  Expense 2026-09-02: 2 000
select tests.login('cashier_a@test.local');
insert into ids select 's1', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('riz', 10)), '[{"method":"CASH","amount":5000}]');
insert into ids select 's2', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('huile', 2)), '[{"method":"CASH","amount":2000}]', pg_temp.k('client'));
insert into ids select 's3', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('huile', 1)), '[{"method":"CASH","amount":1500}]');
insert into ids select 's4', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('riz', 2)), '[{"method":"CASH","amount":1000}]');
insert into ids select 's6', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_2'),
  jsonb_build_array(pg_temp.item('huile', 1)), '[{"method":"WAVE","amount":1500}]');
select tests.login('manager_a@test.local');
insert into ids select 's5', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('huile', 2)), '[{"method":"CASH","amount":2500}]', null, 500);
select public.cancel_sale(pg_temp.k('s4'), 'erreur');
insert into public.expenses (business_id, category_id, amount, spent_on)
values (pg_temp.k('a'), (select id from public.expense_categories where business_id = pg_temp.k('a') and name = 'Loyer'), 2000, '2026-09-02');
select tests.clear_authentication();

-- Back-dating the fixture requires lifting the append-only guard on payments
-- (test transaction only, rolled back).
alter table public.payments disable trigger prevent_update;
select pg_temp.at('s1', '2026-09-01 10:00+00'), pg_temp.at('s2', '2026-09-01 11:00+00'),
       pg_temp.at('s3', '2026-09-02 10:00+00'), pg_temp.at('s4', '2026-09-02 11:00+00'),
       pg_temp.at('s5', '2026-09-03 10:00+00'), pg_temp.at('s6', '2026-09-03 12:00+00');

-- =============================================================================
-- Summary
-- =============================================================================
select tests.login('owner_a@test.local');
create temp table summary as select public.get_dashboard_summary(pg_temp.k('a'), '2026-09-01', '2026-09-03') s;

select is((select (s ->> 'revenue')::bigint from summary), 13500::bigint, 'revenue excludes cancelled sales (5000+3000+1500+2500+1500)');
select is((select (s ->> 'sales_count')::int from summary), 5, 'completed sales are counted');
select is((select (s ->> 'average_basket')::bigint from summary), 2700::bigint, 'average basket = revenue / sales');
select is((select (s ->> 'estimated_margin')::bigint from summary), 3500::bigint,
  'estimated margin = line margins - global discounts (1000+1000+500+500+500)');
select is((select (s ->> 'discounts')::bigint || '/' || (s ->> 'credit_given') || '/' || (s ->> 'cancelled_count')
             || '/' || (s ->> 'active_customers') from summary), '500/1000/1/1',
  'discounts, credit given, cancellations and active customers');
select is((select (s ->> 'cash_in') || '/' || (s ->> 'cash_out') || '/' || (s ->> 'expenses') || '/' || (s ->> 'net_cash_flow') from summary),
  '13500/1000/2000/10500', 'cash flow = payments IN - payments OUT - expenses');
select is((select (s ->> 'customers_debt')::bigint from summary), 1000::bigint, 'outstanding customer debt');

select is((select (public.get_dashboard_summary(pg_temp.k('a'), '2026-09-01', '2026-09-03', pg_temp.k('a_2')) ->> 'revenue')::bigint),
  1500::bigint, 'figures can be filtered by location');
select is((select (public.get_dashboard_summary(pg_temp.k('a'), '2026-09-02', '2026-09-02') ->> 'revenue')::bigint),
  1500::bigint, 'single-day range');

-- =============================================================================
-- Time series and best sellers
-- =============================================================================
select results_eq(
  format($$ select period, revenue, sales_count, estimated_margin from public.get_sales_timeseries(%L, '2026-08-31', '2026-09-04') $$, pg_temp.k('a')),
  $$ values ('2026-08-31'::date, 0::bigint, 0, 0::bigint), ('2026-09-01', 8000, 2, 2000), ('2026-09-02', 1500, 1, 500),
            ('2026-09-03', 4000, 2, 1000), ('2026-09-04', 0, 0, 0) $$,
  'daily series with empty days filled with zeros');
select results_eq(
  format($$ select period, revenue from public.get_sales_timeseries(%L, '2026-09-01', '2026-09-30', 'month') $$, pg_temp.k('a')),
  $$ values ('2026-09-01'::date, 13500::bigint) $$, 'monthly series');
select results_eq(
  format($$ select product_name, quantity, revenue, estimated_margin from public.get_top_products(%L, '2026-09-01', '2026-09-03') $$, pg_temp.k('a')),
  $$ values ('Huile'::text, 6.000::numeric, 9000::bigint, 3000::bigint), ('Riz', 10.000, 5000, 1000) $$,
  'best sellers by revenue (cancelled sales excluded)');
select is((select count(*)::int from public.get_top_products(pg_temp.k('a'), '2026-09-01', '2026-09-03', 1)), 1, 'top products limit');

-- =============================================================================
-- Margin visibility: reports.read without products.read_cost
-- =============================================================================
select tests.clear_authentication();
with r as (insert into public.roles (business_id, code, name, is_system) values (pg_temp.k('a'), 'REPORTER', 'Lecteur rapports', false) returning id)
insert into public.role_permissions (role_id, permission_code) select id, 'reports.read' from r;
select tests.create_user('reporter@test.local');
insert into public.business_members (business_id, user_id, role_id, status, joined_at)
select pg_temp.k('a'), tests.get_user_id('reporter@test.local'), id, 'ACTIVE', now() from public.roles where code = 'REPORTER';

select tests.login('reporter@test.local');
select is((select public.get_dashboard_summary(pg_temp.k('a'), '2026-09-01', '2026-09-03') -> 'estimated_margin'), 'null'::jsonb,
  'without products.read_cost the margin is hidden (summary)');
select is((select count(*)::int from public.get_sales_timeseries(pg_temp.k('a'), '2026-09-01', '2026-09-03') where estimated_margin is not null), 0,
  'without products.read_cost the margin is hidden (series)');
select is((select count(*)::int from public.get_top_products(pg_temp.k('a'), '2026-09-01', '2026-09-03') where estimated_margin is not null), 0,
  'without products.read_cost the margin is hidden (top products)');
select is((select (public.get_dashboard_summary(pg_temp.k('a'), '2026-09-01', '2026-09-03') ->> 'revenue')::bigint), 13500::bigint,
  '... while revenue stays visible');

-- =============================================================================
-- Validation, timezone, permissions
-- =============================================================================
select tests.login('owner_a@test.local');
select throws_ok(format($$ select public.get_dashboard_summary(%L, '2026-09-03', '2026-09-01') $$, pg_temp.k('a')),
  '22023', 'INVALID_DATE_RANGE', 'the end date cannot precede the start date');
select throws_ok(format($$ select public.get_dashboard_summary(%L, '2025-01-01', '2026-09-01') $$, pg_temp.k('a')),
  '22023', 'DATE_RANGE_TOO_LARGE', 'ranges are limited to 366 days');
select throws_ok(format($$ select * from public.get_sales_timeseries(%L, '2026-09-01', '2026-09-03', 'year') $$, pg_temp.k('a')),
  '22023', 'INVALID_GRANULARITY', 'granularity is day, week or month');

select tests.clear_authentication();
select pg_temp.at('s6', '2026-09-04 02:00+00');
update public.businesses set timezone = 'America/New_York' where id = pg_temp.k('a');
select tests.login('owner_a@test.local');
select is((select (public.get_dashboard_summary(pg_temp.k('a'), '2026-09-03', '2026-09-03') ->> 'sales_count')::int), 2,
  'days follow the business timezone (04/09 02:00 UTC is 03/09 in New York)');
select tests.clear_authentication();
update public.businesses set timezone = 'Africa/Dakar' where id = pg_temp.k('a');

select tests.login('cashier_a@test.local');
select throws_ok(format($$ select public.get_dashboard_summary(%L, '2026-09-01', '2026-09-03') $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot read reports');
select tests.login('stock_a@test.local');
select throws_ok(format($$ select * from public.get_top_products(%L, '2026-09-01', '2026-09-03') $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'STOCK_MANAGER cannot read sales reports');
select tests.login('owner_b@test.local');
select throws_ok(format($$ select public.get_dashboard_summary(%L, '2026-09-01', '2026-09-03') $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'B cannot read A reports');
select throws_ok(format($$ select * from public.get_sales_timeseries(%L, '2026-09-01', '2026-09-03') $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'B cannot read A time series');

select tests.clear_authentication();
select * from finish();
rollback;
