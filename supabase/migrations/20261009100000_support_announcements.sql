-- =============================================================================
-- JËND PRO — Support tickets + platform announcements (Phase 16)
-- -----------------------------------------------------------------------------
-- Support:
--   * support_tickets / support_messages. A user opens a ticket (optionally for
--     a business they are an ACTIVE member of) and talks with platform staff.
--   * Users see their own tickets and the non-internal messages; staff with
--     support.read see everything (including internal notes).
--   * Writes through RPC only. Messages are append-only.
-- Announcements:
--   * platform_announcements (DRAFT -> SENT). Sending fans out SYSTEM
--     notifications (existing table + Realtime) to the selected audience:
--     ALL users with an active membership, members of businesses on a PLAN,
--     members of one BUSINESS, or members holding a system ROLE.
--   * No direct API access: admin_* RPCs only.
-- =============================================================================

create type public.ticket_status as enum ('OPEN', 'IN_PROGRESS', 'WAITING', 'RESOLVED', 'CLOSED');
create type public.ticket_priority as enum ('LOW', 'NORMAL', 'HIGH', 'URGENT');
create type public.announcement_audience as enum ('ALL', 'PLAN', 'BUSINESS', 'ROLE');
create type public.announcement_status as enum ('DRAFT', 'SENT');

