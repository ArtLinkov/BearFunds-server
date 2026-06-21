// Shared HTTP helpers for BearFunds Edge Functions: CORS headers, the JSON envelope
// writer, and the authenticated-user gate. Lifted from api/index.ts so every function
// answers CORS and verifies the caller's Bearer JWT exactly the same way.
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

export interface AuthResult {
  supabase: SupabaseClient;
  userId: string;
}

// Verify the caller's Bearer JWT. On failure returns a ready 401 Response so callers can
// early-return; on success returns the RLS-bound client plus the resolved user id. The
// returned client carries the caller's token, so any DB work runs under that session's RLS.
export async function requireUser(req: Request): Promise<Response | AuthResult> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ status: "error", message: "Missing bearer token." }, 401);
  }
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } },
  );
  const { data, error } = await supabase.auth.getUser();
  if (error || !data?.user) {
    return json({ status: "error", message: "Unauthenticated." }, 401);
  }
  return { supabase, userId: data.user.id };
}

// Narrow a requireUser result: true when authentication succeeded.
export function isAuthed(r: Response | AuthResult): r is AuthResult {
  return (r as AuthResult).supabase !== undefined;
}

// An RLS-bound client that also flags the request as TEST context via the `x-bf-test`
// header. The Edge Function builds this ONLY when the validated body flag isTest=true.
// PostgREST forwards the header into the request.headers GUC, where auth_family_id()
// (migration 0011) routes the caller to their per-user test family. The header is server-set
// from a validated flag, and the test family is keyed to auth.uid(), so a caller can only ever
// reach their OWN test family -- never another tenant's data.
export function testScopedClient(req: Request): SupabaseClient {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      global: { headers: { Authorization: authHeader, "x-bf-test": "1" } },
      auth: { persistSession: false },
    },
  );
}
