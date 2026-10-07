-- Expenses (with full audit), employees, private documents bucket, tenancy.
begin;
select plan(42);

select tests.setup_two_tenants();
set local storage.allow_delete_query = 'true';

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
create function pg_temp.cat(text, text) returns uuid language sql as
  $$ select id from public.expense_categories where business_id = pg_temp.k($1) and name = $2 $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into ids values
  ('a', tests.business_id('Business A')),
  ('b', tests.business_id('Business B')),
  ('a_main', (select id from public.locations where business_id = tests.business_id('Business A') and is_default)),
  ('cashier_member', (select id from public.business_members where business_id = tests.business_id('Business A')
                        and user_id = tests.get_user_id('cashier_a@test.local'))),
  ('b_member', (select id from public.business_members where business_id = tests.business_id('Business B')
                  and user_id = tests.get_user_id('owner_b@test.local')));
insert into ids values ('b_loyer', pg_temp.cat('b', 'Loyer'));

-- =============================================================================
-- Categories
-- =============================================================================
select is((select count(*)::int from public.expense_categories where business_id = pg_temp.k('a')), 10,
  'a new business gets the default expense categories');

select tests.login('manager_a@test.local');
select throws_ok(format($$ insert into public.expense_categories (business_id, name) values (%L, 'Publicité') $$, pg_temp.k('a')),
  '42501', null, 'MANAGER cannot manage expense categories');

select tests.login('owner_a@test.local');
select lives_ok(format($$ insert into public.expense_categories (business_id, name) values (%L, 'Publicité') $$, pg_temp.k('a')),
  'OWNER can add an expense category');
select throws_ok(format($$ insert into public.expense_categories (business_id, name) values (%L, 'loyer') $$, pg_temp.k('a')),
  '23505', null, 'active category names are unique (case-insensitive)');

-- =============================================================================
-- Expenses
-- =============================================================================
select tests.login('manager_a@test.local');
with e as (
  insert into public.expenses (business_id, category_id, location_id, amount, description, spent_on, method)
  values (pg_temp.k('a'), pg_temp.cat('a', 'Loyer'), pg_temp.k('a_main'), 150000, 'Loyer octobre', '2026-10-01', 'BANK_TRANSFER')
  returning id)
insert into ids select 'e1', id from e;

select is((select created_by from public.expenses where id = pg_temp.k('e1')), tests.get_user_id('manager_a@test.local'),
  'MANAGER can record an expense; created_by is server-side');
select throws_ok(format($$ insert into public.expenses (business_id, category_id, amount) values (%L, %L, 0) $$,
                        pg_temp.k('a'), pg_temp.cat('a', 'Loyer')),
  '23514', null, 'amounts must be positive');
select throws_ok(format($$ insert into public.expenses (business_id, category_id, amount, receipt_path) values (%L, %L, 1, %L) $$,
                        pg_temp.k('a'), pg_temp.cat('a', 'Loyer'), pg_temp.k('b') || '/expenses/x.pdf'),
  '23514', null, 'a receipt must live in the business expenses folder');
select throws_ok(format($$ insert into public.expenses (business_id, category_id, amount) values (%L, %L, 1) $$,
                        pg_temp.k('a'), pg_temp.k('b_loyer')),
  '23503', null, 'a category of another business cannot be used (composite FK)');
select throws_ok(format($$ insert into public.expenses (business_id, category_id, amount, created_by) values (%L, %L, 1, %L) $$,
                        pg_temp.k('a'), pg_temp.cat('a', 'Loyer'), tests.get_user_id('owner_a@test.local')),
  '42501', null, 'created_by cannot be supplied');

update public.expenses set amount = 1 where id = pg_temp.k('e1');
delete from public.expenses where id = pg_temp.k('e1');
select tests.clear_authentication();
select is((select amount from public.expenses where id = pg_temp.k('e1')), 150000::bigint,
  'MANAGER cannot edit nor delete expenses (expenses.manage)');

select tests.login('owner_a@test.local');
select lives_ok(format($$ update public.expenses set amount = 160000 where id = %L $$, pg_temp.k('e1')),
  'OWNER can correct an expense');
select lives_ok(format($$ delete from public.expenses where id = %L $$, pg_temp.k('e1')),
  'OWNER can delete an expense');

select tests.clear_authentication();
select is((select string_agg(action, ',' order by created_at, action) from public.audit_logs where resource_id = pg_temp.k('e1')),
  'expense.create,expense.delete,expense.update',
  'creation, correction and deletion are all audited');
select is((select (metadata -> 'old' ->> 'amount') || '->' || (metadata -> 'new' ->> 'amount')
             from public.audit_logs where resource_id = pg_temp.k('e1') and action = 'expense.update'),
  '150000->160000', 'the correction keeps old and new values');
select is((select metadata -> 'old' ->> 'description' from public.audit_logs
            where resource_id = pg_temp.k('e1') and action = 'expense.delete'),
  'Loyer octobre', 'a deleted expense remains fully traceable in the audit log');

select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.expenses) + (select count(*)::int from public.expense_categories), 0,
  'CASHIER cannot see expenses');
select throws_ok(format($$ insert into public.expenses (business_id, category_id, amount) values (%L, %L, 1) $$,
                        pg_temp.k('a'), pg_temp.cat('a', 'Loyer')),
  '42501', null, 'CASHIER cannot record expenses');

