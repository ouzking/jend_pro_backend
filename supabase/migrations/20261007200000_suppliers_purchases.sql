-- =============================================================================
-- JËND PRO — Suppliers, purchases, document numbering (Phase 8)
-- -----------------------------------------------------------------------------
-- * suppliers / supplier_products: CRUD through PostgREST (suppliers.manage).
-- * purchases / purchase_items: written ONLY through RPCs so that totals are
--   computed server-side and every transition is atomic:
--     save_purchase (DRAFT/ORDERED, replaces lines) -> order_purchase ->
--     receive_purchase (stock PURCHASE movements + weighted average cost)
--     cancel_purchase (before reception, without payments)
--     record_purchase_payment (payment OUT, advances allowed)
-- * document_sequences: per-business gapless numbering (A-000001, V-000001).
-- See docs/business-rules.md §6 and §10.
-- =============================================================================

create type public.purchase_status as enum ('DRAFT', 'ORDERED', 'RECEIVED', 'CANCELLED');
create type public.payment_status  as enum ('UNPAID', 'PARTIAL', 'PAID');

-- -----------------------------------------------------------------------------
-- document_sequences (internal)
-- -----------------------------------------------------------------------------
create table public.document_sequences (
  business_id uuid not null references public.businesses (id) on delete cascade,
  doc_type    text not null check (doc_type in ('SALE', 'PURCHASE')),
  prefix      text not null check (char_length(prefix) between 1 and 10),
  next_value  bigint not null default 1 check (next_value > 0),
  primary key (business_id, doc_type)
);

comment on table public.document_sequences is
  'Per-business document counters. Internal: incremented under row lock by private.next_document_number().';

alter table public.document_sequences enable row level security;
-- No grant, no policy: never accessible to API roles.

create or replace function private.next_document_number(p_business_id uuid, p_doc_type text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prefix text;
  v_value  bigint;
begin
  insert into public.document_sequences (business_id, doc_type, prefix)
  values (p_business_id, p_doc_type, case p_doc_type when 'SALE' then 'V-' else 'A-' end)
  on conflict do nothing;

  update public.document_sequences
     set next_value = next_value + 1
   where business_id = p_business_id and doc_type = p_doc_type
  returning prefix, next_value - 1 into v_prefix, v_value;

  return v_prefix || lpad(v_value::text, 6, '0');
end;
$$;

create or replace function private.payment_status(p_paid bigint, p_total bigint)
returns public.payment_status
language sql
immutable
set search_path = ''
as $$
  -- A zero total is considered settled (nothing is owed).
  select case when p_paid >= p_total then 'PAID'::public.payment_status
              when p_paid > 0 then 'PARTIAL'::public.payment_status
              else 'UNPAID'::public.payment_status end;
$$;

-- -----------------------------------------------------------------------------
-- suppliers
-- -----------------------------------------------------------------------------
create table public.suppliers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses (id),
  name         text not null check (char_length(btrim(name)) between 1 and 120),
  contact_name text check (char_length(contact_name) <= 120),
  phone        text check (phone ~ '^\+?[0-9]{6,15}$'),
  email        text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  address      text check (char_length(address) <= 300),
  notes        text check (char_length(notes) <= 1000),
  status       public.record_status not null default 'ACTIVE',
  created_by   uuid default auth.uid() references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint suppliers_business_id_id_key unique (business_id, id)
);

create index suppliers_business_id_name_idx on public.suppliers (business_id, name);

create trigger set_updated_at
  before update on public.suppliers
  for each row execute function private.set_updated_at();

create or replace function private.normalize_supplier()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name  := btrim(new.name);
  new.phone := nullif(regexp_replace(new.phone, '[\s.\-()]', '', 'g'), '');
  new.email := nullif(btrim(new.email), '');
  return new;
end;
$$;

create trigger normalize_supplier
  before insert or update on public.suppliers
  for each row execute function private.normalize_supplier();

