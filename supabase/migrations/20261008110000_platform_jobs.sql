-- =============================================================================
-- JËND PRO — Platform operations: billing activation, daily jobs (Phase 14)
-- -----------------------------------------------------------------------------
-- * billing_events: processed payment events (idempotency). Internal.
-- * platform_activate_subscription(): called by the billing-webhook Edge
--   Function with the service_role key ONLY (not executable by API users).
-- * private.daily_maintenance() scheduled with pg_cron (06:00 UTC = Dakar):
--   trial-ending reminders, expiry of lapsed subscriptions (notifies owners),
--   notification retention.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- billing_events (internal)
-- -----------------------------------------------------------------------------
create table public.billing_events (
  id              uuid primary key default gen_random_uuid(),
  provider        text not null check (char_length(provider) between 1 and 40),
  event_id        text not null check (char_length(event_id) between 1 and 200),
  business_id     uuid not null references public.businesses (id) on delete cascade,
  subscription_id uuid references public.subscriptions (id) on delete set null,
  plan_code       text not null,
  months          int not null check (months between 1 and 36),
  amount          bigint not null check (amount >= 0),
  processed_at    timestamptz not null default now(),
  constraint billing_events_provider_event_id_key unique (provider, event_id)
);

comment on table public.billing_events is
  'Processed billing events (idempotency of payment webhooks). Internal: no API access.';

alter table public.billing_events enable row level security;
-- No grant, no policy for API roles.

-- -----------------------------------------------------------------------------
-- platform_activate_subscription (service_role only)
-- Activates or extends the business subscription after a confirmed payment.
-- Same (provider, event_id) twice => no-op, returns the first result.
-- -----------------------------------------------------------------------------
create or replace function public.platform_activate_subscription(
  p_provider    text,
  p_event_id    text,
  p_business_id uuid,
  p_plan_code   text,
  p_months      int,
  p_amount      bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan    public.subscription_plans;
  v_current public.subscriptions;
  v_event   public.billing_events;
  v_start   timestamptz;
  v_base    timestamptz;
  v_sub_id  uuid;
begin
  -- Idempotency first (the unique key also protects against concurrent deliveries).
  select * into v_event from public.billing_events where provider = p_provider and event_id = p_event_id;
  if found then
    return jsonb_build_object('duplicate', true, 'subscription_id', v_event.subscription_id);
  end if;

  if p_months is null or p_months not between 1 and 36 then
    raise exception 'INVALID_PERIOD' using errcode = '22023';
  end if;
  select * into v_plan from public.subscription_plans where code = p_plan_code;
  if not found then
    raise exception 'PLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then
    raise exception 'BUSINESS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if coalesce(p_amount, -1) < v_plan.price_amount * p_months then
    raise exception 'AMOUNT_MISMATCH' using errcode = 'P0001',
      detail = json_build_object('expected', v_plan.price_amount * p_months, 'received', p_amount)::text;
  end if;

  perform 1 from public.businesses where id = p_business_id for update;
  select * into v_current from public.subscriptions
   where business_id = p_business_id and status in ('TRIALING', 'ACTIVE', 'PAST_DUE')
   for update;

  if found then
    -- Renewal of the same paid plan extends from the current end; otherwise starts now.
    v_base := case when v_current.status in ('ACTIVE', 'PAST_DUE') and v_current.plan_id = v_plan.id
                        and v_current.current_period_end > now()
                   then v_current.current_period_end else now() end;
    v_start := case when v_base > now() then v_current.current_period_start else now() end;
    update public.subscriptions
       set plan_id = v_plan.id, status = 'ACTIVE', current_period_start = v_start,
           current_period_end = v_base + make_interval(months => p_months),
           cancel_at_period_end = false, external_reference = p_provider || ':' || p_event_id
     where id = v_current.id
    returning id into v_sub_id;
  else
    insert into public.subscriptions (business_id, plan_id, status, current_period_start, current_period_end,
                                      external_reference)
    values (p_business_id, v_plan.id, 'ACTIVE', now(), now() + make_interval(months => p_months),
            p_provider || ':' || p_event_id)
    returning id into v_sub_id;
  end if;

  insert into public.billing_events (provider, event_id, business_id, subscription_id, plan_code, months, amount)
  values (p_provider, p_event_id, p_business_id, v_sub_id, p_plan_code, p_months, p_amount);

  return jsonb_build_object('duplicate', false, 'subscription_id', v_sub_id,
    'current_period_end', (select current_period_end from public.subscriptions where id = v_sub_id));
end;
$$;

revoke all on function public.platform_activate_subscription(text, text, uuid, text, int, bigint)
  from public, anon, authenticated;
grant execute on function public.platform_activate_subscription(text, text, uuid, text, int, bigint)
  to service_role;

-- -----------------------------------------------------------------------------
-- Daily maintenance
-- -----------------------------------------------------------------------------
create or replace function private.daily_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub       record;
  v_reminders int := 0;
  v_expired   int := 0;
  v_purged    int := 0;
begin
  -- 1. Trial ending within 3 days: one reminder per subscription.
  for v_sub in
    select s.* from public.subscriptions s
     where s.status = 'TRIALING'
       and s.trial_ends_at > now() and s.trial_ends_at <= now() + interval '3 days'
       and not exists (select 1 from public.notifications n
                        where n.resource_id = s.id and n.data ->> 'kind' = 'TRIAL_ENDING')
  loop
    perform private.notify_members(v_sub.business_id, 'subscription.manage', 'SUBSCRIPTION',
      'Votre essai se termine bientôt',
      format('Votre période d''essai se termine le %s. Choisissez un abonnement pour continuer sans interruption.',
             to_char(v_sub.trial_ends_at at time zone 'Africa/Dakar', 'DD/MM/YYYY')),
      jsonb_build_object('kind', 'TRIAL_ENDING', 'trial_ends_at', v_sub.trial_ends_at),
      'subscription', v_sub.id);
    v_reminders := v_reminders + 1;
  end loop;

  -- 2. Lapsed subscriptions become EXPIRED (access is already restricted by
  --    date; this makes the status explicit and notifies owners).
  update public.subscriptions s
     set status = 'EXPIRED', ended_at = now()
   where (s.status = 'TRIALING' and s.trial_ends_at <= now())
      or (s.status in ('ACTIVE', 'PAST_DUE') and s.current_period_end is not null
          and s.current_period_end + interval '7 days' <= now());
  get diagnostics v_expired = row_count;

  -- 3. Notification retention: read > 90 days, any > 180 days.
  delete from public.notifications
   where (read_at is not null and created_at < now() - interval '90 days')
      or created_at < now() - interval '180 days';
  get diagnostics v_purged = row_count;

  return jsonb_build_object('trial_reminders', v_reminders, 'expired', v_expired, 'notifications_purged', v_purged);
end;
$$;

create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule('jendpro-daily-maintenance', '0 6 * * *', $$select private.daily_maintenance()$$);
