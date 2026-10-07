-- =============================================================================
-- Local development seed — applied by `supabase db reset` ONLY.
-- Never run against staging/production. Reference data required in every
-- environment (permissions, system roles, subscription plans) belongs in
-- migrations, not here.
--
-- Demo accounts (password for all: jendpro-demo):
--   owner@demo.jendpro.local    OWNER of "Boutique Démo Dakar"
--   cashier@demo.jendpro.local  CASHIER of "Boutique Démo Dakar"
--   stock@demo.jendpro.local    STOCK_MANAGER of "Boutique Démo Dakar"
--
-- Demo data is created through the real RPCs (purchases, sales, credit), so a
-- successful `db reset` also exercises the main business flows end to end.
-- =============================================================================

-- Creates a confirmed e-mail/password user usable with supabase.auth.signInWithPassword.
create function pg_temp.seed_user(p_email text, p_full_name text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    p_email, extensions.crypt('jendpro-demo', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', p_full_name),
    now(), now(), '', '', '', ''
  );
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', p_email, 'email_verified', true),
          now(), now(), now());
  return v_id;
end;
$$;

-- Acts as a given user for the following RPC calls (same claims as PostgREST).
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  v_owner    uuid := pg_temp.seed_user('owner@demo.jendpro.local', 'Awa Ndiaye');
  v_cashier  uuid := pg_temp.seed_user('cashier@demo.jendpro.local', 'Moussa Fall');
  v_stock    uuid := pg_temp.seed_user('stock@demo.jendpro.local', 'Ibrahima Sarr');
  v_business uuid;
  v_location uuid;
  v_food     uuid;
  v_drinks   uuid;
  v_hygiene  uuid;
  v_supplier uuid;
  v_purchase uuid;
  v_fatou    uuid;
  v_mamadou  uuid;
