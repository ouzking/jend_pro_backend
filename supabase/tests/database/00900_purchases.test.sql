-- Suppliers and purchases: workflow, reception (stock + weighted average cost),
-- supplier payments, numbering, validation, tenancy.
begin;
select plan(53);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on function pg_temp.k(text) to authenticated;
-- Items JSON helper: pg_temp.item('riz', 20, 600)
create function pg_temp.item(text, numeric, bigint) returns jsonb language sql as
  $$ select jsonb_build_object('product_id', pg_temp.k($1), 'quantity', $2, 'unit_cost', $3) $$;
grant execute on function pg_temp.item(text, numeric, bigint) to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('b', tests.business_id('Business B')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default)),
  ('b_main', (select id from public.locations where business_id = tests.business_id('Business B') and is_default));

with p as (
  insert into public.products (business_id, name, unit, sale_price, allows_fractional_quantity, track_stock)
  values (pg_temp.k('a'), 'Riz brisé', 'kg', 500, true, true),
         (pg_temp.k('a'), 'Huile 1L', 'bouteille', 1500, false, true),
         (pg_temp.k('a'), 'Transport', 'service', 0, false, false),
         (pg_temp.k('b'), 'Sucre', 'kg', 700, true, true)
  returning id, name)
insert into ids select case name when 'Riz brisé' then 'riz' when 'Huile 1L' then 'huile'
                                 when 'Transport' then 'transport' else 'b_sucre' end, id from p;

with s as (insert into public.suppliers (business_id, name) values (pg_temp.k('b'), 'Fournisseur B') returning id)
insert into ids select 'b_supplier', id from s;

-- Opening stock of rice: 10 kg at cost 400.
update public.product_costs set cost_price = 400 where product_id = pg_temp.k('riz');
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), 'INITIAL', 10, 400);

-- =============================================================================
-- Suppliers (STOCK_MANAGER has suppliers.manage)
-- =============================================================================
select tests.login('stock_a@test.local');
with s as (insert into public.suppliers (business_id, name, phone) values (pg_temp.k('a'), ' Grossiste Sandaga ', '33 821 00 00') returning id)
insert into ids select 's1', id from s;
select is((select name || '|' || phone from public.suppliers where id = pg_temp.k('s1')), 'Grossiste Sandaga|338210000',
  'STOCK_MANAGER can create a supplier (normalized)');
select lives_ok(format($$ insert into public.supplier_products (business_id, supplier_id, product_id, supplier_sku) values (%L, %L, %L, 'RZ-25') $$,
                       pg_temp.k('a'), pg_temp.k('s1'), pg_temp.k('riz')),
  'supplier catalog entries can be created');
select throws_ok(format($$ update public.supplier_products set last_cost = 1 where supplier_id = %L $$, pg_temp.k('s1')),
  '42501', null, 'last_cost is server-maintained');

-- =============================================================================
-- save_purchase: creation, numbering, validation
-- =============================================================================
insert into ids
select 'p1', public.save_purchase(pg_temp.k('a'), null, pg_temp.k('s1'), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('riz', 20, 600), pg_temp.item('huile', 5, 1200)), 1000);
select is((select row(number, status, subtotal_amount, discount_amount, total_amount, payment_status, created_by)::text
             from public.purchases where id = pg_temp.k('p1')),
  row('A-000001', 'DRAFT'::public.purchase_status, 18000::bigint, 1000::bigint, 17000::bigint,
      'UNPAID'::public.payment_status, tests.get_user_id('stock_a@test.local'))::text,
  'a draft purchase is created with server-computed totals and number A-000001');

insert into ids
select 'p2', public.save_purchase(pg_temp.k('a'), null, null, pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('huile', 2, 1000)));
select is((select number from public.purchases where id = pg_temp.k('p2')), 'A-000002',
  'numbers are sequential per business (purchase without supplier allowed)');

select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, '[]') $$, pg_temp.k('a'), pg_temp.k('a_main')),
  '22023', 'ITEMS_REQUIRED', 'a purchase needs at least one line');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('riz', 0, 600))),
  '22023', 'INVALID_ITEM', 'quantities must be positive');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, '[{"product_id":"x","quantity":1,"unit_cost":1}]') $$,
                        pg_temp.k('a'), pg_temp.k('a_main')),
  '22023', 'INVALID_ITEM', 'malformed lines are rejected');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1.5, 1000))),
  'P0001', 'FRACTIONAL_QUANTITY_NOT_ALLOWED', 'whole-unit products reject fractional quantities');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('riz', 1, 1), pg_temp.item('riz', 2, 1))),
  '22023', 'DUPLICATE_PRODUCT', 'a product appears once per purchase');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('b_sucre', 1, 1))),
  'P0002', 'PRODUCT_NOT_FOUND', 'products of another business are rejected');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, %L, 999999) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('riz', 1, 100))),
  '22023', 'DISCOUNT_EXCEEDS_TOTAL', 'the discount cannot exceed the subtotal');
