// BearFunds parse-receipt - authenticated server-side receipt scanning. The Gemini key
// lives only here (server env), never in the client bundle. Out-of-contract (not a data
// action): no table, no family_id, no RLS surface; the Schema Contract is untouched.
import { handleParseReceipt } from "./handler.ts";
import { geminiParser } from "./gemini.ts";

Deno.serve((req: Request) => handleParseReceipt(req, { parseFn: geminiParser }));