-- -----------------------------------------------------------------------------
-- support_tickets
-- -----------------------------------------------------------------------------
create table public.support_tickets (
  id              uuid primary key default gen_random_uuid(),
  number          bigint generated always as identity unique,
  -- NULL: request not tied to a business (e.g. onboarding). CASCADE: erased with the business.
  business_id     uuid references public.businesses (id) on delete cascade,
  created_by      uuid references auth.users (id) on delete set null,
  subject         text not null check (char_length(btrim(subject)) between 3 and 200),
  status          public.ticket_status not null default 'OPEN',
  priority        public.ticket_priority not null default 'NORMAL',
  assigned_to     uuid references auth.users (id) on delete set null,
  last_message_at timestamptz not null default now(),
  resolved_at     timestamptz,
  closed_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.support_tickets is
  'Support requests from users to the JËND PRO team. Written by RPC only.';

create index support_tickets_business_id_idx on public.support_tickets (business_id);
create index support_tickets_created_by_idx on public.support_tickets (created_by, last_message_at desc);
create index support_tickets_status_idx on public.support_tickets (status, last_message_at desc);
create index support_tickets_assigned_to_idx on public.support_tickets (assigned_to) where assigned_to is not null;

create trigger set_updated_at
  before update on public.support_tickets
  for each row execute function private.set_updated_at();

create table public.support_messages (
  id          uuid primary key default gen_random_uuid(),
  -- CASCADE: messages are pure children of their ticket.
  ticket_id   uuid not null references public.support_tickets (id) on delete cascade,
  author_id   uuid references auth.users (id) on delete set null,
  is_staff    boolean not null default false,
  -- Internal notes are visible to platform staff only.
  is_internal boolean not null default false,
  body        text not null check (char_length(btrim(body)) between 1 and 5000),
  -- clock_timestamp(): several messages written in one transaction (reply +
  -- status change, seeds, imports) keep their real order.
  created_at  timestamptz not null default clock_timestamp(),
  constraint support_messages_internal_staff_check check (not is_internal or is_staff)
);

comment on table public.support_messages is 'Conversation of a support ticket. Append-only.';

create index support_messages_ticket_id_idx on public.support_messages (ticket_id, created_at);

create trigger prevent_update
  before update on public.support_messages
  for each row execute function private.prevent_update();

alter table public.support_tickets  enable row level security;
alter table public.support_messages enable row level security;

grant select on public.support_tickets, public.support_messages to authenticated;

create policy "users can select their tickets and staff can select all"
  on public.support_tickets for select to authenticated
  using (created_by = (select auth.uid()) or (select private.has_platform_permission('support.read')));

create policy "users can select public messages of their tickets and staff all"
  on public.support_messages for select to authenticated
  using ((select private.has_platform_permission('support.read'))
         or (not is_internal and exists (select 1 from public.support_tickets t
                                          where t.id = ticket_id and t.created_by = (select auth.uid()))));

-- -----------------------------------------------------------------------------
-- Support RPC — users
-- -----------------------------------------------------------------------------
create or replace function public.create_support_ticket(
  p_subject     text,
  p_body        text,
  p_business_id uuid default null,
  p_priority    public.ticket_priority default 'NORMAL'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if p_business_id is not null and not private.is_member(p_business_id) then
    raise exception 'PERMISSION_DENIED' using errcode = '42501';
  end if;
  -- Anti-spam: at most 10 tickets per user per day.
  if (select count(*) from public.support_tickets
       where created_by = (select auth.uid()) and created_at > now() - interval '1 day') >= 10 then
    raise exception 'RATE_LIMITED' using errcode = 'P0001';
  end if;

  insert into public.support_tickets (business_id, created_by, subject, priority)
  values (p_business_id, (select auth.uid()), btrim(p_subject), coalesce(p_priority, 'NORMAL'))
  returning id into v_id;

  insert into public.support_messages (ticket_id, author_id, body)
  values (v_id, (select auth.uid()), btrim(p_body));
  return v_id;
end;
$$;

-- The requester replies; a WAITING / RESOLVED ticket goes back to OPEN.
create or replace function public.reply_support_ticket(p_ticket_id uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket public.support_tickets;
  v_id     uuid;
begin
  select * into v_ticket from public.support_tickets
   where id = p_ticket_id and created_by = (select auth.uid())
   for update;
  if not found then
    raise exception 'PERMISSION_DENIED' using errcode = '42501';
  end if;
  if v_ticket.status = 'CLOSED' then
    raise exception 'TICKET_CLOSED' using errcode = 'P0001';
  end if;

  insert into public.support_messages (ticket_id, author_id, body)
  values (p_ticket_id, (select auth.uid()), btrim(p_body))
  returning id into v_id;

  update public.support_tickets
     set last_message_at = now(),
         status = case when status in ('WAITING', 'RESOLVED') then 'OPEN' else status end,
         resolved_at = case when status = 'RESOLVED' then null else resolved_at end
   where id = p_ticket_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Support RPC — staff
-- -----------------------------------------------------------------------------
create or replace function public.admin_list_support_tickets(
  p_status      public.ticket_status default null,
  p_priority    public.ticket_priority default null,
  p_assigned_to uuid default null,
  p_unassigned  boolean default false,
  p_business_id uuid default null,
  p_search      text default null,
  p_open_only   boolean default false,
  p_limit       int default 25,
  p_offset      int default 0
)
returns table (
  id               uuid,
  number           bigint,
  subject          text,
  status           public.ticket_status,
  priority         public.ticket_priority,
  business_id      uuid,
  business_name    text,
  created_by       uuid,
  requester_name   text,
  requester_email  text,
  assigned_to      uuid,
  assignee_name    text,
  messages_count   int,
  last_message_at  timestamptz,
  created_at       timestamptz,
  total_count      bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.like_pattern(p_search);
begin
  perform private.require_platform_permission('support.read');

  return query
  select t.id, t.number, t.subject, t.status, t.priority, t.business_id, b.name, t.created_by,
         rp.full_name, ru.email::text, t.assigned_to, ap.full_name,
         (select count(*)::int from public.support_messages m where m.ticket_id = t.id and not m.is_internal),
         t.last_message_at, t.created_at, count(*) over ()
    from public.support_tickets t
    left join public.businesses b on b.id = t.business_id
    left join public.profiles rp on rp.id = t.created_by
    left join auth.users ru on ru.id = t.created_by
    left join public.profiles ap on ap.id = t.assigned_to
   where (p_status is null or t.status = p_status)
     and (not coalesce(p_open_only, false) or t.status in ('OPEN', 'IN_PROGRESS', 'WAITING'))
     and (p_priority is null or t.priority = p_priority)
     and (p_assigned_to is null or t.assigned_to = p_assigned_to)
     and (not coalesce(p_unassigned, false) or t.assigned_to is null)
     and (p_business_id is null or t.business_id = p_business_id)
     and (v_pattern is null or t.subject ilike v_pattern or b.name ilike v_pattern or ru.email ilike v_pattern
          or t.number::text = btrim(p_search))
   order by case t.priority when 'URGENT' then 0 when 'HIGH' then 1 when 'NORMAL' then 2 else 3 end,
            t.last_message_at desc, t.id
   limit private.page_limit(p_limit) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create or replace function public.admin_get_support_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ticket jsonb;
begin
  perform private.require_platform_permission('support.read');

  select to_jsonb(t) || jsonb_build_object(
           'business_name', b.name, 'requester_name', rp.full_name, 'requester_email', ru.email,
           'assignee_name', ap.full_name)
    into v_ticket
    from public.support_tickets t
    left join public.businesses b on b.id = t.business_id
    left join public.profiles rp on rp.id = t.created_by
    left join auth.users ru on ru.id = t.created_by
    left join public.profiles ap on ap.id = t.assigned_to
   where t.id = p_ticket_id;

  if v_ticket is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;

  return v_ticket || jsonb_build_object('messages', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', m.id, 'author_id', m.author_id, 'author_name', p.full_name, 'is_staff', m.is_staff,
             'is_internal', m.is_internal, 'body', m.body, 'created_at', m.created_at)
           order by m.created_at, m.id)
      from public.support_messages m
      left join public.profiles p on p.id = m.author_id
     where m.ticket_id = p_ticket_id), '[]'::jsonb));
