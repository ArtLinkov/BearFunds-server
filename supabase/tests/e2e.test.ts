// Server E2E — drives the RUNNING Edge Function over HTTP against the local Supabase
// stack, proving the v1.6.0 contract end to end (auth + DB + RLS), not just in isolation.
//
// Run via the orchestrator: supabase/tests/run_e2e.sh  (it brings up the stack, applies
// migrations, serves the function, and exports the env below from `supabase status`).
// Or manually, with the local stack up and env set:
//   deno test --allow-net --allow-env supabase/tests/e2e.test.ts
//
// Auth is dev-only: the local SERVICE_ROLE_KEY creates two confirmed users (which fires
// handle_new_user -> two families), and we mint each user's `authenticated` JWT by
// HS256-signing it with the local JWT secret. No OAuth, no secrets in the repo.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const ANON_KEY = req("SUPABASE_ANON_KEY");
const SERVICE_ROLE_KEY = req("SUPABASE_SERVICE_ROLE_KEY");
const JWT_SECRET = req("SUPABASE_JWT_SECRET");
const FUNCTION_URL = Deno.env.get("FUNCTION_URL") ?? `${SUPABASE_URL}/functions/v1/api`;
const RUN = crypto.randomUUID().slice(0, 8); // unique ids/emails per run

function req(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing env ${name} (run via run_e2e.sh, or export it from \`supabase status\`).`);
  return v;
}

// ---- dev JWT minting (Web Crypto HS256; no external deps) -------------------
function b64url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function mintJwt(sub: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    sub, role: "authenticated", aud: "authenticated", iat: now, exp: now + 3600,
  }));
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(JWT_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signingInput)));
  return `${signingInput}.${b64url(sig)}`;
}

// ---- HTTP helpers ----------------------------------------------------------
async function createUser(email: string, fullName: string, avatarUrl?: string): Promise<string> {
  const userMetadata: Record<string, string> = { full_name: fullName };
  if (avatarUrl) userMetadata.avatar_url = avatarUrl;
  const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ email, password: crypto.randomUUID(), email_confirm: true, user_metadata: userMetadata }),
  });
  if (!r.ok) throw new Error(`admin createUser ${email} failed: ${r.status} ${await r.text()}`);
  return (await r.json()).id as string;
}

type ApiResult = { http: number; status?: string; data?: unknown; message?: string };
async function api(jwt: string | null, body: unknown): Promise<ApiResult> {
  const headers: Record<string, string> = { apikey: ANON_KEY, "Content-Type": "application/json" };
  if (jwt) headers.Authorization = `Bearer ${jwt}`;
  const r = await fetch(FUNCTION_URL, { method: "POST", headers, body: JSON.stringify(body) });
  let j: { status?: string; data?: unknown; message?: string } = {};
  try { j = await r.json(); } catch { /* non-JSON */ }
  return { http: r.status, ...j };
}
const rows = (r: ApiResult) => (r.data as Record<string, unknown>[]) ?? [];

