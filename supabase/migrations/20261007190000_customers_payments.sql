-- =============================================================================
-- JËND PRO — Customers, customer account ledger, payments (Phase 7)
-- -----------------------------------------------------------------------------
-- * customers: CRUD through PostgREST. `balance` (amount owed) is a cache and
--   `credit_limit` is set only through set_customer_credit_limit() — otherwise
--   anyone allowed to create a customer could grant unlimited credit.
-- * customer_transactions: append-only ledger of the customer account.
--   Invariant: customers.balance = SUM(customer_transactions.amount) and >= 0
--   (no customer credit note / "avoir" in V1).
-- * private.apply_customer_transaction() is the only writer of balance and
--   ledger (row lock, limit check). Reused by sales (Phase 9).
-- * payments: every money movement (IN / OUT), append-only. Created here for
--   credit settlements; sales and purchases add their links in later phases.
-- See docs/business-rules.md §5.
-- =============================================================================

create type public.payment_method as enum (
  'CASH', 'WAVE', 'ORANGE_MONEY', 'FREE_MONEY', 'CARD', 'BANK_TRANSFER', 'CHEQUE', 'OTHER'
);
create type public.payment_direction as enum ('IN', 'OUT');
create type public.customer_transaction_type as enum (
  'CREDIT_SALE',        -- part of a sale left unpaid (+)
  'PAYMENT',            -- settlement received (-)
  'ADJUSTMENT',         -- manual correction / opening debt migrated from paper (±)
  'SALE_CANCELLATION'   -- credit part of a cancelled sale (-)
);

-- -----------------------------------------------------------------------------
-- customers
-- -----------------------------------------------------------------------------
create table public.customers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses (id),
  name         text not null check (char_length(btrim(name)) between 1 and 120),
  phone        text check (phone ~ '^\+?[0-9]{6,15}$'),
  email        text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  address      text check (char_length(address) <= 300),
  notes        text check (char_length(notes) <= 1000),
  -- 0 = no credit (default), NULL = no ceiling, > 0 = ceiling (business currency).
  credit_limit bigint default 0 check (credit_limit >= 0),
  -- Amount currently owed by the customer. Cache of customer_transactions.
  balance      bigint not null default 0 check (balance >= 0),
  status       public.record_status not null default 'ACTIVE',
  created_by   uuid default auth.uid() references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint customers_business_id_id_key unique (business_id, id)
);

comment on table public.customers is
  'Customers of a business. balance is maintained only by private.apply_customer_transaction().';

-- Customer search by name / phone at checkout.
create index customers_business_id_name_idx on public.customers (business_id, name);
create index customers_business_id_phone_idx on public.customers (business_id, phone) where phone is not null;
-- "Who owes us money" list.
create index customers_business_id_debtors_idx on public.customers (business_id, balance desc) where balance > 0;

create trigger set_updated_at
  before update on public.customers
  for each row execute function private.set_updated_at();

create or replace function private.normalize_customer()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name  := btrim(new.name);
  new.phone := nullif(regexp_replace(new.phone, '[\s.\-()]', '', 'g'), '');
  new.email := nullif(btrim(new.email), '');
  if tg_op = 'UPDATE' and new.status = 'ARCHIVED' and old.status <> 'ARCHIVED' and new.balance > 0 then
    raise exception 'CUSTOMER_HAS_BALANCE' using errcode = 'P0001',
      detail = 'A customer who still owes money cannot be archived.';
  end if;
  return new;
end;
$$;

create trigger normalize_customer
  before insert or update on public.customers
  for each row execute function private.normalize_customer();

-- -----------------------------------------------------------------------------
-- payments
-- -----------------------------------------------------------------------------
create table public.payments (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses (id),
  location_id        uuid not null,
  direction          public.payment_direction not null,
  method             public.payment_method not null,
  amount             bigint not null check (amount > 0),
  -- Context (exactly one). Sales / purchases are added in their phases.
  customer_id        uuid,
  -- Transaction id from Wave / Orange Money / bank: idempotency for webhooks.
  external_reference text check (char_length(external_reference) <= 120),
  note               text check (char_length(note) <= 500),
  paid_at            timestamptz not null default now(),
  recorded_by        uuid default auth.uid() references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  constraint payments_business_id_id_key unique (business_id, id),
  constraint payments_location_fkey foreign key (business_id, location_id)
    references public.locations (business_id, id),
  constraint payments_customer_fkey foreign key (business_id, customer_id)
    references public.customers (business_id, id),
  constraint payments_context_check check (num_nonnulls(customer_id) = 1),
  constraint payments_external_reference_key unique (business_id, method, external_reference)
);

