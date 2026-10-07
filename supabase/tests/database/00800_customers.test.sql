-- Customers, credit, customer payments: rules, atomicity, ledger invariant, tenancy.
begin;
select plan(39);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on function pg_temp.k(text) to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('b', tests.business_id('Business B')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default)),
  ('b_main', (select id from public.locations where business_id = tests.business_id('Business B') and is_default));

-- =============================================================================
-- Customer creation (CASHIER has customers.create only)
-- =============================================================================
select tests.login('cashier_a@test.local');
with c as (
  insert into public.customers (business_id, name, phone)
  values (pg_temp.k('a'), ' Fatou Sow ', ' 77 123-45.67 ') returning id)
insert into ids select 'fatou', id from c;

select is((select row(name, phone, credit_limit, balance, created_by)::text from public.customers where id = pg_temp.k('fatou')),
  row('Fatou Sow', '771234567', 0::bigint, 0::bigint, tests.get_user_id('cashier_a@test.local'))::text,
  'CASHIER can create a customer; phone normalized; no credit by default; created_by server-side');
select throws_ok(format($$ insert into public.customers (business_id, name, credit_limit) values (%L, 'Crédit illimité', null) $$, pg_temp.k('a')),
  '42501', null, 'credit_limit cannot be set at creation by the client');
select throws_ok(format($$ insert into public.customers (business_id, name, balance) values (%L, 'Solde forgé', 1000) $$, pg_temp.k('a')),
  '42501', null, 'balance cannot be set by the client');
select throws_ok(format($$ update public.customers set balance = 0 where id = %L $$, pg_temp.k('fatou')),
  '42501', null, 'balance cannot be updated by the client');
select throws_ok(format($$ select public.set_customer_credit_limit(%L, 1000000) $$, pg_temp.k('fatou')),
  '42501', 'PERMISSION_DENIED', 'CASHIER cannot set a credit limit');
update public.customers set name = 'Renamed by cashier' where id = pg_temp.k('fatou');

select tests.clear_authentication();
select is((select name from public.customers where id = pg_temp.k('fatou')), 'Fatou Sow',
  'CASHIER cannot edit customers (customers.manage)');

-- =============================================================================
-- Credit limit and opening balance (MANAGER)
-- =============================================================================
select tests.login('manager_a@test.local');
select lives_ok(format($$ select public.set_customer_credit_limit(%L, 50000) $$, pg_temp.k('fatou')),
  'MANAGER can set a credit limit');
select lives_ok(format($$ select public.adjust_customer_balance(%L, 30000, 'Reprise cahier de crédit') $$, pg_temp.k('fatou')),
  'MANAGER can record an opening debt');
select is((select balance from public.customers where id = pg_temp.k('fatou')), 30000::bigint, 'balance is updated');
select throws_ok(format($$ select public.adjust_customer_balance(%L, 100, '  ') $$, pg_temp.k('fatou')),
  '22023', 'REASON_REQUIRED', 'a reason is required for manual adjustments');
select throws_ok(format($$ select public.adjust_customer_balance(%L, -40000, 'erreur') $$, pg_temp.k('fatou')),
  'P0001', 'AMOUNT_EXCEEDS_BALANCE', 'a balance cannot go below zero (no credit note in V1)');
select throws_ok(format($$ update public.customers set status = 'ARCHIVED' where id = %L $$, pg_temp.k('fatou')),
  'P0001', 'CUSTOMER_HAS_BALANCE', 'a customer who owes money cannot be archived');

-- =============================================================================
-- Payments (CASHIER has customers.payments)
-- =============================================================================
select tests.login('cashier_a@test.local');
select lives_ok(format($$ select public.record_customer_payment(%L, 10000, 'CASH', %L) $$, pg_temp.k('fatou'), pg_temp.k('a_main')),
  'CASHIER can record a debt settlement');
select is((select balance from public.customers where id = pg_temp.k('fatou')), 20000::bigint,
  'the settlement reduces the balance');
select is((select row(t.type, t.amount, t.balance_after, p.direction, p.method, p.amount, p.recorded_by)::text
             from public.customer_transactions t join public.payments p on p.id = t.payment_id
            where t.customer_id = pg_temp.k('fatou') and t.type = 'PAYMENT'),
  row('PAYMENT'::public.customer_transaction_type, -10000::bigint, 20000::bigint, 'IN'::public.payment_direction,
      'CASH'::public.payment_method, 10000::bigint, tests.get_user_id('cashier_a@test.local'))::text,
  'one payment IN and one linked ledger entry are written');
select throws_ok(format($$ select public.record_customer_payment(%L, 25000, 'CASH', %L) $$, pg_temp.k('fatou'), pg_temp.k('a_main')),
  'P0001', 'AMOUNT_EXCEEDS_BALANCE', 'a settlement cannot exceed the amount owed');
select is((select count(*)::int from public.payments where customer_id = pg_temp.k('fatou')), 1,
  'a refused settlement leaves no payment behind (atomic)');
