-- Profiles: creation on signup, self-only access, write restrictions.
begin;
select plan(11);

select tests.create_user('alice@test.local', 'Alice Diop');
select tests.create_user('bob@test.local');

-- -----------------------------------------------------------------------------
-- Signup trigger
-- -----------------------------------------------------------------------------
select is((select full_name from public.profiles where id = tests.get_user_id('alice@test.local')),
  'Alice Diop', 'profile is created on signup with full_name from metadata');
select is((select locale from public.profiles where id = tests.get_user_id('bob@test.local')),
  'fr', 'default locale is fr');

insert into auth.users (id, instance_id, aud, role, email, phone, encrypted_password, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'weird@test.local', 'not-a-phone', '', now(), now());
select is((select p.phone from public.profiles p where p.id = tests.get_user_id('weird@test.local')),
  null, 'invalid auth phone does not block signup (dropped from profile)');

-- -----------------------------------------------------------------------------
-- Access as alice
-- -----------------------------------------------------------------------------
select tests.login('alice@test.local');

select is((select count(*)::int from public.profiles), 1, 'a user sees exactly one profile');
select is((select id from public.profiles), tests.get_user_id('alice@test.local'),
  'that profile is their own');

select lives_ok($$ update public.profiles set full_name = 'Alice D.' where id = auth.uid() $$,
  'a user can update their own profile');

update public.profiles set full_name = 'hacked' where id = tests.get_user_id('bob@test.local');

select throws_ok($$ update public.profiles set id = gen_random_uuid() $$, '42501', null,
  'a user cannot update a non-granted column (id)');
select throws_ok($$ insert into public.profiles (id) values (gen_random_uuid()) $$, '42501', null,
  'a user cannot insert profiles');
select throws_ok($$ delete from public.profiles $$, '42501', null,
  'a user cannot delete profiles');

select tests.clear_authentication();
select is((select full_name from public.profiles where id = tests.get_user_id('bob@test.local')),
  'bob', 'updating another user''s profile has no effect');

-- -----------------------------------------------------------------------------
-- anon
-- -----------------------------------------------------------------------------
select tests.authenticate_as_anon();
select throws_ok($$ select * from public.profiles $$, '42501', null, 'anon cannot read profiles');
select tests.clear_authentication();

select * from finish();
rollback;
