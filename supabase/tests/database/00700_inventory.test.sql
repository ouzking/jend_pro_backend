-- Inventory: stock engine rules, atomicity, ledger invariant, tenancy, permissions.
begin;
select plan(46);

select tests.setup_two_tenants();

-- -----------------------------------------------------------------------------
-- Fixture (as postgres)
-- -----------------------------------------------------------------------------
create temp table ids (key text primary key, id uuid);
grant select on ids to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('b', tests.business_id('Business B')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default)),
  ('b_main', (select id from public.locations where business_id = tests.business_id('Business B') and is_default));

with l as (
  insert into public.locations (business_id, name, type)
  values (tests.business_id('Business A'), 'Dépôt', 'WAREHOUSE'),
         (tests.business_id('Business A'), 'Ancienne boutique', 'STORE')
  returning id, name)
insert into ids select case name when 'Dépôt' then 'a_depot' else 'a_old' end, id from l;

with p as (
  insert into public.products (business_id, name, unit, sale_price, allows_fractional_quantity, track_stock, min_stock_level)
  values (tests.business_id('Business A'), 'Riz brisé', 'kg', 500, true, true, 30),
         (tests.business_id('Business A'), 'Téléphone', 'pièce', 45000, false, true, 2),
         (tests.business_id('Business A'), 'Livraison', 'service', 1000, false, false, 0),
         (tests.business_id('Business B'), 'Sucre', 'kg', 700, true, true, 0)
  returning id, name)
insert into ids select case name when 'Riz brisé' then 'riz' when 'Téléphone' then 'tel'
                                 when 'Livraison' then 'service' else 'b_sucre' end, id from p;

update public.product_costs set cost_price = 400 where product_id = (select id from ids where key = 'riz');

-- Shorthand for readability.
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on function pg_temp.k(text) to authenticated;

-- =============================================================================
-- adjust_stock rules (STOCK_MANAGER)
-- =============================================================================
select tests.login('stock_a@test.local');

select lives_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 50) $$,
                       pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  'STOCK_MANAGER can set the opening stock');
select is((select quantity from public.inventory where product_id = pg_temp.k('riz') and location_id = pg_temp.k('a_main')),
  50.000, 'stock is updated');
select is((select row(type, quantity, quantity_after, unit_cost, created_by)::text from public.inventory_movements
            where product_id = pg_temp.k('riz')),
  row('INITIAL'::public.inventory_movement_type, 50.000, 50.000, 400::bigint, tests.get_user_id('stock_a@test.local'))::text,
  'the movement records type, signed quantity, stock after, unit cost and actor');

select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 10) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  'P0001', 'INITIAL_ALREADY_SET', 'opening stock can only be set once per product and location');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', -5) $$,
                        pg_temp.k('a'), pg_temp.k('tel'), pg_temp.k('a_main')),
  '22023', 'INVALID_QUANTITY_SIGN', 'INITIAL must be positive');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'LOSS', 2, 'vol') $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '22023', 'INVALID_QUANTITY_SIGN', 'LOSS must be negative');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'ADJUSTMENT', -1) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '22023', 'REASON_REQUIRED', 'a reason is required for adjustments');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'SALE', -1, 'x') $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '22023', 'INVALID_MOVEMENT_TYPE', 'sales cannot be faked through adjust_stock');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 1.5) $$,
                        pg_temp.k('a'), pg_temp.k('tel'), pg_temp.k('a_main')),
  'P0001', 'FRACTIONAL_QUANTITY_NOT_ALLOWED', 'whole-unit products reject fractional quantities');
select lives_ok(format($$ select public.adjust_stock(%L, %L, %L, 'LOSS', -2.5, 'sac percé') $$,
                       pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  'fractional quantities are accepted for products sold by weight');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 1) $$,
                        pg_temp.k('a'), pg_temp.k('service'), pg_temp.k('a_main')),
  'P0001', 'PRODUCT_NOT_STOCKED', 'non-stocked products have no inventory');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'DAMAGE', -100, 'casse') $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  'P0001', 'INSUFFICIENT_STOCK', 'negative stock is refused by default');