select throws_ok(format($$ select public.save_purchase(%L, null, %L, %L, %L) $$, pg_temp.k('a'), pg_temp.k('b_supplier'),
                        pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('riz', 1, 100))),
  'P0002', 'SUPPLIER_NOT_FOUND', 'suppliers of another business are rejected');

-- Edit: lines are replaced as a whole.
select lives_ok(format($$ select public.save_purchase(%L, %L, %L, %L, %L, 1000) $$, pg_temp.k('a'), pg_temp.k('p1'),
                       pg_temp.k('s1'), pg_temp.k('a_main'),
                       jsonb_build_array(pg_temp.item('riz', 20, 600), pg_temp.item('huile', 5, 1200), pg_temp.item('transport', 1, 1000))),
  'a draft can be edited');
select is((select subtotal_amount || '/' || total_amount from public.purchases where id = pg_temp.k('p1')), '19000/18000',
  'totals are recomputed after edit');
select is((select count(*)::int from public.purchase_items where purchase_id = pg_temp.k('p1')), 3, 'lines are replaced');
select lives_ok(format($$ select public.order_purchase(%L) $$, pg_temp.k('p1')), 'a draft can be marked as ordered');

-- =============================================================================
-- Supplier payments (MANAGER has purchases.payments, STOCK_MANAGER does not)
-- =============================================================================
select throws_ok(format($$ select public.record_purchase_payment(%L, 1000, 'CASH', %L) $$, pg_temp.k('p1'), pg_temp.k('a_main')),
  '42501', 'PERMISSION_DENIED', 'STOCK_MANAGER cannot pay suppliers');

select tests.login('manager_a@test.local');
select lives_ok(format($$ select public.record_purchase_payment(%L, 5000, 'CASH', %L) $$, pg_temp.k('p1'), pg_temp.k('a_main')),
  'an advance can be paid on an ordered purchase');
select is((select amount_paid || '/' || payment_status from public.purchases where id = pg_temp.k('p1')), '5000/PARTIAL',
  'amount paid and payment status are updated');
select is((select direction || '/' || amount from public.payments where purchase_id = pg_temp.k('p1')), 'OUT/5000',
  'a supplier payment is a payment OUT linked to the purchase');
select throws_ok(format($$ select public.record_purchase_payment(%L, 13001, 'CASH', %L) $$, pg_temp.k('p1'), pg_temp.k('a_main')),
  'P0001', 'AMOUNT_EXCEEDS_BALANCE', 'cannot pay more than the purchase total');
select throws_ok(format($$ select public.cancel_purchase(%L, 'erreur') $$, pg_temp.k('p1')),
  'P0001', 'PURCHASE_HAS_PAYMENTS', 'a purchase with payments cannot be cancelled');
select throws_ok(format($$ select public.save_purchase(%L, %L, %L, %L, %L) $$, pg_temp.k('a'), pg_temp.k('p1'),
                        pg_temp.k('s1'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('riz', 1, 100))),
  'P0001', 'TOTAL_BELOW_AMOUNT_PAID', 'an edit cannot bring the total below what was already paid');

