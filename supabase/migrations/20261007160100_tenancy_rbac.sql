-- =============================================================================
-- JËND PRO — Tenancy + RBAC (Phases 3-4)
-- -----------------------------------------------------------------------------
-- businesses (tenant), locations, business_members, permissions, roles,
-- role_permissions, security helpers and RLS. Delivered together because a
-- membership needs a role and tenant RLS needs permissions (decision D1: no
-- table ever exists without RLS).
--
-- Write paths:
--   * businesses: INSERT via public.create_business() only; UPDATE of a fixed
--     column list for `settings.manage`.
--   * locations: INSERT/UPDATE for `settings.manage`; no DELETE (archive).
--   * business_members: RPC only (invite/accept/change role/remove).
--   * permissions / roles / role_permissions: migrations only.
-- See docs/security.md and docs/roles-and-permissions.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------
create type public.business_status as enum ('ACTIVE', 'SUSPENDED');
create type public.record_status   as enum ('ACTIVE', 'ARCHIVED');
create type public.location_type   as enum ('STORE', 'WAREHOUSE');
create type public.member_status   as enum ('INVITED', 'ACTIVE', 'SUSPENDED');

-- -----------------------------------------------------------------------------
-- businesses — the tenant
-- -----------------------------------------------------------------------------
create table public.businesses (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null check (char_length(btrim(name)) between 2 and 120),
  legal_name           text check (char_length(legal_name) <= 200),
  ninea                text check (char_length(ninea) <= 30),
  rccm                 text check (char_length(rccm) <= 50),
  phone                text check (phone ~ '^\+?[0-9]{6,15}$'),
  email                text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  address              text check (char_length(address) <= 300),
  city                 text check (char_length(city) <= 100),
  country_code         char(2) not null default 'SN' check (country_code ~ '^[A-Z]{2}$'),
  currency_code        char(3) not null default 'XOF' check (currency_code ~ '^[A-Z]{3}$'),
  timezone             text not null default 'Africa/Dakar',
  logo_path            text check (char_length(logo_path) <= 500),
  allow_negative_stock boolean not null default false,
  status               public.business_status not null default 'ACTIVE',
  created_by           uuid references auth.users (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.businesses is 'Tenant. Created only through public.create_business().';
comment on column public.businesses.currency_code is
  'ISO 4217. All amounts of the business are bigint in this currency''s minor unit (XOF: francs). Immutable for clients.';
comment on column public.businesses.status is
  'Platform-level status. SUSPENDED businesses are inaccessible to their members.';

create trigger set_updated_at
  before update on public.businesses
  for each row execute function private.set_updated_at();

-- Normalizes name and validates the IANA timezone (not expressible as CHECK).
create or replace function private.validate_business()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  if (tg_op = 'INSERT' or new.timezone is distinct from old.timezone)
     and not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'INVALID_TIMEZONE' using errcode = '22023', detail = new.timezone;
  end if;
  return new;
end;
$$;

create trigger validate_business
  before insert or update on public.businesses
  for each row execute function private.validate_business();

-- -----------------------------------------------------------------------------
-- RBAC catalog
-- -----------------------------------------------------------------------------
create table public.permissions (
  code        text primary key check (code ~ '^[a-z_]+\.[a-z_]+$'),
  module      text not null,
  description text not null,
  created_at  timestamptz not null default now()
);

comment on table public.permissions is 'Global permission catalog. Managed by migrations only.';

create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  -- NULL = system role shared by every business; NOT NULL = custom role (future).
  business_id uuid references public.businesses (id) on delete cascade,
  code        text not null check (code ~ '^[A-Z][A-Z_]{1,49}$'),
  name        text not null check (char_length(name) between 1 and 80),
  description text,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint roles_scope_check check (is_system = (business_id is null))
);

comment on table public.roles is
  'System roles (business_id NULL) and future per-business custom roles.';

create unique index roles_system_code_key on public.roles (code) where business_id is null;
create unique index roles_business_code_key on public.roles (business_id, code) where business_id is not null;

create trigger set_updated_at
  before update on public.roles
  for each row execute function private.set_updated_at();

create table public.role_permissions (
  -- CASCADE: a grant has no meaning without its role or permission.
  role_id         uuid not null references public.roles (id) on delete cascade,
  permission_code text not null references public.permissions (code) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (role_id, permission_code)
);

-- -----------------------------------------------------------------------------
-- locations — stores / warehouses of a business
-- -----------------------------------------------------------------------------
create table public.locations (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id),
  name        text not null check (char_length(btrim(name)) between 1 and 120),
  type        public.location_type not null default 'STORE',
  address     text check (char_length(address) <= 300),
  is_default  boolean not null default false,
  status      public.record_status not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint locations_business_id_id_key unique (business_id, id),
  constraint locations_default_active_check check (not (is_default and status = 'ARCHIVED'))
);

