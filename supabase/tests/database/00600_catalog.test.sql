-- Catalog: categories, products, cost isolation, archiving, audit, tenancy.
begin;
select plan(39);

select tests.setup_two_tenants();

-- Fixture ids reused through the file.
create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;

-- =============================================================================
-- Categories
-- =============================================================================
select tests.login('stock_a@test.local');

with ins as (
  insert into public.categories (business_id, name)
  values (tests.business_id('Business A'), '  Boissons ') returning id)
insert into ids select 'cat_a', id from ins;
with ins as (
  insert into public.categories (business_id, parent_id, name)
  values (tests.business_id('Business A'), (select id from ids where key = 'cat_a'), 'Jus') returning id)
insert into ids select 'sub_a', id from ins;

select is((select name from public.categories where id = (select id from ids where key = 'cat_a')),
  'Boissons', 'STOCK_MANAGER can create a category (name is trimmed)');
select throws_ok(format($$ insert into public.categories (business_id, parent_id, name) values (%L, %L, 'Trop profond') $$,
                        tests.business_id('Business A'), (select id from ids where key = 'sub_a')),
  'P0001', 'CATEGORY_TOO_DEEP', 'categories are limited to two levels');
select throws_ok(format($$ insert into public.categories (business_id, name) values (%L, 'boissons') $$,
                        tests.business_id('Business A')),
  '23505', null, 'active category names are unique per business and level (case-insensitive)');

select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.categories), 2, 'CASHIER can read categories');
select throws_ok(format($$ insert into public.categories (business_id, name) values (%L, 'Caisse') $$,
                        tests.business_id('Business A')),
  '42501', null, 'CASHIER cannot create categories');

select tests.login('owner_b@test.local');
select is((select count(*)::int from public.categories), 0, 'B cannot see A categories');
select throws_ok(format($$ insert into public.categories (business_id, parent_id, name) values (%L, %L, 'Pirate') $$,
                        tests.business_id('Business B'), (select id from ids where key = 'cat_a')),
  '23503', null, 'a B category cannot use an A category as parent (composite FK)');
select lives_ok(format($$ insert into public.categories (business_id, name) values (%L, 'Boissons') $$,
                       tests.business_id('Business B')),
  'the same category name is allowed in another business');

-- =============================================================================
-- Products
-- =============================================================================
select tests.login('stock_a@test.local');

with ins as (
  insert into public.products (business_id, category_id, name, sku, barcode, unit, sale_price, min_stock_level, image_path)
  values (tests.business_id('Business A'), (select id from ids where key = 'cat_a'), ' Bissap 1L ', ' BIS-1L ', '',
          'bouteille', 1500, 10, tests.business_id('Business A') || '/bissap.png')
  returning id)
insert into ids select 'prod_a', id from ins;

select is((select row(name, sku, barcode, unit)::text from public.products where id = (select id from ids where key = 'prod_a')),
  row('Bissap 1L', 'BIS-1L', null::text, 'bouteille')::text, 'product fields are normalized (trim, empty barcode -> NULL)');
select is((select created_by from public.products where id = (select id from ids where key = 'prod_a')),
  tests.get_user_id('stock_a@test.local'), 'created_by is set server-side');
select is((select status from public.products where id = (select id from ids where key = 'prod_a')),
  'ACTIVE'::public.record_status, 'new products are ACTIVE');
select is((select cost_price from public.product_costs where product_id = (select id from ids where key = 'prod_a')),
  0::bigint, 'a cost row (0) is created automatically');

select throws_ok(format($$ insert into public.products (business_id, name, sku) values (%L, 'Doublon', 'BIS-1L') $$,
                        tests.business_id('Business A')),
  '23505', null, 'SKU is unique per business');
select throws_ok(format($$ insert into public.products (business_id, name, sale_price) values (%L, 'Négatif', -5) $$,
                        tests.business_id('Business A')),
  '23514', null, 'negative prices are rejected');
select throws_ok(format($$ insert into public.products (business_id, name, image_path) values (%L, 'Image volée', %L) $$,
                        tests.business_id('Business A'), tests.business_id('Business B') || '/x.png'),
  '23514', null, 'image_path must live under the product''s business folder');
select throws_ok(format($$ insert into public.products (business_id, name, created_by) values (%L, 'Usurpation', %L) $$,
                        tests.business_id('Business A'), tests.get_user_id('owner_a@test.local')),
  '42501', null, 'created_by cannot be supplied by the client');
select throws_ok(format($$ insert into public.products (business_id, name, status) values (%L, 'Statut', 'ARCHIVED') $$,
                        tests.business_id('Business A')),
  '42501', null, 'status cannot be supplied by the client');
