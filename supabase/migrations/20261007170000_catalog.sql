-- =============================================================================
-- JËND PRO — Catalog: categories, products, product costs (Phase 5)
-- -----------------------------------------------------------------------------
-- * categories / products: plain CRUD through PostgREST, protected by RLS and
--   explicit column grants. Products are never deleted (archived through
--   public.set_product_status, which requires products.delete).
-- * product_costs: purchase cost isolated in its own table so it can be hidden
--   from roles without `products.read_cost` (RLS is row-level, not column-level;
--   column privileges cannot depend on the business role). One row per product,
--   created automatically. Later maintained by purchases (weighted average cost).
-- * Composite FKs (business_id, …) make cross-tenant references impossible.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- categories
-- -----------------------------------------------------------------------------
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id),
  parent_id   uuid,
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  status      public.record_status not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categories_business_id_id_key unique (business_id, id),
  constraint categories_parent_fkey foreign key (business_id, parent_id)
    references public.categories (business_id, id),
  constraint categories_not_own_parent_check check (parent_id <> id)
);

comment on table public.categories is
  'Product categories, at most two levels (category > sub-category).';

create unique index categories_business_name_key
  on public.categories (business_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name))
  where status = 'ACTIVE';
-- Sub-category lookups and FK checks on parent deletion.
create index categories_business_id_parent_id_idx
  on public.categories (business_id, parent_id) where parent_id is not null;

create trigger set_updated_at
  before update on public.categories
  for each row execute function private.set_updated_at();

-- Two levels max: a parent cannot itself have a parent, and a category that
-- has children cannot become a child.
create or replace function private.validate_category()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  if new.parent_id is not null then
    if exists (select 1 from public.categories p where p.id = new.parent_id and p.parent_id is not null) then
      raise exception 'CATEGORY_TOO_DEEP' using errcode = 'P0001';
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from public.categories c where c.parent_id = new.id) then
      raise exception 'CATEGORY_TOO_DEEP' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create trigger validate_category
  before insert or update of name, parent_id on public.categories
  for each row execute function private.validate_category();

-- -----------------------------------------------------------------------------
-- products
-- -----------------------------------------------------------------------------
create table public.products (
  id                         uuid primary key default gen_random_uuid(),
  business_id                uuid not null references public.businesses (id),
  category_id                uuid,
  name                       text not null check (char_length(btrim(name)) between 1 and 150),
  description                text check (char_length(description) <= 2000),
  sku                        text check (char_length(sku) <= 64),
  barcode                    text check (char_length(barcode) <= 64),
  unit                       text not null default 'pièce' check (char_length(btrim(unit)) between 1 and 20),
  -- Integer amount in the business currency (XOF: francs). See business-rules §1.
  sale_price                 bigint not null default 0 check (sale_price >= 0),
  -- false = service / non-stocked item: no inventory, no stock checks (Phase 6).
  -- Immutable for clients once created (inventory consistency).
  track_stock                boolean not null default true,
  -- false = only whole quantities can be sold/moved (e.g. phones); true = kg, litre…
  allows_fractional_quantity boolean not null default false,
  min_stock_level            numeric(14, 3) not null default 0 check (min_stock_level >= 0),
  -- Storage path in bucket product-images; must live under the business folder.
  image_path                 text check (char_length(image_path) <= 500),
  status                     public.record_status not null default 'ACTIVE',
  created_by                 uuid default auth.uid() references auth.users (id) on delete set null,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  constraint products_business_id_id_key unique (business_id, id),
  constraint products_category_fkey foreign key (business_id, category_id)
    references public.categories (business_id, id),
  constraint products_business_id_sku_key unique (business_id, sku),
  constraint products_business_id_barcode_key unique (business_id, barcode),
  constraint products_image_path_scope_check
    check (image_path is null or image_path like business_id::text || '/%')
);

comment on table public.products is
  'Catalog item. Never deleted: archived via set_product_status(). Cost lives in product_costs.';

-- Catalog listing (filtered by business, sorted by name) and category filter / FK checks.
create index products_business_id_name_idx on public.products (business_id, name);
create index products_business_id_category_id_idx
  on public.products (business_id, category_id) where category_id is not null;

create trigger set_updated_at
  before update on public.products
  for each row execute function private.set_updated_at();

create or replace function private.normalize_product()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name    := btrim(new.name);
  new.unit    := btrim(new.unit);
  new.sku     := nullif(btrim(new.sku), '');
  new.barcode := nullif(btrim(new.barcode), '');
  return new;
end;
$$;

create trigger normalize_product
  before insert or update on public.products
  for each row execute function private.normalize_product();