// ===========================================================================
Deno.test("server E2E — v1.6.0 contract + cross-family isolation", async (t) => {
  // Two Google-equivalent sign-ins -> two families (via handle_new_user).
  const ALICE_AVATAR = "https://example.test/alice.jpg";
  const aliceId = await createUser(`alice+${RUN}@bearfunds.test`, "Alice", ALICE_AVATAR);
  const bobId = await createUser(`bob+${RUN}@bearfunds.test`, "Bob");
  const aliceJwt = await mintJwt(aliceId);
  const bobJwt = await mintJwt(bobId);

  const wA = `w_a1_${RUN}`;
  const wForge = `w_bforge_${RUN}`;
  const stA = `st_a1_${RUN}`;
  const tPromoted = `t_promoted_${RUN}`;
  let aliceFamily = "";

  await t.step("unauthenticated request is rejected", async () => {
    const r = await api(null, { action: "read", table: "WALLETS" });
    // With verify_jwt=true the platform rejects before our function (body may be {msg});
    // with verify_jwt=false our function answers with the {status:"error"} envelope. Accept both.
    assert(r.http === 401 || r.http === 400, `expected 401/400 for a no-token request, got ${r.http}`);
    if (r.status !== undefined) assertEquals(r.status, "error");
  });

  await t.step("A: batchCreate -> success, family_id server-derived", async () => {
    const r = await api(aliceJwt, { action: "batchCreate", table: "WALLETS", rows: [{ id: wA, name: "Alice EUR", currency: "EUR" }] });
    assertEquals(r.status, "success");
    const created = rows(r)[0];
    assertEquals(created.id, wA);
    aliceFamily = created.family_id as string;
    assert(aliceFamily, "created row must carry a server-set family_id");
  });

  await t.step("A: read sees own wallet", async () => {
    const r = await api(aliceJwt, { action: "read", table: "WALLETS", since: "1970-01-01T00:00:00Z" });
    assertEquals(r.status, "success");
    assert(rows(r).some((w) => w.id === wA), "Alice should see her wallet");
  });

  await t.step("A: batchUpdate then batchUpsert succeed", async () => {
    const up = await api(aliceJwt, { action: "batchUpdate", table: "WALLETS", updates: [{ id: wA, name: "Alice EUR v2" }] });
    assertEquals(up.status, "success");
    assertEquals((rows(up)[0] as Record<string, unknown>).name, "Alice EUR v2");
    const us = await api(aliceJwt, { action: "batchUpsert", table: "WALLETS", rows: [{ id: wA, name: "Alice EUR v3", currency: "EUR" }] });
    assertEquals(us.status, "success");
    assertEquals((rows(us)[0] as Record<string, unknown>).name, "Alice EUR v3");
  });

  await t.step("B: cannot READ A's wallet (isolation)", async () => {
    const r = await api(bobJwt, { action: "read", table: "WALLETS", since: "1970-01-01T00:00:00Z" });
    assertEquals(r.status, "success");
    assert(!rows(r).some((w) => w.id === wA), "Bob must not see Alice's wallet");
  });

  await t.step("B: UPDATE of A's wallet is a no-op (invisible row)", async () => {
    const r = await api(bobJwt, { action: "batchUpdate", table: "WALLETS", updates: [{ id: wA, name: "HACKED" }] });
    assertEquals(r.status, "success");
    assertEquals(rows(r).length, 0, "Bob's cross-family update must affect zero rows");
  });

  await t.step("B: forged family_id is overwritten to Bob's family", async () => {
    const r = await api(bobJwt, { action: "batchCreate", table: "WALLETS", rows: [{ id: wForge, name: "forged", currency: "USD", family_id: aliceFamily }] });
    assertEquals(r.status, "success");
    const created = rows(r)[0] as Record<string, unknown>;
    assert(created.family_id !== aliceFamily, "forged family_id must not land in Alice's family");
  });

  await t.step("A: wallet survived Bob untouched", async () => {
    const r = await api(aliceJwt, { action: "read", table: "WALLETS", since: "1970-01-01T00:00:00Z" });
    const mine = rows(r).find((w) => w.id === wA) as Record<string, unknown> | undefined;
    assertEquals(mine?.name, "Alice EUR v3", "Alice's wallet name must be unchanged by Bob");
    assert(!rows(r).some((w) => w.id === wForge), "Alice must not see Bob's forged wallet");
  });

  await t.step("strict validation: unknown key is rejected over HTTP", async () => {
    const r = await api(aliceJwt, { action: "batchCreate", table: "WALLETS", rows: [{ id: `x_${RUN}`, bogus: 1 }] });
    assertEquals(r.status, "error");
  });

  await t.step("wipe (isTest) clears only the caller's family", async () => {
    const r = await api(bobJwt, { action: "wipe", table: "WALLETS", isTest: true });
    assertEquals(r.status, "success");
    const a = await api(aliceJwt, { action: "read", table: "WALLETS", since: "1970-01-01T00:00:00Z" });
    assert(rows(a).some((w) => w.id === wA), "Bob's wipe must not clear Alice's wallet");
  });

  await t.step("linking member is born with the sign-up avatar (0003)", async () => {
    const r = await api(aliceJwt, { action: "read", table: "MEMBERS", since: "1970-01-01T00:00:00Z" });
    assertEquals(r.status, "success");
    const linking = rows(r).find((m) => (m as Record<string, unknown>).user_id === aliceId);
    assert(linking, "Alice's linking member must exist");
    assertEquals((linking as Record<string, unknown>).avatar, ALICE_AVATAR, "avatar_url metadata must land on the linking member");
  });

  await t.step("wipe MEMBERS preserves the account-linking member (tenancy survives)", async () => {
    const before = await api(aliceJwt, { action: "read", table: "MEMBERS", since: "1970-01-01T00:00:00Z" });
    assert(rows(before).some((m) => (m as Record<string, unknown>).user_id === aliceId), "linking member should exist before wipe");

    const w = await api(aliceJwt, { action: "wipe", table: "MEMBERS", isTest: true });
    assertEquals(w.status, "success");

    const after = await api(aliceJwt, { action: "read", table: "MEMBERS", since: "1970-01-01T00:00:00Z" });
    assert(rows(after).some((m) => (m as Record<string, unknown>).user_id === aliceId), "linking member must survive a MEMBERS wipe");

    // Tenancy still resolves after the wipe: a follow-up write must succeed.
    const c = await api(aliceJwt, { action: "batchUpsert", table: "CATEGORIES", rows: [{ id: `c_after_${RUN}`, name: "After Wipe", type: "expense" }] });
    assertEquals(c.status, "success");
  });

  await t.step("STAGED: A creates a partially-mapped staged row (raw amount, null FKs)", async () => {
    const r = await api(aliceJwt, {
      action: "batchCreate", table: "STAGED_TRANSACTIONS",
      rows: [{
        id: stA, batch_id: `b_${RUN}`, amount: "-1.234,56", source_name: "ACME / GMBH",
        source_row: JSON.stringify({ Memo: "ACME / GMBH", Value: "-1.234,56" }),
      }],
    });
    assertEquals(r.status, "success");
    const created = rows(r)[0] as Record<string, unknown>;
    assertEquals(created.amount, "-1.234,56", "raw amount text persists verbatim (not numeric)");
    assertEquals(created.category_id, null, "an unmapped FK stays null while staged");
    assert(created.family_id, "family_id is server-derived onto the staged row");
  });

  await t.step("STAGED: B cannot read A's staged rows (isolation)", async () => {
    const r = await api(bobJwt, { action: "read", table: "STAGED_TRANSACTIONS", since: "1970-01-01T00:00:00Z" });
    assertEquals(r.status, "success");
    assert(!rows(r).some((s) => s.id === stA), "Bob must not see Alice's staged row");
  });

  await t.step("STAGED: client-orchestrated promotion uses existing actions (no new verb)", async () => {
    // Promote: write the parsed row into TRANSACTIONS, then soft-delete the staging row.
    const promote = await api(aliceJwt, {
      action: "batchCreate", table: "TRANSACTIONS",
      rows: [{ id: tPromoted, amount: -1234.56, currency: "EUR", type: "expense", date: "2026-06-14" }],
    });
    assertEquals(promote.status, "success");
    const softDelete = await api(aliceJwt, {
      action: "batchUpdate", table: "STAGED_TRANSACTIONS", updates: [{ id: stA, deleted: true }],
    });
    assertEquals(softDelete.status, "success");

    const tx = await api(aliceJwt, { action: "read", table: "TRANSACTIONS", since: "1970-01-01T00:00:00Z" });
    assert(rows(tx).some((x) => x.id === tPromoted), "promoted transaction lands in TRANSACTIONS");
    const staged = await api(aliceJwt, { action: "read", table: "STAGED_TRANSACTIONS", since: "1970-01-01T00:00:00Z" });
    const left = rows(staged).find((s) => s.id === stA) as Record<string, unknown> | undefined;
    assertEquals(left?.deleted, true, "the staged row is soft-deleted after promotion");
  });
});
