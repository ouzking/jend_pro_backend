-- =============================================================================
-- JËND PRO — Foundation
-- -----------------------------------------------------------------------------
-- * `private` schema: security helpers and internal functions. Not exposed by
--   PostgREST (absent from [api].schemas), but `authenticated` needs USAGE so
--   RLS policies can call the helpers it is explicitly granted.
-- * Default privileges: nothing is implicitly granted to `anon`/`authenticated`.
--   Every table and function declares its own grants in the migration that
--   creates it (defense in depth on top of RLS; enables column-level grants).
-- * Shared trigger functions.
-- See docs/architecture.md §3 and docs/security.md §3-4.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schema `private`
-- -----------------------------------------------------------------------------
create schema if not exists private;
comment on schema private is
  'Internal helpers (RLS checks, stock engine, audit). Never exposed through the API.';

revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Default privileges for objects created by the migration role (postgres)
-- -----------------------------------------------------------------------------
-- Functions: PostgreSQL grants EXECUTE to PUBLIC by default, and Supabase adds
-- explicit grants to anon/authenticated in `public`. Remove both: every function
-- must grant EXECUTE explicitly.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;

-- Tables / sequences in `public`: no implicit access for API roles. Each table
-- grants exactly the operations (and columns) its RLS policies are designed for.
-- `service_role` keeps Supabase's default grants (server-side only).
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Shared trigger functions
-- -----------------------------------------------------------------------------
-- Maintains `updated_at` on every mutable table:
--   create trigger set_updated_at before update on public.<table>
--     for each row execute function private.set_updated_at();
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function private.set_updated_at() is
  'BEFORE UPDATE trigger: sets updated_at to the transaction timestamp.';