comment on table public.locations is
  'Store or warehouse. Every business has exactly one default location (created with it).';

create unique index locations_one_default_per_business_key
  on public.locations (business_id) where is_default;
create unique index locations_business_name_key
  on public.locations (business_id, lower(name)) where status = 'ACTIVE';

create trigger set_updated_at
  before update on public.locations
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- business_members — user × business × role
-- -----------------------------------------------------------------------------
create table public.business_members (
  id          uuid primary key default gen_random_uuid(),
  -- CASCADE: memberships are meaningless without their business / user.
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role_id     uuid not null references public.roles (id),
  status      public.member_status not null default 'INVITED',
  invited_by  uuid references auth.users (id) on delete set null,
  joined_at   timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint business_members_business_id_user_id_key unique (business_id, user_id),
  constraint business_members_business_id_id_key unique (business_id, id),
  constraint business_members_joined_at_check check ((status = 'INVITED') = (joined_at is null))
);

comment on table public.business_members is
  'Membership of a user in a business. Written only by RPCs. A user may belong to several businesses.';

-- "My businesses / my permissions" lookups (RLS helpers) filter by user_id first.
create index business_members_user_id_idx on public.business_members (user_id);

create trigger set_updated_at
  before update on public.business_members
  for each row execute function private.set_updated_at();

-- A member's role must be a system role or a custom role of the same business.
create or replace function private.check_member_role_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.roles r
     where r.id = new.role_id
       and (r.business_id is null or r.business_id = new.business_id)
  ) then
    raise exception 'ROLE_NOT_IN_BUSINESS' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger check_member_role_scope
  before insert or update of role_id, business_id on public.business_members
  for each row execute function private.check_member_role_scope();

