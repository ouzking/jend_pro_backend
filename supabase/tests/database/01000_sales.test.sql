-- Sales: atomic checkout, idempotency, payments, credit, discounts, cancellation,
-- visibility, invariants, tenancy.
begin;
select plan(69);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
create function pg_temp.item(text, numeric, bigint default 0) returns jsonb language sql as
  $$ select jsonb_build_object('product_id', pg_temp.k($1), 'quantity', $2, 'discount_amount', $3) $$;
create function pg_temp.pay(text, bigint, text default null) returns jsonb language sql as
  $$ select jsonb_strip_nulls(jsonb_build_object('method', $1, 'amount', $2, 'external_reference', $3)) $$;
create function pg_temp.stock(text) returns numeric language sql as
  $$ select coalesce((select quantity from public.inventory where product_id = pg_temp.k($1) and location_id = pg_temp.k('a_main')), 0) $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('b', tests.business_id('Business B')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default)),
  ('b_main', (select id from public.locations where business_id = tests.business_id('Business B') and is_default)),
  ('ref1', gen_random_uuid());

with p as (
  insert into public.products (business_id, name, unit, sale_price, allows_fractional_quantity, track_stock)
  values (pg_temp.k('a'), 'Riz brisé', 'kg', 500, true, true),
         (pg_temp.k('a'), 'Huile 1L', 'bouteille', 1500, false, true),
         (pg_temp.k('a'), 'Livraison', 'service', 2000, false, false),
         (pg_temp.k('a'), 'Ancien produit', 'pièce', 100, false, true),
         (pg_temp.k('b'), 'Sucre', 'kg', 700, true, true)
  returning id, name)
insert into ids select case name when 'Riz brisé' then 'riz' when 'Huile 1L' then 'huile' when 'Livraison' then 'service'
                                 when 'Ancien produit' then 'old' else 'b_sucre' end, id from p;
update public.products set status = 'ARCHIVED' where id = pg_temp.k('old');
update public.product_costs set cost_price = 400 where product_id = pg_temp.k('riz');
update public.product_costs set cost_price = 1000 where product_id = pg_temp.k('huile');
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('riz'), pg_temp.k('a_main'), 'INITIAL', 100);
select private.apply_stock_movement(pg_temp.k('a'), pg_temp.k('huile'), pg_temp.k('a_main'), 'INITIAL', 10);

with c as (
  insert into public.customers (business_id, name, credit_limit)
  values (pg_temp.k('a'), 'Fatou', 20000), (pg_temp.k('a'), 'Sans crédit', 0), (pg_temp.k('a'), 'VIP', null),
         (pg_temp.k('b'), 'Client B', null)
  returning id, name)
insert into ids select case name when 'Fatou' then 'fatou' when 'Sans crédit' then 'nocredit' when 'VIP' then 'vip'
                                 else 'b_client' end, id from c;

-- =============================================================================
-- Cash sale (CASHIER)
-- =============================================================================
select tests.login('cashier_a@test.local');

insert into ids
select 's1', public.create_sale(pg_temp.k('a'), pg_temp.k('ref1'), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('riz', 2.5), pg_temp.item('huile', 2)),
  jsonb_build_array(pg_temp.pay('CASH', 4250)));

select is((select row(number, status, subtotal_amount, total_amount, amount_paid, credit_amount, payment_status, sold_by)::text
             from public.sales where id = pg_temp.k('s1')),
  row('V-000001', 'COMPLETED'::public.sale_status, 4250::bigint, 4250::bigint, 4250::bigint, 0::bigint,
      'PAID'::public.payment_status, tests.get_user_id('cashier_a@test.local'))::text,
  'a cash sale is recorded with server-computed totals (2.5 kg x 500 + 2 x 1500)');
select is(pg_temp.stock('riz') || '/' || pg_temp.stock('huile'), '97.500/8.000', 'stock is decreased');
select is((select count(*)::int from public.inventory_movements where reference_id = pg_temp.k('s1') and type = 'SALE'), 2,
  'one SALE movement per line, linked to the sale');
select is((select string_agg(product_name || ':' || unit_price || ':' || line_total, ',' order by product_name)
             from public.sale_items where sale_id = pg_temp.k('s1')),
  'Huile 1L:1500:3000,Riz brisé:500:1250', 'lines freeze name and catalog price');
select is((select sum(amount)::bigint from public.payments where sale_id = pg_temp.k('s1') and direction = 'IN'), 4250::bigint,
  'the payment IN is linked to the sale');
select is((select count(*)::int from public.sale_item_costs), 0, 'CASHIER cannot see frozen costs (margins)');

