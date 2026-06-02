-- BearFunds server — initial schema (forward-only).
-- Honors Schema Contract v1.6.0: tenancy root `families` + one table per client
-- collection mapping the Syncable model 1:1, server-managed updated_at, soft-delete,
-- is_immutable, and a server-derived family_id on every tenant table.
--
-- Tenancy invariants (see 0_AI_INSTRUCTIONS.md, brain QA Areas 008/019):
--   * family_id is NEVER trusted from the client — a BEFORE trigger force-sets it from
--     the session (auth_family_id()), and RLS (migration 0002) is the backstop.
--   * updated_at is server-managed via a BEFORE trigger (overwrites any client value).
-- Note: gen_random_uuid() is core in PG13+ (Supabase PG15+); no extension required.

-- ===========================================================================
-- 1. Tables (created first so SQL functions below can resolve them).
-- ===========================================================================

-- Tenancy root.
create table if not exists public.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default 'My Family',
  created_at  timestamptz not null default now()
);

-- Tenant tables. Global columns: id, family_id, updated_at, deleted, is_immutable.
-- id is TEXT (UUIDs, 'c001'/'w001'/... formatted ids, and immutable/test specials).
create table if not exists public.transactions (
  id            text primary key,
  family_id     uuid not null references public.families(id) on delete cascade,
  date          text,
  amount        numeric,
  currency      text,
  type          text,
  category_id   text,
  sub_category  text,
  entity_id     text,
  wallet_id     text,
  member_id     text,
  description   text,
  tags          text,
  status        text,
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false,
  is_immutable  boolean not null default false
);

create table if not exists public.categories (
  id              text primary key,
  family_id       uuid not null references public.families(id) on delete cascade,
  name            text,
  type            text,
  sub_categories  text,
  icon            text,
  color           text,
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false,
  is_immutable    boolean not null default false
);

create table if not exists public.wallets (
  id            text primary key,
  family_id     uuid not null references public.families(id) on delete cascade,
  name          text,
  currency      text,
  icon          text,
  color         text,
  description   text,
  is_default    boolean not null default false,
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false,
  is_immutable  boolean not null default false
);

create table if not exists public.entities (
  id                    text primary key,
  family_id             uuid not null references public.families(id) on delete cascade,
  name                  text,
  aliases               text,
  match_patterns        text,
  default_category_id   text,
  default_sub_category  text,
  icon                  text,
  color                 text,
  updated_at            timestamptz not null default now(),
  deleted               boolean not null default false,
  is_immutable          boolean not null default false
);

create table if not exists public.members (
  id            text primary key,
  family_id     uuid not null references public.families(id) on delete cascade,
  user_id       uuid unique references auth.users(id) on delete set null,
  name          text,
  role          text not null default 'member' check (role in ('admin','member')),
  is_me         boolean not null default false,
  avatar        text,
  color         text,
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false,
  is_immutable  boolean not null default false
);

-- Delta-sync read path hits (family_id, updated_at) on every table.
create index if not exists transactions_family_updated_idx on public.transactions (family_id, updated_at);
create index if not exists categories_family_updated_idx   on public.categories   (family_id, updated_at);
create index if not exists wallets_family_updated_idx       on public.wallets       (family_id, updated_at);
create index if not exists entities_family_updated_idx      on public.entities      (family_id, updated_at);
create index if not exists members_family_updated_idx       on public.members       (family_id, updated_at);

-- ===========================================================================
-- 2. Session -> family resolution helper.
-- SECURITY DEFINER + STABLE so it bypasses RLS on `members` (prevents recursive
-- policy evaluation) and returns a single deterministic family_id for the caller.
-- ===========================================================================
create or replace function public.auth_family_id()
  returns uuid
  language sql
  stable
  security definer
  set search_path = public, auth
as $$
  select m.family_id
  from public.members m
  where m.user_id = auth.uid()
  limit 1
$$;

-- ===========================================================================
-- 3. Shared triggers.
-- ===========================================================================
-- updated_at is always server-managed: overwrite whatever the client sent.
create or replace function public.set_updated_at()
  returns trigger
  language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- family_id is always server-derived: force it to the session's family on insert,
-- and make it immutable on update. A client-supplied family_id is ignored.
create or replace function public.set_family_id()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, auth
as $$
declare
  session_family uuid;
begin
  if tg_op = 'INSERT' then
    session_family := public.auth_family_id();
    if session_family is not null then
      -- Normal authenticated path: force the row onto the caller's family,
      -- ignoring any client-supplied family_id.
      new.family_id := session_family;
    end if;
    -- else: bootstrap/service context (no membership yet) — keep the explicit
    -- family_id. RLS WITH CHECK is the backstop for any non-bootstrap caller.
  elsif tg_op = 'UPDATE' then
    new.family_id := old.family_id; -- tenancy key cannot move between families
  end if;
  return new;
end;
$$;

-- Attach shared triggers to every tenant table.
do $$
declare t text;
begin
  foreach t in array array['transactions','categories','wallets','entities','members']
  loop
    execute format('create trigger %I_set_updated_at before insert or update on public.%I
                    for each row execute function public.set_updated_at();', t, t);
    execute format('create trigger %I_set_family_id before insert or update on public.%I
                    for each row execute function public.set_family_id();', t, t);
  end loop;
end;
$$;

-- ===========================================================================
-- 4. Auto-create family on first sign-in.
-- A new auth user gets a fresh family + an admin member row linking the account.
-- SECURITY DEFINER: runs as the function owner so it can write the tenancy root
-- before any RLS context exists for the new user. set_family_id() resolves to NULL
-- here (no membership yet) and therefore keeps the explicit family_id below.
-- ===========================================================================
create or replace function public.handle_new_user()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, auth
as $$
declare
  new_family_id uuid;
  display_name  text;
begin
  display_name := coalesce(new.raw_user_meta_data->>'full_name', new.email, 'Me');

  insert into public.families (name)
  values (display_name || '''s Family')
  returning id into new_family_id;

  insert into public.members (id, family_id, user_id, name, role, is_me)
  values ('m_' || replace(new.id::text, '-', ''), new_family_id, new.id, display_name, 'admin', true);

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