begin
  -- Business, created through the real RPC as the owner.
  perform pg_temp.act_as(v_owner);
  v_business := public.create_business('Boutique Démo Dakar', '+221771234567', 'Dakar', 'Avenue Cheikh Anta Diop');
  select id into v_location from public.locations where business_id = v_business and is_default;
  update public.businesses set large_sale_threshold = 50000 where id = v_business;

  insert into public.business_members (business_id, user_id, role_id, status, joined_at)
  select v_business, u, r.id, 'ACTIVE', now()
    from (values (v_cashier, 'CASHIER'), (v_stock, 'STOCK_MANAGER')) m(u, code)
    join public.roles r on r.business_id is null and r.code = m.code;

  -- Catalog.
  insert into public.categories (business_id, name) values (v_business, 'Alimentation') returning id into v_food;
  insert into public.categories (business_id, name) values (v_business, 'Boissons') returning id into v_drinks;
  insert into public.categories (business_id, name) values (v_business, 'Hygiène') returning id into v_hygiene;

  insert into public.products (business_id, category_id, name, sku, barcode, unit, sale_price, allows_fractional_quantity, min_stock_level)
  values
    (v_business, v_food,    'Riz brisé',           'RIZ-KG',  null,            'kg',        500,  true,  20),
    (v_business, v_food,    'Sucre',               'SUC-KG',  null,            'kg',        700,  true,  10),
    (v_business, v_food,    'Huile Dinor 1L',      'HUI-1L',  '6044000000011', 'bouteille', 1500, false, 10),
    (v_business, v_food,    'Lait en poudre 400g', 'LAI-400', '6044000000028', 'boîte',     1800, false, 5),
    (v_business, v_drinks,  'Thé vert Ataya',      'THE-01',  '6044000000035', 'paquet',    250,  false, 20),
    (v_business, v_drinks,  'Bissap 1L',           'BIS-1L',  '6044000000042', 'bouteille', 1000, false, 6),
    (v_business, v_drinks,  'Eau minérale 1,5L',   'EAU-15',  '6044000000059', 'bouteille', 400,  false, 12),
    (v_business, v_hygiene, 'Savon de Marseille',  'SAV-01',  '6044000000066', 'pièce',     300,  false, 10);

  -- Supplier + received purchase (sets stock and weighted average costs).
  perform pg_temp.act_as(v_stock);
  insert into public.suppliers (business_id, name, contact_name, phone)
  values (v_business, 'Grossiste Sandaga', 'Cheikh Mbaye', '338210000') returning id into v_supplier;
  v_purchase := public.save_purchase(v_business, null, v_supplier, v_location,
    (select jsonb_agg(jsonb_build_object('product_id', id, 'quantity', q, 'unit_cost', c))
       from (values ('RIZ-KG', 100, 400), ('SUC-KG', 50, 550), ('HUI-1L', 40, 1150), ('LAI-400', 24, 1450),
                    ('THE-01', 60, 180), ('BIS-1L', 24, 650), ('EAU-15', 48, 280), ('SAV-01', 30, 200)) x(sku, q, c)
       join public.products pr on pr.business_id = v_business and pr.sku = x.sku),
    0, 'FAC-SANDAGA-001');
  perform public.receive_purchase(v_purchase);

  perform pg_temp.act_as(v_owner);
  perform public.record_purchase_payment(v_purchase, 100000, 'CASH', v_location);

  -- Customers, one with an opening debt from the paper notebook.
  insert into public.customers (business_id, name, phone) values (v_business, 'Fatou Sow', '771112233') returning id into v_fatou;
  insert into public.customers (business_id, name, phone) values (v_business, 'Mamadou Diallo', '762223344') returning id into v_mamadou;
  insert into public.customers (business_id, name) values (v_business, 'Aïssatou Ba');
  perform public.set_customer_credit_limit(v_fatou, 50000);
  perform public.adjust_customer_balance(v_fatou, 12000, 'Reprise du cahier de crédit');

  -- Sales by the cashier: cash, split cash + Wave, credit.
  perform pg_temp.act_as(v_cashier);
  perform public.create_sale(v_business, gen_random_uuid(), v_location,
    (select jsonb_agg(jsonb_build_object('product_id', id, 'quantity', q)) from (values ('RIZ-KG', 5), ('HUI-1L', 2)) x(sku, q)
       join public.products pr on pr.business_id = v_business and pr.sku = x.sku),
    '[{"method":"CASH","amount":5500}]');
  perform public.create_sale(v_business, gen_random_uuid(), v_location,
    (select jsonb_agg(jsonb_build_object('product_id', id, 'quantity', q)) from (values ('LAI-400', 2), ('THE-01', 4)) x(sku, q)
       join public.products pr on pr.business_id = v_business and pr.sku = x.sku),
    '[{"method":"CASH","amount":2000},{"method":"WAVE","amount":2600,"external_reference":"WAVE-DEMO-1"}]');
  perform public.create_sale(v_business, gen_random_uuid(), v_location,
    (select jsonb_agg(jsonb_build_object('product_id', id, 'quantity', q)) from (values ('SUC-KG', 2.5), ('SAV-01', 3)) x(sku, q)
       join public.products pr on pr.business_id = v_business and pr.sku = x.sku),
    '[{"method":"CASH","amount":1000}]', v_fatou);
  perform public.record_customer_payment(v_fatou, 5000, 'ORANGE_MONEY', v_location, 'OM-DEMO-1');

  -- Expenses.
  perform pg_temp.act_as(v_owner);
  insert into public.expenses (business_id, category_id, location_id, amount, description, method)
  select v_business, id, v_location, a, d, m::public.payment_method
    from (values ('Loyer', 150000, 'Loyer du mois', 'BANK_TRANSFER'), ('Électricité', 25000, 'Facture Senelec', 'WAVE')) x(cat, a, d, m)
    join public.expense_categories ec on ec.business_id = v_business and ec.name = x.cat;

  perform set_config('request.jwt.claims', '', true);
end;
$$;
