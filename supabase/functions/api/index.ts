// BearFunds API - single POST Edge Function honoring the Schema Contract. Auth: the
// Bearer JWT is verified by the shared requireUser gate. Tenancy: family_id is
// server-derived by the DB (trigger + RLS); this function never reads a family_id from
// the body. Envelope: { status: 'success' | 'error', data | message }.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { CORS, json, requireUser, isAuthed } from "../_shared/http.ts";
import { parseRequest, ValidationError } from "./_shared/validation.ts";
import { DbExecutor, runAction } from "./_shared/actions.ts";

// supabase-js-backed executor. The client carries the caller's JWT, so every query
// runs under that session's RLS - isolation does not depend on this function's logic.
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
      let q = supabase.from(table).delete({ count: "exact" }).neq("id", "__never_matches__");
      // Never delete account-linking members (user_id set): that row establishes the
      // caller's tenancy (auth_family_id reads it), so wiping it strands the user with no
      // family. Only app-data members (user_id null) are test data. Other tables unaffected.
      if (table === "members") q = q.is("user_id", null);
      const { count, error } = await q;
      if (error) fail(error);
      return count ?? 0;
    },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ status: "error", message: "POST only." }, 405);

  const auth = await requireUser(req);
  if (!isAuthed(auth)) return auth; // ready 401 Response (missing bearer / unauthenticated)

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ status: "error", message: "Body must be valid JSON." }, 400);
  }

  try {
    const request = parseRequest(body);
    const isTest = (body as { isTest?: unknown }).isTest === true;
    const data = await runAction(request, makeExecutor(auth.supabase), { isTest });
    return json({ status: "success", data });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Unknown error.";
    const code = e instanceof ValidationError ? 400 : 500;
    return json({ status: "error", message }, code);
  }
});
