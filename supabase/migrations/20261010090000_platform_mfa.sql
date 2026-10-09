-- =============================================================================
-- JËND PRO — Platform MFA (Phase 17)
-- -----------------------------------------------------------------------------
-- The back-office sees every tenant: a stolen staff password must not be
-- enough. Enforced in the ONE place every admin RPC and staff RLS policy goes
-- through (private.has_platform_permission), from the session's Authenticator
-- Assurance Level (JWT claim `aal`, set by Supabase Auth after a TOTP check):
--
--   1. A staff member who enrolled a verified MFA factor needs an aal2 session
--      for ANY platform permission (no downgrade to password-only).
--   2. Sensitive permissions (platform_permissions.requires_mfa) always need
--      aal2: business suspension, manual payments, staff management,
--      announcements. Data-driven, like permissions.allowed_when_restricted.
--
-- The role grant and the MFA requirement are distinct errors for the UI:
-- PERMISSION_DENIED (role) vs MFA_REQUIRED (verify / enrol a second factor).
-- =============================================================================

alter table public.platform_permissions
  add column requires_mfa boolean not null default false;

comment on column public.platform_permissions.requires_mfa is
  'Sensitive permission: only granted to an aal2 session (TOTP verified).';

update public.platform_permissions set requires_mfa = true
 where code in ('businesses.manage', 'billing.manage', 'admins.manage', 'announcements.manage');

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function private.session_is_aal2()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select auth.jwt()) ->> 'aal', 'aal1') = 'aal2';
$$;

create or replace function private.has_verified_mfa(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from auth.mfa_factors f where f.user_id = p_user_id and f.status = 'verified');
$$;

-- Role grant only (no MFA condition): used to tell MFA_REQUIRED from PERMISSION_DENIED.
create or replace function private.role_has_platform_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.platform_admins a
      join public.platform_role_permissions rp on rp.role = a.role
     where a.user_id = (select auth.uid())
       and a.status = 'ACTIVE'
       and rp.permission_code = p_permission);
$$;

-- Central resolver (signature unchanged: every policy and RPC inherits the rule).
create or replace function private.has_platform_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.role_has_platform_permission(p_permission)
     and (private.session_is_aal2()
          or (not private.has_verified_mfa((select auth.uid()))
              and not exists (select 1 from public.platform_permissions p
                               where p.code = p_permission and p.requires_mfa)));
$$;

create or replace function private.require_platform_permission(p_permission text)
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
  if not private.role_has_platform_permission(p_permission) then
    raise exception 'PERMISSION_DENIED' using errcode = '42501', detail = p_permission;
  end if;
  if not private.has_platform_permission(p_permission) then
    raise exception 'MFA_REQUIRED' using errcode = '42501', detail = p_permission;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Access description for the UI (role permissions + MFA state of the session)
-- -----------------------------------------------------------------------------
drop function public.get_my_platform_access();

create function public.get_my_platform_access()
returns table (
  role            public.platform_role,
  status          public.platform_admin_status,
  permissions     text[],
  mfa_permissions text[],
  mfa_enrolled    boolean,
  aal             text
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.role, a.status,
         case when a.status = 'ACTIVE'
              then coalesce((select array_agg(rp.permission_code order by rp.permission_code)
                               from public.platform_role_permissions rp where rp.role = a.role), '{}')
              else '{}' end,
         coalesce((select array_agg(p.code order by p.code) from public.platform_permissions p where p.requires_mfa), '{}'),
         private.has_verified_mfa(a.user_id),
         coalesce((select auth.jwt()) ->> 'aal', 'aal1')
    from public.platform_admins a
   where a.user_id = (select auth.uid());
$$;

revoke all on function public.get_my_platform_access() from public, anon;
grant execute on function public.get_my_platform_access() to authenticated;
