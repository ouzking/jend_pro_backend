-- Support tickets and platform announcements (Phase 16).
begin;
select plan(38);

select tests.setup_two_tenants();

create temp table ids (key text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.k(text) returns uuid language sql as $$ select id from ids where key = $1 $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into ids values ('a', tests.business_id('Business A')), ('b', tests.business_id('Business B'));

select tests.create_user(e) from unnest(array['ops@jendpro.test', 'support@jendpro.test', 'analyst@jendpro.test']) e;
insert into public.platform_admins (user_id, role) values
  (tests.get_user_id('ops@jendpro.test'),     'OPERATIONS'),
  (tests.get_user_id('support@jendpro.test'), 'SUPPORT'),
  (tests.get_user_id('analyst@jendpro.test'), 'ANALYST');

-- =============================================================================
-- Tickets — requester side
-- =============================================================================
select tests.login('owner_a@test.local');
select lives_ok($$ insert into ids select 't', public.create_support_ticket('Imprimante ticket', 'Le ticket ne s''imprime plus.', pg_temp.k('a'), 'HIGH') $$,
  'a member opens a ticket for their business');
select throws_ok($$ insert into public.support_tickets (subject) values ('Direct') $$, '42501', null,
  'tickets cannot be inserted directly');

select tests.login('outsider@test.local');
select throws_ok($$ select public.create_support_ticket('Accès', 'Bonjour', pg_temp.k('a')) $$, '42501', 'PERMISSION_DENIED',
  'a non-member cannot open a ticket for a business');
select lives_ok($$ select public.create_support_ticket('Inscription', 'Je n''arrive pas à créer mon entreprise.') $$,
  'a user can open a ticket without a business');

select tests.login('cashier_a@test.local');
select is((select count(*)::int from public.support_tickets), 0, 'colleagues do not see each other''s tickets');
select tests.login('owner_b@test.local');
select throws_ok($$ select public.reply_support_ticket(pg_temp.k('t'), 'Hello') $$, '42501', 'PERMISSION_DENIED',
  'only the requester can reply');

select tests.login('owner_a@test.local');
select is((select count(*)::int from public.support_tickets), 1, 'the requester sees their ticket');
select tests.clear_authentication();

-- =============================================================================
-- Tickets — staff side
-- =============================================================================
select tests.login_mfa('analyst@jendpro.test');
select throws_ok($$ select * from public.admin_list_support_tickets() $$, '42501', 'PERMISSION_DENIED',
  'ANALYST has no support access');

select tests.login_mfa('support@jendpro.test');
select is((select count(*)::int from public.admin_list_support_tickets(p_search => 'Business A')), 1,
  'support staff list tickets of every tenant');
select is((select requester_email from public.admin_list_support_tickets(p_search => 'Business A')), 'owner_a@test.local',
  'the requester is resolved');
select is((select count(*)::int from public.support_tickets
            where business_id = pg_temp.k('a') or created_by = tests.get_user_id('outsider@test.local')), 2,
  'support staff can read every ticket (of every requester)');
select lives_ok($$ select public.admin_reply_support_ticket(pg_temp.k('t'), 'Pouvez-vous redémarrer l''imprimante ?') $$,
  'support replies');
select lives_ok($$ select public.admin_reply_support_ticket(pg_temp.k('t'), 'Client VIP, traiter vite', true) $$,
  'support adds an internal note');
select is(jsonb_array_length(public.admin_get_support_ticket(pg_temp.k('t')) -> 'messages'), 3,
  'staff see the whole conversation, internal notes included');
select is((select status::text from public.support_tickets where id = pg_temp.k('t')), 'IN_PROGRESS',
  'a staff reply moves an OPEN ticket to IN_PROGRESS');

select tests.login('owner_a@test.local');
select is((select count(*)::int from public.support_messages where ticket_id = pg_temp.k('t')), 2,
  'the requester never sees internal notes');
select is((select count(*)::int from public.notifications where data ->> 'kind' = 'SUPPORT_REPLY'), 1,
  'the requester is notified of the reply');

select tests.login_mfa('support@jendpro.test');
select lives_ok($$ select public.admin_update_support_ticket(pg_temp.k('t'), p_status => 'WAITING') $$, 'status change');
select tests.login('owner_a@test.local');
select lives_ok($$ select public.reply_support_ticket(pg_temp.k('t'), 'Toujours pas.') $$, 'the requester answers');
select tests.clear_authentication();
select is((select status::text from public.support_tickets where id = pg_temp.k('t')), 'OPEN',
  'an answer to a WAITING ticket reopens it');

select tests.login_mfa('support@jendpro.test');
select throws_ok($$ select public.admin_update_support_ticket(pg_temp.k('t'), p_assigned_to => tests.get_user_id('analyst@jendpro.test')) $$,
  'P0001', 'INVALID_ASSIGNEE', 'tickets can only be assigned to support-capable staff');
select lives_ok($$ select public.admin_update_support_ticket(pg_temp.k('t'), p_assigned_to => tests.get_user_id('support@jendpro.test'), p_status => 'CLOSED') $$,
  'assign and close');
select tests.clear_authentication();
select ok((select closed_at is not null and assigned_to = tests.get_user_id('support@jendpro.test')
             from public.support_tickets where id = pg_temp.k('t')), 'closing timestamps the ticket');
select is((select count(*)::int from public.audit_logs where action = 'support.ticket_update' and resource_id = pg_temp.k('t')), 2,
  'ticket changes are audited');
select throws_ok($$ update public.support_messages set body = 'x' $$, 'P0001', 'APPEND_ONLY', 'messages are append-only');

select tests.login('owner_a@test.local');
select throws_ok($$ select public.reply_support_ticket(pg_temp.k('t'), 'Encore ?') $$, 'P0001', 'TICKET_CLOSED',
  'a closed ticket cannot be answered');
select tests.clear_authentication();

-- =============================================================================
-- Announcements
-- =============================================================================
select tests.login('owner_a@test.local');
select throws_ok($$ select count(*) from public.platform_announcements $$, '42501', null,
  'announcements are not readable through the API');

select tests.login_mfa('support@jendpro.test');
select throws_ok($$ select public.admin_save_announcement(null, 'Maintenance', 'Ce soir', 'ALL') $$, '42501',
  'PERMISSION_DENIED', 'SUPPORT cannot write announcements');

select tests.login_mfa('ops@jendpro.test');
select throws_ok($$ select public.admin_save_announcement(null, 'Promo', 'Texte', 'PLAN', 'GOLD') $$, 'P0002',
  'PLAN_NOT_FOUND', 'the audience must exist');
select throws_ok($$ select public.admin_save_announcement(null, 'Promo', 'Texte', 'BUSINESS', 'not-a-uuid') $$, 'P0002',
  'BUSINESS_NOT_FOUND', 'a business audience must be a real business');
select lives_ok($$ insert into ids select 'ann', public.admin_save_announcement(null, 'Nouvelle version', 'Découvrez les rapports.', 'BUSINESS', pg_temp.k('a')::text) $$,
  'OPERATIONS saves a draft');
select is(public.admin_count_announcement_recipients('BUSINESS', pg_temp.k('a')::text), 6,
  'the recipient count can be previewed');
select is(public.admin_send_announcement(pg_temp.k('ann')), 6, 'sending reaches every active member of the audience');
select throws_ok($$ select public.admin_send_announcement(pg_temp.k('ann')) $$, 'P0001', 'ANNOUNCEMENT_NOT_EDITABLE',
  'an announcement is sent once');
select is((select audience_label from public.admin_list_announcements() where id = pg_temp.k('ann')), 'Business A',
  'the history shows a readable audience');

select lives_ok($$ insert into ids select 'ann2', public.admin_save_announcement(null, 'Caissiers', 'Astuce caisse', 'ROLE', 'CASHIER') $$,
  'a role audience');
select lives_ok($$ select public.admin_send_announcement(pg_temp.k('ann2')) $$, 'sent to cashiers');
select tests.clear_authentication();

select results_eq($$ select u.email::text from public.notifications n join auth.users u on u.id = n.user_id
                      where n.resource_id = pg_temp.k('ann2') and u.email like '%@test.local' order by 1 $$,
  array['cashier_a@test.local', 'multi@test.local'], 'only members holding the role receive it');

select * from finish();
rollback;
