-- Test-family isolation suite -- proves the 0011 per-user TEST family routing.
-- Run order: auth_shim.sql -> migrations 0001-0011 -> THIS. Wrapped in a rolled-back tx.
-- The Edge Function sets the `x-bf-test` request header only when the validated body flag
-- isTest=true; here we simulate it with `set request.headers`. ON_ERROR_STOP exits nonzero
-- on the first failed assertion.
\set ON_ERROR_STOP on
begin;

-- Two Google sign-ins (fixed ids). Each fires handle_new_user -> a real family + admin member.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'alice.tf@fam.test', '{"full_name":"Alice"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'bob.tf@fam.test',   '{"full_name":"Bob"}');

-- Snapshot the REAL family ids (superuser temp table; visible to authenticated for asserts).
create temporary table rfam as
  select 'A'::text as who, family_id from public.members where user_id = '00000000-0000-0000-0000-0000000000a1'
  union all
  select 'B'::text,        family_id from public.members where user_id = '00000000-0000-0000-0000-0000000000b1';
grant select on rfam to authenticated;

-- ============ Alice: provision + write in TEST context ============
set role authenticated;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1"}';

-- Provision the test family (idempotent). Distinct from the real family.
do $$ declare tf uuid; begin
  tf := public.ensure_test_family();
  assert tf is not null, 'Alice test family provisioned';
  assert tf <> (select family_id from rfam where who = 'A'), 'test family is distinct from the real family';
  assert (select family_id from public.user_test_family where user_id = '00000000-0000-0000-0000-0000000000a1') = tf,
         'mapping row points at the test family';
end $$;

-- With the test header present, tenancy resolves to the test family.
set request.headers = '{"x-bf-test":"1"}';
do $$ begin
  assert public.is_test_request(), 'header => is_test_request() true';
  assert public.auth_family_id() = (select family_id from public.user_test_family where user_id = '00000000-0000-0000-0000-0000000000a1'),
         'header routes auth_family_id() to Alice test family';
end $$;

insert into public.wallets (id, name, currency) values ('w_tf_test', 'Alice Test', 'EUR');
do $$ begin
  assert (select family_id from public.wallets where id = 'w_tf_test')
           = (select family_id from public.user_test_family where user_id = '00000000-0000-0000-0000-0000000000a1'),
         'test-context write is scoped to the test family';
  assert (select count(*) from public.wallets) = 1, 'in test context Alice sees only the test wallet';
end $$;

-- ============ Invariant: drop the header => REAL family, byte-identical behaviour ============
set request.headers = '';
do $$ begin
  assert not public.is_test_request(), 'no header => is_test_request() false';
  assert public.auth_family_id() = (select family_id from rfam where who = 'A'),
         'no header => auth_family_id() is the real family (invariant)';
  assert (select count(*) from public.wallets) = 0, 'real family does not contain the test wallet';
end $$;

insert into public.wallets (id, name, currency) values ('w_tf_real', 'Alice Real', 'EUR');
do $$ begin
  assert (select family_id from public.wallets where id = 'w_tf_real') = (select family_id from rfam where who = 'A'),
         'real-context write goes to the real family';
end $$;

-- Back to test context: the real wallet is invisible, the test wallet is visible.
set request.headers = '{"x-bf-test":"1"}';
do $$ begin
  assert (select count(*) from public.wallets) = 1, 'test context sees exactly the test wallet';
  assert exists (select 1 from public.wallets where id = 'w_tf_test'), 'test wallet visible in test context';
  assert not exists (select 1 from public.wallets where id = 'w_tf_real'), 'real wallet invisible in test context';
end $$;
set request.headers = ''; reset role; reset request.jwt.claims;

-- Snapshot Alice's test family id as superuser: user_test_family RLS (self-only) hides it from
-- Bob, so the cross-tenant assert below must compare against this captured value, not a
-- Bob-session subquery (which would correctly return NULL).
create temporary table atf as
  select family_id from public.user_test_family where user_id = '00000000-0000-0000-0000-0000000000a1';
grant select on atf to authenticated;

-- ============ Bob: cross-tenant test isolation ============
set role authenticated;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1"}';
do $$ declare tf uuid; begin tf := public.ensure_test_family(); assert tf is not null, 'Bob test family provisioned'; end $$;
set request.headers = '{"x-bf-test":"1"}';
do $$ begin
  assert public.auth_family_id() = (select family_id from public.user_test_family where user_id = '00000000-0000-0000-0000-0000000000b1'),
         'Bob is routed to his OWN test family';
  assert public.auth_family_id() <> (select family_id from atf),
         'Bob test family != Alice test family';
  assert (select count(*) from public.wallets) = 0, 'Bob test family cannot see Alice test wallet (cross-tenant isolation)';
end $$;
set request.headers = ''; reset role; reset request.jwt.claims;

-- ============ ensure_test_family idempotent ============
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1"}';
do $$ declare tf1 uuid; tf2 uuid; begin
  tf1 := public.ensure_test_family();
  tf2 := public.ensure_test_family();
  assert tf1 = tf2, 'ensure_test_family is idempotent (same id)';
  assert (select count(*) from public.user_test_family where user_id = '00000000-0000-0000-0000-0000000000a1') = 1,
         'no duplicate mapping row';
end $$;
reset role; reset request.jwt.claims;

-- ============ wipe under the header clears only the test family ============
-- Mimics the executor's RLS-scoped delete (the real `wipe` runs the same delete under RLS).
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1"}';
set request.headers = '{"x-bf-test":"1"}';
delete from public.wallets where id <> '__never_matches__';
do $$ begin
  assert not exists (select 1 from public.wallets where id = 'w_tf_test'), 'test-context wipe cleared the test wallet';
end $$;
set request.headers = '';
do $$ begin
  assert exists (select 1 from public.wallets where id = 'w_tf_real'), 'the real wallet survived the test-context wipe';
end $$;
reset role; reset request.jwt.claims;

rollback;
\echo '===================================='
\echo 'TEST FAMILY ISOLATION TESTS: ALL PASSED'
\echo '===================================='
