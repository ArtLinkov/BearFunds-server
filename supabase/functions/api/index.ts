// BearFunds API — single POST Edge Function honoring Schema Contract v1.6.0.
// Auth: Authorization: Bearer <JWT>. Tenancy: family_id is server-derived by the DB
// (trigger + RLS); this function never reads a family_id from the body. Envelope:
// { status: 'success' | 'error', data | message }.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { parseRequest, ValidationError } from "./_shared/validation.ts";
import { DbExecutor, runAction } from "./_shared/actions.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// supabase-js-backed executor. The client carries the caller's JWT, so every query
// runs under that session's RLS — isolation does not depend on this function's logic.
function makeExecutor(supabase: SupabaseClient): DbExecutor {
  const fail = (e: { message: string }) => { throw new Error(e.message); };
  return {
    async read(table, since) {
      let q = supabase.from(table).select("*");
      if (since) q = q.gt("updated_at", since);
      const { data, error } = await q;
      if (error) fail(error);
      return data ?? [];
    },
    async insert(table, rows) {
      const { data, error } = await supabase.from(table).insert(rows).select();
      if (error) fail(error);
      return data ?? [];
    },
    async update(table, id, changed) {
      const { data, error } = await supabase.from(table).update(changed).eq("id", id).select();
      if (error) fail(error);
      return data ?? [];
    },
    async upsert(table, rows) {
      const { data, error } = await supabase.from(table).upsert(rows).select();
      if (error) fail(error);
      return data ?? [];
    },
    async wipe(table) {
      const { count, error } = await supabase
        .from(table).delete({ count: "exact" }).neq("id", "__never_matches__");
      if (error) fail(error);
      return count ?? 0;
    },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ status: "error", message: "POST only." }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ status: "error", message: "Missing bearer token." }, 401);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ status: "error", message: "Body must be valid JSON." }, 400);
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } },
    );

    // Confirm the token resolves to a user; unauthenticated => error (no DB work).
    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ status: "error", message: "Unauthenticated." }, 401);
    }

    const request = parseRequest(body);
    const isTest = (body as { isTest?: unknown }).isTest === true;
    const data = await runAction(request, makeExecutor(supabase), { isTest });
    return json({ status: "success", data });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Unknown error.";
    const code = e instanceof ValidationError ? 400 : 500;
    return json({ status: "error", message }, code);
  }
});
