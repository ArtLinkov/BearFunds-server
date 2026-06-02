// Boundary validation for the single-POST contract. Strict: an unknown key in a row
// is a hard error (Schema Contract ErrorHandling rule). Server-derived / sync-internal
// keys are stripped before the unknown-key check so a well-behaved client that echoes
// them back is not rejected, while genuinely unknown keys still fail.

import {
  ACTIONS, isLogicalTable, LogicalTable, STRIPPED_KEYS, WRITABLE,
} from "./contract.ts";

export class ValidationError extends Error {}

export interface ReadRequest {
  action: "read";
  table: LogicalTable;
  since: string | null;
}
export interface RowsRequest {
  action: "batchCreate" | "batchUpsert";
  table: LogicalTable;
  rows: Record<string, unknown>[];
}
export interface UpdatesRequest {
  action: "batchUpdate";
  table: LogicalTable;
  updates: Record<string, unknown>[];
}
export interface WipeRequest {
  action: "wipe";
  table: LogicalTable;
}
export type ApiRequest = ReadRequest | RowsRequest | UpdatesRequest | WipeRequest;

function requireObject(v: unknown): Record<string, unknown> {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    throw new ValidationError("Payload must be a JSON object.");
  }
  return v as Record<string, unknown>;
}

// Strip server-controlled keys, then reject any remaining key not writable for the table.
function sanitizeRow(
  table: LogicalTable,
  row: unknown,
  requireId: boolean,
): Record<string, unknown> {
  const obj = requireObject(row);
  const out: Record<string, unknown> = {};
  const allowed = WRITABLE[table];
  for (const [k, v] of Object.entries(obj)) {
    if (STRIPPED_KEYS.has(k)) continue; // server-derived/internal — drop silently
    if (!allowed.has(k)) {
      throw new ValidationError(`Unknown key '${k}' for table ${table}.`);
    }
    out[k] = v;
  }
  if (requireId && (out.id === undefined || out.id === null || out.id === "")) {
    throw new ValidationError(`Action requires an 'id' for table ${table}.`);
  }
  return out;
}

export function parseRequest(body: unknown): ApiRequest {
  const obj = requireObject(body);
  const { action, table } = obj as { action?: unknown; table?: unknown };

  if (typeof action !== "string" || !ACTIONS.has(action)) {
    throw new ValidationError(`Unknown or missing action.`);
  }
  if (!isLogicalTable(table)) {
    throw new ValidationError(`Unknown or missing table.`);
  }

  switch (action) {
    case "read": {
      const since = (obj as { since?: unknown }).since;
      if (since !== undefined && since !== null && typeof since !== "string") {
        throw new ValidationError("'since' must be an ISO string or omitted.");
      }
      return { action, table, since: (since as string) ?? null };
    }
    case "wipe":
      return { action, table };
    case "batchCreate":
    case "batchUpsert": {
      const rows = (obj as { rows?: unknown }).rows;
      if (!Array.isArray(rows)) throw new ValidationError("'rows' must be an array.");
      // batchUpsert needs ids to be idempotent; batchCreate may omit (server generates).
      const requireId = action === "batchUpsert";
      return { action, table, rows: rows.map((r) => sanitizeRow(table, r, requireId)) };
    }
    case "batchUpdate": {
      const updates = (obj as { updates?: unknown }).updates;
      if (!Array.isArray(updates)) throw new ValidationError("'updates' must be an array.");
      return { action, table, updates: updates.map((r) => sanitizeRow(table, r, true)) };
    }
    default:
      throw new ValidationError("Unhandled action.");
  }
}
