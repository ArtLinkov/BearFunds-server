-- BearFunds server - composite (family_id, id) primary key ([Q20], forward-only).
-- Every family seeds IDENTICAL fixed ids (categories c001.., entities e001.., wallets,
-- deterministic sub ids), but the tenant tables used a GLOBAL `id` primary key - so the
-- 2nd family to sync its seed collided on the PK, the upsert took ON CONFLICT DO UPDATE,
-- and RLS denied updating another family's row (500). Re-key each tenant table on
-- (family_id, id): `id` stays unique WITHIN a family, and families can share fixed ids.
-- family_id is server-derived (set_family_id BEFORE-INSERT trigger) before the conflict
-- check, so an upsert lands in the caller's family and never touches another's.
--
-- families keeps its global uuid PK. members.user_id keeps its global UNIQUE (one member
-- per user). RLS policies, triggers, and the (family_id, updated_at) indexes are unchanged.
-- No tenant table references another tenant table's id via a FK, so no FK churn. Forward-
-- only; no prod data exists and local DBs are reset for tests.

do $$
declare t text;
begin
  foreach t in array array['transactions','categories','subcategories','wallets','entities','members','staged_transactions']
  loop
    execute format('alter table public.%I drop constraint %I_pkey, add primary key (family_id, id);', t, t);
  end loop;
end $$;
