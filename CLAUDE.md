# BearFunds Server — Operating Manual

Entry point for any Claude Code session in this repo. This file is a **thin loader**: it points at the canonical sources of truth rather than restating them, so there is exactly one authoritative copy of each. Read the chain below before doing any work.

This is the **server** of BearFunds ("Sweet Savings For Families") — the backend that introduces real authentication, multi-family tenancy, and server-side secrets. The **client repo** (React 19 + TS + Vite, offline-first) lives separately at `D:\Projects\github\BearFunds-client`; a **brain vault** at `D:\Projects\Brains\BearFunds` holds the decisions and synthesis. This repo is **newly created and not yet scaffolded** beyond these governance files — the design it implements is the brain's [[BearFunds Server Architecture]] (Q6).

## Read these first (in order)

1. **`0_AI_INSTRUCTIONS.md`** — the engineering protocol. The canonical working discipline (Impact Analysis → Approval Lock → Test-first → Verify), adapted for server work (contract bumps, tenancy, RLS). Read it fully and follow it exactly. It is authoritative over this file if they ever disagree.
2. **`2_SCHEMA_CONTRACT.xml`** — the backend API + DB contract (v1.5.0). **This repo is its canonical home** (the producer owns the interface; decided in the brain's Sources of Truth, 2026-06-01). It is a *shared* client↔server interface, so changes are deliberate version bumps that the operator drops into the client — never casual edits. **Pending:** the canonical copy must be dropped in from the client with a `Canonical: <this repo> · vX.Y` header line (see "Setup TODO" below).

## The working loop (summary — `0_AI_INSTRUCTIONS.md` is canonical)

- Output an `## Impact Analysis` **before any code**: files/migrations/policies to touch, contract compliance (or an explicit versioned bump), the tenancy & auth check (server-derived `family_id`, RLS coverage, brain QA Areas 008/019), risk, and a test plan including RLS-isolation tests.
- Then present the plan and **enter the Approval Lock** — end with exactly: `Awaiting approval. Please use an approval keyword to proceed.` Generate no code until an approval keyword arrives. **Never simulate a user approval.**
- On approval: write tests first (incl. isolation tests), then the implementation, then remove dead code. Verify against the contract and the tenancy invariants.

## Architecture orientation (target — see the brain for the full design)

- **Platform:** Supabase — managed **Postgres** (datastore), **Auth** (Google sign-in), and **Edge Functions** (the API seam).
- **API seam:** a single Edge Function that **honors the v1.5.x Schema Contract** — one POST endpoint, action-based (`read`/`batchCreate`/`batchUpdate`/`batchUpsert`/`wipe`), snake_case logical keys, `{ status, data }` envelope. This keeps the client's `core/api/` layer almost unchanged (it swaps the shared bundle key for a Supabase session JWT).
- **Datastore:** one table per client collection (`transactions`, `categories`, `wallets`, `entities`, `members`) + a `families` tenancy root, mapping the brain's `Syncable` model 1:1, with server-managed `updated_at`, soft-delete `deleted`, and `is_immutable`.
- **Tenancy/auth:** every tenant row carries a server-derived `family_id`, enforced by Postgres **RLS**; `FamilyMember.role` (`admin`/`member`) becomes server-enforced. Secrets (Gemini, JWT) live server-side, never in the client bundle.
- A RESTful **v2** contract is deferred future work; honor v1.5.x now.

## Critical guardrails

- **Never** write secrets into the repo or commits; **never** overwrite `.env*`. New key needed → say so in chat.
- **Never** change the wire shape implicitly — `2_SCHEMA_CONTRACT.xml` changes are deliberate, versioned, and propagated to the client.
- **Never** trust a client-supplied `family_id`/`user_id`; derive tenancy from the session. RLS on every tenant table is the backstop, and isolation must be tested directly.
- **Migrations are forward-only** — add a new one, don't edit an applied migration.
- Warn when a file exceeds ~300 lines; reuse existing helpers before writing new ones; don't refactor working architecture unless asked.

## Relationship to the brain (decisions live there, not here)

The **BearFunds brain vault** (separate repo; at `D:\Projects\Brains\BearFunds`) owns the decisions, the maps, and the decision trail. This repo owns the runtime and (now) the canonical Schema Contract. When a "why" is needed, it lives in the brain.

Brain Reference docs (under `Areas/BearFunds/`):
- `Reference/BearFunds Server Architecture.md` — the design this repo implements (datastore, auth, tenancy, contract handling, migration path).
- `Reference/BearFunds Schema Contract.md`, `Reference/BearFunds Data Model.md`, `Reference/BearFunds Persistence and Sync.md` — the contract map, the `Syncable` model, and the client's sync layer this server must interoperate with.
- `Sources of Truth.md` (governance + the Schema Contract re-home), `Migration Playbook.md` (esp. L2 auth, L4 server-authoritative sync), `Open Questions.md` (Q1 secrets, Q3 Sheets, Q7 role-enum).

## Setup TODO (before real code)

1. Drop in the canonical `2_SCHEMA_CONTRACT.xml` from the client, add the `Canonical: <this repo> · v1.5.0` header line, and update the client's copy to note it is now a downstream drop-in.
2. Scaffold the Supabase project layout: `supabase/` (migrations + RLS policies + Edge Functions) and `contracts/` (the canonical contract), with tests for action handlers and RLS isolation.

Both steps go through the `0_AI_INSTRUCTIONS.md` protocol (Impact Analysis → Approval) before code.


## Tool reliability (file writes)

The Edit/Write tools can silently truncate a file mid-write while reporting success. Two known triggers, often combined: (1) multi-byte / non-ASCII characters in the content (em dashes, smart quotes, arrows, emoji), where the write is cut at the offending character; and (2) large files, very long lines, or content near the end. The Edit tool rewrites the whole file, so a stray non-ASCII character anywhere in it - not only in the change - can trip this.

Policy (prevention-first; mirrors the brain vault CLAUDE.md):
- Default to writing through bash (a heredoc, or a Python literal-replace) for anything beyond a tiny, ASCII-only, surgical edit. Use the Edit tool only for small ASCII-only changes.
- Keep all authored content strict ASCII - no em dashes, smart quotes, arrows, or emoji in code or comments.
- Verify every write immediately (wc -l plus tail, or grep for the expected closing section). A "success" tool result is not proof; the file on disk is.
- If a write did truncate, recover from git (tracked files) or rewrite via heredoc (new files), then re-verify.