select throws_ok(format($$ select public.record_customer_payment(%L, 0, 'CASH', %L) $$, pg_temp.k('fatou'), pg_temp.k('a_main')),
  '22023', 'INVALID_AMOUNT', 'amount must be positive');
select throws_ok(format($$ select public.record_customer_payment(%L, 100, 'CASH', %L) $$, pg_temp.k('fatou'), pg_temp.k('b_main')),
  'P0002', 'LOCATION_NOT_FOUND', 'a payment cannot be booked on another business location');
select lives_ok(format($$ select public.record_customer_payment(%L, 5000, 'WAVE', %L, 'WAVE-TX-123') $$, pg_temp.k('fatou'), pg_temp.k('a_main')),
  'a mobile-money settlement can carry its transaction reference');
select throws_ok(format($$ select public.record_customer_payment(%L, 5000, 'WAVE', %L, 'WAVE-TX-123') $$, pg_temp.k('fatou'), pg_temp.k('a_main')),
  '23505', null, 'the same mobile-money transaction cannot be recorded twice');
select ok((select count(*) from public.payments) = 2, 'CASHIER can see customer payments');

-- Direct writes are impossible.
select throws_ok(format($$ insert into public.payments (business_id, location_id, direction, method, amount, customer_id)
                           values (%L, %L, 'IN', 'CASH', 1, %L) $$, pg_temp.k('a'), pg_temp.k('a_main'), pg_temp.k('fatou')),
  '42501', null, 'payments cannot be inserted directly');
select throws_ok(format($$ insert into public.customer_transactions (business_id, customer_id, type, amount, balance_after, note)
                           values (%L, %L, 'ADJUSTMENT', -15000, 0, 'effacement') $$, pg_temp.k('a'), pg_temp.k('fatou')),
  '42501', null, 'ledger entries cannot be inserted directly');
select throws_ok($$ select private.apply_customer_transaction(null, null, 'PAYMENT', -1) $$,
  '42501', null, 'the account engine is not callable by API roles');

select tests.clear_authentication();

-- =============================================================================
-- Invariants and append-only
-- =============================================================================
select is_empty($$
  select c.id from public.customers c
    left join (select customer_id, sum(amount) s from public.customer_transactions group by 1) t on t.customer_id = c.id
   where c.balance <> coalesce(t.s, 0) $$,
  'ledger invariant: every balance equals the sum of its transactions');
select throws_ok($$ update public.payments set amount = 1 $$, 'P0001', 'APPEND_ONLY', 'payments are append-only');
select throws_ok($$ update public.customer_transactions set amount = 1 $$, 'P0001', 'APPEND_ONLY',
  'customer transactions are append-only');
select ok((select count(*) from public.audit_logs where business_id = pg_temp.k('a')
            and action in ('customer.payment', 'customer.balance_adjust', 'customer.credit_limit_change')) = 4,
  'settlements, adjustments and credit limit changes are audited');

-- =============================================================================
-- Other roles and tenants
-- =============================================================================
select tests.login('stock_a@test.local');
select is((select count(*)::int from public.customers) + (select count(*)::int from public.payments), 0,
  'STOCK_MANAGER cannot see customers nor payments');

select tests.login('owner_b@test.local');
select is((select count(*)::int from public.customers) + (select count(*)::int from public.payments)
          + (select count(*)::int from public.customer_transactions), 0,
  'B cannot see A customers, payments or ledger');
select throws_ok(format($$ select public.record_customer_payment(%L, 100, 'CASH', %L) $$, pg_temp.k('fatou'), pg_temp.k('b_main')),
  '42501', 'PERMISSION_DENIED', 'B cannot settle an A customer debt');
select throws_ok(format($$ select public.adjust_customer_balance(%L, -15000, 'effacement') $$, pg_temp.k('fatou')),
  '42501', 'PERMISSION_DENIED', 'B cannot erase an A customer debt');
select throws_ok(format($$ select public.set_customer_credit_limit(%L, null) $$, pg_temp.k('fatou')),
  '42501', 'PERMISSION_DENIED', 'B cannot change an A credit limit');
select throws_ok(format($$ select public.record_customer_payment(%L, 100, 'CASH', %L) $$, gen_random_uuid(), pg_temp.k('b_main')),
  '42501', 'PERMISSION_DENIED', 'an unknown customer gives the same error (no existence leak)');
select throws_ok(format($$ insert into public.customers (business_id, name) values (%L, 'Intrus') $$, pg_temp.k('a')),
  '42501', null, 'B cannot create customers in A');
update public.customers set name = 'pwned' where id = pg_temp.k('fatou');

select tests.clear_authentication();
select is((select name from public.customers where id = pg_temp.k('fatou')), 'Fatou Sow',
  'cross-tenant customer update had no effect');
select is((select balance from public.customers where id = pg_temp.k('fatou')), 15000::bigint,
  'final balance: 30 000 - 10 000 - 5 000 (credit sales are covered in 01000_sales)');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.customers $$, '42501', null, 'anon cannot read customers');
select tests.clear_authentication();

select * from finish();
rollback;
