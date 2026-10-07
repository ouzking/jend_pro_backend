-- =============================================================================
-- JËND PRO — Analytics RPCs + hardening indexes (Phase 15)
-- -----------------------------------------------------------------------------
-- * Dashboard aggregations computed in the database (never on the client):
--     get_dashboard_summary, get_sales_timeseries, get_top_products.
--   Permission reports.read; margins only with products.read_cost (NULL otherwise).
--   Dates are business-local days (businesses.timezone), range <= 366 days.
-- * Indexes for cost tables listed per business (previously only reachable by
--   primary key, i.e. a per-business listing scanned every tenant's rows).
-- =============================================================================

create index product_costs_business_id_idx on public.product_costs (business_id);
create index sale_item_costs_business_item_idx on public.sale_item_costs (business_id, sale_item_id);

-- Validates a reporting range and returns it as UTC bounds [from, to).
create or replace function private.report_bounds(p_business_id uuid, p_from date, p_to date)
returns table (from_ts timestamptz, to_ts timestamptz, tz text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID_DATE_RANGE' using errcode = '22023';
  end if;
  if p_to - p_from > 366 then
    raise exception 'DATE_RANGE_TOO_LARGE' using errcode = '22023', detail = 'max 366 days';
  end if;
  select timezone into v_tz from public.businesses where id = p_business_id;
  return query select (p_from::timestamp at time zone v_tz), ((p_to + 1)::timestamp at time zone v_tz), v_tz;
end;
$$;

-- -----------------------------------------------------------------------------
-- Summary for a period (business-local dates, inclusive).
-- -----------------------------------------------------------------------------
create or replace function public.get_dashboard_summary(
  p_business_id uuid,
  p_from        date,
  p_to          date,
  p_location_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b        record;
  v_costs    boolean;
  v_sales    record;
  v_margin   bigint;
  v_cash     record;
  v_expenses bigint;
begin
  perform private.require_permission(p_business_id, 'reports.read');
  v_costs := private.has_permission(p_business_id, 'products.read_cost');
  select * into v_b from private.report_bounds(p_business_id, p_from, p_to);

  select count(*) filter (where s.status = 'COMPLETED')                          as sales_count,
         coalesce(sum(s.total_amount) filter (where s.status = 'COMPLETED'), 0)  as revenue,
         coalesce(sum(s.discount_amount) filter (where s.status = 'COMPLETED'), 0) as sale_discounts,
         coalesce(sum(s.credit_amount) filter (where s.status = 'COMPLETED'), 0) as credit_given,
         count(*) filter (where s.status = 'CANCELLED')                          as cancelled_count,
         count(distinct s.customer_id) filter (where s.status = 'COMPLETED')     as active_customers
    into v_sales
    from public.sales s
   where s.business_id = p_business_id
     and s.sold_at >= v_b.from_ts and s.sold_at < v_b.to_ts
     and (p_location_id is null or s.location_id = p_location_id);

  if v_costs then
    -- Line margins minus the global sale discounts.
    select coalesce(sum(si.line_total - round(si.quantity * c.unit_cost)), 0)::bigint - v_sales.sale_discounts
      into v_margin
      from public.sales s
      join public.sale_items si on si.business_id = s.business_id and si.sale_id = s.id
      join public.sale_item_costs c on c.business_id = si.business_id and c.sale_item_id = si.id
     where s.business_id = p_business_id and s.status = 'COMPLETED'
       and s.sold_at >= v_b.from_ts and s.sold_at < v_b.to_ts
       and (p_location_id is null or s.location_id = p_location_id);
  end if;

  select coalesce(sum(p.amount) filter (where p.direction = 'IN'), 0)  as cash_in,
         coalesce(sum(p.amount) filter (where p.direction = 'OUT'), 0) as cash_out
    into v_cash
    from public.payments p
   where p.business_id = p_business_id
     and p.paid_at >= v_b.from_ts and p.paid_at < v_b.to_ts
     and (p_location_id is null or p.location_id = p_location_id);

  select coalesce(sum(e.amount), 0) into v_expenses
    from public.expenses e
   where e.business_id = p_business_id
     and e.spent_on between p_from and p_to
     and (p_location_id is null or e.location_id = p_location_id);

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_b.tz, 'location_id', p_location_id,
    'revenue', v_sales.revenue,
    'sales_count', v_sales.sales_count,
    'average_basket', case when v_sales.sales_count > 0 then round(v_sales.revenue::numeric / v_sales.sales_count)::bigint else 0 end,
    'discounts', v_sales.sale_discounts,
    'credit_given', v_sales.credit_given,
    'cancelled_count', v_sales.cancelled_count,
    'active_customers', v_sales.active_customers,
    'estimated_margin', v_margin,
    'cash_in', v_cash.cash_in,
    'cash_out', v_cash.cash_out,
    'expenses', v_expenses,
    'net_cash_flow', v_cash.cash_in - v_cash.cash_out - v_expenses,
    -- Point-in-time figures (not period-bound).
    'customers_debt', (select coalesce(sum(balance), 0) from public.customers where business_id = p_business_id),
    'low_stock_count', (select count(*) from public.inventory i
                          join public.products pr on pr.business_id = i.business_id and pr.id = i.product_id
                         where i.business_id = p_business_id and pr.status = 'ACTIVE' and pr.track_stock
                           and pr.min_stock_level > 0 and i.quantity <= pr.min_stock_level
                           and (p_location_id is null or i.location_id = p_location_id)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Time series (gaps filled with zeros).
-- -----------------------------------------------------------------------------
create or replace function public.get_sales_timeseries(
  p_business_id uuid,
  p_from        date,
  p_to          date,
  p_granularity text default 'day',
  p_location_id uuid default null
)
returns table (period date, revenue bigint, sales_count int, estimated_margin bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b     record;
  v_costs boolean;
begin
  perform private.require_permission(p_business_id, 'reports.read');
  if p_granularity not in ('day', 'week', 'month') then
    raise exception 'INVALID_GRANULARITY' using errcode = '22023';
  end if;
  v_costs := private.has_permission(p_business_id, 'products.read_cost');
  select * into v_b from private.report_bounds(p_business_id, p_from, p_to);

  return query
  with s as (
    select date_trunc(p_granularity, s.sold_at at time zone v_b.tz)::date as period, s.id, s.business_id,
           s.total_amount, s.discount_amount
      from public.sales s
     where s.business_id = p_business_id and s.status = 'COMPLETED'
       and s.sold_at >= v_b.from_ts and s.sold_at < v_b.to_ts
       and (p_location_id is null or s.location_id = p_location_id)
  ), agg as (
    select s.period, sum(s.total_amount)::bigint as revenue, count(*)::int as sales_count
      from s group by s.period
  ), margin as (
    select s.period,
           (sum(si.line_total - round(si.quantity * c.unit_cost))
            - coalesce((select sum(x.discount_amount) from s x where x.period = s.period), 0))::bigint as margin
      from s
      join public.sale_items si on si.business_id = s.business_id and si.sale_id = s.id
      join public.sale_item_costs c on c.business_id = si.business_id and c.sale_item_id = si.id
     where v_costs
     group by s.period
  )
  select g.d::date,
         coalesce(agg.revenue, 0),
         coalesce(agg.sales_count, 0),
         case when v_costs then coalesce(margin.margin, 0) end
    from generate_series(date_trunc(p_granularity, p_from::timestamp), p_to::timestamp,
                         ('1 ' || p_granularity)::interval) g(d)
    left join agg on agg.period = g.d::date
    left join margin on margin.period = g.d::date
   order by 1;
end;
$$;

-- -----------------------------------------------------------------------------
-- Best sellers.
-- -----------------------------------------------------------------------------
create or replace function public.get_top_products(
  p_business_id uuid,
  p_from        date,
  p_to          date,
  p_limit       int default 10,
  p_location_id uuid default null
)
returns table (product_id uuid, product_name text, quantity numeric, revenue bigint, estimated_margin bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b     record;
  v_costs boolean;
begin
  perform private.require_permission(p_business_id, 'reports.read');
  v_costs := private.has_permission(p_business_id, 'products.read_cost');
  select * into v_b from private.report_bounds(p_business_id, p_from, p_to);

  return query
  select si.product_id,
         max(si.product_name),
         sum(si.quantity),
         sum(si.line_total)::bigint,
         case when v_costs then sum(si.line_total - round(si.quantity * c.unit_cost))::bigint end
    from public.sales s
    join public.sale_items si on si.business_id = s.business_id and si.sale_id = s.id
    left join public.sale_item_costs c on c.business_id = si.business_id and c.sale_item_id = si.id
   where s.business_id = p_business_id and s.status = 'COMPLETED'
     and s.sold_at >= v_b.from_ts and s.sold_at < v_b.to_ts
     and (p_location_id is null or s.location_id = p_location_id)
   group by si.product_id
   order by sum(si.line_total) desc, sum(si.quantity) desc
   limit least(greatest(coalesce(p_limit, 10), 1), 100);
end;
$$;

revoke all on function
  public.get_dashboard_summary(uuid, date, date, uuid),
  public.get_sales_timeseries(uuid, date, date, text, uuid),
  public.get_top_products(uuid, date, date, int, uuid)
from public, anon;

grant execute on function
  public.get_dashboard_summary(uuid, date, date, uuid),
  public.get_sales_timeseries(uuid, date, date, text, uuid),
  public.get_top_products(uuid, date, date, int, uuid)
to authenticated;