select is((select quantity from public.inventory where product_id = pg_temp.k('riz') and location_id = pg_temp.k('a_main')),
  47.500, 'a refused movement leaves stock untouched (atomic)');

-- =============================================================================
-- count_stock
-- =============================================================================
select lives_ok(format($$ select public.count_stock(%L, %L, %L, 40) $$,
                       pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  'a physical count can be recorded');
select is((select quantity from public.inventory_movements
            where product_id = pg_temp.k('riz') and reference_type = 'count'),
  -7.500, 'the server computes the count delta (40 - 47.5)');
select is((select public.count_stock(pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), 40)),
  null, 'counting the current quantity creates no movement');
select throws_ok(format($$ select public.count_stock(%L, %L, %L, -1) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '22023', 'INVALID_QUANTITY', 'a counted quantity cannot be negative');

-- =============================================================================
-- transfer_stock
-- =============================================================================
select lives_ok(format($$ select public.transfer_stock(%L, %L, %L, %L, 15) $$,
                       pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), pg_temp.k('a_depot')),
  'stock can be transferred between locations');
select results_eq(
  format($$ select location_id, quantity from public.inventory where product_id = %L order by quantity $$, pg_temp.k('riz')),
  format($$ values (%L::uuid, 15.000::numeric), (%L::uuid, 25.000::numeric) $$, pg_temp.k('a_depot'), pg_temp.k('a_main')),
  'source decreases and destination increases');
select is((select count(distinct transfer_id)::int || '/' || count(*)::int || '/' || sum(quantity)::text
             from public.inventory_movements where product_id = pg_temp.k('riz') and transfer_id is not null),
  '1/2/0.000', 'a transfer is one OUT + one IN movement sharing a transfer_id');
select throws_ok(format($$ select public.transfer_stock(%L, %L, %L, %L, 100) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), pg_temp.k('a_depot')),
  'P0001', 'INSUFFICIENT_STOCK', 'cannot transfer more than available');
select is((select quantity from public.inventory where product_id = pg_temp.k('riz') and location_id = pg_temp.k('a_depot')),
  15.000, 'a failed transfer changes nothing on either side');
select throws_ok(format($$ select public.transfer_stock(%L, %L, %L, %L, 1) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), pg_temp.k('a_main')),
  '22023', 'SAME_LOCATION', 'source and destination must differ');

select tests.clear_authentication();

-- =============================================================================
-- Locations, negative stock setting, append-only ledger
-- =============================================================================
select throws_ok(format($$ update public.locations set status = 'ARCHIVED' where id = %L $$, pg_temp.k('a_depot')),
  'P0001', 'LOCATION_HAS_STOCK', 'a location holding stock cannot be archived');
update public.locations set status = 'ARCHIVED' where id = pg_temp.k('a_old');
select tests.login('stock_a@test.local');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 1) $$,
                        pg_temp.k('a'), pg_temp.k('tel'), pg_temp.k('a_old')),
  'P0001', 'LOCATION_ARCHIVED', 'no movement on an archived location');
select tests.clear_authentication();