end;
$$;

-- Staff reply (or internal note). A public reply on an OPEN ticket moves it to
-- IN_PROGRESS and notifies the requester.
create or replace function public.admin_reply_support_ticket(p_ticket_id uuid, p_body text, p_internal boolean default false)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket public.support_tickets;
  v_id     uuid;
begin
  perform private.require_platform_permission('support.manage');

  select * into v_ticket from public.support_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_ticket.status = 'CLOSED' and not coalesce(p_internal, false) then
    raise exception 'TICKET_CLOSED' using errcode = 'P0001';
  end if;

  insert into public.support_messages (ticket_id, author_id, is_staff, is_internal, body)
  values (p_ticket_id, (select auth.uid()), true, coalesce(p_internal, false), btrim(p_body))
  returning id into v_id;

  if not coalesce(p_internal, false) then
    update public.support_tickets
       set last_message_at = now(),
           status = case when status = 'OPEN' then 'IN_PROGRESS' else status end
     where id = p_ticket_id;

    if v_ticket.created_by is not null then
      perform private.notify_user(v_ticket.created_by, v_ticket.business_id, 'SYSTEM',
        format('Réponse du support — ticket #%s', v_ticket.number),
        left(btrim(p_body), 300),
        jsonb_build_object('kind', 'SUPPORT_REPLY', 'ticket_id', p_ticket_id),
        'support_ticket', p_ticket_id);
    end if;
  end if;
  return v_id;
end;
$$;