-- Idempotency: same client_reference, even with a different payload.
select is(public.create_sale(pg_temp.k('a'), pg_temp.k('ref1'), pg_temp.k('a_main'),
            jsonb_build_array(pg_temp.item('huile', 5)), jsonb_build_array(pg_temp.pay('CASH', 7500))),
  pg_temp.k('s1'), 'retrying with the same client_reference returns the original sale');
select is(pg_temp.stock('huile'), 8.000, '... without selling twice');

-- Split payment.
insert into ids
select 's2', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('huile', 2)),
  jsonb_build_array(pg_temp.pay('CASH', 1000), pg_temp.pay('WAVE', 2000, 'WAVE-777')));
select is((select string_agg(method || ':' || amount, ',' order by method) from public.payments where sale_id = pg_temp.k('s2')),
  'CASH:1000,WAVE:2000', 'a sale can be paid with several methods');
select is((select number from public.sales where id = pg_temp.k('s2')), 'V-000002', 'sale numbers are sequential');

-- Non-stocked product.
insert into ids
select 's_service', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('service', 1)), jsonb_build_array(pg_temp.pay('CASH', 2000)));
select is((select count(*)::int from public.inventory_movements where reference_id = pg_temp.k('s_service')), 0,
  'non-stocked products create no stock movement');

-- =============================================================================
-- Credit sales
-- =============================================================================
insert into ids
select 's_credit', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('service', 1), pg_temp.item('huile', 1)),
  jsonb_build_array(pg_temp.pay('CASH', 1000)), pg_temp.k('fatou'));
select is((select amount_paid || '/' || credit_amount || '/' || payment_status from public.sales where id = pg_temp.k('s_credit')),
  '1000/2500/PARTIAL', 'the unpaid remainder becomes credit');
select is((select balance from public.customers where id = pg_temp.k('fatou')), 2500::bigint,
  'the credit is added to the customer account');
select is((select type || ':' || amount from public.customer_transactions where sale_id = pg_temp.k('s_credit')),
  'CREDIT_SALE:2500', 'the ledger entry is linked to the sale');

select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$,
                        pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('huile', 1))),
  'P0001', 'CUSTOMER_REQUIRED_FOR_CREDIT', 'credit requires an identified customer');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[]', %L) $$,
                        pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('riz', 40)), pg_temp.k('fatou')),
  'P0001', 'CREDIT_LIMIT_EXCEEDED', 'credit beyond the customer limit is refused (2 500 + 20 000 > 20 000)');
select is(pg_temp.stock('riz'), 97.500, 'a refused credit sale leaves stock untouched (atomic)');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[]', %L) $$,
                        pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('huile', 1)), pg_temp.k('nocredit')),
  'P0001', 'CREDIT_LIMIT_EXCEEDED', 'a customer with limit 0 gets no credit');
select lives_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[]', %L) $$,
                       pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('riz', 20)), pg_temp.k('vip')),
  'a customer without ceiling can buy fully on credit');

-- =============================================================================
-- Validation (nothing is written on failure)
-- =============================================================================
create temp table counts_before as
  select (select count(*) from public.sales) s, (select count(*) from public.payments) p,
         (select count(*) from public.inventory_movements) m;
grant select on counts_before to authenticated;

select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('riz', 1), pg_temp.item('huile', 100)), jsonb_build_array(pg_temp.pay('CASH', 150500))),
  'P0001', 'INSUFFICIENT_STOCK', 'a sale exceeding stock is refused');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1)), jsonb_build_array(pg_temp.pay('CASH', 2000))),
  '22023', 'PAYMENT_EXCEEDS_TOTAL', 'payments cannot exceed the total (change is not a payment)');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1, 100)), jsonb_build_array(pg_temp.pay('CASH', 1400))),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot give a line discount (sales.discount)');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, %L, null, 100) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1)), jsonb_build_array(pg_temp.pay('CASH', 1400))),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot give a global discount');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('old', 1))),
  'P0001', 'PRODUCT_ARCHIVED', 'archived products cannot be sold');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1.5))),
  'P0001', 'FRACTIONAL_QUANTITY_NOT_ALLOWED', 'whole-unit products reject fractional quantities');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1), pg_temp.item('huile', 1))),
  '22023', 'DUPLICATE_PRODUCT', 'a product appears once per sale');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, '[]') $$, pg_temp.k('a'), pg_temp.k('a_main')),
  '22023', 'ITEMS_REQUIRED', 'a sale needs at least one line');
