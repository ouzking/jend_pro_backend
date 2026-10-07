-- =============================================================================
-- JËND PRO — Storage: product images and business assets (Phase 5)
-- -----------------------------------------------------------------------------
-- Path convention: `{business_id}/...` — the first folder is the tenant.
-- Both buckets are PUBLIC for reads (decision 2026-10-07: non-sensitive,
-- CDN-friendly; object URLs contain random UUIDs). Writes, overwrites,
-- deletes and API listing are restricted to the business with the right
-- permission. Private buckets (documents, invoices) come with their phases.
-- SVG is excluded on purpose (script injection risk on a public domain).
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('product-images',  'product-images',  true, 2 * 1024 * 1024,
   array['image/jpeg', 'image/png', 'image/webp']),
  ('business-assets', 'business-assets', true, 1 * 1024 * 1024,
   array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Tenant of an object path; NULL when the first segment is not a UUID
-- (so malformed paths match no policy instead of raising a cast error).
create or replace function private.storage_business_id(p_name text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case
    when split_part(p_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;

grant execute on function private.storage_business_id(text) to authenticated;

-- -----------------------------------------------------------------------------
-- product-images: write with products.update, list with products.read
-- -----------------------------------------------------------------------------
create policy "product-images: members with products.read can list"
  on storage.objects for select to authenticated
  using (bucket_id = 'product-images'
         and private.storage_business_id(name) in (select private.businesses_with_permission('products.read')));

create policy "product-images: members with products.update can upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images'
              and private.storage_business_id(name) in (select private.businesses_with_permission('products.update')));

create policy "product-images: members with products.update can replace"
  on storage.objects for update to authenticated
  using (bucket_id = 'product-images'
         and private.storage_business_id(name) in (select private.businesses_with_permission('products.update')))
  with check (bucket_id = 'product-images'
              and private.storage_business_id(name) in (select private.businesses_with_permission('products.update')));

create policy "product-images: members with products.update can delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'product-images'
         and private.storage_business_id(name) in (select private.businesses_with_permission('products.update')));

-- -----------------------------------------------------------------------------
-- business-assets (logo…): write with settings.manage, list for members
-- -----------------------------------------------------------------------------
create policy "business-assets: members can list"
  on storage.objects for select to authenticated
  using (bucket_id = 'business-assets'
         and private.storage_business_id(name) in (select private.member_business_ids()));

create policy "business-assets: members with settings.manage can upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'business-assets'
              and private.storage_business_id(name) in (select private.businesses_with_permission('settings.manage')));

create policy "business-assets: members with settings.manage can replace"
  on storage.objects for update to authenticated
  using (bucket_id = 'business-assets'
         and private.storage_business_id(name) in (select private.businesses_with_permission('settings.manage')))
  with check (bucket_id = 'business-assets'
              and private.storage_business_id(name) in (select private.businesses_with_permission('settings.manage')));

create policy "business-assets: members with settings.manage can delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'business-assets'
         and private.storage_business_id(name) in (select private.businesses_with_permission('settings.manage')));

-- Logo path must live under the business folder (same rule as product images).
alter table public.businesses
  add constraint businesses_logo_path_scope_check
  check (logo_path is null or logo_path like id::text || '/%');
