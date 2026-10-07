-- =============================================================================
-- JËND PRO — Inventory (Phase 6)
-- -----------------------------------------------------------------------------
-- * inventory_movements: append-only ledger (signed quantities).
-- * inventory: current stock per (product, location) — a CACHE of the ledger.
--   Invariant: inventory.quantity = SUM(inventory_movements.quantity).
-- * private.apply_stock_movement() is the ONLY writer of both tables. It locks
--   the stock row, enforces business rules (negative stock, whole quantities,
--   stocked products, active locations) and writes cache + ledger atomically.
--   Sales and purchases (Phases 8-9) reuse it.
-- * Clients never write these tables: they call adjust_stock / count_stock /
--   transfer_stock. See docs/business-rules.md §3.
-- =============================================================================

create type public.inventory_movement_type as enum (
  'INITIAL',            -- opening stock (once per product × location)
  'PURCHASE',           -- purchase receipt (Phase 8)
  'SALE',               -- sale (Phase 9)
  'SALE_CANCELLATION',  -- sale cancelled (Phase 9)
  'RETURN',             -- customer return (Phase 9)
  'ADJUSTMENT',         -- physical count / correction (signed)
  'TRANSFER_OUT',       -- transfer, source side
  'TRANSFER_IN',        -- transfer, destination side
  'LOSS',               -- loss, theft
  'DAMAGE'              -- breakage, expiry
);

-- -----------------------------------------------------------------------------
-- inventory — current stock (cache)
-- -----------------------------------------------------------------------------
create table public.inventory (
  business_id uuid not null,
  product_id  uuid not null,
  location_id uuid not null,
  quantity    numeric(14, 3) not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (business_id, product_id, location_id),
  constraint inventory_product_fkey foreign key (business_id, product_id)
    references public.products (business_id, id),
  constraint inventory_location_fkey foreign key (business_id, location_id)
    references public.locations (business_id, id)
);

comment on table public.inventory is
  'Current stock per product and location. Cache of inventory_movements, written only by private.apply_stock_movement().';

-- Stock screen of one location (the PK serves per-product lookups).
create index inventory_business_id_location_id_idx on public.inventory (business_id, location_id);

-- -----------------------------------------------------------------------------
-- inventory_movements — ledger
-- -----------------------------------------------------------------------------
create table public.inventory_movements (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null,
  product_id     uuid not null,
  location_id    uuid not null,
  type           public.inventory_movement_type not null,
  -- Signed: > 0 stock in, < 0 stock out.
  quantity       numeric(14, 3) not null,
  quantity_after numeric(14, 3) not null,
  -- Unit cost at movement time (valuation of losses, margins). Business currency.
  unit_cost      bigint check (unit_cost >= 0),
  reference_type text check (reference_type in ('sale', 'purchase', 'adjustment', 'count', 'transfer')),
  reference_id   uuid,
  transfer_id    uuid,
  reason         text check (char_length(reason) <= 500),
  created_by     uuid default auth.uid() references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),
  constraint inventory_movements_business_id_id_key unique (business_id, id),
  constraint inventory_movements_product_fkey foreign key (business_id, product_id)
    references public.products (business_id, id),
  constraint inventory_movements_location_fkey foreign key (business_id, location_id)
    references public.locations (business_id, id),
  constraint inventory_movements_sign_check check (
    quantity <> 0 and case
      when type in ('INITIAL', 'PURCHASE', 'SALE_CANCELLATION', 'RETURN', 'TRANSFER_IN') then quantity > 0
      when type in ('SALE', 'TRANSFER_OUT', 'LOSS', 'DAMAGE') then quantity < 0
      else true  -- ADJUSTMENT
    end),
  constraint inventory_movements_transfer_check check (
    (type in ('TRANSFER_IN', 'TRANSFER_OUT')) = (transfer_id is not null)),
  constraint inventory_movements_reason_required_check check (
    type not in ('ADJUSTMENT', 'LOSS', 'DAMAGE') or char_length(btrim(reason)) > 0)
);

comment on table public.inventory_movements is
  'Append-only stock ledger. Written only by private.apply_stock_movement().';

