-- 0011: per-user TEST family isolation.
--
-- Problem: test mode (mock seed + the ghost suite) used the SAME family_id as the caller's
-- real data, because tenancy is derived from the session and `isTest` only gated `wipe`. On
-- the shared prod+QA database that commingled mock data with real data.
--
-- Fix: when a request carries the server-set header `x-bf-test: 1` (the Edge Function adds it
-- ONLY when the validated body flag isTest=true; PostgREST exposes it via request.headers),
-- tenancy resolves to a dedicated, per-user TEST family instead of the real family. RLS is
-- unchanged in structure -- only what auth_family_id() resolves to changes, and ONLY when the
-- header is present. With no header (every prod request -- prod never sends isTest),
-- auth_family_id() is byte-identical to migration 0001. Forward-only; no destructive change.

-- ---------------------------------------------------------------------------
-- 1. Per-user mapping: user -> their TEST family. Deliberately NOT a membership, so the test
--    family carries no user-linked member row (its member list is purely the seeded mocks).
-- ---------------------------------------------------------------------------
create table if not exists public.user_test_family (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  family_id  uuid not null references public.families(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.user_test_family enable row level security;

-- Self-only read; writes are exclusively via ensure_test_family() (SECURITY DEFINER).
create policy user_test_family_self_select on public.user_test_family
  for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 2. is_test_request(): true iff the request carries `x-bf-test: 1`. plpgsql with an
--    exception guard so a missing/empty/malformed request.headers GUC can never raise -- it
--    simply reads as "not a test request" (fail-safe toward real-family behaviour).
-- ---------------------------------------------------------------------------
create or replace function public.is_test_request()
  returns boolean
  language plpgsql
  stable
  set search_path = public
as $$
declare
  h text := current_setting('request.headers', true);
begin
  if h is null or h = '' then
    return false;
  end if;
  return (h::jsonb ->> 'x-bf-test') = '1';
exception when others then
  return false;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. ensure_test_family(): idempotently provision the caller's test family + mapping.
--    SECURITY DEFINER so it can write the tenancy root before any test-family RLS context
--    exists. The Edge Function calls this on every isTest request (cheap when already set).
-- ---------------------------------------------------------------------------
create or replace function public.ensure_test_family()
  returns uuid
  language plpgsql
  security definer
  set search_path = public, auth
as $$
declare
  tf_id uuid;
  uid   uuid := auth.uid();
begin
  if uid is null then
    raise exception 'ensure_test_family requires an authenticated user';
  end if;

  select family_id into tf_id from public.user_test_family where user_id = uid;
  if tf_id is not null then
    return tf_id;
  end if;

  insert into public.families (name) values ('QA Test Family') returning id into tf_id;
  insert into public.user_test_family (user_id, family_id)
    values (uid, tf_id)
    on conflict (user_id) do nothing;

  -- Re-read in case a concurrent first-test request won the race (its family stands; the
  -- one we just created above is harmlessly orphaned -- acceptable for a test-only root).
  select family_id into tf_id from public.user_test_family where user_id = uid;
  return tf_id;
end;
$$;

revoke all on function public.ensure_test_family() from public;
grant execute on function public.ensure_test_family() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Test-aware tenancy resolution. The else-branch is the verbatim migration-0001 query, so
--    the non-test path (no header) is provably unchanged. CASE short-circuits: the test-family
--    subquery only runs when is_test_request() is true.
-- ---------------------------------------------------------------------------
create or replace function public.auth_family_id()
  returns uuid
  language sql
  stable
  security definer
  set search_path = public, auth
as $$
  select case
    when public.is_test_request()
      then (select family_id from public.user_test_family where user_id = auth.uid())
    else (select m.family_id from public.members m where m.user_id = auth.uid() limit 1)
  end
$$;
