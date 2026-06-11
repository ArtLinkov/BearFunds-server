-- BearFunds server — Schema Contract v1.9 cutover (forward-only).
-- Elevates sub-categories to a first-class tenant table and switches transactions +
-- entities to FK references; also lands the v1.8 categories.description column the
-- server had not yet adopted.
--
-- DESTRUCTIVE: drops transactions.sub_category, entities.default_sub_category,
-- categories.sub_categories. No backfill — the client is the source of truth and
-- re-pushes the FK data; the local DB is rebuilt via `supabase db reset`, and no
-- production data exists yet (local-first, pre-deploy).
--
-- Tenancy invariants preserved (0_AI_INSTRUCTIONS.md, brain QA Areas 008/019):
-- subcategories carries a server-derived family_id (set_family_id trigger), a
-- server-managed updated_at trigger, and an explicit RLS family-isolation policy.
-- The trigger/policy loops in 0001/0002 are hardcoded arrays that exclude this new
-- table, so its triggers + policy are wired explicitly below.

-- 1. New tenant table: subcategories (global columns + category_id FK-by-id + is_default).
create table if not exists public.subcategories (
  id            text primary key,
  family_id     uuid not null references public.families(id) on delete cascade,
  category_id   text,
  name          text,
  is_default    boolean not null default false,
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false,
  is_immutable  boolean not null default false
);

create index if not exists subcategories_family_updated_idx
  on public.subcategories (family_id, updated_at);

-- 2. Shared triggers: server-managed updated_at + server-derived family_id.
create trigger subcategories_set_updated_at before insert or update on public.subcategories
  for each row execute function public.set_updated_at();
create trigger subcategories_set_family_id before insert or update on public.subcategories
  for each row execute function public.set_family_id();

-- 3. Grants + RLS family isolation (mirrors migration 0002 for every tenant table).
grant select, insert, update, delete on public.subcategories to authenticated;
alter table public.subcategories enable row level security;
create policy subcategories_family_isolation on public.subcategories
  for all to authenticated
  using (family_id = public.auth_family_id())
  with check (family_id = public.auth_family_id());

-- 4. v1.9 FK column flips on transactions + entities (destructive drops).
alter table public.transactions add column if not exists sub_category_id text;
alter table public.transactions drop column if exists sub_category;
alter table public.entities add column if not exists default_sub_category_id text;
alter table public.entities drop column if exists default_sub_category;

-- 5. categories: land the v1.8 description column, drop the now-normalized sub_categories.
alter table public.categories add column if not exists description text;
alter table public.categories drop column if exists sub_categories;
