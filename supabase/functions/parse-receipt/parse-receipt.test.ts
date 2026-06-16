// Handler tests for the parse-receipt Edge Function (pure; no network/DB).
// The auth gate and the Gemini parser are both injected as fakes, so every branch -
// method guard, auth gate, body validation, success, and parser failure - is exercised
// without a real JWT verify or a real Gemini call. The live Gemini path is operator-
// verified in dev (CI has no key and must not depend on external network).
// Run: deno test supabase/functions/parse-receipt/parse-receipt.test.ts
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handleParseReceipt } from "./handler.ts";
import type { AuthResult } from "../_shared/http.ts";

const okAuth: AuthResult = { supabase: {} as unknown as AuthResult["supabase"], userId: "u1" };
const passGate = () => Promise.resolve(okAuth);
const fakeParse = (_b64: string) =>
  Promise.resolve({ entity: "Cafe", amount: 4.5, date: "2026-06-16", category: "Food", description: "coffee" });

function post(body: unknown): Request {
  return new Request("http://localhost/parse-receipt", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

Deno.test("CORS preflight (OPTIONS) returns ok", async () => {
  const res = await handleParseReceipt(
    new Request("http://localhost/parse-receipt", { method: "OPTIONS" }),
    { parseFn: fakeParse, requireUser: passGate },
  );
  assertEquals(res.status, 200);
});

Deno.test("rejects non-POST with 405", async () => {
  const res = await handleParseReceipt(
    new Request("http://localhost/parse-receipt", { method: "GET" }),
    { parseFn: fakeParse, requireUser: passGate },
  );
  assertEquals(res.status, 405);
});

Deno.test("401 when the auth gate rejects (missing/invalid bearer)", async () => {
  const failGate = () =>
    Promise.resolve(new Response(JSON.stringify({ status: "error", message: "Missing bearer token." }), { status: 401 }));
  const res = await handleParseReceipt(post({ image: "abc" }), { parseFn: fakeParse, requireUser: failGate });
  assertEquals(res.status, 401);
  assertEquals((await res.json()).status, "error");
});

Deno.test("400 on malformed JSON body", async () => {
  const req = new Request("http://localhost/parse-receipt", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{not json",
  });
  const res = await handleParseReceipt(req, { parseFn: fakeParse, requireUser: passGate });
  assertEquals(res.status, 400);
});

Deno.test("400 when image is missing or empty", async () => {
  const missing = await handleParseReceipt(post({}), { parseFn: fakeParse, requireUser: passGate });
  assertEquals(missing.status, 400);
  const empty = await handleParseReceipt(post({ image: "   " }), { parseFn: fakeParse, requireUser: passGate });
  assertEquals(empty.status, 400);
});

Deno.test("success envelope returns the ParsedReceipt", async () => {
  const res = await handleParseReceipt(post({ image: "base64data" }), { parseFn: fakeParse, requireUser: passGate });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.status, "success");
  assertEquals(body.data.entity, "Cafe");
  assertEquals(body.data.amount, 4.5);
});

Deno.test("502 when the parser throws (Gemini failure surfaces cleanly)", async () => {
  const boom = (_b64: string) => Promise.reject(new Error("Gemini timeout"));
  const res = await handleParseReceipt(post({ image: "x" }), { parseFn: boom, requireUser: passGate });
  assertEquals(res.status, 502);
  const body = await res.json();
  assertEquals(body.status, "error");
  assert(String(body.message).includes("Gemini timeout"));
});