select throws_ok(format($$ select public.create_sale(%L, null, %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1))),
  '22023', 'CLIENT_REFERENCE_REQUIRED', 'a client reference is required (idempotency)');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[{"method":"BITCOIN","amount":1500}]') $$,
                        pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('huile', 1))),
  '22023', 'INVALID_PAYMENT', 'unknown payment methods are rejected');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[{"method":"CASH","amount":0}]') $$,
                        pg_temp.k('a'), pg_temp.k('a_main'), jsonb_build_array(pg_temp.item('huile', 1))),
  '22023', 'INVALID_PAYMENT', 'payment amounts must be positive');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('b_sucre', 1))),
  'P0002', 'PRODUCT_NOT_FOUND', 'products of another business cannot be sold');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('b_main'),
                        jsonb_build_array(pg_temp.item('huile', 1))),
  'P0002', 'LOCATION_NOT_FOUND', 'cannot sell from another business location');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[]', %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1)), pg_temp.k('b_client')),
  'P0002', 'CUSTOMER_NOT_FOUND', 'cannot sell to another business customer');
select is((select (select count(*) from public.sales) || '/' || (select count(*) from public.payments) || '/'
                  || (select count(*) from public.inventory_movements)),
  (select s || '/' || p || '/' || m from counts_before), 'failed sales leave no trace (sale, payment, stock)');

-- =============================================================================
-- Discounts (MANAGER)
-- =============================================================================
select tests.login('manager_a@test.local');
insert into ids
select 's_disc', public.create_sale(pg_temp.k('a'), gen_random_uuid(), pg_temp.k('a_main'),
  jsonb_build_array(pg_temp.item('huile', 2, 200)), jsonb_build_array(pg_temp.pay('CASH', 2500)), null, 300);
select is((select subtotal_amount || '/' || discount_amount || '/' || total_amount from public.sales where id = pg_temp.k('s_disc')),
  '2800/300/2500', 'line and global discounts: 3 000 - 200 = 2 800, - 300 = 2 500');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L, '[]', null, 5000) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1))),
  '22023', 'DISCOUNT_EXCEEDS_TOTAL', 'a discount cannot exceed the subtotal');

-- =============================================================================
-- Visibility
-- =============================================================================
select is((select count(*)::int from public.sales), 6, 'MANAGER (sales.read) sees all sales');
select ok((select count(*) from public.sale_item_costs) > 0, 'MANAGER can see frozen costs');
select is((select unit_cost from public.sale_item_costs c join public.sale_items i on i.id = c.sale_item_id
            where i.sale_id = pg_temp.k('s1') and i.product_id = pg_temp.k('riz')), 400::bigint,
  'the unit cost is frozen at sale time');

select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.sales), 5, 'CASHIER (sales.read_own) sees only their own sales');
select is((select count(*)::int from public.sale_items where sale_id = pg_temp.k('s_disc')), 0,
  'CASHIER cannot see lines of others'' sales');
select is((select count(*)::int from public.payments where sale_id = pg_temp.k('s_disc')), 0,
  'CASHIER cannot see payments of others'' sales');