select throws_ok($$ update public.products set track_stock = false $$,
  '42501', null, 'track_stock is immutable for clients');
select throws_ok(format($$ update public.products set business_id = %L $$, tests.business_id('Business B')),
  '42501', null, 'a product cannot be moved to another business');
select throws_ok($$ delete from public.products $$, '42501', null, 'products cannot be deleted');
select throws_ok(format($$ select public.set_product_status(%L, 'ARCHIVED') $$, (select id from ids where key = 'prod_a')),
  '42501', 'PERMISSION_DENIED', 'STOCK_MANAGER cannot archive (no products.delete)');

update public.products set sale_price = 1750 where id = (select id from ids where key = 'prod_a');
update public.product_costs set cost_price = 900 where product_id = (select id from ids where key = 'prod_a');

select tests.clear_authentication();
select ok(exists (select 1 from public.audit_logs where action = 'product.price_change'
                   and resource_id = (select id from ids where key = 'prod_a')
                   and metadata = '{"old": 1500, "new": 1750}'::jsonb),
  'price changes are audited (old/new)');
select ok(exists (select 1 from public.audit_logs where action = 'product.cost_change'
                   and resource_id = (select id from ids where key = 'prod_a')
                   and metadata = '{"old": 0, "new": 900}'::jsonb
                   and actor_id = tests.get_user_id('stock_a@test.local')),
  'cost changes are audited with the actor');

-- =============================================================================
-- Cost isolation (CASHIER)
-- =============================================================================
select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.products), 1, 'CASHIER can read products');
select is((select count(*)::int from public.product_costs), 0, 'CASHIER cannot read product costs');
update public.product_costs set cost_price = 1 where product_id = (select id from ids where key = 'prod_a');
update public.products set sale_price = 1 where id = (select id from ids where key = 'prod_a');
select throws_ok(format($$ insert into public.products (business_id, name) values (%L, 'Caisse') $$,
                        tests.business_id('Business A')),
  '42501', null, 'CASHIER cannot create products');

select tests.clear_authentication();
select is((select sale_price from public.products where id = (select id from ids where key = 'prod_a')),
  1750::bigint, 'CASHIER cannot change prices');
select is((select cost_price from public.product_costs where product_id = (select id from ids where key = 'prod_a')),
  900::bigint, 'CASHIER cannot change costs');

-- =============================================================================
-- Archiving (MANAGER has products.delete)
-- =============================================================================
select tests.login('manager_a@test.local');
select lives_ok(format($$ select public.set_product_status(%L, 'ARCHIVED') $$, (select id from ids where key = 'prod_a')),
  'MANAGER can archive a product');
select is((select status from public.products where id = (select id from ids where key = 'prod_a')),
  'ARCHIVED'::public.record_status, 'product is archived (still readable for history)');
select throws_ok(format($$ delete from public.categories where id = %L $$, (select id from ids where key = 'cat_a')),
  '23503', null, 'a category referenced by products cannot be deleted');

-- =============================================================================
-- Cross-tenant (B probing A)
-- =============================================================================
select tests.login('owner_b@test.local');
select is((select count(*)::int from public.products) + (select count(*)::int from public.product_costs),
  0, 'B cannot see A products nor costs');
update public.products set name = 'pwned' where id = (select id from ids where key = 'prod_a');
select throws_ok(format($$ insert into public.products (business_id, name) values (%L, 'Intrus') $$,
                        tests.business_id('Business A')),
  '42501', null, 'B cannot create products in A');
select throws_ok(format($$ insert into public.products (business_id, category_id, name) values (%L, %L, 'Pirate') $$,
                        tests.business_id('Business B'), (select id from ids where key = 'cat_a')),
  '23503', null, 'a B product cannot reference an A category (composite FK)');
select throws_ok(format($$ select public.set_product_status(%L, 'ACTIVE') $$, (select id from ids where key = 'prod_a')),
  '42501', 'PERMISSION_DENIED', 'B cannot change the status of an A product');
select throws_ok(format($$ select public.set_product_status(%L, 'ACTIVE') $$, gen_random_uuid()),
  '42501', 'PERMISSION_DENIED', 'an unknown product gives the same error (no existence leak)');
select lives_ok(format($$ insert into public.products (business_id, name, sku) values (%L, 'Bissap B', 'BIS-1L') $$,
                       tests.business_id('Business B')),
  'the same SKU is allowed in another business');

select tests.clear_authentication();
select is((select name from public.products where id = (select id from ids where key = 'prod_a')),
  'Bissap 1L', 'cross-tenant product update had no effect');

select tests.authenticate_as_anon();
select throws_ok($$ select * from public.products $$, '42501', null, 'anon cannot read products');
select tests.clear_authentication();

select * from finish();
rollback;