select tests.login('stock_a@test.local');
select is((select count(*)::int from public.expenses), 0, 'STOCK_MANAGER cannot see expenses');

-- =============================================================================
-- Employees
-- =============================================================================
select tests.login('admin_a@test.local');
with e as (
  insert into public.employees (business_id, full_name, phone, position, salary_amount, hired_at, member_id)
  values (pg_temp.k('a'), ' Moussa Fall ', '77 000 00 01', 'Caissier', 120000, '2026-01-15', pg_temp.k('cashier_member'))
  returning id)
insert into ids select 'emp1', id from e;
select is((select full_name || '|' || phone from public.employees where id = pg_temp.k('emp1')), 'Moussa Fall|770000001',
  'ADMIN can create an employee linked to a member (normalized)');
with e as (
  insert into public.employees (business_id, full_name, position, salary_amount)
  values (pg_temp.k('a'), 'Awa Diop', 'Ménage', 60000) returning id)
insert into ids select 'emp2', id from e;
select ok((select member_id is null from public.employees where id = pg_temp.k('emp2')),
  'an employee does not need a login account');
select throws_ok(format($$ insert into public.employees (business_id, full_name, member_id) values (%L, 'Doublon', %L) $$,
                        pg_temp.k('a'), pg_temp.k('cashier_member')),
  '23505', null, 'a member is linked to at most one employee record');
select throws_ok(format($$ insert into public.employees (business_id, full_name, member_id) values (%L, 'Intrus', %L) $$,
                        pg_temp.k('a'), pg_temp.k('b_member')),
  '23503', null, 'an employee cannot be linked to a member of another business');
select throws_ok(format($$ insert into public.employees (business_id, full_name, hired_at, ended_at) values (%L, 'X', '2026-05-01', '2026-01-01') $$,
                        pg_temp.k('a')),
  '23514', null, 'end date cannot precede hire date');
select lives_ok(format($$ update public.employees set salary_amount = 130000 where id = %L $$, pg_temp.k('emp1')),
  'ADMIN can change a salary');
select throws_ok($$ delete from public.employees $$, '42501', null, 'employees are archived, never deleted');

select tests.login('manager_a@test.local');
select is((select salary_amount from public.employees where id = pg_temp.k('emp1')), 130000::bigint,
  'MANAGER (employees.read) can see employees and salaries');
select throws_ok(format($$ insert into public.employees (business_id, full_name) values (%L, 'X') $$, pg_temp.k('a')),
  '42501', null, 'MANAGER cannot create employees (employees.manage)');

select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.employees), 0, 'CASHIER cannot see employees nor salaries');

select tests.clear_authentication();
select ok(exists (select 1 from public.audit_logs where action = 'employee.salary_change' and resource_id = pg_temp.k('emp1')
                   and metadata = '{"old": 120000, "new": 130000}'::jsonb),
  'salary changes are audited');
delete from public.business_members where id = pg_temp.k('cashier_member');
select ok((select member_id is null from public.employees where id = pg_temp.k('emp1')),
  'removing the member keeps the employee record (link set to NULL)');

-- =============================================================================
-- documents bucket (private)
-- =============================================================================
select is((select public from storage.buckets where id = 'documents'), false, 'documents is a private bucket');

select tests.login('manager_a@test.local');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$, pg_temp.k('a') || '/expenses/recu.pdf'),
  'MANAGER can upload an expense receipt');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$, pg_temp.k('a') || '/autres/x.pdf'),
  '42501', null, 'only the expenses folder is writable in documents');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$, pg_temp.k('b') || '/expenses/x.pdf'),
  '42501', null, 'cannot upload into another business folder');
select is((select count(*)::int from storage.objects where bucket_id = 'documents'), 1, 'MANAGER can read the receipt');

select tests.login('cashier_a@test.local');
select is((select count(*)::int from storage.objects where bucket_id = 'documents'), 0, 'CASHIER cannot read receipts');

select tests.login('owner_b@test.local');
select is((select count(*)::int from storage.objects where bucket_id = 'documents'), 0, 'B cannot read A receipts');
delete from storage.objects where bucket_id = 'documents';
select tests.clear_authentication();
select is((select count(*)::int from storage.objects where bucket_id = 'documents'), 1, 'B cannot delete A receipts');

-- =============================================================================
-- Cross-tenant and anon
-- =============================================================================
select tests.login('owner_b@test.local');
select is((select count(*)::int from public.expenses where business_id = pg_temp.k('a'))
          + (select count(*)::int from public.expense_categories where business_id = pg_temp.k('a'))
          + (select count(*)::int from public.employees), 0,
  'B cannot see A expenses, categories or employees');
select throws_ok(format($$ insert into public.expenses (business_id, category_id, amount) values (%L, %L, 1) $$,
                        pg_temp.k('a'), pg_temp.cat('a', 'Loyer')),
  '42501', null, 'B cannot record expenses in A');
update public.employees set salary_amount = 1 where id = pg_temp.k('emp2');
select tests.clear_authentication();
select is((select salary_amount from public.employees where id = pg_temp.k('emp2')), 60000::bigint,
  'B cannot change A salaries');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.expenses $$, '42501', null, 'anon cannot read expenses');

select tests.clear_authentication();
select * from finish();
rollback;