-- =============================================================================
-- Reception
-- =============================================================================
select tests.login('cashier_a@test.local');
select throws_ok(format($$ select public.receive_purchase(%L) $$, pg_temp.k('p1')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot receive purchases');

select tests.login('stock_a@test.local');
select lives_ok(format($$ select public.receive_purchase(%L) $$, pg_temp.k('p1')), 'STOCK_MANAGER can receive a purchase');
select is((select status || '/' || (received_by = tests.get_user_id('stock_a@test.local'))::text from public.purchases where id = pg_temp.k('p1')),
  'RECEIVED/true', 'the purchase is RECEIVED with the receiver recorded');
select results_eq(
  format($$ select product_id, quantity from public.inventory where location_id = %L order by quantity $$, pg_temp.k('a_main')),
  format($$ values (%L::uuid, 5.000::numeric), (%L::uuid, 30.000::numeric) $$, pg_temp.k('huile'), pg_temp.k('riz')),
  'stock increases by the received quantities (non-stocked lines ignored)');
select is((select count(*)::int from public.inventory_movements where reference_id = pg_temp.k('p1') and type = 'PURCHASE'), 2,
  'one PURCHASE movement per stocked line, linked to the purchase');
select is((select cost_price from public.product_costs where product_id = pg_temp.k('riz')), 533::bigint,
  'weighted average cost: (10 x 400 + 20 x 600) / 30 = 533');
select is((select cost_price from public.product_costs where product_id = pg_temp.k('huile')), 1200::bigint,
  'without previous stock, cost = purchase cost');
select is((select last_cost from public.supplier_products where supplier_id = pg_temp.k('s1') and product_id = pg_temp.k('riz')),
  600::bigint, 'the supplier last cost is updated');
select throws_ok(format($$ select public.receive_purchase(%L) $$, pg_temp.k('p1')),
  'P0001', 'INVALID_PURCHASE_STATUS', 'a purchase cannot be received twice');
select throws_ok(format($$ select public.save_purchase(%L, %L, %L, %L, %L) $$, pg_temp.k('a'), pg_temp.k('p1'),
                        pg_temp.k('s1'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('riz', 100, 600))),
  'P0001', 'PURCHASE_NOT_EDITABLE', 'a received purchase cannot be edited');

select tests.login('manager_a@test.local');
select is((select amount_due from public.supplier_balances where supplier_id = pg_temp.k('s1')), 13000::bigint,
  'supplier balance shows what is still owed');
select lives_ok(format($$ select public.record_purchase_payment(%L, 13000, 'WAVE', %L, 'WV-1') $$, pg_temp.k('p1'), pg_temp.k('a_main')),
  'the remaining amount can be paid');
select is((select payment_status from public.purchases where id = pg_temp.k('p1')), 'PAID'::public.payment_status,
  'the purchase is PAID');

-- =============================================================================
-- Cancellation
-- =============================================================================
select throws_ok(format($$ select public.cancel_purchase(%L, ' ') $$, pg_temp.k('p2')),
  '22023', 'REASON_REQUIRED', 'a cancellation needs a reason');
select lives_ok(format($$ select public.cancel_purchase(%L, 'Commande en double') $$, pg_temp.k('p2')),
  'a purchase without payment can be cancelled before reception');
select throws_ok(format($$ select public.record_purchase_payment(%L, 100, 'CASH', %L) $$, pg_temp.k('p2'), pg_temp.k('a_main')),
  'P0001', 'INVALID_PURCHASE_STATUS', 'a cancelled purchase cannot be paid');
select throws_ok(format($$ select public.receive_purchase(%L) $$, pg_temp.k('p2')),
  'P0001', 'INVALID_PURCHASE_STATUS', 'a cancelled purchase cannot be received');

-- Direct writes are impossible.
select throws_ok(format($$ update public.purchases set total_amount = 0 where id = %L $$, pg_temp.k('p1')),
  '42501', null, 'purchases cannot be updated directly');
select throws_ok(format($$ insert into public.purchase_items (business_id, purchase_id, product_id, quantity, unit_cost, line_total)
                           values (%L, %L, %L, 1, 1, 1) $$, pg_temp.k('a'), pg_temp.k('p1'), pg_temp.k('riz')),
  '42501', null, 'purchase lines cannot be inserted directly');

select tests.clear_authentication();
select is_empty($$
  select i.product_id from public.inventory i
    left join (select business_id, product_id, location_id, sum(quantity) s from public.inventory_movements group by 1, 2, 3) m
      using (business_id, product_id, location_id)
   where i.quantity <> coalesce(m.s, 0) $$,
  'stock ledger invariant still holds after receptions');
select is((select count(*)::int from public.audit_logs where business_id = pg_temp.k('a')
            and action in ('purchase.receive', 'purchase.payment', 'purchase.cancel')), 4,
  'reception, payments and cancellation are audited');

-- =============================================================================
-- Roles and tenants
-- =============================================================================
select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.suppliers) + (select count(*)::int from public.purchases)
          + (select count(*)::int from public.supplier_balances), 0,
  'CASHIER cannot see suppliers, purchases nor supplier balances');
select throws_ok(format($$ insert into public.suppliers (business_id, name) values (%L, 'X') $$, pg_temp.k('a')),
  '42501', null, 'CASHIER cannot create suppliers');

select tests.login('owner_b@test.local');
select is((select count(*)::int from public.suppliers where business_id = pg_temp.k('a'))
          + (select count(*)::int from public.purchases) + (select count(*)::int from public.purchase_items)
          + (select count(*)::int from public.supplier_balances), 0,
  'B cannot see A suppliers, purchases, lines or balances');
select throws_ok(format($$ select public.receive_purchase(%L) $$, pg_temp.k('p1')),
  '42501', 'PERMISSION_DENIED', 'B cannot receive an A purchase');
select throws_ok(format($$ select public.record_purchase_payment(%L, 1, 'CASH', %L) $$, pg_temp.k('p1'), pg_temp.k('b_main')),
  '42501', 'PERMISSION_DENIED', 'B cannot pay an A purchase');
select throws_ok(format($$ select public.save_purchase(%L, null, %L, %L, %L) $$, pg_temp.k('b'), pg_temp.k('s1'),
                        pg_temp.k('b_main'), jsonb_build_array(pg_temp.item('b_sucre', 1, 100))),
  'P0002', 'SUPPLIER_NOT_FOUND', 'B cannot use an A supplier');
select throws_ok(format($$ select public.save_purchase(%L, null, null, %L, %L) $$, pg_temp.k('b'),
                        pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('b_sucre', 1, 100))),
  'P0002', 'LOCATION_NOT_FOUND', 'B cannot receive goods into an A location');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.suppliers $$, '42501', null, 'anon cannot read suppliers');

select tests.clear_authentication();
select * from finish();
rollback;
