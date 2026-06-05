-- RLS isolation suite — proves per-family tenancy (brain QA Area 008 Identity / 019 Isolation).
-- Run order: auth_shim.sql -> migrations 0001,0002 -> THIS. Wrapped in a rolled-back tx.
-- Asserts via DO/ASSERT; psql with ON_ERROR_STOP exits nonzero on the first failure.
\set ON_ERROR_STOP on
begin;

-- Two Google sign-ins (fixed ids so we can forge claims). Each fires handle_new_user.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'alice@fam.test', '{"full_name":"Alice"}'),
  ('00000000-0000-0000-0000-00000000000b', 'bob@fam.test',   '{"full_name":"Bob"}');

-- Bootstrap: each user got a family + one admin member.
do $$ begin
  assert (select count(*) from public.families) = 2, 'expected 2 families from signup';
  assert (select count(*) from public.members where role = 'admin' and user_id is not null) = 2, 'expected 2 admin linking members';
  assert (select role from public.members where user_id = '00000000-0000-0000-0000-00000000000a') = 'admin', 'Alice should be admin';
end $$;

-- Capture family ids for assertions; expose to the authenticated role.
create temporary table fam as
  select 'A'::text as who, family_id from public.members where user_id = '00000000-0000-0000-0000-00000000000a'
  union all
  select 'B'::text,        family_id from public.members where user_id = '00000000-0000-0000-0000-00000000000b';
grant select on fam to authenticated;

-- ============ Act as Alice ============
set role authenticated;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';

do $$ begin
  assert (select count(*) from public.families) = 1, 'Alice must see only her own family';
end $$;

-- Create a wallet with family_id omitted -> server-derived to Alice.
insert into public.wallets (id, name, currency) values ('w_a1', 'Alice EUR', 'EUR');
do $$ begin
  assert (select family_id from public.wallets where id = 'w_a1') = (select family_id from fam where who = 'A'),
         'new wallet must be scoped to Alice family';
  assert (select count(*) from public.wallets) = 1, 'Alice sees exactly her wallet';
end $$;

reset role; reset request.jwt.claims;

-- ============ Act as Bob ============
set role authenticated;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';

-- READ isolation: Bob cannot see Alice's wallet.
do $$ begin
  assert (select count(*) from public.wallets) = 0, 'Bob must not see Alice wallet (read isolation)';
end $$;

-- WRITE isolation: Bob's update of Alice's row hits nothing (row invisible).
update public.wallets set name = 'HACKED' where id = 'w_a1';
do $$ begin
  assert not exists (select 1 from public.wallets where id = 'w_a1'), 'Alice wallet stays invisible to Bob';
end $$;

-- FORGERY: Bob inserts with Alice family_id in the body -> trigger forces it to Bob.
insert into public.wallets (id, name, currency, family_id)
  values ('w_b_forge', 'forged', 'USD', (select family_id from fam where who = 'A'));
do $$ begin
  assert (select family_id from public.wallets where id = 'w_b_forge') = (select family_id from fam where who = 'B'),
         'forged family_id must be overwritten to Bob family';
end $$;

reset role; reset request.jwt.claims;

-- ============ Superuser: confirm Alice survived Bob entirely ============
do $$ begin
  assert (select name from public.wallets where id = 'w_a1') = 'Alice EUR', 'Alice wallet must be unchanged';
  assert (select count(*) from public.wallets where family_id = (select family_id from fam where who = 'A')) = 1,
         'Alice family still has exactly one wallet';
  assert (select count(*) from public.wallets where family_id = (select family_id from fam where who = 'B')) = 1,
         'Bob family has only the forged-then-corrected wallet';
end $$;

-- ============ updated_at is server-managed ============
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
insert into public.wallets (id, name, currency, updated_at) values ('w_a2', 't', 'EUR', '2000-01-01T00:00:00Z');
do $$ begin
  assert (select updated_at from public.wallets where id = 'w_a2') > now() - interval '1 minute',
         'updated_at must be overwritten to server now()';
end $$;

-- ============ family_id is immutable on update ============
update public.wallets set family_id = (select family_id from fam where who = 'B') where id = 'w_a2';
do $$ begin
  assert (select family_id from public.wallets where id = 'w_a2') = (select family_id from fam where who = 'A'),
         'family_id must not move families on update';
end $$;
reset role; reset request.jwt.claims;

rollback;
\echo '================================'
\echo 'RLS ISOLATION TESTS: ALL PASSED'
\echo '================================'