-- Product history and global journal, most recent first.
create index inventory_movements_business_product_created_idx
  on public.inventory_movements (business_id, product_id, created_at desc);
create index inventory_movements_business_created_idx
  on public.inventory_movements (business_id, created_at desc);

create trigger prevent_update
  before update on public.inventory_movements
  for each row execute function private.prevent_update();

-- -----------------------------------------------------------------------------
-- A location holding stock cannot be archived.
-- -----------------------------------------------------------------------------
create or replace function private.check_location_archivable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.inventory i
              where i.business_id = new.business_id and i.location_id = new.id and i.quantity <> 0) then
    raise exception 'LOCATION_HAS_STOCK' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger check_location_archivable
  before update of status on public.locations
  for each row when (new.status = 'ARCHIVED' and old.status <> 'ARCHIVED')
  execute function private.check_location_archivable();

-- -----------------------------------------------------------------------------
-- Stock engine (internal, not granted to any API role)
-- -----------------------------------------------------------------------------
create or replace function private.apply_stock_movement(
  p_business_id    uuid,
  p_product_id     uuid,
  p_location_id    uuid,
  p_type           public.inventory_movement_type,
  p_quantity       numeric,
  p_unit_cost      bigint default null,
  p_reference_type text default null,
  p_reference_id   uuid default null,
  p_transfer_id    uuid default null,
  p_reason         text default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product  public.products;
  v_location public.locations;
  v_current  numeric(14, 3);
  v_after    numeric(14, 3);
  v_movement public.inventory_movements;
begin
  if p_quantity is null or p_quantity = 0 then
    raise exception 'INVALID_QUANTITY' using errcode = '22023';
  end if;

  select * into v_product from public.products
   where business_id = p_business_id and id = p_product_id;
  if not found then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not v_product.track_stock then
    raise exception 'PRODUCT_NOT_STOCKED' using errcode = 'P0001';
  end if;
  if not v_product.allows_fractional_quantity and p_quantity <> trunc(p_quantity) then
    raise exception 'FRACTIONAL_QUANTITY_NOT_ALLOWED' using errcode = 'P0001';
  end if;

  select * into v_location from public.locations
   where business_id = p_business_id and id = p_location_id;
  if not found then
    raise exception 'LOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_location.status <> 'ACTIVE' then
    raise exception 'LOCATION_ARCHIVED' using errcode = 'P0001';
  end if;

  insert into public.inventory (business_id, product_id, location_id)
  values (p_business_id, p_product_id, p_location_id)
  on conflict do nothing;

  select quantity into v_current from public.inventory
   where business_id = p_business_id and product_id = p_product_id and location_id = p_location_id
   for update;

  v_after := v_current + p_quantity;
  if v_after < 0 and p_quantity < 0
     and not (select allow_negative_stock from public.businesses where id = p_business_id) then
    raise exception 'INSUFFICIENT_STOCK' using errcode = 'P0001',
      detail = json_build_object('product_id', p_product_id, 'location_id', p_location_id,
                                 'available', v_current, 'requested', -p_quantity)::text;
  end if;

  update public.inventory set quantity = v_after, updated_at = now()
   where business_id = p_business_id and product_id = p_product_id and location_id = p_location_id;

  insert into public.inventory_movements (
    business_id, product_id, location_id, type, quantity, quantity_after, unit_cost,
    reference_type, reference_id, transfer_id, reason
  ) values (
    p_business_id, p_product_id, p_location_id, p_type, p_quantity, v_after, p_unit_cost,
    p_reference_type, p_reference_id, p_transfer_id, nullif(btrim(p_reason), '')
  ) returning * into v_movement;

  -- Low-stock notifications are emitted from here in Phase 12.
  return v_movement;
end;
$$;

-- Current unit cost of a product (0 when unknown).
create or replace function private.current_unit_cost(p_product_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select cost_price from public.product_costs where product_id = p_product_id), 0);
$$;

