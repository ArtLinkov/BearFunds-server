// parse-receipt handler: an authenticated, stateless AI proxy. It verifies the caller's
// session, validates a base64 image, and delegates to an injected receipt parser. It
// touches no tenant table, so there is no family_id derivation and no RLS surface here -
// the only access-control property is "authenticated callers only" (protects the key/quota).
// The Gemini call and the auth gate are injected so the whole handler is unit-testable
// without network. Envelope matches the api function: { status, data | message }.
import { json, requireUser as defaultRequireUser, isAuthed } from "../_shared/http.ts";
import type { AuthResult } from "../_shared/http.ts";

export interface ParsedReceipt {
  entity: string;
  amount: number;
  date: string;
  category?: string;
  description?: string;
}

export type ReceiptParser = (base64Image: string) => Promise<ParsedReceipt>;
export type AuthGate = (req: Request) => Promise<Response | AuthResult>;

export interface Deps {
  parseFn: ReceiptParser;
  // Injectable for tests; defaults to the real Bearer-JWT verify.
  requireUser?: AuthGate;
}

export async function handleParseReceipt(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return json({ status: "success" });
  if (req.method !== "POST") return json({ status: "error", message: "POST only." }, 405);

  const gate = deps.requireUser ?? defaultRequireUser;
  const auth = await gate(req);
  if (!isAuthed(auth)) return auth; // ready 401 Response

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ status: "error", message: "Body must be valid JSON." }, 400);
  }

  const image = (body as { image?: unknown }).image;
  if (typeof image !== "string" || image.trim().length === 0) {
    return json({ status: "error", message: "Missing 'image' (base64 string)." }, 400);
  }

  try {
    const data = await deps.parseFn(image);
    return json({ status: "success", data });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Receipt parsing failed.";
    return json({ status: "error", message }, 502);
  }
}
