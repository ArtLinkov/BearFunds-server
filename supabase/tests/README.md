# Server tests

Two layers, matching the two risk surfaces:

## 1. RLS isolation + triggers (authoritative for tenancy)

`rls_isolation.test.sql` proves the brain's QA Area 008 (Identity) / 019 (Isolation)
invariants at the Postgres layer — independent of any Edge Function logic:

- a new auth user auto-gets a family + one admin member (`handle_new_user`);
- a session reads/writes only its own `family_id` (read + write isolation);
- a forged body `family_id` is overwritten to the caller's family (`set_family_id` trigger);
- `updated_at` is server-managed (trigger overwrites client values);
- `family_id` is immutable across updates.

**Run against a real Supabase project** (which provides the `auth` schema natively):

```bash
supabase db reset          # applies migrations 0001 + 0002
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_isolation.test.sql
```

`auth_shim.sql` is **test-only** — it recreates the minimal Supabase `auth` surface
(`auth.users`, `auth.uid()`, `auth.jwt()`, the `authenticated` role) so the same
migrations + suite run on a **stock Postgres** with no Supabase. Never apply it to a
real project. Stock-Postgres run order: `auth_shim.sql` → `0001` → `0002` → the suite.

## 2. Edge Function action routing + boundary validation

`../functions/api/api.test.ts` covers the pure contract logic with an injected fake
DB (no network): server-key stripping, strict unknown-key rejection, action→table
mapping, `batchUpdate` fan-out, `wipe` test-gating, empty-batch no-ops.

```bash
deno test supabase/functions/api/api.test.ts
```

> Verified in the scaffolding session against a sandboxed Postgres 16 (RLS suite, all
> assertions passed) and the validation/routing logic via an equivalent Node harness
> (11/11). The end-to-end Edge Function (`index.ts`, which imports supabase-js from
> esm.sh and calls Supabase Auth) is exercised by the operator via `supabase functions serve`.