-- -----------------------------------------------------------------------------
-- Security helpers (private, SECURITY DEFINER to avoid RLS recursion)
-- Only ACTIVE members of ACTIVE businesses have any right.
-- -----------------------------------------------------------------------------
create or replace function private.system_role_id(p_code text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.roles where business_id is null and code = p_code;
$$;

create or replace function private.member_business_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.business_id
    from public.business_members m
    join public.businesses b on b.id = m.business_id
   where m.user_id = (select auth.uid())
     and m.status = 'ACTIVE'
     and b.status = 'ACTIVE';
$$;

create or replace function private.businesses_with_permission(p_permission text)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.business_id
    from public.business_members m
    join public.businesses b on b.id = m.business_id
    join public.role_permissions rp on rp.role_id = m.role_id
   where m.user_id = (select auth.uid())
     and m.status = 'ACTIVE'
     and b.status = 'ACTIVE'
     and rp.permission_code = p_permission;
$$;

create or replace function private.is_member(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.member_business_ids() id where id = p_business_id);
$$;

create or replace function private.has_permission(p_business_id uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.businesses_with_permission(p_permission) id where id = p_business_id
  );
$$;

-- Guard used as the first statement of every business RPC.
-- Same error whether the business exists or not: no information leak.
create or replace function private.require_permission(p_business_id uuid, p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if not private.has_permission(p_business_id, p_permission) then
    raise exception 'PERMISSION_DENIED' using errcode = '42501', detail = p_permission;
  end if;
end;
$$;

grant execute on function
  private.system_role_id(text),
  private.member_business_ids(),
  private.businesses_with_permission(text),
  private.is_member(uuid),
  private.has_permission(uuid, text),
  private.require_permission(uuid, text)
to authenticated;

-- -----------------------------------------------------------------------------
-- Invariant: a business always keeps at least one ACTIVE OWNER.
-- The business row is locked so concurrent demotions are serialized.
-- Skipped when the business itself is being deleted (cascade).
-- -----------------------------------------------------------------------------
create or replace function private.ensure_business_has_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_role uuid := private.system_role_id('OWNER');
begin
  if old.status = 'ACTIVE' and old.role_id = v_owner_role then
    perform 1 from public.businesses where id = old.business_id for update;
    if found and not exists (
      select 1 from public.business_members m
       where m.business_id = old.business_id
         and m.status = 'ACTIVE'
         and m.role_id = v_owner_role
    ) then
      raise exception 'LAST_OWNER' using errcode = 'P0001',
        detail = 'A business must keep at least one active owner.';
    end if;
  end if;
  return null;
end;
$$;

create trigger ensure_business_has_owner
  after update or delete on public.business_members
  for each row execute function private.ensure_business_has_owner();

-- -----------------------------------------------------------------------------
-- Privileges + RLS
-- -----------------------------------------------------------------------------
alter table public.businesses       enable row level security;
alter table public.permissions      enable row level security;
alter table public.roles            enable row level security;
alter table public.role_permissions enable row level security;
alter table public.locations        enable row level security;
alter table public.business_members enable row level security;

-- businesses
grant select on public.businesses to authenticated;
grant update (name, legal_name, ninea, rccm, phone, email, address, city,
              timezone, logo_path, allow_negative_stock)
  on public.businesses to authenticated;

create policy "members can select their businesses"
  on public.businesses for select to authenticated
  using (id in (select private.member_business_ids()));

create policy "members with settings.manage can update their business"
  on public.businesses for update to authenticated
  using (id in (select private.businesses_with_permission('settings.manage')))
  with check (id in (select private.businesses_with_permission('settings.manage')));

-- RBAC catalog: readable, never writable by clients.
grant select on public.permissions, public.roles, public.role_permissions to authenticated;

create policy "authenticated users can select permissions"
  on public.permissions for select to authenticated
  using (true);

create policy "users can select system roles and roles of their businesses"
  on public.roles for select to authenticated
  using (business_id is null or business_id in (select private.member_business_ids()));

create policy "users can select grants of visible roles"
  on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id));

-- locations
grant select on public.locations to authenticated;
grant insert (business_id, name, type, address) on public.locations to authenticated;
grant update (name, type, address, status) on public.locations to authenticated;

create policy "members can select locations"
  on public.locations for select to authenticated
  using (business_id in (select private.member_business_ids()));

create policy "members with settings.manage can insert locations"
  on public.locations for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('settings.manage')));

create policy "members with settings.manage can update locations"
  on public.locations for update to authenticated
  using (business_id in (select private.businesses_with_permission('settings.manage')))
  with check (business_id in (select private.businesses_with_permission('settings.manage')));

-- business_members: own rows (incl. pending invitations) or full list with members.read.
grant select on public.business_members to authenticated;

create policy "users can select their own memberships"
  on public.business_members for select to authenticated
  using (user_id = (select auth.uid()));

create policy "members with members.read can select memberships"
  on public.business_members for select to authenticated
  using (business_id in (select private.businesses_with_permission('members.read')));