comment on table public.payments is
  'Append-only money movements (IN = received, OUT = paid out / refunded). Written only by RPCs.';

-- Cash journal per day and per location.
create index payments_business_id_paid_at_idx on public.payments (business_id, paid_at desc);
create index payments_business_id_customer_id_idx on public.payments (business_id, customer_id)
  where customer_id is not null;

create trigger prevent_update
  before update on public.payments
  for each row execute function private.prevent_update();

-- -----------------------------------------------------------------------------
-- customer_transactions — account ledger
-- -----------------------------------------------------------------------------
create table public.customer_transactions (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null,
  customer_id   uuid not null,
  type          public.customer_transaction_type not null,
  -- Signed: > 0 increases the debt, < 0 decreases it.
  amount        bigint not null,
  balance_after bigint not null,
  payment_id    uuid,
  note          text check (char_length(note) <= 500),
  created_by    uuid default auth.uid() references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  constraint customer_transactions_business_id_id_key unique (business_id, id),
  constraint customer_transactions_customer_fkey foreign key (business_id, customer_id)
    references public.customers (business_id, id),
  constraint customer_transactions_payment_fkey foreign key (business_id, payment_id)
    references public.payments (business_id, id),
  constraint customer_transactions_sign_check check (
    amount <> 0 and case
      when type = 'CREDIT_SALE' then amount > 0
      when type in ('PAYMENT', 'SALE_CANCELLATION') then amount < 0
      else true  -- ADJUSTMENT
    end),
  constraint customer_transactions_payment_required_check check ((type = 'PAYMENT') = (payment_id is not null)),
  constraint customer_transactions_note_required_check check (type <> 'ADJUSTMENT' or char_length(btrim(note)) > 0)
);

comment on table public.customer_transactions is
  'Append-only customer account ledger. Written only by private.apply_customer_transaction().';

-- Customer statement ("relevé"), most recent first.
create index customer_transactions_business_customer_created_idx
  on public.customer_transactions (business_id, customer_id, created_at desc);

create trigger prevent_update
  before update on public.customer_transactions
  for each row execute function private.prevent_update();

-- -----------------------------------------------------------------------------
-- Account engine (internal, not granted to any API role)
-- -----------------------------------------------------------------------------
create or replace function private.apply_customer_transaction(
  p_business_id uuid,
  p_customer_id uuid,
  p_type        public.customer_transaction_type,
  p_amount      bigint,
  p_payment_id  uuid default null,
  p_note        text default null
)
returns public.customer_transactions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer public.customers;
  v_after    bigint;
  v_tx       public.customer_transactions;
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;

  select * into v_customer from public.customers
   where business_id = p_business_id and id = p_customer_id
   for update;
  if not found then
    raise exception 'CUSTOMER_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_after := v_customer.balance + p_amount;
  if v_after < 0 then
    raise exception 'AMOUNT_EXCEEDS_BALANCE' using errcode = 'P0001',
      detail = json_build_object('balance', v_customer.balance, 'requested', -p_amount)::text;
  end if;
  if p_type = 'CREDIT_SALE' then
    if v_customer.status <> 'ACTIVE' then
      raise exception 'CUSTOMER_ARCHIVED' using errcode = 'P0001';
    end if;
    if v_customer.credit_limit is not null and v_after > v_customer.credit_limit then
      raise exception 'CREDIT_LIMIT_EXCEEDED' using errcode = 'P0001',
        detail = json_build_object('balance', v_customer.balance, 'credit_limit', v_customer.credit_limit,
                                   'requested', p_amount)::text;
    end if;
  end if;

  update public.customers set balance = v_after where id = p_customer_id;

  insert into public.customer_transactions (business_id, customer_id, type, amount, balance_after, payment_id, note)
  values (p_business_id, p_customer_id, p_type, p_amount, v_after, p_payment_id, nullif(btrim(p_note), ''))
  returning * into v_tx;
  return v_tx;
end;
$$;

