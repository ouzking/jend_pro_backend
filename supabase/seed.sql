-- =============================================================================
-- Local development seed — applied by `supabase db reset` ONLY.
-- Never run against staging/production. Reference data required in every
-- environment (permissions, system roles, subscription plans) belongs in
-- migrations, not here.
--
-- Demo accounts (password for all: jendpro-demo):
--   owner@demo.jendpro.local    OWNER of "Boutique Démo Dakar"
--   cashier@demo.jendpro.local  CASHIER of "Boutique Démo Dakar"
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

do $$
declare
  v_owner    uuid := pg_temp.seed_user('owner@demo.jendpro.local', 'Awa Ndiaye');
  v_cashier  uuid := pg_temp.seed_user('cashier@demo.jendpro.local', 'Moussa Fall');
  v_business uuid;
begin
  -- Create the business through the real RPC, as the owner.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_business := public.create_business('Boutique Démo Dakar', '+221771234567', 'Dakar', 'Avenue Cheikh Anta Diop');
  perform set_config('request.jwt.claims', '', true);

  insert into public.business_members (business_id, user_id, role_id, status, joined_at)
  values (v_business, v_cashier, (select id from public.roles where business_id is null and code = 'CASHIER'),
          'ACTIVE', now());
end;
$$;