-- -----------------------------------------------------------------------------
-- Public RPCs
-- -----------------------------------------------------------------------------
-- Manual movement. p_quantity is the SIGNED delta:
--   INITIAL > 0 (once per product × location), LOSS / DAMAGE < 0, ADJUSTMENT ≠ 0.
-- Reason required for ADJUSTMENT, LOSS, DAMAGE.
create or replace function public.adjust_stock(
  p_business_id uuid,
  p_product_id  uuid,
  p_location_id uuid,
  p_type        public.inventory_movement_type,
  p_quantity    numeric,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_movement public.inventory_movements;
begin
  perform private.require_permission(p_business_id, 'inventory.adjust');

  if p_type not in ('INITIAL', 'ADJUSTMENT', 'LOSS', 'DAMAGE') then
    raise exception 'INVALID_MOVEMENT_TYPE' using errcode = '22023',
      detail = 'adjust_stock accepts INITIAL, ADJUSTMENT, LOSS, DAMAGE';
  end if;
  if (p_type = 'INITIAL' and p_quantity <= 0)
     or (p_type in ('LOSS', 'DAMAGE') and p_quantity >= 0) then
    raise exception 'INVALID_QUANTITY_SIGN' using errcode = '22023';
  end if;
  if p_type <> 'INITIAL' and coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  if p_type = 'INITIAL' and exists (
    select 1 from public.inventory_movements
     where business_id = p_business_id and product_id = p_product_id and location_id = p_location_id
  ) then
    raise exception 'INITIAL_ALREADY_SET' using errcode = 'P0001';
  end if;

  v_movement := private.apply_stock_movement(
    p_business_id, p_product_id, p_location_id, p_type, p_quantity,
    private.current_unit_cost(p_product_id), 'adjustment', null, null, p_reason);

  perform private.log_audit(p_business_id, 'inventory.adjust', 'inventory_movement', v_movement.id,
    jsonb_build_object('product_id', p_product_id, 'location_id', p_location_id, 'type', p_type,
                       'quantity', p_quantity, 'quantity_after', v_movement.quantity_after));
  return v_movement.id;
end;
$$;

-- Physical count: the server computes the delta under lock, so concurrent sales
-- cannot be lost. Returns NULL when the counted quantity equals current stock.
create or replace function public.count_stock(
  p_business_id      uuid,
  p_product_id       uuid,
  p_location_id      uuid,
  p_counted_quantity numeric,
  p_reason           text default 'Inventaire physique'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current  numeric(14, 3);
  v_movement public.inventory_movements;
begin
  perform private.require_permission(p_business_id, 'inventory.adjust');
  if p_counted_quantity is null or p_counted_quantity < 0 then
    raise exception 'INVALID_QUANTITY' using errcode = '22023';
  end if;

  select quantity into v_current from public.inventory
   where business_id = p_business_id and product_id = p_product_id and location_id = p_location_id
   for update;
  v_current := coalesce(v_current, 0);

  if p_counted_quantity = v_current then
    return null;
  end if;

  v_movement := private.apply_stock_movement(
    p_business_id, p_product_id, p_location_id, 'ADJUSTMENT', p_counted_quantity - v_current,
    private.current_unit_cost(p_product_id), 'count', null, null,
    coalesce(nullif(btrim(p_reason), ''), 'Inventaire physique'));

  perform private.log_audit(p_business_id, 'inventory.count', 'inventory_movement', v_movement.id,
    jsonb_build_object('product_id', p_product_id, 'location_id', p_location_id,
                       'previous', v_current, 'counted', p_counted_quantity));
  return v_movement.id;
end;
$$;

-- Transfer between two locations of the same business. Returns the transfer id
-- shared by the TRANSFER_OUT / TRANSFER_IN pair.
create or replace function public.transfer_stock(
  p_business_id      uuid,
  p_product_id       uuid,
  p_from_location_id uuid,
  p_to_location_id   uuid,
  p_quantity         numeric,
  p_reason           text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transfer_id uuid := gen_random_uuid();
  v_unit_cost   bigint;
begin
  perform private.require_permission(p_business_id, 'inventory.transfer');
  if p_from_location_id = p_to_location_id then
    raise exception 'SAME_LOCATION' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'INVALID_QUANTITY' using errcode = '22023';
  end if;
  if not exists (select 1 from public.products where business_id = p_business_id and id = p_product_id) then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if (select count(*) from public.locations
       where business_id = p_business_id and id in (p_from_location_id, p_to_location_id)) <> 2 then
    raise exception 'LOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Lock both stock rows in a deterministic order (location id) so that two
  -- opposite concurrent transfers cannot deadlock.
  insert into public.inventory (business_id, product_id, location_id)
  select p_business_id, p_product_id, l.id
    from public.locations l
   where l.business_id = p_business_id and l.id in (p_from_location_id, p_to_location_id)
  on conflict do nothing;
  perform 1 from public.inventory
   where business_id = p_business_id and product_id = p_product_id
     and location_id in (p_from_location_id, p_to_location_id)
   order by location_id
   for update;

  v_unit_cost := private.current_unit_cost(p_product_id);
  perform private.apply_stock_movement(p_business_id, p_product_id, p_from_location_id, 'TRANSFER_OUT',
    -p_quantity, v_unit_cost, 'transfer', v_transfer_id, v_transfer_id, p_reason);
  perform private.apply_stock_movement(p_business_id, p_product_id, p_to_location_id, 'TRANSFER_IN',
    p_quantity, v_unit_cost, 'transfer', v_transfer_id, v_transfer_id, p_reason);

  perform private.log_audit(p_business_id, 'inventory.transfer', 'transfer', v_transfer_id,
    jsonb_build_object('product_id', p_product_id, 'from', p_from_location_id,
                       'to', p_to_location_id, 'quantity', p_quantity));
  return v_transfer_id;
end;
$$;

-- Products at or below their minimum level, per active location (a product
-- without stock row counts as 0). Requires inventory.read; SECURITY INVOKER so
-- RLS on products / inventory applies to the caller as well.
create or replace function public.list_low_stock(p_business_id uuid, p_location_id uuid default null)
returns table (
  product_id      uuid,
  product_name    text,
  location_id     uuid,
  location_name   text,
  quantity        numeric,
  min_stock_level numeric
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  perform private.require_permission(p_business_id, 'inventory.read');

  return query
  select p.id, p.name, l.id, l.name, coalesce(i.quantity, 0::numeric), p.min_stock_level
    from public.products p
    join public.locations l
      on l.business_id = p.business_id and l.status = 'ACTIVE'
     and (p_location_id is null or l.id = p_location_id)
    left join public.inventory i
      on i.business_id = p.business_id and i.product_id = p.id and i.location_id = l.id
   where p.business_id = p_business_id
     and p.status = 'ACTIVE'
     and p.track_stock
     and p.min_stock_level > 0
     and coalesce(i.quantity, 0) <= p.min_stock_level
   order by coalesce(i.quantity, 0) - p.min_stock_level, p.name;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges + RLS: read-only for clients.
-- -----------------------------------------------------------------------------
alter table public.inventory           enable row level security;
alter table public.inventory_movements enable row level security;

grant select on public.inventory, public.inventory_movements to authenticated;

create policy "members with inventory.read can select inventory"
  on public.inventory for select to authenticated
  using (business_id in (select private.businesses_with_permission('inventory.read')));

create policy "members with inventory.read can select inventory movements"
  on public.inventory_movements for select to authenticated
  using (business_id in (select private.businesses_with_permission('inventory.read')));

revoke all on function
  public.adjust_stock(uuid, uuid, uuid, public.inventory_movement_type, numeric, text),
  public.count_stock(uuid, uuid, uuid, numeric, text),
  public.transfer_stock(uuid, uuid, uuid, uuid, numeric, text),
  public.list_low_stock(uuid, uuid)
from public, anon;

grant execute on function
  public.adjust_stock(uuid, uuid, uuid, public.inventory_movement_type, numeric, text),
  public.count_stock(uuid, uuid, uuid, numeric, text),
  public.transfer_stock(uuid, uuid, uuid, uuid, numeric, text),
  public.list_low_stock(uuid, uuid)
to authenticated;