update public.businesses set allow_negative_stock = true where id = pg_temp.k('a');
select tests.login('stock_a@test.local');
select lives_ok(format($$ select public.adjust_stock(%L, %L, %L, 'LOSS', -20, 'vol') $$,
                       pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_depot')),
  'negative stock is possible when the business explicitly allows it');
select tests.clear_authentication();
select is((select quantity from public.inventory where product_id = pg_temp.k('riz') and location_id = pg_temp.k('a_depot')),
  -5.000, '... and the stock goes negative');
update public.businesses set allow_negative_stock = false where id = pg_temp.k('a');

select throws_ok($$ update public.inventory_movements set quantity = 1000 $$,
  'P0001', 'APPEND_ONLY', 'the ledger cannot be rewritten, even by privileged roles');

select is_empty($$
  select i.product_id, i.location_id
    from public.inventory i
    left join (select business_id, product_id, location_id, sum(quantity) s
                 from public.inventory_movements group by 1, 2, 3) m using (business_id, product_id, location_id)
   where i.quantity <> coalesce(m.s, 0) $$,
  'ledger invariant: every stock row equals the sum of its movements');

select ok(exists (select 1 from public.audit_logs where business_id = pg_temp.k('a') and action = 'inventory.adjust')
          and exists (select 1 from public.audit_logs where business_id = pg_temp.k('a') and action = 'inventory.count')
          and exists (select 1 from public.audit_logs where business_id = pg_temp.k('a') and action = 'inventory.transfer'),
  'adjustments, counts and transfers are audited');

-- =============================================================================
-- CASHIER: read-only
-- =============================================================================
select tests.login('cashier_a@test.local');
select ok((select count(*) from public.inventory) > 0, 'CASHIER can read stock');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'ADJUSTMENT', 5, 'x') $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot adjust stock');
select throws_ok(format($$ select public.transfer_stock(%L, %L, %L, %L, 1) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), pg_temp.k('a_depot')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot transfer stock');
select throws_ok($$ update public.inventory set quantity = 9999 $$,
  '42501', null, 'stock cannot be written directly');
select throws_ok(format($$ insert into public.inventory_movements (business_id, product_id, location_id, type, quantity, quantity_after)
                           values (%L, %L, %L, 'PURCHASE', 100, 100) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '42501', null, 'movements cannot be inserted directly');
select ok((select count(*) from public.list_low_stock(pg_temp.k('a'))) > 0, 'CASHIER can list low stock');

-- =============================================================================
-- Low stock
-- =============================================================================
select tests.login('manager_a@test.local');
select set_eq(format($$ select product_name || '@' || location_name from public.list_low_stock(%L) $$, pg_temp.k('a')),
  array['Riz brisé@Boutique principale', 'Riz brisé@Dépôt', 'Téléphone@Boutique principale', 'Téléphone@Dépôt'],
  'low stock lists products at or below their minimum per active location (missing stock = 0)');
select set_eq(format($$ select product_name from public.list_low_stock(%L, %L) $$, pg_temp.k('a'), pg_temp.k('a_depot')),
  array['Riz brisé', 'Téléphone'], 'low stock can be filtered by location');

-- =============================================================================
-- Cross-tenant
-- =============================================================================
select tests.login('owner_b@test.local');
select is((select count(*)::int from public.inventory) + (select count(*)::int from public.inventory_movements),
  0, 'B cannot see A stock nor movements');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'ADJUSTMENT', 5, 'x') $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '42501', 'PERMISSION_DENIED', 'B cannot adjust A stock');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 5) $$,
                        pg_temp.k('b'), pg_temp.k('riz'), pg_temp.k('b_main')),
  'P0002', 'PRODUCT_NOT_FOUND', 'B cannot move an A product through its own business');
select throws_ok(format($$ select public.adjust_stock(%L, %L, %L, 'INITIAL', 5) $$,
                        pg_temp.k('b'), pg_temp.k('b_sucre'), pg_temp.k('a_main')),
  'P0002', 'LOCATION_NOT_FOUND', 'B cannot put stock in an A location');
select throws_ok(format($$ select public.transfer_stock(%L, %L, %L, %L, 1) $$,
                        pg_temp.k('b'), pg_temp.k('b_sucre'), pg_temp.k('b_main'), pg_temp.k('a_main')),
  'P0002', 'LOCATION_NOT_FOUND', 'B cannot transfer stock into an A location');
select throws_ok(format($$ select * from public.list_low_stock(%L) $$, pg_temp.k('a')),
  '42501', 'PERMISSION_DENIED', 'B cannot list A low stock');
select throws_ok(format($$ select public.count_stock(%L, %L, %L, 0) $$,
                        pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main')),
  '42501', 'PERMISSION_DENIED', 'B cannot count A stock');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.inventory $$, '42501', null, 'anon cannot read stock');

select tests.clear_authentication();
select * from finish();
rollback;