-- -----------------------------------------------------------------------------
-- Public RPCs
-- -----------------------------------------------------------------------------
-- Credit ceiling: 0 = no credit, NULL = no ceiling. customers.manage.
create or replace function public.set_customer_credit_limit(p_customer_id uuid, p_credit_limit bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer public.customers;
begin
  select * into v_customer from public.customers where id = p_customer_id for update;
  perform private.require_permission(v_customer.business_id, 'customers.manage');
  if p_credit_limit < 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;
  if v_customer.credit_limit is not distinct from p_credit_limit then
    return;
  end if;

  update public.customers set credit_limit = p_credit_limit where id = p_customer_id;

  perform private.log_audit(v_customer.business_id, 'customer.credit_limit_change', 'customer', p_customer_id,
    jsonb_build_object('old', v_customer.credit_limit, 'new', p_credit_limit));
end;
$$;

-- Settlement of a customer debt: payment IN + ledger entry, atomically.
create or replace function public.record_customer_payment(
  p_customer_id        uuid,
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
  v_business_id uuid;
  v_payment_id  uuid;
  v_tx          public.customer_transactions;
begin
  select business_id into v_business_id from public.customers where id = p_customer_id;
  perform private.require_permission(v_business_id, 'customers.payments');
  if p_amount is null or p_amount <= 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;
  if not exists (select 1 from public.locations
                  where business_id = v_business_id and id = p_location_id and status = 'ACTIVE') then
    raise exception 'LOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.payments (business_id, location_id, direction, method, amount, customer_id,
                               external_reference, note)
  values (v_business_id, p_location_id, 'IN', p_method, p_amount, p_customer_id,
          nullif(btrim(p_external_reference), ''), nullif(btrim(p_note), ''))
  returning id into v_payment_id;

  v_tx := private.apply_customer_transaction(v_business_id, p_customer_id, 'PAYMENT', -p_amount,
                                             v_payment_id, p_note);

  perform private.log_audit(v_business_id, 'customer.payment', 'payment', v_payment_id,
    jsonb_build_object('customer_id', p_customer_id, 'amount', p_amount, 'method', p_method,
                       'balance_after', v_tx.balance_after));
  return v_payment_id;
end;
$$;

-- Manual correction of a customer account (e.g. migrating debts from the paper
-- credit notebook). p_amount is signed (+ the customer owes more). customers.manage.
create or replace function public.adjust_customer_balance(p_customer_id uuid, p_amount bigint, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_business_id uuid;
  v_tx          public.customer_transactions;
begin
  select business_id into v_business_id from public.customers where id = p_customer_id;
  perform private.require_permission(v_business_id, 'customers.manage');
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  v_tx := private.apply_customer_transaction(v_business_id, p_customer_id, 'ADJUSTMENT', p_amount, null, p_reason);

  perform private.log_audit(v_business_id, 'customer.balance_adjust', 'customer', p_customer_id,
    jsonb_build_object('amount', p_amount, 'balance_after', v_tx.balance_after, 'reason', btrim(p_reason)));
  return v_tx.id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Privileges + RLS
-- -----------------------------------------------------------------------------
alter table public.customers             enable row level security;
alter table public.payments              enable row level security;
alter table public.customer_transactions enable row level security;

-- customers: create with customers.create (no credit_limit / balance / status),
-- edit and archive with customers.manage.
grant select on public.customers to authenticated;
grant insert (business_id, name, phone, email, address, notes) on public.customers to authenticated;
grant update (name, phone, email, address, notes, status) on public.customers to authenticated;

create policy "members with customers.read can select customers"
  on public.customers for select to authenticated
  using (business_id in (select private.businesses_with_permission('customers.read')));

create policy "members with customers.create can insert customers"
  on public.customers for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('customers.create')));

create policy "members with customers.manage can update customers"
  on public.customers for update to authenticated
  using (business_id in (select private.businesses_with_permission('customers.manage')))
  with check (business_id in (select private.businesses_with_permission('customers.manage')));

-- customer_transactions: read-only.
grant select on public.customer_transactions to authenticated;

create policy "members with customers.read can select customer transactions"
  on public.customer_transactions for select to authenticated
  using (business_id in (select private.businesses_with_permission('customers.read')));

-- payments: read-only. Reports readers see everything; customer settlements are
-- visible to customer readers. Later phases add sale / purchase visibility.
grant select on public.payments to authenticated;

create policy "members with reports.read can select payments"
  on public.payments for select to authenticated
  using (business_id in (select private.businesses_with_permission('reports.read')));

create policy "members with customers.read can select customer payments"
  on public.payments for select to authenticated
  using (customer_id is not null
         and business_id in (select private.businesses_with_permission('customers.read')));

revoke all on function
  public.set_customer_credit_limit(uuid, bigint),
  public.record_customer_payment(uuid, bigint, public.payment_method, uuid, text, text),
  public.adjust_customer_balance(uuid, bigint, text)
from public, anon;

grant execute on function
  public.set_customer_credit_limit(uuid, bigint),
  public.record_customer_payment(uuid, bigint, public.payment_method, uuid, text, text),
  public.adjust_customer_balance(uuid, bigint, text)
to authenticated;
