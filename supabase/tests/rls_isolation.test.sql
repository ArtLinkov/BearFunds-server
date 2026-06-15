-- RLS isolation suite — proves per-family tenancy (brain QA Area 008 Identity / 019 Isolation).
-- Run order: auth_shim.sql -> migrations 0001-0005 -> THIS. Wrapped in a rolled-back tx.
-- Asserts via DO/ASSERT; psql with ON_ERROR_STOP exits nonzero on the first failure.
\set ON_ERROR_STOP on
begin;

-- Two Google sign-ins (fixed ids so we can forge claims). Each fires handle_new_user.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'alice@fam.test', '{"full_name":"Alice"}'),
  ('00000000-0000-0000-0000-00000000000b', 'bob@fam.test',   '{"full_name":"Bob"}');

-- Bootstrap: each user got a family + one admin member.
-- Bootstrap asserts are scoped to the suite's two fixed uids (not whole-table
-- counts) so the suite is order-independent: a prior sign-up on the local stack
-- (e.g. a dev-shim user from a ghost run) no longer trips it (brain Hygiene 2026-06-05).
do $$ begin
  assert (select count(*) from public.members where user_id in
            ('00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-00000000000b')) = 2,
         'expected the 2 suite linking members';
  assert (select count(*) from public.members where role = 'admin' and user_id in
            ('00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-00000000000b')) = 2,
         'expected 2 admin linking members for the suite uids';
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

-- ============ subcategories: per-family isolation (v1.9 new tenant table) ============
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
-- Alice creates a subcategory with family_id omitted -> server-derived to Alice.
insert into public.subcategories (id, category_id, name) values ('sc_a1', 'c1', 'Groceries');
do $$ begin
  assert (select family_id from public.subcategories where id = 'sc_a1') = (select family_id from fam where who = 'A'),
         'new subcategory must be scoped to Alice family';
  assert (select count(*) from public.subcategories) = 1, 'Alice sees exactly her subcategory';
end $$;
reset role; reset request.jwt.claims;

set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
do $$ begin
  assert (select count(*) from public.subcategories) = 0, 'Bob must not see Alice subcategory (read isolation)';
end $$;
update public.subcategories set name = 'HACKED' where id = 'sc_a1';
do $$ begin
  assert not exists (select 1 from public.subcategories where id = 'sc_a1'), 'Alice subcategory stays invisible to Bob';
end $$;
insert into public.subcategories (id, category_id, name, family_id)
  values ('sc_b_forge', 'c1', 'forged', (select family_id from fam where who = 'A'));
do $$ begin
  assert (select family_id from public.subcategories where id = 'sc_b_forge') = (select family_id from fam where who = 'B'),
         'forged family_id must be overwritten to Bob family';
end $$;
reset role; reset request.jwt.claims;

do $$ begin
  assert (select name from public.subcategories where id = 'sc_a1') = 'Groceries', 'Alice subcategory must be unchanged by Bob';
end $$;

-- ============ staged_transactions: per-family isolation + raw-text amount (v1.10) ============
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
-- Alice stages a partially-mapped import row: family_id omitted -> server-derived; amount
-- is RAW, unparsed text; FKs left null. Proves a not-yet-valid row can persist while staged.
insert into public.staged_transactions (id, batch_id, amount, source_name, source_row)
  values ('st_a1', 'batch_a', '-1.234,56', 'ACME / GMBH', '{"Memo":"ACME / GMBH","Value":"-1.234,56"}');
do $$ begin
  assert (select family_id from public.staged_transactions where id = 'st_a1') = (select family_id from fam where who = 'A'),
         'new staged row must be scoped to Alice family';
  assert (select count(*) from public.staged_transactions) = 1, 'Alice sees exactly her staged row';
  assert (select amount from public.staged_transactions where id = 'st_a1') = '-1.234,56',
         'raw unparsed amount text must persist verbatim (not coerced to numeric)';
  assert (select category_id from public.staged_transactions where id = 'st_a1') is null,
         'an unmapped FK may stay null while staged';
end $$;
reset role; reset request.jwt.claims;

set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
do $$ begin
  assert (select count(*) from public.staged_transactions) = 0, 'Bob must not see Alice staged row (read isolation)';
end $$;
update public.staged_transactions set source_name = 'HACKED' where id = 'st_a1';
do $$ begin
  assert not exists (select 1 from public.staged_transactions where id = 'st_a1'), 'Alice staged row stays invisible to Bob';
end $$;
insert into public.staged_transactions (id, batch_id, amount, family_id)
  values ('st_b_forge', 'batch_b', '9', (select family_id from fam where who = 'A'));
do $$ begin
  assert (select family_id from public.staged_transactions where id = 'st_b_forge') = (select family_id from fam where who = 'B'),
         'forged family_id must be overwritten to Bob family';
end $$;
reset role; reset request.jwt.claims;

do $$ begin
  assert (select source_name from public.staged_transactions where id = 'st_a1') = 'ACME / GMBH', 'Alice staged row must be unchanged by Bob';
end $$;

-- ============ invites + join_family: control-plane RPCs (S9a / [Q8]) ============
-- Two more sign-ins: Carol (joins via invite) and Dave (exercises the teardown guard).
-- Each fires handle_new_user -> their own throwaway family + admin member.
reset role; reset request.jwt.claims;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000c', 'carol@fam.test', '{"full_name":"Carol"}'),
  ('00000000-0000-0000-0000-00000000000d', 'dave@fam.test',  '{"full_name":"Dave"}');

-- Snapshot Carol's + Dave's original throwaway family ids (superuser temp tables).
create temporary table cfam as
  select family_id from public.members where user_id = '00000000-0000-0000-0000-00000000000c';
