-- =============================================================================
-- JËND PRO — Tenancy RPCs (Phases 3-4)
-- -----------------------------------------------------------------------------
-- Business creation and membership management. All are SECURITY DEFINER and
-- follow docs/security.md §4: pinned search_path, permission check first,
-- server-side actor (auth.uid()), audit.
--
-- Hierarchy rule (generic, works for future custom roles):
--   a caller may only grant, modify, suspend or remove a role whose permissions
--   are a SUBSET of the caller's own permissions.
--   => ADMIN (no subscription.manage) can never touch or create an OWNER.
-- Plus: nobody changes their own role/status, and a business always keeps an
-- active OWNER (trigger private.ensure_business_has_owner).
--
-- Error contract: message = stable machine code (see docs/business-rules.md §13).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Internal helpers
-- -----------------------------------------------------------------------------
create or replace function private.resolve_role(p_business_id uuid, p_role_code text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role_id uuid;
begin
  select r.id into v_role_id
    from public.roles r
   where r.code = p_role_code
     and (r.business_id is null or r.business_id = p_business_id)
   order by r.business_id nulls first
   limit 1;
  if v_role_id is null then
    raise exception 'ROLE_NOT_FOUND' using errcode = 'P0002', detail = p_role_code;
  end if;
  return v_role_id;
end;
$$;

create or replace function private.require_role_within_caller(p_business_id uuid, p_role_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select rp.permission_code from public.role_permissions rp where rp.role_id = p_role_id
    except
    select rp.permission_code
      from public.business_members m
      join public.role_permissions rp on rp.role_id = m.role_id
     where m.business_id = p_business_id
       and m.user_id = (select auth.uid())
       and m.status = 'ACTIVE'
  ) then
    raise exception 'ROLE_ABOVE_CALLER' using errcode = '42501';
  end if;
end;
$$;

-- Locks and returns the target membership (raises if absent).
create or replace function private.lock_member(p_business_id uuid, p_user_id uuid)
returns public.business_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
begin
  select * into v_member
    from public.business_members
   where business_id = p_business_id and user_id = p_user_id
   for update;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v_member;
end;
$$;

-- -----------------------------------------------------------------------------
-- create_business: business + default location + OWNER membership, atomically.
-- -----------------------------------------------------------------------------
create or replace function public.create_business(
  p_name    text,
  p_phone   text default null,
  p_city    text default null,
  p_address text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_business_id uuid;
  -- Abuse guard; raise via a migration if real customers need more.
  c_max_owned   constant int := 10;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;

  if (select count(*) from public.business_members m
       where m.user_id = v_uid and m.role_id = private.system_role_id('OWNER')) >= c_max_owned then
    raise exception 'BUSINESS_LIMIT_REACHED' using errcode = 'P0001';
  end if;

  insert into public.businesses (name, phone, city, address, created_by)
  values (p_name, p_phone, p_city, p_address, v_uid)
  returning id into v_business_id;

  insert into public.locations (business_id, name, is_default)
  values (v_business_id, 'Boutique principale', true);

  insert into public.business_members (business_id, user_id, role_id, status, joined_at)
  values (v_business_id, v_uid, private.system_role_id('OWNER'), 'ACTIVE', now());

  perform private.log_audit(v_business_id, 'business.create', 'business', v_business_id,
                            jsonb_build_object('name', btrim(p_name)));
  return v_business_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Read helpers for clients
-- -----------------------------------------------------------------------------
-- Permission codes of the caller in a business (empty when not an active member).
-- Used by Flutter/React to adapt the UI; enforcement stays in RLS/RPC.
create or replace function public.get_my_permissions(p_business_id uuid)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select rp.permission_code
    from public.business_members m
    join public.businesses b on b.id = m.business_id
    join public.role_permissions rp on rp.role_id = m.role_id
   where m.business_id = p_business_id
     and m.user_id = (select auth.uid())
     and m.status = 'ACTIVE'
     and b.status = 'ACTIVE'
   order by 1;
$$;

-- Pending invitations of the caller, with the business name to display.
create or replace function public.list_my_invitations()
returns table (
  business_id   uuid,
  business_name text,
  role_code     text,
  role_name     text,
  invited_at    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select m.business_id, b.name, r.code, r.name, m.created_at
    from public.business_members m
    join public.businesses b on b.id = m.business_id
    join public.roles r on r.id = m.role_id
   where m.user_id = (select auth.uid())
     and m.status = 'INVITED'
     and b.status = 'ACTIVE'
   order by m.created_at desc;
$$;

-- Member directory. Any active member sees active co-workers' display names
-- (needed e.g. to show who made a sale). Contact details, invited and
-- suspended members require members.read.
create or replace function public.list_business_members(p_business_id uuid)
returns table (
  user_id     uuid,
  full_name   text,
  avatar_path text,
  role_code   text,
  role_name   text,
  status      public.member_status,
  joined_at   timestamptz,
  email       text,
  phone       text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_full boolean;
begin
  if not private.is_member(p_business_id) then
    raise exception 'PERMISSION_DENIED' using errcode = '42501';
  end if;
  v_full := private.has_permission(p_business_id, 'members.read');

  return query
  select m.user_id, p.full_name, p.avatar_path, r.code, r.name, m.status, m.joined_at,
         case when v_full then u.email::text end,
         case when v_full then p.phone end
    from public.business_members m
    join public.roles r on r.id = m.role_id
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
   where m.business_id = p_business_id
     and (v_full or m.status = 'ACTIVE')
   order by r.code, p.full_name;
end;
$$;

-- -----------------------------------------------------------------------------
-- Invitations
-- -----------------------------------------------------------------------------
-- Invites an EXISTING user (by e-mail). Inviting someone without an account
-- requires the Auth admin API -> Edge Function (Phase 14), which will create
-- the user then call this RPC.
create or replace function public.invite_member(
  p_business_id uuid,
  p_email       text,
  p_role_code   text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role_id   uuid;
  v_user_id   uuid;
  v_member_id uuid;
begin
  perform private.require_permission(p_business_id, 'members.manage');
  v_role_id := private.resolve_role(p_business_id, p_role_code);
  perform private.require_role_within_caller(p_business_id, v_role_id);

  select u.id into v_user_id from auth.users u where lower(u.email) = lower(btrim(p_email));
  if v_user_id is null then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if exists (select 1 from public.business_members
              where business_id = p_business_id and user_id = v_user_id) then
    raise exception 'ALREADY_MEMBER' using errcode = 'P0001';
  end if;

  insert into public.business_members (business_id, user_id, role_id, status, invited_by)
  values (p_business_id, v_user_id, v_role_id, 'INVITED', (select auth.uid()))
  returning id into v_member_id;

  perform private.log_audit(p_business_id, 'member.invite', 'business_member', v_member_id,
                            jsonb_build_object('user_id', v_user_id, 'role', p_role_code));
  return v_member_id;
end;
$$;

create or replace function public.accept_invitation(p_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
begin
  update public.business_members
     set status = 'ACTIVE', joined_at = now()
   where business_id = p_business_id
     and user_id = (select auth.uid())
     and status = 'INVITED'
  returning id into v_member_id;

  if v_member_id is null then
    raise exception 'INVITATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform private.log_audit(p_business_id, 'member.join', 'business_member', v_member_id);
end;
$$;

create or replace function public.decline_invitation(p_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
begin
  delete from public.business_members
   where business_id = p_business_id
     and user_id = (select auth.uid())
     and status = 'INVITED'
  returning id into v_member_id;

  if v_member_id is null then
    raise exception 'INVITATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform private.log_audit(p_business_id, 'member.decline', 'business_member', v_member_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- Member management
-- -----------------------------------------------------------------------------
create or replace function public.change_member_role(
  p_business_id uuid,
  p_user_id     uuid,
  p_role_code   text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member   public.business_members;
  v_new_role uuid;
  v_old_code text;
begin
  perform private.require_permission(p_business_id, 'members.manage');
  if p_user_id = (select auth.uid()) then
    raise exception 'CANNOT_MODIFY_SELF' using errcode = '42501';
  end if;

  v_member := private.lock_member(p_business_id, p_user_id);
  v_new_role := private.resolve_role(p_business_id, p_role_code);
  perform private.require_role_within_caller(p_business_id, v_member.role_id);
  perform private.require_role_within_caller(p_business_id, v_new_role);

  if v_new_role = v_member.role_id then
    return;
  end if;

  select code into v_old_code from public.roles where id = v_member.role_id;

  update public.business_members set role_id = v_new_role where id = v_member.id;

  perform private.log_audit(p_business_id, 'member.role_change', 'business_member', v_member.id,
                            jsonb_build_object('user_id', p_user_id, 'from', v_old_code, 'to', p_role_code));
end;
$$;

-- Suspend (ACTIVE -> SUSPENDED) or reactivate (SUSPENDED -> ACTIVE).
create or replace function public.set_member_status(
  p_business_id uuid,
  p_user_id     uuid,
  p_status      public.member_status
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
begin
  perform private.require_permission(p_business_id, 'members.manage');
  if p_status not in ('ACTIVE', 'SUSPENDED') then
    raise exception 'INVALID_STATUS' using errcode = '22023';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'CANNOT_MODIFY_SELF' using errcode = '42501';
  end if;

  v_member := private.lock_member(p_business_id, p_user_id);
  if v_member.status = 'INVITED' then
    raise exception 'INVALID_STATUS' using errcode = '22023',
      detail = 'Pending invitations cannot be suspended or activated by an administrator.';
  end if;
  perform private.require_role_within_caller(p_business_id, v_member.role_id);

  if v_member.status = p_status then
    return;
  end if;

  update public.business_members set status = p_status where id = v_member.id;

  perform private.log_audit(p_business_id, 'member.status_change', 'business_member', v_member.id,
                            jsonb_build_object('user_id', p_user_id,
                                               'from', v_member.status, 'to', p_status));
end;
$$;

-- Removes another member (or cancels a pending invitation).
create or replace function public.remove_member(p_business_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
begin
  perform private.require_permission(p_business_id, 'members.manage');
  if p_user_id = (select auth.uid()) then
    raise exception 'CANNOT_MODIFY_SELF' using errcode = '42501',
      detail = 'Use leave_business() to leave a business.';
  end if;

  v_member := private.lock_member(p_business_id, p_user_id);
  perform private.require_role_within_caller(p_business_id, v_member.role_id);

  delete from public.business_members where id = v_member.id;

  perform private.log_audit(p_business_id, 'member.remove', 'business_member', v_member.id,
                            jsonb_build_object('user_id', p_user_id));
end;
$$;

-- The caller leaves a business (blocked for the last OWNER by trigger).
create or replace function public.leave_business(p_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
begin
  delete from public.business_members
   where business_id = p_business_id
     and user_id = (select auth.uid())
     and status <> 'INVITED'
  returning id into v_member_id;

  if v_member_id is null then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform private.log_audit(p_business_id, 'member.leave', 'business_member', v_member_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants: API functions callable by signed-in users only.
-- -----------------------------------------------------------------------------
revoke all on function
  public.create_business(text, text, text, text),
  public.get_my_permissions(uuid),
  public.list_my_invitations(),
  public.list_business_members(uuid),
  public.invite_member(uuid, text, text),
  public.accept_invitation(uuid),
  public.decline_invitation(uuid),
  public.change_member_role(uuid, uuid, text),
  public.set_member_status(uuid, uuid, public.member_status),
  public.remove_member(uuid, uuid),
  public.leave_business(uuid)
from public, anon;

grant execute on function
  public.create_business(text, text, text, text),
  public.get_my_permissions(uuid),
  public.list_my_invitations(),
  public.list_business_members(uuid),
  public.invite_member(uuid, text, text),
  public.accept_invitation(uuid),
  public.decline_invitation(uuid),
  public.change_member_role(uuid, uuid, text),
  public.set_member_status(uuid, uuid, public.member_status),
  public.remove_member(uuid, uuid),
  public.leave_business(uuid)
to authenticated;
