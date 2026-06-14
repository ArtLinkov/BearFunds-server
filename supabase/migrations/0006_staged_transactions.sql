-- BearFunds server - Schema Contract v1.10 cutover (forward-only).
-- Adds STAGED_TRANSACTIONS: a synced, RLS-scoped import staging area (the [Q15]
-- foundation for the S7 bulk-import rework). Rows are partially-mapped, possibly
-- invalid import candidates the client bulk-edits before promotion. On commit, valid
-- rows are copied into TRANSACTIONS (client-orchestrated batchCreate) and the staging
-- rows are soft-deleted. No new server verb; promotion uses the existing actions.
--
-- Mirrors TRANSACTIONS but with amount as RAW TEXT and nullable FKs so partially
-- mapped rows persist and can be bulk-edited; adds batch_id + source_* raw columns
-- and a source_row JSON-as-text column (the full original import row) so the grid can
-- filter on ANY source column, mapped or not.
--
-- Tenancy invariants preserved (0_AI_INSTRUCTIONS.md, brain QA Areas 008/019):
-- staged_transactions carries a server-derived family_id (set_family_id trigger), a
-- server-managed updated_at trigger, and an explicit RLS family-isolation policy. The
-- trigger/policy loops in 0001/0002 are hardcoded arrays that exclude this new table,
-- so its triggers + policy are wired explicitly below (same as subcategories in 0005).
--
-- Forward-only, additive, non-destructive: no existing table or column is touched.

-- 1. New tenant table: staged_transactions (global columns + staged/source columns).
--    amount is TEXT here (raw import text, parsed to numeric only on promotion).
--    All FKs are nullable and unconstrained: staging rows may reference ids that do
--    not exist yet, and partially-mapped rows must be allowed to persist.
create table if not exists public.staged_transactions (
  id               text primary key,
  family_id        uuid not null references public.families(id) on delete cascade,
  batch_id         text,
  date             text,
  amount           text,
  currency         text,
  type             text,
  category_id      text,
  sub_category_id  text,
  entity_id        text,
  wallet_id        text,
  member_id        text,
  description      text,
  tags             text,
  status           text,
  source_wallet    text,
  source_category  text,
  source_name      text,
  source_row       text,
  updated_at       timestamptz not null default now(),
  deleted          boolean not null default false,
  is_immutable     boolean not null default false
);

create index if not exists staged_transactions_family_updated_idx
  on public.staged_transactions (family_id, updated_at);

-- 2. Shared triggers: server-managed updated_at + server-derived family_id.
create trigger staged_transactions_set_updated_at before insert or update on public.staged_transactions
  for each row execute function public.set_updated_at();
create trigger staged_transactions_set_family_id before insert or update on public.staged_transactions
  for each row execute function public.set_family_id();

-- 3. Grants + RLS family isolation (mirrors migration 0002 for every tenant table).
grant select, insert, update, delete on public.staged_transactions to authenticated;
alter table public.staged_transactions enable row level security;
create policy staged_transactions_family_isolation on public.staged_transactions
  for all to authenticated
  using (family_id = public.auth_family_id())
  with check (family_id = public.auth_family_id());
