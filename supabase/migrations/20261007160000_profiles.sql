-- =============================================================================
-- JËND PRO — Profiles (Phase 3)
-- -----------------------------------------------------------------------------
-- Application profile of a Supabase Auth user (1:1). Authentication data
-- (password, tokens, sessions) stays in auth.*; nothing sensitive is copied.
-- Co-workers' display names are exposed through public.list_business_members()
-- (tenancy RPC migration), not through this table.
-- =============================================================================

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text check (char_length(full_name) <= 120),
  phone       text check (phone ~ '^\+?[0-9]{6,15}$'),
  avatar_path text check (char_length(avatar_path) <= 500),
  locale      text not null default 'fr' check (locale in ('fr', 'en', 'wo')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is
  'Application profile of an auth user (1:1). Created by trigger on auth.users.';

create trigger set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Privileges + RLS: a user reads and edits only their own profile.
-- -----------------------------------------------------------------------------
alter table public.profiles enable row level security;

grant select on public.profiles to authenticated;
grant update (full_name, phone, avatar_path, locale) on public.profiles to authenticated;

create policy "users can select their own profile"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()));

create policy "users can update their own profile"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- Profile creation on signup.
-- Defensive on purpose: invalid metadata must never block a signup, so values
-- that would violate a constraint are dropped instead of raising.
-- -----------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    nullif(left(btrim(new.raw_user_meta_data ->> 'full_name'), 120), ''),
    case when new.phone ~ '^\+?[0-9]{6,15}$' then new.phone end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();
