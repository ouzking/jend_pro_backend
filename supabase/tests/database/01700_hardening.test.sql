-- =============================================================================
-- Architecture guardrails (Phase 15).
-- These assertions freeze the security surface and the data conventions of the
-- schema. A failure here means a change must be REVIEWED, not that the test
-- should be blindly updated:
--   * new RPC exposed to users         -> check permission + tenancy + tests
--   * new client-writable table/column -> check RLS policies + column grants
--   * new SECURITY DEFINER without require_permission -> justify (self-scoped?)
-- =============================================================================
begin;
select plan(16);

-- -----------------------------------------------------------------------------
-- Data conventions (docs/architecture.md §7, docs/business-rules.md §1)
-- -----------------------------------------------------------------------------
select is_empty($$
  select table_name || '.' || column_name from information_schema.columns
   where table_schema = 'public' and data_type in ('real', 'double precision', 'money') $$,
  'no floating point or money type: amounts are integers');

select is_empty($$
  select table_name || '.' || column_name || ' ' || data_type from information_schema.columns
   where table_schema = 'public'
     and column_name ~ '(amount|price|cost|balance|credit_limit|threshold)$'
     and data_type <> 'bigint' $$,
  'every money column is bigint (minor units of the business currency)');

select is_empty($$
  select table_name || '.' || column_name from information_schema.columns
   where table_schema = 'public' and data_type = 'timestamp without time zone' $$,
  'every timestamp is timestamptz');

select is_empty($$
  select c.relname from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and not exists (select 1 from pg_constraint where conrelid = c.oid and contype = 'p') $$,
  'every table has a primary key');

-- -----------------------------------------------------------------------------
-- Functions
-- -----------------------------------------------------------------------------
select is_empty($$
  select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') $$,
  'every function pins its search_path');

select is_empty($$
  select p.proname from pg_proc p
   where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace) and p.prosecdef
     and pg_get_userbyid(p.proowner) <> 'postgres' $$,
  'every SECURITY DEFINER function is owned by postgres');

select set_eq($$
  select p.proname::text from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef
     and pg_get_functiondef(p.oid) not like '%require_permission%' $$,
  array[
    -- self-scoped (auth.uid()) or membership-checked (is_member), reviewed:
    'accept_invitation', 'create_business', 'decline_invitation', 'get_my_permissions',
    'get_subscription_status', 'leave_business', 'list_business_members', 'list_my_invitations',
    -- service_role only:
    'platform_activate_subscription'],
  'SECURITY DEFINER RPCs without require_permission are exactly the reviewed self-scoped / platform ones');

select set_eq($$
  select p.proname::text from pg_proc p
   where p.pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', p.oid, 'EXECUTE') $$,
  array['accept_invitation', 'adjust_customer_balance', 'adjust_stock', 'cancel_purchase', 'cancel_sale',
        'change_member_role', 'count_stock', 'create_business', 'create_sale', 'decline_invitation',
        'get_audit_log', 'get_dashboard_summary', 'get_my_permissions', 'get_sales_timeseries',
        'get_subscription_status', 'get_top_products', 'invite_member', 'leave_business',
        'list_business_members', 'list_low_stock', 'list_my_invitations', 'mark_all_notifications_read',
        'order_purchase', 'receive_purchase', 'record_customer_payment', 'record_purchase_payment',
        'remove_member', 'save_purchase', 'set_customer_credit_limit', 'set_member_status',
        'set_product_status', 'transfer_stock'],
  'the RPC surface exposed to users is exactly the reviewed one');

select ok(not has_function_privilege('authenticated', 'public.platform_activate_subscription(text,text,uuid,text,int,bigint)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.platform_activate_subscription(text,text,uuid,text,int,bigint)', 'EXECUTE'),
  'platform RPCs are reserved to service_role');

select is_empty($$
  select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.proname not in ('system_role_id', 'member_business_ids', 'businesses_with_permission', 'is_member',
                           'has_permission', 'require_permission', 'storage_business_id') $$,
  'only the read-only RLS helpers of the private schema are executable by users');

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------
select set_eq($$
  select c.relname || ':' || priv from pg_class c cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) priv
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v')
     and case when priv = 'DELETE' then has_table_privilege('authenticated', c.oid, 'DELETE')
              else has_any_column_privilege('authenticated', c.oid, priv) end $$,
  array['businesses:UPDATE', 'categories:DELETE', 'categories:INSERT', 'categories:UPDATE',
        'customers:INSERT', 'customers:UPDATE', 'employees:INSERT', 'employees:UPDATE',
        'expense_categories:INSERT', 'expense_categories:UPDATE', 'expenses:DELETE', 'expenses:INSERT',
        'expenses:UPDATE', 'locations:INSERT', 'locations:UPDATE', 'notifications:DELETE',
        'notifications:UPDATE', 'product_costs:UPDATE', 'products:INSERT', 'products:UPDATE',
        'profiles:UPDATE', 'supplier_products:DELETE', 'supplier_products:INSERT',
        'supplier_products:UPDATE', 'suppliers:INSERT', 'suppliers:UPDATE'],
  'the tables writable by clients are exactly the reviewed ones (ledgers, sales, payments, audit: RPC only)');

select is_empty($$
  select c.relname from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and has_table_privilege('authenticated', c.oid, 'SELECT')
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname
                       and p.cmd in ('SELECT', 'ALL')) $$,
  'every table readable by users has a SELECT policy');

select is_empty($$
  select c.relname from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'business_id' and not a.attisdropped)
     and c.relname not in ('notifications', 'billing_events')  -- queried by user / by event id
     and not exists (select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                      where i.indrelid = c.oid and a.attname = 'business_id') $$,
  'every tenant table has an index leading with business_id');

select is_empty($$
  select c.relname from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
     and not coalesce(c.reloptions @> array['security_invoker=true'], false) $$,
  'every view is security_invoker (RLS of the caller applies)');

-- -----------------------------------------------------------------------------
-- Storage and Realtime
-- -----------------------------------------------------------------------------
select set_eq($$ select id from storage.buckets where public $$, array['business-assets', 'product-images'],
  'only non-sensitive buckets are public');

select set_eq($$ select tablename::text from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' $$,
  array['notifications'], 'only notifications are broadcast through Realtime');

select * from finish();
rollback;