-- -----------------------------------------------------------------------------
-- supplier_products — which supplier sells which product, at what last cost
-- -----------------------------------------------------------------------------
create table public.supplier_products (
  business_id  uuid not null,
  supplier_id  uuid not null,
  product_id   uuid not null,
  supplier_sku text check (char_length(supplier_sku) <= 64),
  -- Last unit cost received from this supplier (maintained by receive_purchase).
  last_cost    bigint check (last_cost >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (supplier_id, product_id),
  constraint supplier_products_supplier_fkey foreign key (business_id, supplier_id)
    references public.suppliers (business_id, id),
  constraint supplier_products_product_fkey foreign key (business_id, product_id)
    references public.products (business_id, id)
);

-- "Who sells this product?" lookups.
create index supplier_products_business_product_idx on public.supplier_products (business_id, product_id);

create trigger set_updated_at
  before update on public.supplier_products
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- purchases / purchase_items
-- -----------------------------------------------------------------------------
create table public.purchases (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses (id),
  number             text not null,
  -- NULL = purchase without registered supplier (e.g. market purchase).
  supplier_id        uuid,
  location_id        uuid not null,
  status             public.purchase_status not null default 'DRAFT',
  supplier_reference text check (char_length(supplier_reference) <= 64),
  subtotal_amount    bigint not null default 0 check (subtotal_amount >= 0),
  discount_amount    bigint not null default 0 check (discount_amount >= 0),
  total_amount       bigint not null default 0 check (total_amount >= 0),
  amount_paid        bigint not null default 0 check (amount_paid >= 0),
  -- Derived, never written: cannot drift from the amounts.
  payment_status     public.payment_status generated always as (private.payment_status(amount_paid, total_amount)) stored,
  notes              text check (char_length(notes) <= 1000),
  ordered_at         timestamptz,
  received_at        timestamptz,
  received_by        uuid references auth.users (id) on delete set null,
  cancelled_at       timestamptz,
  cancelled_by       uuid references auth.users (id) on delete set null,
  cancel_reason      text check (char_length(cancel_reason) <= 500),
  created_by         uuid default auth.uid() references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint purchases_business_id_id_key unique (business_id, id),
  constraint purchases_business_id_number_key unique (business_id, number),
  constraint purchases_supplier_fkey foreign key (business_id, supplier_id)
    references public.suppliers (business_id, id),
  constraint purchases_location_fkey foreign key (business_id, location_id)
    references public.locations (business_id, id),
  constraint purchases_total_consistency_check check (total_amount = subtotal_amount - discount_amount),
  constraint purchases_paid_range_check check (amount_paid <= total_amount),
  constraint purchases_received_consistency_check check ((status = 'RECEIVED') = (received_at is not null)),
  constraint purchases_cancelled_consistency_check check ((status = 'CANCELLED') = (cancelled_at is not null))
);

comment on table public.purchases is 'Supplier purchases. Written only through purchase RPCs.';

-- Purchase list (most recent first) and supplier history.
create index purchases_business_id_created_at_idx on public.purchases (business_id, created_at desc);
create index purchases_business_id_supplier_id_idx on public.purchases (business_id, supplier_id)
  where supplier_id is not null;

create trigger set_updated_at
  before update on public.purchases
  for each row execute function private.set_updated_at();

create table public.purchase_items (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  purchase_id uuid not null,
  product_id  uuid not null,
  quantity    numeric(14, 3) not null check (quantity > 0),
  unit_cost   bigint not null check (unit_cost >= 0),
  line_total  bigint not null check (line_total >= 0),
  created_at  timestamptz not null default now(),
  -- CASCADE: lines of a draft are replaced as a whole by save_purchase.
  constraint purchase_items_purchase_fkey foreign key (business_id, purchase_id)
    references public.purchases (business_id, id) on delete cascade,
  constraint purchase_items_product_fkey foreign key (business_id, product_id)
    references public.products (business_id, id),
  constraint purchase_items_purchase_product_key unique (purchase_id, product_id)
);

-- Product purchase history.
create index purchase_items_business_product_idx on public.purchase_items (business_id, product_id);

-- -----------------------------------------------------------------------------
-- payments: purchase context
-- -----------------------------------------------------------------------------
alter table public.payments
  add column purchase_id uuid,
  add constraint payments_purchase_fkey foreign key (business_id, purchase_id)
    references public.purchases (business_id, id),
  drop constraint payments_context_check,
  add constraint payments_context_check check (num_nonnulls(customer_id, purchase_id) = 1);

create index payments_business_id_purchase_id_idx on public.payments (business_id, purchase_id)
  where purchase_id is not null;

-- -----------------------------------------------------------------------------
-- supplier_balances — what we owe each supplier (RLS of the caller applies)
-- -----------------------------------------------------------------------------
create view public.supplier_balances
with (security_invoker = true)
as
select p.business_id,
       p.supplier_id,
       sum(p.total_amount - p.amount_paid) filter (where p.status = 'RECEIVED')::bigint as amount_due,
       sum(p.amount_paid) filter (where p.status in ('DRAFT', 'ORDERED'))::bigint     as advances_paid,
       count(*) filter (where p.status = 'RECEIVED' and p.payment_status <> 'PAID')::int as unpaid_purchases
  from public.purchases p
 where p.supplier_id is not null
 group by p.business_id, p.supplier_id;

comment on view public.supplier_balances is
  'Amount due per supplier (received purchases) and advances paid on pending ones. security_invoker: RLS applies.';

-- -----------------------------------------------------------------------------
-- Internal: validates and (re)writes purchase lines, returns the subtotal.
-- p_items: [{"product_id": uuid, "quantity": number, "unit_cost": integer}, …]
-- -----------------------------------------------------------------------------
create or replace function private.write_purchase_items(p_business_id uuid, p_purchase_id uuid, p_items jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item     jsonb;
  v_product  public.products;
  v_product_id uuid;
  v_quantity numeric(14, 3);
  v_cost     bigint;
  v_subtotal bigint := 0;
  v_line     bigint;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'ITEMS_REQUIRED' using errcode = '22023';
  end if;

  delete from public.purchase_items where purchase_id = p_purchase_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_product_id := (v_item ->> 'product_id')::uuid;
      v_quantity   := (v_item ->> 'quantity')::numeric;
      v_cost       := (v_item ->> 'unit_cost')::bigint;
    exception when others then
      raise exception 'INVALID_ITEM' using errcode = '22023', detail = v_item::text;
    end;
    if v_quantity is null or v_quantity <= 0 or v_cost is null or v_cost < 0 then
      raise exception 'INVALID_ITEM' using errcode = '22023', detail = v_item::text;
    end if;

    select * into v_product from public.products
     where business_id = p_business_id and id = v_product_id;
    if not found then
      raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0002', detail = v_item ->> 'product_id';
    end if;
    if not v_product.allows_fractional_quantity and v_quantity <> trunc(v_quantity) then
      raise exception 'FRACTIONAL_QUANTITY_NOT_ALLOWED' using errcode = 'P0001', detail = v_product.id::text;
    end if;

    v_line := round(v_quantity * v_cost)::bigint;
    begin
      insert into public.purchase_items (business_id, purchase_id, product_id, quantity, unit_cost, line_total)
      values (p_business_id, p_purchase_id, v_product.id, v_quantity, v_cost, v_line);
    exception when unique_violation then
      raise exception 'DUPLICATE_PRODUCT' using errcode = '22023', detail = v_product.id::text;
    end;
    v_subtotal := v_subtotal + v_line;
  end loop;

  return v_subtotal;
end;
$$;

-- -----------------------------------------------------------------------------
-- Public RPCs
-- -----------------------------------------------------------------------------
-- Creates (p_purchase_id NULL) or replaces a DRAFT / ORDERED purchase.
create or replace function public.save_purchase(
  p_business_id        uuid,
  p_purchase_id        uuid,
  p_supplier_id        uuid,
  p_location_id        uuid,
  p_items              jsonb,
  p_discount_amount    bigint default 0,
  p_supplier_reference text default null,
  p_notes              text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase public.purchases;
  v_subtotal bigint;
  v_id       uuid := p_purchase_id;
begin
  perform private.require_permission(p_business_id, 'purchases.create');

  if p_supplier_id is not null and not exists (
    select 1 from public.suppliers where business_id = p_business_id and id = p_supplier_id and status = 'ACTIVE') then
    raise exception 'SUPPLIER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.locations
                  where business_id = p_business_id and id = p_location_id and status = 'ACTIVE') then
    raise exception 'LOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if coalesce(p_discount_amount, 0) < 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.purchases (business_id, number, supplier_id, location_id)
    values (p_business_id, private.next_document_number(p_business_id, 'PURCHASE'), p_supplier_id, p_location_id)
    returning id into v_id;
  else
    select * into v_purchase from public.purchases
     where business_id = p_business_id and id = v_id for update;
    if not found then
      raise exception 'PURCHASE_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_purchase.status not in ('DRAFT', 'ORDERED') then
      raise exception 'PURCHASE_NOT_EDITABLE' using errcode = 'P0001', detail = v_purchase.status::text;
    end if;
  end if;

  v_subtotal := private.write_purchase_items(p_business_id, v_id, p_items);
  if coalesce(p_discount_amount, 0) > v_subtotal then
    raise exception 'DISCOUNT_EXCEEDS_TOTAL' using errcode = '22023';
  end if;
  -- Advances already paid must still fit in the new total.
  if coalesce(v_purchase.amount_paid, 0) > v_subtotal - coalesce(p_discount_amount, 0) then
    raise exception 'TOTAL_BELOW_AMOUNT_PAID' using errcode = 'P0001';
  end if;

  update public.purchases
     set supplier_id        = p_supplier_id,
         location_id        = p_location_id,
         subtotal_amount    = v_subtotal,
         discount_amount    = coalesce(p_discount_amount, 0),
         total_amount       = v_subtotal - coalesce(p_discount_amount, 0),
         supplier_reference = nullif(btrim(p_supplier_reference), ''),
         notes              = nullif(btrim(p_notes), '')
   where id = v_id;

  return v_id;
end;
$$;

create or replace function public.order_purchase(p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase public.purchases;
begin
  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  perform private.require_permission(v_purchase.business_id, 'purchases.create');
  if v_purchase.status <> 'DRAFT' then
    raise exception 'INVALID_PURCHASE_STATUS' using errcode = 'P0001', detail = v_purchase.status::text;
  end if;
  update public.purchases set status = 'ORDERED', ordered_at = now() where id = p_purchase_id;
end;
$$;

-- Reception: stock in (PURCHASE movements), weighted average cost, supplier last
-- cost, status RECEIVED — all or nothing. A purchase is received exactly once.
create or replace function public.receive_purchase(p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase public.purchases;
  v_item     record;
  v_stock    numeric;
  v_old_cost bigint;
  v_new_cost bigint;
begin
  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  perform private.require_permission(v_purchase.business_id, 'purchases.receive');
  if v_purchase.status not in ('DRAFT', 'ORDERED') then
    raise exception 'INVALID_PURCHASE_STATUS' using errcode = 'P0001', detail = v_purchase.status::text;
  end if;

  -- Deterministic order (product id) to avoid deadlocks with concurrent operations.
  for v_item in
    select pi.product_id, pi.quantity, pi.unit_cost, p.track_stock
      from public.purchase_items pi
      join public.products p on p.business_id = pi.business_id and p.id = pi.product_id
     where pi.purchase_id = p_purchase_id
     order by pi.product_id
  loop
    if v_item.track_stock then
      -- Weighted average cost over the whole business stock (negative stock counts as 0).
      select cost_price into v_old_cost from public.product_costs
       where product_id = v_item.product_id for update;
      select greatest(coalesce(sum(quantity), 0), 0) into v_stock from public.inventory
       where business_id = v_purchase.business_id and product_id = v_item.product_id;
      v_new_cost := round((v_stock * v_old_cost + v_item.quantity * v_item.unit_cost)
                          / (v_stock + v_item.quantity))::bigint;
      update public.product_costs set cost_price = v_new_cost where product_id = v_item.product_id;

      perform private.apply_stock_movement(v_purchase.business_id, v_item.product_id, v_purchase.location_id,
        'PURCHASE', v_item.quantity, v_item.unit_cost, 'purchase', p_purchase_id, null, null);
    end if;

    if v_purchase.supplier_id is not null then
      insert into public.supplier_products (business_id, supplier_id, product_id, last_cost)
      values (v_purchase.business_id, v_purchase.supplier_id, v_item.product_id, v_item.unit_cost)
      on conflict (supplier_id, product_id) do update set last_cost = excluded.last_cost;
    end if;
  end loop;

  update public.purchases
     set status = 'RECEIVED', received_at = now(), received_by = (select auth.uid()),
         ordered_at = coalesce(ordered_at, now())
   where id = p_purchase_id;

  perform private.log_audit(v_purchase.business_id, 'purchase.receive', 'purchase', p_purchase_id,
    jsonb_build_object('number', v_purchase.number, 'total', v_purchase.total_amount));
end;
$$;

create or replace function public.cancel_purchase(p_purchase_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase public.purchases;
begin
  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  perform private.require_permission(v_purchase.business_id, 'purchases.cancel');
  if v_purchase.status not in ('DRAFT', 'ORDERED') then
    raise exception 'INVALID_PURCHASE_STATUS' using errcode = 'P0001', detail = v_purchase.status::text;
  end if;
  if v_purchase.amount_paid > 0 then
    raise exception 'PURCHASE_HAS_PAYMENTS' using errcode = 'P0001';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  update public.purchases
     set status = 'CANCELLED', cancelled_at = now(), cancelled_by = (select auth.uid()),
         cancel_reason = btrim(p_reason)
   where id = p_purchase_id;

  perform private.log_audit(v_purchase.business_id, 'purchase.cancel', 'purchase', p_purchase_id,
    jsonb_build_object('number', v_purchase.number, 'reason', btrim(p_reason)));
end;
$$;

-- Supplier payment (payment OUT). Advances on pending purchases are allowed.
create or replace function public.record_purchase_payment(
  p_purchase_id        uuid,
  p_amount             bigint,
  p_method             public.payment_method,
  p_location_id        uuid,
  p_external_reference text default null,
  p_note               text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase   public.purchases;
  v_payment_id uuid;
begin
  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  perform private.require_permission(v_purchase.business_id, 'purchases.payments');
  if v_purchase.status = 'CANCELLED' then
    raise exception 'INVALID_PURCHASE_STATUS' using errcode = 'P0001', detail = 'CANCELLED';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;
  if v_purchase.amount_paid + p_amount > v_purchase.total_amount then
    raise exception 'AMOUNT_EXCEEDS_BALANCE' using errcode = 'P0001',
      detail = json_build_object('due', v_purchase.total_amount - v_purchase.amount_paid,
                                 'requested', p_amount)::text;
  end if;
  if not exists (select 1 from public.locations
                  where business_id = v_purchase.business_id and id = p_location_id and status = 'ACTIVE') then
    raise exception 'LOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.payments (business_id, location_id, direction, method, amount, purchase_id,
                               external_reference, note)
  values (v_purchase.business_id, p_location_id, 'OUT', p_method, p_amount, p_purchase_id,
          nullif(btrim(p_external_reference), ''), nullif(btrim(p_note), ''))
  returning id into v_payment_id;

  update public.purchases
     set amount_paid = amount_paid + p_amount
   where id = p_purchase_id;

  perform private.log_audit(v_purchase.business_id, 'purchase.payment', 'payment', v_payment_id,
    jsonb_build_object('purchase_id', p_purchase_id, 'amount', p_amount, 'method', p_method));
  return v_payment_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges + RLS
-- -----------------------------------------------------------------------------
alter table public.suppliers         enable row level security;
alter table public.supplier_products enable row level security;
alter table public.purchases         enable row level security;
alter table public.purchase_items    enable row level security;

-- suppliers
grant select on public.suppliers to authenticated;
grant insert (business_id, name, contact_name, phone, email, address, notes) on public.suppliers to authenticated;
grant update (name, contact_name, phone, email, address, notes, status) on public.suppliers to authenticated;

create policy "members with suppliers.read can select suppliers"
  on public.suppliers for select to authenticated
  using (business_id in (select private.businesses_with_permission('suppliers.read')));

create policy "members with suppliers.manage can insert suppliers"
  on public.suppliers for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('suppliers.manage')));

create policy "members with suppliers.manage can update suppliers"
  on public.suppliers for update to authenticated
  using (business_id in (select private.businesses_with_permission('suppliers.manage')))
  with check (business_id in (select private.businesses_with_permission('suppliers.manage')));

-- supplier_products (last_cost is server-maintained)
grant select on public.supplier_products to authenticated;
grant insert (business_id, supplier_id, product_id, supplier_sku) on public.supplier_products to authenticated;
grant update (supplier_sku) on public.supplier_products to authenticated;
grant delete on public.supplier_products to authenticated;

create policy "members with suppliers.read can select supplier products"
  on public.supplier_products for select to authenticated
  using (business_id in (select private.businesses_with_permission('suppliers.read')));

create policy "members with suppliers.manage can insert supplier products"
  on public.supplier_products for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('suppliers.manage')));

create policy "members with suppliers.manage can update supplier products"
  on public.supplier_products for update to authenticated
  using (business_id in (select private.businesses_with_permission('suppliers.manage')))
  with check (business_id in (select private.businesses_with_permission('suppliers.manage')));

create policy "members with suppliers.manage can delete supplier products"
  on public.supplier_products for delete to authenticated
  using (business_id in (select private.businesses_with_permission('suppliers.manage')));

-- purchases / items: read-only (RPC writes)
grant select on public.purchases, public.purchase_items, public.supplier_balances to authenticated;

create policy "members with purchases.read can select purchases"
  on public.purchases for select to authenticated
  using (business_id in (select private.businesses_with_permission('purchases.read')));

create policy "members with purchases.read can select purchase items"
  on public.purchase_items for select to authenticated
  using (business_id in (select private.businesses_with_permission('purchases.read')));

-- payments: supplier payments visible to purchase readers
create policy "members with purchases.read can select purchase payments"
  on public.payments for select to authenticated
  using (purchase_id is not null
         and business_id in (select private.businesses_with_permission('purchases.read')));

revoke all on function
  public.save_purchase(uuid, uuid, uuid, uuid, jsonb, bigint, text, text),
  public.order_purchase(uuid),
  public.receive_purchase(uuid),
  public.cancel_purchase(uuid, text),
  public.record_purchase_payment(uuid, bigint, public.payment_method, uuid, text, text)
from public, anon;

grant execute on function
  public.save_purchase(uuid, uuid, uuid, uuid, jsonb, bigint, text, text),
  public.order_purchase(uuid),
  public.receive_purchase(uuid),
  public.cancel_purchase(uuid, text),
  public.record_purchase_payment(uuid, bigint, public.payment_method, uuid, text, text)
to authenticated;