-- -----------------------------------------------------------------------------
-- Seed: permission catalog (docs/roles-and-permissions.md §2)
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description) values
  ('settings.manage',      'business',  'Modifier les informations, paramètres et emplacements de l''entreprise'),
  ('subscription.manage',  'business',  'Gérer l''abonnement'),
  ('members.read',         'members',   'Voir les membres et leurs rôles'),
  ('members.manage',       'members',   'Inviter, changer le rôle, suspendre, retirer un membre'),
  ('employees.read',       'employees', 'Voir les fiches employés'),
  ('employees.manage',     'employees', 'Gérer les fiches employés'),
  ('products.read',        'products',  'Voir le catalogue'),
  ('products.create',      'products',  'Créer un produit'),
  ('products.update',      'products',  'Modifier un produit'),
  ('products.delete',      'products',  'Archiver un produit'),
  ('products.read_cost',   'products',  'Voir les coûts d''achat et les marges'),
  ('categories.manage',    'products',  'Gérer les catégories'),
  ('inventory.read',       'inventory', 'Voir les stocks et mouvements'),
  ('inventory.adjust',     'inventory', 'Ajuster le stock (inventaire, perte, casse, stock initial)'),
  ('inventory.transfer',   'inventory', 'Transférer du stock entre emplacements'),
  ('customers.read',       'customers', 'Voir les clients, soldes et historiques'),
  ('customers.create',     'customers', 'Créer un client'),
  ('customers.manage',     'customers', 'Modifier/archiver un client, plafond de crédit'),
  ('customers.payments',   'customers', 'Enregistrer un règlement de crédit client'),
  ('suppliers.read',       'suppliers', 'Voir les fournisseurs'),
  ('suppliers.manage',     'suppliers', 'Gérer les fournisseurs'),
  ('purchases.read',       'purchases', 'Voir les achats'),
  ('purchases.create',     'purchases', 'Créer/modifier un achat'),
  ('purchases.receive',    'purchases', 'Réceptionner un achat'),
  ('purchases.payments',   'purchases', 'Enregistrer un paiement fournisseur'),
  ('purchases.cancel',     'purchases', 'Annuler un achat non réceptionné'),
  ('sales.read',           'sales',     'Voir toutes les ventes'),
  ('sales.read_own',       'sales',     'Voir ses propres ventes'),
  ('sales.create',         'sales',     'Enregistrer une vente'),
  ('sales.discount',       'sales',     'Appliquer une remise'),
  ('sales.credit',         'sales',     'Vendre à crédit'),
  ('sales.cancel',         'sales',     'Annuler une vente'),
  ('expenses.read',        'expenses',  'Voir les dépenses'),
  ('expenses.create',      'expenses',  'Enregistrer une dépense'),
  ('expenses.manage',      'expenses',  'Modifier/supprimer une dépense, gérer les catégories'),
  ('reports.read',         'reports',   'Voir les tableaux de bord et rapports'),
  ('audit.read',           'audit',     'Consulter le journal d''audit');

-- -----------------------------------------------------------------------------
-- Seed: system roles + matrix (docs/roles-and-permissions.md §3)
-- -----------------------------------------------------------------------------
insert into public.roles (code, name, description, is_system) values
  ('OWNER',         'Propriétaire',          'Tous les droits, y compris abonnement et propriété', true),
  ('ADMIN',         'Administrateur',        'Tous les droits sauf l''abonnement', true),
  ('MANAGER',       'Gérant',                'Gestion opérationnelle complète', true),
  ('CASHIER',       'Caissier',              'Ventes, clients et encaissements', true),
  ('STOCK_MANAGER', 'Gestionnaire de stock', 'Produits, stock, fournisseurs et achats', true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.business_id is null
   and (
        r.code = 'OWNER'
     or (r.code = 'ADMIN' and p.code <> 'subscription.manage')
     or (r.code = 'MANAGER' and p.code = any (array[
          'members.read', 'employees.read',
          'products.read', 'products.create', 'products.update', 'products.delete',
          'products.read_cost', 'categories.manage',
          'inventory.read', 'inventory.adjust', 'inventory.transfer',
          'customers.read', 'customers.create', 'customers.manage', 'customers.payments',
          'suppliers.read', 'suppliers.manage',
          'purchases.read', 'purchases.create', 'purchases.receive',
          'purchases.payments', 'purchases.cancel',
          'sales.read', 'sales.read_own', 'sales.create', 'sales.discount',
          'sales.credit', 'sales.cancel',
          'expenses.read', 'expenses.create', 'reports.read']))
     or (r.code = 'CASHIER' and p.code = any (array[
          'products.read', 'inventory.read',
          'customers.read', 'customers.create', 'customers.payments',
          'sales.read_own', 'sales.create', 'sales.credit']))
     or (r.code = 'STOCK_MANAGER' and p.code = any (array[
          'products.read', 'products.create', 'products.update', 'products.read_cost',
          'categories.manage',
          'inventory.read', 'inventory.adjust', 'inventory.transfer',
          'suppliers.read', 'suppliers.manage',
          'purchases.read', 'purchases.create', 'purchases.receive']))
   );
