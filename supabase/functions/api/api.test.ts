// Action-handler + boundary-validation tests (pure; no network/DB).
// Run: deno test --allow-none supabase/functions/api/api.test.ts
import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseRequest, ValidationError } from "./_shared/validation.ts";
import { DbExecutor, runAction } from "./_shared/actions.ts";

// A fake executor that records calls and returns echo data.
function fakeDb() {
  const calls: { op: string; table: string; arg: unknown }[] = [];
  const db: DbExecutor = {
    read: (t, since) => { calls.push({ op: "read", table: t, arg: since }); return Promise.resolve([{ id: "r1" }]); },
    insert: (t, rows) => { calls.push({ op: "insert", table: t, arg: rows }); return Promise.resolve(rows); },
    update: (t, id, ch) => { calls.push({ op: "update", table: t, arg: { id, ch } }); return Promise.resolve([{ id, ...ch }]); },
    upsert: (t, rows) => { calls.push({ op: "upsert", table: t, arg: rows }); return Promise.resolve(rows); },
    wipe: (t) => { calls.push({ op: "wipe", table: t, arg: null }); return Promise.resolve(3); },
  };
  return { db, calls };
}

Deno.test("strips server-derived & internal keys, keeps writable keys", () => {
  const req = parseRequest({
    action: "batchUpsert", table: "WALLETS",
    rows: [{ id: "w1", name: "A", currency: "EUR", family_id: "forged", user_id: "x", updated_at: "2000", isDirty: true }],
  });
  if (req.action !== "batchUpsert") throw new Error("wrong action");
  assertEquals(req.rows[0], { id: "w1", name: "A", currency: "EUR" });
});

Deno.test("rejects unknown row key (strict contract)", () => {
  assertThrows(
    () => parseRequest({ action: "batchCreate", table: "WALLETS", rows: [{ id: "w1", bogus: 1 }] }),
    ValidationError, "Unknown key 'bogus'",
  );
});

Deno.test("SUBCATEGORIES: strips server keys, keeps writable (category_id,name,is_default)", () => {
  const req = parseRequest({
    action: "batchUpsert", table: "SUBCATEGORIES",
    rows: [{ id: "sc1", category_id: "c1", name: "General", is_default: true, family_id: "forged", updated_at: "2000", isDirty: true }],
  });
  if (req.action !== "batchUpsert") throw new Error("wrong action");
  assertEquals(req.rows[0], { id: "sc1", category_id: "c1", name: "General", is_default: true });
});

Deno.test("SUBCATEGORIES: rejects unknown row key and read maps logical->physical", async () => {
  assertThrows(
    () => parseRequest({ action: "batchCreate", table: "SUBCATEGORIES", rows: [{ id: "sc1", bogus: 1 }] }),
    ValidationError, "Unknown key 'bogus'",
  );
  const { db, calls } = fakeDb();
  await runAction(parseRequest({ action: "read", table: "SUBCATEGORIES" }), db, { isTest: false });
  assertEquals(calls[0].table, "subcategories");
});

Deno.test("rejects unknown action and unknown table", () => {
  assertThrows(() => parseRequest({ action: "delete", table: "WALLETS" }), ValidationError);
  assertThrows(() => parseRequest({ action: "read", table: "ACCOUNTS" }), ValidationError);
});

Deno.test("batchUpsert requires id; batchCreate does not", () => {
  assertThrows(() => parseRequest({ action: "batchUpsert", table: "WALLETS", rows: [{ name: "x" }] }), ValidationError);
  const ok = parseRequest({ action: "batchCreate", table: "WALLETS", rows: [{ name: "x", currency: "EUR" }] });
  assert(ok.action === "batchCreate");
});

Deno.test("read routes with since and maps logical->physical table", async () => {
  const { db, calls } = fakeDb();
  const out = await runAction(parseRequest({ action: "read", table: "TRANSACTIONS", since: "2024-01-01T00:00:00Z" }), db, { isTest: false });
  assertEquals(calls[0], { op: "read", table: "transactions", arg: "2024-01-01T00:00:00Z" });
  assertEquals(out, [{ id: "r1" }]);
});

Deno.test("batchUpdate fans out per row id", async () => {
  const { db, calls } = fakeDb();
  await runAction(parseRequest({ action: "batchUpdate", table: "TRANSACTIONS", updates: [{ id: "t1", amount: 5 }, { id: "t2", amount: 9 }] }), db, { isTest: false });
  assertEquals(calls.map((c) => c.op), ["update", "update"]);
  assertEquals(calls[0].arg, { id: "t1", ch: { amount: 5 } });
});

Deno.test("wipe is blocked outside test context, allowed inside", async () => {
  const { db } = fakeDb();
  let threw = false;
  try { await runAction(parseRequest({ action: "wipe", table: "MEMBERS" }), db, { isTest: false }); }
  catch (e) { threw = e instanceof ValidationError; }
  assert(threw, "wipe must throw when isTest=false");
  const res = await runAction(parseRequest({ action: "wipe", table: "MEMBERS" }), db, { isTest: true });
  assertEquals(res, { wiped: 3 });
});

Deno.test("empty batches are no-ops", async () => {
  const { db, calls } = fakeDb();
  assertEquals(await runAction(parseRequest({ action: "batchCreate", table: "WALLETS", rows: [] }), db, { isTest: false }), []);
  assertEquals(calls.length, 0);
});