create temporary table dfam as
  select family_id from public.members where user_id = '00000000-0000-0000-0000-00000000000d';

-- Make Dave's family NON-solo: a second (placeholder) member. The teardown guard must
-- therefore NOT delete Dave's family when he joins elsewhere.
insert into public.members (id, family_id, user_id, name, role)
  values ('m_extra_d', (select family_id from dfam), null, 'Extra D', 'member');

-- Token relay table (create_invite returns the token; stash it across role switches).
create temporary table inv (slot text primary key, token text);
grant select, insert on inv to authenticated;

-- ---- Alice (admin of A) mints invites ----
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
insert into inv values ('i1',   public.create_invite('member'));
insert into inv values ('i2',   public.create_invite('member'));
insert into inv values ('i3',   public.create_invite('member'));
insert into inv values ('iexp', public.create_invite('member'));
-- Alice sees only her own family's invites (RLS select scope).
do $t$ begin
  assert (select count(*) from public.invites) = 4, 'Alice sees her 4 invites';
end $t$;
reset role; reset request.jwt.claims;

-- Expire one invite (superuser) to test the expiry rejection.
update public.invites set expires_at = now() - interval '1 day'
  where token = (select token from inv where slot = 'iexp');

-- ---- RLS isolation: Bob (family B) cannot see family A's invites ----
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
do $t$ begin
  assert (select count(*) from public.invites) = 0, 'Bob must not see family A invites (read isolation)';
end $t$;
-- Invalid token is rejected.
do $t$ begin
  begin
    perform public.join_family('not-a-real-token-0000000000000000');
    raise exception 'EXPECTED join_family to reject an invalid token';
  exception when others then
    if sqlerrm like 'EXPECTED %' then raise; end if;
  end;
end $t$;
-- Expired (still-pending) token is rejected.
do $t$ begin
  begin
    perform public.join_family((select token from inv where slot = 'iexp'));
    raise exception 'EXPECTED join_family to reject an expired invite';
  exception when others then
    if sqlerrm like 'EXPECTED %' then raise; end if;
  end;
end $t$;
reset role; reset request.jwt.claims;

-- ---- Carol joins family A via i1 (happy path: re-home + fresh member) ----
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000c"}';
select public.join_family((select token from inv where slot = 'i1'), 'Carol Joiner', 'http://avatars.test/c.png');
do $t$ begin
  assert public.auth_family_id() = (select family_id from fam where who = 'A'),
         'Carol auth_family_id() now resolves to family A';
  assert (select role from public.members where user_id = '00000000-0000-0000-0000-00000000000c') = 'member',
         'Carol joined as role member (not admin)';
  assert (select name from public.members where user_id = '00000000-0000-0000-0000-00000000000c') = 'Carol Joiner',
         'Carol member carries the Join-Form name';
end $t$;
reset role; reset request.jwt.claims;
-- Superuser: Carol's throwaway family is gone; A now has exactly Alice + Carol.
do $t$ begin
  assert not exists (select 1 from public.families where id = (select family_id from cfam)),
         'Carol throwaway family was torn down (sole-member)';
  assert (select count(*) from public.members where family_id = (select family_id from fam where who = 'A')) = 2,
         'family A now has Alice + Carol';
end $t$;

-- ---- Idempotent re-join: Carol redeems i2 while already in A -> no-op, no dup member ----
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000c"}';
select public.join_family((select token from inv where slot = 'i2'), 'Carol Again', null);
reset role; reset request.jwt.claims;
do $t$ begin
  assert (select count(*) from public.members where family_id = (select family_id from fam where who = 'A')) = 2,
         'idempotent re-join created no duplicate member';
  assert (select status from public.invites where token = (select token from inv where slot = 'i2')) = 'redeemed',
         'i2 marked redeemed on idempotent join';
end $t$;

-- ---- Admin-gate: Carol (now a plain member of A) cannot mint invites ----
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000c"}';
do $t$ begin
  begin
    perform public.create_invite('member');
    raise exception 'EXPECTED create_invite to reject a non-admin member';
  exception when others then
    if sqlerrm like 'EXPECTED %' then raise; end if;
  end;
end $t$;
reset role; reset request.jwt.claims;

-- ---- Teardown guard: Dave (family D has 2 members) joins A; D must survive ----
set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000d"}';
select public.join_family((select token from inv where slot = 'i3'), 'Dave Joiner', null);
do $t$ begin
  assert public.auth_family_id() = (select family_id from fam where who = 'A'), 'Dave now in family A';
end $t$;
reset role; reset request.jwt.claims;
do $t$ begin
  assert exists (select 1 from public.families where id = (select family_id from dfam)),
         'Dave family D was NOT deleted (non-solo; teardown guard held)';
  assert (select count(*) from public.members where family_id = (select family_id from dfam)) = 1,
         'family D keeps its other member; only Dave row was removed';
  assert (select count(*) from public.members where family_id = (select family_id from fam where who = 'A')) = 3,
         'family A now has Alice + Carol + Dave';
end $t$;

-- ---- Final invite-state + invariant checks ----
do $t$ begin
  assert (select status from public.invites where token = (select token from inv where slot = 'i1')) = 'redeemed', 'i1 redeemed';
  assert (select status from public.invites where token = (select token from inv where slot = 'i3')) = 'redeemed', 'i3 redeemed';
  assert (select status from public.invites where token = (select token from inv where slot = 'iexp')) = 'pending',
         'expired invite was never redeemed (stays pending)';
  assert (select role from public.members where user_id = '00000000-0000-0000-0000-00000000000a') = 'admin',
         'Alice remains admin of family A';
end $t$;

rollback;
\echo '================================'
\echo 'RLS ISOLATION TESTS: ALL PASSED'
\echo '================================'