-- Status / priority / assignment. NULL argument = unchanged. p_unassign clears the assignee.
create or replace function public.admin_update_support_ticket(
  p_ticket_id   uuid,
  p_status      public.ticket_status default null,
  p_priority    public.ticket_priority default null,
  p_assigned_to uuid default null,
  p_unassign    boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.support_tickets;
  v_new public.support_tickets;
begin
  perform private.require_platform_permission('support.manage');

  select * into v_old from public.support_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_assigned_to is not null and not exists (
       select 1 from public.platform_admins a
         join public.platform_role_permissions rp on rp.role = a.role
        where a.user_id = p_assigned_to and a.status = 'ACTIVE' and rp.permission_code = 'support.manage') then
    raise exception 'INVALID_ASSIGNEE' using errcode = 'P0001';
  end if;

  update public.support_tickets t
     set status      = coalesce(p_status, t.status),
         priority    = coalesce(p_priority, t.priority),
         assigned_to = case when coalesce(p_unassign, false) then null else coalesce(p_assigned_to, t.assigned_to) end,
         resolved_at = case when coalesce(p_status, t.status) = 'RESOLVED' then coalesce(t.resolved_at, now())
                            when coalesce(p_status, t.status) = 'CLOSED' then t.resolved_at
                            else null end,
         closed_at   = case when coalesce(p_status, t.status) = 'CLOSED' then coalesce(t.closed_at, now()) else null end
   where t.id = p_ticket_id
  returning * into v_new;

  if v_new.status is distinct from v_old.status or v_new.priority is distinct from v_old.priority
     or v_new.assigned_to is distinct from v_old.assigned_to then
    perform private.log_audit(null, 'support.ticket_update', 'support_ticket', p_ticket_id,
      jsonb_build_object('business_id', v_old.business_id,
        'status', jsonb_build_object('old', v_old.status, 'new', v_new.status),
        'priority', jsonb_build_object('old', v_old.priority, 'new', v_new.priority),
        'assigned_to', jsonb_build_object('old', v_old.assigned_to, 'new', v_new.assigned_to)));
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- platform_announcements
-- -----------------------------------------------------------------------------
create table public.platform_announcements (
  id               uuid primary key default gen_random_uuid(),
  title            text not null check (char_length(btrim(title)) between 3 and 150),
  body             text not null check (char_length(btrim(body)) between 1 and 1000),
  audience         public.announcement_audience not null default 'ALL',
  -- PLAN: plan code · BUSINESS: business id · ROLE: system role code · ALL: NULL.
  audience_value   text check (char_length(audience_value) <= 100),
  status           public.announcement_status not null default 'DRAFT',
  recipients_count int,
  created_by       uuid references auth.users (id) on delete set null,
  sent_by          uuid references auth.users (id) on delete set null,
  sent_at          timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint platform_announcements_audience_scope_check check ((audience = 'ALL') = (audience_value is null)),
  constraint platform_announcements_sent_check check ((status = 'SENT') = (sent_at is not null))
);

comment on table public.platform_announcements is
  'Announcements from the JËND PRO team, delivered as SYSTEM notifications. RPC only.';

create index platform_announcements_created_at_idx on public.platform_announcements (created_at desc);

create trigger set_updated_at
  before update on public.platform_announcements
  for each row execute function private.set_updated_at();

alter table public.platform_announcements enable row level security;
-- No grant, no policy for API roles: admin_* RPCs only.

create or replace function private.validate_announcement_audience(
  p_audience public.announcement_audience,
  p_value    text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_value text := nullif(btrim(p_value), '');
begin
  if p_audience = 'ALL' then
    return null;
  end if;
  if v_value is null then
    raise exception 'AUDIENCE_VALUE_REQUIRED' using errcode = '22023';
  end if;
  if p_audience = 'PLAN' and not exists (select 1 from public.subscription_plans where code = v_value) then
    raise exception 'PLAN_NOT_FOUND' using errcode = 'P0002';
  elsif p_audience = 'ROLE' and not exists (select 1 from public.roles where business_id is null and code = v_value) then
    raise exception 'ROLE_NOT_FOUND' using errcode = 'P0002';
  elsif p_audience = 'BUSINESS' and (v_value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                     or not exists (select 1 from public.businesses where id = v_value::uuid)) then
    raise exception 'BUSINESS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v_value;
end;
$$;

-- Recipients: ACTIVE members of ACTIVE businesses matching the audience.
create or replace function private.announcement_recipients(
  p_audience public.announcement_audience,
  p_value    text
)
returns table (user_id uuid, business_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (m.user_id) m.user_id,
         case when p_audience = 'BUSINESS' then m.business_id end
    from public.business_members m
    join public.businesses b on b.id = m.business_id and b.status = 'ACTIVE'
    join public.roles r on r.id = m.role_id
   where m.status = 'ACTIVE'
     and (p_audience <> 'BUSINESS' or m.business_id = p_value::uuid)
     and (p_audience <> 'ROLE' or (r.business_id is null and r.code = p_value))
     and (p_audience <> 'PLAN' or exists (
           select 1 from public.subscriptions s
             join public.subscription_plans p on p.id = s.plan_id
            where s.business_id = m.business_id and p.code = p_value
              and s.status in ('TRIALING', 'ACTIVE', 'PAST_DUE')))
   order by m.user_id;
$$;

create or replace function public.admin_list_announcements(p_limit int default 25, p_offset int default 0)
returns table (
  id               uuid,
  title            text,
  body             text,
  audience         public.announcement_audience,
  audience_value   text,
  audience_label   text,
  status           public.announcement_status,
  recipients_count int,
  created_by_name  text,
  sent_by_name     text,
  sent_at          timestamptz,
  created_at       timestamptz,
  total_count      bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('announcements.read');

  return query
  select a.id, a.title, a.body, a.audience, a.audience_value,
         case a.audience
           when 'PLAN' then (select p.name from public.subscription_plans p where p.code = a.audience_value)
           when 'ROLE' then (select r.name from public.roles r where r.business_id is null and r.code = a.audience_value)
           when 'BUSINESS' then (select b.name from public.businesses b where b.id::text = a.audience_value)
         end,
         a.status, a.recipients_count, cp.full_name, sp.full_name, a.sent_at, a.created_at, count(*) over ()
    from public.platform_announcements a
    left join public.profiles cp on cp.id = a.created_by
    left join public.profiles sp on sp.id = a.sent_by
   order by a.created_at desc, a.id
   limit private.page_limit(p_limit) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- Creates (p_id NULL) or edits a DRAFT.
create or replace function public.admin_save_announcement(
  p_id             uuid,
  p_title          text,
  p_body           text,
  p_audience       public.announcement_audience,
  p_audience_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_value text;
  v_id    uuid;
begin
  perform private.require_platform_permission('announcements.manage');
  v_value := private.validate_announcement_audience(p_audience, p_audience_value);

  if p_id is null then
    insert into public.platform_announcements (title, body, audience, audience_value, created_by)
    values (btrim(p_title), btrim(p_body), p_audience, v_value, (select auth.uid()))
    returning id into v_id;
  else
    update public.platform_announcements
       set title = btrim(p_title), body = btrim(p_body), audience = p_audience, audience_value = v_value
     where id = p_id and status = 'DRAFT'
    returning id into v_id;
    if v_id is null then
      raise exception 'ANNOUNCEMENT_NOT_EDITABLE' using errcode = 'P0001';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_delete_announcement(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('announcements.manage');
  delete from public.platform_announcements where id = p_id and status = 'DRAFT';
  if not found then
    raise exception 'ANNOUNCEMENT_NOT_EDITABLE' using errcode = 'P0001';
  end if;
end;
$$;

-- Number of users a draft would reach (preview before sending).
create or replace function public.admin_count_announcement_recipients(
  p_audience       public.announcement_audience,
  p_audience_value text default null
)
returns int
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('announcements.read');
  return (select count(*)::int from private.announcement_recipients(
            p_audience, private.validate_announcement_audience(p_audience, p_audience_value)));
end;
$$;

create or replace function public.admin_send_announcement(p_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ann   public.platform_announcements;
  v_count int;
begin
  perform private.require_platform_permission('announcements.manage');

  select * into v_ann from public.platform_announcements where id = p_id for update;
  if not found or v_ann.status <> 'DRAFT' then
    raise exception 'ANNOUNCEMENT_NOT_EDITABLE' using errcode = 'P0001';
  end if;
  -- Re-validate: the target may have disappeared since the draft was saved.
  perform private.validate_announcement_audience(v_ann.audience, v_ann.audience_value);

  insert into public.notifications (business_id, user_id, type, title, body, data, resource_type, resource_id)
  select r.business_id, r.user_id, 'SYSTEM', v_ann.title, v_ann.body,
         jsonb_build_object('kind', 'ANNOUNCEMENT', 'announcement_id', v_ann.id),
         'announcement', v_ann.id
    from private.announcement_recipients(v_ann.audience, v_ann.audience_value) r;
  get diagnostics v_count = row_count;

  update public.platform_announcements
     set status = 'SENT', sent_at = now(), sent_by = (select auth.uid()), recipients_count = v_count
   where id = p_id;

  perform private.log_audit(null, 'announcement.send', 'announcement', p_id,
    jsonb_build_object('audience', v_ann.audience, 'audience_value', v_ann.audience_value, 'recipients', v_count));
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke all on function
  public.create_support_ticket(text, text, uuid, public.ticket_priority),
  public.reply_support_ticket(uuid, text),
  public.admin_list_support_tickets(public.ticket_status, public.ticket_priority, uuid, boolean, uuid, text, boolean, int, int),
  public.admin_get_support_ticket(uuid),
  public.admin_reply_support_ticket(uuid, text, boolean),
  public.admin_update_support_ticket(uuid, public.ticket_status, public.ticket_priority, uuid, boolean),
  public.admin_list_announcements(int, int),
  public.admin_save_announcement(uuid, text, text, public.announcement_audience, text),
  public.admin_delete_announcement(uuid),
  public.admin_count_announcement_recipients(public.announcement_audience, text),
  public.admin_send_announcement(uuid)
from public, anon;

grant execute on function
  public.create_support_ticket(text, text, uuid, public.ticket_priority),
  public.reply_support_ticket(uuid, text),
  public.admin_list_support_tickets(public.ticket_status, public.ticket_priority, uuid, boolean, uuid, text, boolean, int, int),
  public.admin_get_support_ticket(uuid),
  public.admin_reply_support_ticket(uuid, text, boolean),
  public.admin_update_support_ticket(uuid, public.ticket_status, public.ticket_priority, uuid, boolean),
  public.admin_list_announcements(int, int),
  public.admin_save_announcement(uuid, text, text, public.announcement_audience, text),
  public.admin_delete_announcement(uuid),
  public.admin_count_announcement_recipients(public.announcement_audience, text),
  public.admin_send_announcement(uuid)
to authenticated;