-- -----------------------------------------------------------------------------
-- product_costs
-- -----------------------------------------------------------------------------
create table public.product_costs (
  product_id  uuid primary key,
  business_id uuid not null,
  -- Current unit cost (weighted average once purchases exist), business currency.
  cost_price  bigint not null default 0 check (cost_price >= 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- CASCADE is moot (products are never deleted) but keeps the pair consistent.
  constraint product_costs_product_fkey foreign key (business_id, product_id)
    references public.products (business_id, id) on delete cascade
);

comment on table public.product_costs is
  'Purchase cost per product, readable only with products.read_cost. One row per product.';

create trigger set_updated_at
  before update on public.product_costs
  for each row execute function private.set_updated_at();

create or replace function private.create_product_cost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.product_costs (product_id, business_id) values (new.id, new.business_id);
  return null;
end;
$$;

create trigger create_product_cost
  after insert on public.products
  for each row execute function private.create_product_cost();

-- -----------------------------------------------------------------------------
-- Audit: price and cost changes (business-rules §12)
-- -----------------------------------------------------------------------------
create or replace function private.audit_product_price()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_audit(new.business_id, 'product.price_change', 'product', new.id,
                            jsonb_build_object('old', old.sale_price, 'new', new.sale_price));
  return null;
end;
$$;

create trigger audit_product_price
  after update of sale_price on public.products
  for each row when (old.sale_price is distinct from new.sale_price)
  execute function private.audit_product_price();

create or replace function private.audit_product_cost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_audit(new.business_id, 'product.cost_change', 'product', new.product_id,
                            jsonb_build_object('old', old.cost_price, 'new', new.cost_price));
  return null;
end;
$$;

create trigger audit_product_cost
  after update of cost_price on public.product_costs
  for each row when (old.cost_price is distinct from new.cost_price)
  execute function private.audit_product_cost();

-- -----------------------------------------------------------------------------
-- Privileges + RLS
-- -----------------------------------------------------------------------------
alter table public.categories    enable row level security;
alter table public.products      enable row level security;
alter table public.product_costs enable row level security;

-- categories: readable with products.read, managed with categories.manage.
grant select on public.categories to authenticated;
grant insert (business_id, parent_id, name) on public.categories to authenticated;
grant update (parent_id, name, status) on public.categories to authenticated;
grant delete on public.categories to authenticated;

create policy "members with products.read can select categories"
  on public.categories for select to authenticated
  using (business_id in (select private.businesses_with_permission('products.read')));

create policy "members with categories.manage can insert categories"
  on public.categories for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('categories.manage')));

create policy "members with categories.manage can update categories"
  on public.categories for update to authenticated
  using (business_id in (select private.businesses_with_permission('categories.manage')))
  with check (business_id in (select private.businesses_with_permission('categories.manage')));

-- Deleting a category still referenced by products/sub-categories fails (FK);
-- archive it instead.
create policy "members with categories.manage can delete categories"
  on public.categories for delete to authenticated
  using (business_id in (select private.businesses_with_permission('categories.manage')));

-- products: status and track_stock are not client-updatable; created_by is server-set.
grant select on public.products to authenticated;
grant insert (business_id, category_id, name, description, sku, barcode, unit, sale_price,
              track_stock, allows_fractional_quantity, min_stock_level, image_path)
  on public.products to authenticated;
grant update (category_id, name, description, sku, barcode, unit, sale_price,
              allows_fractional_quantity, min_stock_level, image_path)
  on public.products to authenticated;

create policy "members with products.read can select products"
  on public.products for select to authenticated
  using (business_id in (select private.businesses_with_permission('products.read')));

create policy "members with products.create can insert products"
  on public.products for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('products.create')));

create policy "members with products.update can update products"
  on public.products for update to authenticated
  using (business_id in (select private.businesses_with_permission('products.update')))
  with check (business_id in (select private.businesses_with_permission('products.update')));

-- product_costs: read with products.read_cost; edit needs read_cost AND update.
grant select on public.product_costs to authenticated;
grant update (cost_price) on public.product_costs to authenticated;

create policy "members with products.read_cost can select product costs"
  on public.product_costs for select to authenticated
  using (business_id in (select private.businesses_with_permission('products.read_cost')));

create policy "members with products.read_cost and products.update can update product costs"
  on public.product_costs for update to authenticated
  using (business_id in (select private.businesses_with_permission('products.read_cost'))
         and business_id in (select private.businesses_with_permission('products.update')))
  with check (business_id in (select private.businesses_with_permission('products.read_cost'))
              and business_id in (select private.businesses_with_permission('products.update')));

-- -----------------------------------------------------------------------------
-- RPC: archive / reactivate a product (products.delete)
-- -----------------------------------------------------------------------------
create or replace function public.set_product_status(p_product_id uuid, p_status public.record_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products;
begin
  select * into v_product from public.products where id = p_product_id for update;
  -- Unknown id and foreign tenant produce the same error (no existence leak).
  perform private.require_permission(v_product.business_id, 'products.delete');

  if v_product.status = p_status then
    return;
  end if;

  update public.products set status = p_status where id = p_product_id;

  perform private.log_audit(v_product.business_id, 'product.status_change', 'product', p_product_id,
                            jsonb_build_object('from', v_product.status, 'to', p_status));
end;
$$;

revoke all on function public.set_product_status(uuid, public.record_status) from public, anon;
grant execute on function public.set_product_status(uuid, public.record_status) to authenticated;
