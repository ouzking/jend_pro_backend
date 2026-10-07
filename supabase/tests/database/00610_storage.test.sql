-- Storage policies: product-images and business-assets are tenant-scoped.
begin;
select plan(14);

-- The Storage API sets this to perform deletes; emulate it so the DELETE
-- policies (not storage.protect_delete) are what is being tested.
set local storage.allow_delete_query = 'true';

select tests.setup_two_tenants();

select is((select public from storage.buckets where id = 'product-images'), true,
  'product-images is a public-read bucket');
select is((select allowed_mime_types from storage.buckets where id = 'product-images'),
  array['image/jpeg', 'image/png', 'image/webp'], 'product-images accepts only raster images (no SVG)');

-- -----------------------------------------------------------------------------
-- product-images
-- -----------------------------------------------------------------------------
select tests.login('stock_a@test.local');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('product-images', %L) $$,
                       tests.business_id('Business A') || '/p1/photo.png'),
  'STOCK_MANAGER can upload a product image in their business folder');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('product-images', %L) $$,
                        tests.business_id('Business B') || '/p1/photo.png'),
  '42501', null, 'nobody can upload into another business folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('product-images', 'not-a-uuid/photo.png') $$,
  '42501', null, 'paths outside a business folder are rejected');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('business-assets', %L) $$,
                        tests.business_id('Business A') || '/logo.png'),
  '42501', null, 'STOCK_MANAGER cannot upload the business logo (settings.manage)');

select tests.login('cashier_a@test.local');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('product-images', %L) $$,
                        tests.business_id('Business A') || '/p2/photo.png'),
  '42501', null, 'CASHIER cannot upload product images');
select is((select count(*)::int from storage.objects where bucket_id = 'product-images'), 1,
  'CASHIER can list their business images');
delete from storage.objects where bucket_id = 'product-images';

select tests.login('owner_b@test.local');
select is((select count(*)::int from storage.objects where bucket_id = 'product-images'), 0,
  'B cannot list A images');
delete from storage.objects where bucket_id = 'product-images';
update storage.objects set name = tests.business_id('Business B') || '/stolen.png' where bucket_id = 'product-images';

select tests.clear_authentication();
select is((select name from storage.objects where bucket_id = 'product-images'),
  tests.business_id('Business A') || '/p1/photo.png',
  'neither CASHIER nor another business can delete, move or rename the image');

select tests.login('stock_a@test.local');
delete from storage.objects where bucket_id = 'product-images';
select tests.clear_authentication();
select is((select count(*)::int from storage.objects where bucket_id = 'product-images'), 0,
  'a member with products.update can delete their business images');

-- -----------------------------------------------------------------------------
-- business-assets
-- -----------------------------------------------------------------------------
select tests.login('admin_a@test.local');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('business-assets', %L) $$,
                       tests.business_id('Business A') || '/logo.png'),
  'ADMIN can upload the business logo');
select lives_ok(format($$ update public.businesses set logo_path = %L where id = %L $$,
                       tests.business_id('Business A') || '/logo.png', tests.business_id('Business A')),
  'logo_path under the business folder is accepted');
select throws_ok(format($$ update public.businesses set logo_path = %L where id = %L $$,
                        tests.business_id('Business B') || '/logo.png', tests.business_id('Business A')),
  '23514', null, 'logo_path pointing to another business folder is rejected');

select tests.clear_authentication();
select * from finish();
rollback;
