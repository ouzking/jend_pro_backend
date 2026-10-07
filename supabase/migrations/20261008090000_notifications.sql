-- =============================================================================
-- JËND PRO — Notifications + Realtime (Phase 12)
-- -----------------------------------------------------------------------------
-- * notifications: one row per recipient. Users read / mark as read / delete
--   only their own. Written only by the database (private.notify*).
-- * Events (all generated server-side by triggers, never by clients):
--     LOW_STOCK          stock crosses min_stock_level downwards  -> inventory.adjust holders
--     LARGE_SALE         sale total >= businesses.large_sale_threshold -> reports.read holders
--     MEMBER_INVITED     invitation created                       -> the invitee
--     SUBSCRIPTION       subscription becomes PAST_DUE / EXPIRED  -> subscription.manage holders
-- * Realtime: ONLY public.notifications is published (RLS applies to
--   postgres_changes subscribers).
-- =============================================================================

create type public.notification_type as enum (
  'LOW_STOCK', 'LARGE_SALE', 'MEMBER_INVITED', 'SUBSCRIPTION', 'PAYMENT_RECEIVED', 'SYSTEM'
);

create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  -- NULL for platform-level notifications.
  business_id   uuid references public.businesses (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  type          public.notification_type not null,
  title         text not null check (char_length(title) <= 150),
  body          text check (char_length(body) <= 1000),
  data          jsonb not null default '{}'::jsonb,
  resource_type text check (char_length(resource_type) <= 50),
  resource_id   uuid,
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

comment on table public.notifications is
  'In-app notifications, one row per recipient. Written only by the database. Published to Realtime.';

-- Notification center (latest first) and unread badge.
create index notifications_user_id_created_at_idx on public.notifications (user_id, created_at desc);
create index notifications_user_id_unread_idx on public.notifications (user_id) where read_at is null;

-- -----------------------------------------------------------------------------
-- Writers (internal)
-- -----------------------------------------------------------------------------
create or replace function private.notify_user(
  p_user_id       uuid,
  p_business_id   uuid,
  p_type          public.notification_type,
  p_title         text,
  p_body          text default null,
  p_data          jsonb default '{}'::jsonb,
  p_resource_type text default null,
  p_resource_id   uuid default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notifications (business_id, user_id, type, title, body, data, resource_type, resource_id)
  values (p_business_id, p_user_id, p_type, left(p_title, 150), left(p_body, 1000),
          coalesce(p_data, '{}'::jsonb), p_resource_type, p_resource_id);
$$;

-- Fan-out to every ACTIVE member whose role grants p_permission (role grants,
-- independent of the subscription state: owners must be told when restricted).
create or replace function private.notify_members(
  p_business_id   uuid,
  p_permission    text,
  p_type          public.notification_type,
  p_title         text,
  p_body          text default null,
  p_data          jsonb default '{}'::jsonb,
  p_resource_type text default null,
  p_resource_id   uuid default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notifications (business_id, user_id, type, title, body, data, resource_type, resource_id)
  select p_business_id, m.user_id, p_type, left(p_title, 150), left(p_body, 1000),
         coalesce(p_data, '{}'::jsonb), p_resource_type, p_resource_id
    from public.business_members m
    join public.role_permissions rp on rp.role_id = m.role_id
   where m.business_id = p_business_id
     and m.status = 'ACTIVE'
     and rp.permission_code = p_permission;
$$;

-- -----------------------------------------------------------------------------
-- LOW_STOCK: only when a movement makes stock cross the threshold downwards,
-- so there is one alert per episode (no spam while stock stays low).
-- -----------------------------------------------------------------------------
create or replace function private.notify_low_stock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product  public.products;
  v_location text;
  v_before   numeric := new.quantity_after - new.quantity;
begin
  select * into v_product from public.products where business_id = new.business_id and id = new.product_id;
  if v_product.min_stock_level > 0
     and v_before > v_product.min_stock_level
     and new.quantity_after <= v_product.min_stock_level then
    select name into v_location from public.locations where business_id = new.business_id and id = new.location_id;
    perform private.notify_members(new.business_id, 'inventory.adjust', 'LOW_STOCK',
      'Stock faible : ' || v_product.name,
      format('Il reste %s %s à %s (seuil : %s).', trim_scale(new.quantity_after), v_product.unit, v_location,
             trim_scale(v_product.min_stock_level)),
      jsonb_build_object('product_id', v_product.id, 'location_id', new.location_id,
                         'quantity', new.quantity_after, 'min_stock_level', v_product.min_stock_level),
      'product', v_product.id);
  end if;
  return null;
end;
$$;

create trigger notify_low_stock
  after insert on public.inventory_movements
  for each row when (new.quantity < 0)
  execute function private.notify_low_stock();

-- -----------------------------------------------------------------------------
-- LARGE_SALE: threshold configured per business (NULL = disabled).
-- -----------------------------------------------------------------------------
alter table public.businesses
  add column large_sale_threshold bigint check (large_sale_threshold > 0);

comment on column public.businesses.large_sale_threshold is
  'Sales with total >= this amount notify reports.read holders. NULL = disabled.';

grant update (large_sale_threshold) on public.businesses to authenticated;

create or replace function private.notify_large_sale()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_threshold bigint;
begin
  select large_sale_threshold into v_threshold from public.businesses where id = new.business_id;
  if v_threshold is not null and new.total_amount >= v_threshold then
    perform private.notify_members(new.business_id, 'reports.read', 'LARGE_SALE',
      'Vente importante : ' || new.number,
      format('Vente de %s FCFA enregistrée.', to_char(new.total_amount, 'FM999G999G999G999')),
      jsonb_build_object('sale_id', new.id, 'number', new.number, 'total_amount', new.total_amount,
                         'sold_by', new.sold_by),
      'sale', new.id);
  end if;
  return null;
end;
$$;

create trigger notify_large_sale
  after insert on public.sales
  for each row execute function private.notify_large_sale();

-- -----------------------------------------------------------------------------
-- MEMBER_INVITED
-- -----------------------------------------------------------------------------
create or replace function private.notify_member_invited()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_business text;
  v_role     text;
begin
  select name into v_business from public.businesses where id = new.business_id;
  select name into v_role from public.roles where id = new.role_id;
  perform private.notify_user(new.user_id, new.business_id, 'MEMBER_INVITED',
    'Invitation : ' || v_business,
    format('Vous êtes invité(e) à rejoindre %s en tant que %s.', v_business, v_role),
    jsonb_build_object('business_id', new.business_id, 'role', v_role),
    'business', new.business_id);
  return null;
end;
$$;

create trigger notify_member_invited
  after insert on public.business_members
  for each row when (new.status = 'INVITED')
  execute function private.notify_member_invited();

-- -----------------------------------------------------------------------------
-- SUBSCRIPTION: payment issues
-- -----------------------------------------------------------------------------
create or replace function private.notify_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.notify_members(new.business_id, 'subscription.manage', 'SUBSCRIPTION',
    case new.status when 'PAST_DUE' then 'Paiement de l''abonnement en retard'
                    else 'Abonnement expiré' end,
    case new.status
      when 'PAST_DUE' then 'Réglez votre abonnement pour éviter le passage en lecture seule.'
      else 'Votre espace est en lecture seule ; la caisse reste disponible. Renouvelez votre abonnement.' end,
    jsonb_build_object('status', new.status, 'current_period_end', new.current_period_end),
    'subscription', new.id);
  return null;
end;
$$;

create trigger notify_subscription
  after update of status on public.subscriptions
  for each row when (new.status in ('PAST_DUE', 'EXPIRED') and old.status is distinct from new.status)
  execute function private.notify_subscription();

-- -----------------------------------------------------------------------------
-- Privileges + RLS: own notifications only.
-- -----------------------------------------------------------------------------
alter table public.notifications enable row level security;

grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

create policy "users can select their own notifications"
  on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

create policy "users can mark their own notifications as read"
  on public.notifications for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "users can delete their own notifications"
  on public.notifications for delete to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.mark_all_notifications_read(p_business_id uuid default null)
returns int
language sql
security invoker
set search_path = ''
as $$
  with updated as (
    update public.notifications set read_at = now()
     where user_id = (select auth.uid())
       and read_at is null
       and (p_business_id is null or business_id = p_business_id)
    returning 1)
  select count(*)::int from updated;
$$;

revoke all on function public.mark_all_notifications_read(uuid) from public, anon;
grant execute on function public.mark_all_notifications_read(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Realtime
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;
