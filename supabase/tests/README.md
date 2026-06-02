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

## 3. Server E2E (live function + DB + RLS over HTTP)

`e2e.test.ts` drives the **running** Edge Function against the local Supabase stack —
real auth, real Postgres, real RLS — proving the v1.6.0 contract end to end. It creates
two users via the local service-role admin API (firing `handle_new_user` → two families),
mints each user's `authenticated` JWT (HS256-signed with the local JWT secret — dev-only,
no OAuth, no committed secrets), then over HTTP: runs all five actions for family A and
asserts family B cannot read/write A's rows, a forged body `family_id` lands in B not A,
the `{ status, data }` envelope, strict unknown-key rejection, and that an unauthenticated
request is refused.

**Prereqs:** Docker, Supabase CLI, Deno (on Windows: `scoop install supabase deno`).

```bash
bash supabase/tests/run_e2e.sh          # macOS / Linux / Git Bash
```

On **Windows PowerShell**, use the native runner — the Scoop-installed CLI is on the
PowerShell PATH, not bash's — which does the same thing without needing bash:

```powershell
./supabase/tests/run_e2e.ps1
```

> With `verify_jwt = true`, the Supabase platform answers a no-token request with its own
> `{ "msg": ... }` 401 *before* the function runs — so a bare `curl` smoke test returns that,
> not our `{ status, data }` envelope. That's the auth gate working; the harness accepts it.

The runner is idempotent: `supabase start` → `supabase db reset` → ensures the function is
served → exports `SUPABASE_URL` / `*_KEY` / `JWT_SECRET` from `supabase status` (never
echoed) → `deno test`. To run the harness by hand against an already-up stack, export those
four env vars (plus optional `FUNCTION_URL`) and run
`deno test --allow-net --allow-env supabase/tests/e2e.test.ts`.

> The dev JWT-minting algorithm was cross-checked offline against a standard HS256 verifier
> (the scheme GoTrue uses): correct `sub`/`role`/`aud`/`exp`, rejected under a wrong secret.
> The full HTTP run requires Docker + Deno on your machine (it can't run in the scaffolding sandbox).
