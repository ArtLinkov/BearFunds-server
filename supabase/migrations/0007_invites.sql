-- BearFunds server - family invites + join (S9a, forward-only, additive).
-- Implements [Q8] (brain Open Questions / UX Plan S9): a second user joins an
-- existing family via an invite link, creating a NEW member (role 'member') with a
-- name/avatar prefilled by the client Join Form.
--
-- CONTROL-PLANE, NOT THE SYNC CONTRACT. Invites are auth/family-management, not synced
-- domain data: they are reached through the RPCs below (supabase.rpc), NOT the single
-- POST action endpoint. So `invites` is never a synced/Dexie collection and the Schema
-- Contract (2_SCHEMA_CONTRACT.xml) is UNCHANGED - no version bump, no contract.ts edit.
--
-- handle_new_user is deliberately UNCHANGED: Google OAuth cannot carry an invite token
-- into raw_user_meta_data at first sign-in, so an invited user still transiently gets
-- their own throwaway family + admin member; join_family() re-homes them.
--
-- Tenancy invariants (0_AI_INSTRUCTIONS.md, brain QA Areas 008/019):
--   * create_invite / join_family / revoke_invite derive identity from auth.uid();
--     family_id is NEVER taken from the client. The new member's family_id is the
--     invite's family, set explicitly inside join_family (SECURITY DEFINER).
--   * RLS on invites scopes SELECT to the caller's own family (backstop). The joiner is
--     not yet a family member, so join_family is SECURITY DEFINER to validate the token
--     without RLS visibility.

-- ===========================================================================
-- 1. invites table.
-- token: opaque 32-char hex (a uuid with dashes stripped); core gen_random_uuid(),
--        no pgcrypto extension required.
-- ===========================================================================
create table if not exists public.invites (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  token        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  role         text not null default 'member' check (role in ('admin','member')),
  status       text not null default 'pending' check (status in ('pending','redeemed','revoked')),
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days',
  redeemed_by  uuid references auth.users(id) on delete set null,
  redeemed_at  timestamptz
);

create index if not exists invites_family_idx on public.invites (family_id);

-- ===========================================================================
-- 2. RLS: a caller may SELECT only their own family's invites (admin UI listing).
-- No direct INSERT/UPDATE/DELETE grant: only the SECURITY DEFINER RPCs write.
-- ===========================================================================
grant select on public.invites to authenticated;
alter table public.invites enable row level security;

create policy invites_family_select on public.invites
  for select to authenticated
  using (family_id = public.auth_family_id());

-- ===========================================================================
-- 3. create_invite(role) -> token. Admin-gated server-side (not via RLS).
-- ===========================================================================
create or replace function public.create_invite(p_role text default 'member')
  returns text
  language plpgsql
  security definer
  set search_path = public, auth
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_family uuid;
  v_role   text;
  v_token  text;
begin
  if v_uid is null then
    raise exception 'authentication required';
  end if;
  if p_role not in ('admin','member') then
    raise exception 'invalid invite role: %', p_role;
  end if;

  select family_id, role into v_family, v_role
  from public.members
  where user_id = v_uid
  limit 1;

  if v_family is null then
    raise exception 'caller has no family';
  end if;
  if v_role <> 'admin' then
    raise exception 'admin role required to create invites';
  end if;

  insert into public.invites (family_id, role, created_by)
  values (v_family, p_role, v_uid)
  returning token into v_token;

  return v_token;
end;
$fn$;

-- ===========================================================================
-- 4. join_family(token, name, avatar) -> target family_id.
-- Re-homes the caller from their throwaway solo family into the invite's family:
-- frees the unique user_id, deletes the solo throwaway family (guarded), inserts a
-- fresh member (role from the invite), marks the invite redeemed. Idempotent.
-- ===========================================================================
create or replace function public.join_family(
    p_token  text,
    p_name   text default null,
    p_avatar text default null)
  returns uuid
  language plpgsql
  security definer
  set search_path = public, auth
as $fn$
declare
  v_uid           uuid := auth.uid();
  v_inv           public.invites%rowtype;
  v_target        uuid;
  v_caller_family uuid;
  v_caller_count  int;
begin
  if v_uid is null then
    raise exception 'authentication required';
  end if;

  -- Lock the invite row so a concurrent redeem cannot double-spend it.
  select * into v_inv
  from public.invites
  where token = p_token
  for update;

  if not found or v_inv.status <> 'pending' or v_inv.expires_at <= now() then
    raise exception 'invalid or expired invite';
  end if;
  v_target := v_inv.family_id;

  -- Idempotent: already a member of the target family -> redeem (if still pending) + return.
  if exists (
    select 1 from public.members
    where user_id = v_uid and family_id = v_target and deleted = false
  ) then
    update public.invites
      set status = 'redeemed', redeemed_by = v_uid, redeemed_at = now()
      where id = v_inv.id and status = 'pending';
    return v_target;
  end if;

  -- The caller's current (throwaway) family, and whether they are its sole member.
  select family_id into v_caller_family
  from public.members
  where user_id = v_uid
  limit 1;

  select count(*) into v_caller_count
  from public.members
  where family_id = v_caller_family;

  -- Free the unique user_id (members.user_id is UNIQUE) before the new insert.
  -- This also drops auth_family_id() to NULL, so set_family_id() keeps the explicit
  -- target family_id on the insert below (same bootstrap path handle_new_user uses).
  delete from public.members where user_id = v_uid;

  -- Teardown the throwaway family ONLY if the caller was its sole member (data-loss
  -- guard: never delete a populated/shared family). Cascades any seeded rows.
  if v_caller_family is not null
     and v_caller_family <> v_target
     and v_caller_count = 1 then
    delete from public.families where id = v_caller_family;
  end if;

  -- Create the fresh member in the invite's family. Columns mirror handle_new_user
  -- (members.is_me was dropped in 0004; Me is derived from user_id).
  insert into public.members (id, family_id, user_id, name, role, avatar)
  values (
    'm_' || replace(v_uid::text, '-', ''),
    v_target,
    v_uid,
    coalesce(nullif(p_name, ''), 'Member'),
    v_inv.role,
    nullif(p_avatar, '')
  );

  update public.invites
    set status = 'redeemed', redeemed_by = v_uid, redeemed_at = now()
    where id = v_inv.id;

  return v_target;
end;
$fn$;

-- ===========================================================================
-- 5. revoke_invite(token) -> boolean. Admin-gated; only a pending invite of the
-- caller's own family can be revoked.
-- ===========================================================================
create or replace function public.revoke_invite(p_token text)
  returns boolean
  language plpgsql
  security definer
  set search_path = public, auth
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_family uuid;
  v_role   text;
  v_rows   int;
begin
  if v_uid is null then
    raise exception 'authentication required';
  end if;

  select family_id, role into v_family, v_role
  from public.members
  where user_id = v_uid
  limit 1;

  if v_family is null then
    raise exception 'caller has no family';
  end if;
  if v_role <> 'admin' then
    raise exception 'admin role required to revoke invites';
  end if;

  update public.invites
    set status = 'revoked'
    where token = p_token and family_id = v_family and status = 'pending';
  get diagnostics v_rows = row_count;

  return v_rows > 0;
end;
$fn$;

grant execute on function public.create_invite(text) to authenticated;
grant execute on function public.join_family(text, text, text) to authenticated;
grant execute on function public.revoke_invite(text) to authenticated;