select throws_ok(format($$ select public.cancel_sale(%L, 'erreur') $$, pg_temp.k('s1')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot cancel a sale');
select throws_ok(format($$ update public.sales set total_amount = 0 where id = %L $$, pg_temp.k('s1')),
  '42501', null, 'sales cannot be updated directly');
select throws_ok(format($$ insert into public.sale_items (business_id, sale_id, product_id, product_name, quantity, unit_price, line_total)
                           values (%L, %L, %L, 'x', 1, 0, 0) $$, pg_temp.k('a'), pg_temp.k('s1'), pg_temp.k('huile')),
  '42501', null, 'sale lines cannot be inserted directly');

-- =============================================================================
-- Cancellation (MANAGER)
-- =============================================================================
select tests.login('manager_a@test.local');
select throws_ok(format($$ select public.cancel_sale(%L, ' ') $$, pg_temp.k('s1')),
  '22023', 'REASON_REQUIRED', 'a cancellation needs a reason');
select lives_ok(format($$ select public.cancel_sale(%L, 'Client a changé d''avis') $$, pg_temp.k('s1')),
  'MANAGER can cancel a sale');
select is((select status || '/' || (cancelled_by = tests.get_user_id('manager_a@test.local'))::text from public.sales where id = pg_temp.k('s1')),
  'CANCELLED/true', 'the sale is CANCELLED with the actor recorded');
select is((select sum(quantity)::numeric from public.inventory_movements where reference_id = pg_temp.k('s1')), 0.000,
  'stock movements of the cancelled sale net to zero');
select is((select direction || ':' || method || ':' || amount from public.payments where sale_id = pg_temp.k('s1') and direction = 'OUT'),
  'OUT:CASH:4250', 'the amount paid is refunded as a payment OUT');
select throws_ok(format($$ select public.cancel_sale(%L, 'encore') $$, pg_temp.k('s1')),
  'P0001', 'SALE_ALREADY_CANCELLED', 'a sale cannot be cancelled twice');

-- Credit sale partly settled afterwards: Fatou owes 2 500, pays 2 000, then the sale is cancelled.
select public.record_customer_payment(pg_temp.k('fatou'), 2000, 'CASH', pg_temp.k('a_main'));
select lives_ok(format($$ select public.cancel_sale(%L, 'Retour marchandise', 'WAVE') $$, pg_temp.k('s_credit')),
  'a credit sale can be cancelled');
select is((select balance from public.customers where id = pg_temp.k('fatou')), 0::bigint,
  'the remaining credit (500) is reversed, the balance never goes negative');
select is((select method || ':' || amount from public.payments where sale_id = pg_temp.k('s_credit') and direction = 'OUT'),
  'WAVE:3000', 'refund = paid at checkout (1 000) + credit already settled (2 000)');
select is((select type || ':' || amount from public.customer_transactions
            where sale_id = pg_temp.k('s_credit') and type = 'SALE_CANCELLATION'),
  'SALE_CANCELLATION:-500', 'the reversal is recorded in the ledger');

select tests.clear_authentication();
select ok(exists (select 1 from public.audit_logs where action = 'sale.cancel' and resource_id = pg_temp.k('s1'))
          and exists (select 1 from public.audit_logs where action = 'sale.discount' and resource_id = pg_temp.k('s_disc')),
  'cancellations and discounts are audited');

-- =============================================================================
-- Invariants
-- =============================================================================
select is_empty($$
  select i.product_id from public.inventory i
    left join (select business_id, product_id, location_id, sum(quantity) s from public.inventory_movements group by 1, 2, 3) m
      using (business_id, product_id, location_id)
   where i.quantity <> coalesce(m.s, 0) $$,
  'stock ledger invariant holds after sales and cancellations');
select is_empty($$
  select c.id from public.customers c
    left join (select customer_id, sum(amount) s from public.customer_transactions group by 1) t on t.customer_id = c.id
   where c.balance <> coalesce(t.s, 0) $$,
  'customer ledger invariant holds after credit sales and cancellations');
select is_empty($$
  select s.id from public.sales s
    left join (select sale_id, sum(line_total) t from public.sale_items group by 1) i on i.sale_id = s.id
   where s.subtotal_amount <> coalesce(i.t, 0) $$,
  'every sale subtotal equals the sum of its lines');
select is_empty($$
  select s.id from public.sales s
    left join (select sale_id, sum(amount) p from public.payments where direction = 'IN' group by 1) p on p.sale_id = s.id
   where s.amount_paid <> coalesce(p.p, 0) $$,
  'every sale amount_paid equals the sum of its IN payments');
select is((select count(distinct number)::int from public.sales where business_id = pg_temp.k('a')),
  (select count(*)::int from public.sales where business_id = pg_temp.k('a')), 'sale numbers are unique');

-- =============================================================================
-- Other roles and tenants
-- =============================================================================
select tests.login('stock_a@test.local');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1))),
  '42501', 'PERMISSION_DENIED', 'STOCK_MANAGER cannot sell');
select is((select count(*)::int from public.sales), 0, 'STOCK_MANAGER cannot see sales');

select tests.login('owner_b@test.local');
select is((select count(*)::int from public.sales) + (select count(*)::int from public.sale_items)
          + (select count(*)::int from public.payments) + (select count(*)::int from public.sale_item_costs), 0,
  'B cannot see A sales, lines, payments or costs');
select throws_ok(format($$ select public.cancel_sale(%L, 'sabotage') $$, pg_temp.k('s2')),
  '42501', 'PERMISSION_DENIED', 'B cannot cancel an A sale');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'),
                        jsonb_build_array(pg_temp.item('huile', 1))),
  '42501', 'PERMISSION_DENIED', 'B cannot sell in A');
select throws_ok(format($$ select public.create_sale(%L, gen_random_uuid(), %L, %L) $$, pg_temp.k('b'), pg_temp.k('b_main'),
                        jsonb_build_array(pg_temp.item('huile', 1))),
  'P0002', 'PRODUCT_NOT_FOUND', 'B cannot sell an A product through its own business');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.sales $$, '42501', null, 'anon cannot read sales');
select throws_ok($$ select public.create_sale(null, null, null, null) $$, '42501', null, 'anon cannot sell');

select tests.clear_authentication();
select * from finish();
rollback;
