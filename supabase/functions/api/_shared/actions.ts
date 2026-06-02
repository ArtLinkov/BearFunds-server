// Pure action router. Translates the validated contract request into calls on a
// DbExecutor (injected) so the routing/envelope logic is unit-testable without a
// network or a live database. family_id is NEVER set here — it is server-derived by
// the DB trigger + RLS. wipe is test-context only.

import { PHYSICAL } from "./contract.ts";
import { ApiRequest, ValidationError } from "./validation.ts";

export interface DbExecutor {
  read(physicalTable: string, since: string | null): Promise<unknown[]>;
  insert(physicalTable: string, rows: Record<string, unknown>[]): Promise<unknown[]>;
  update(physicalTable: string, id: string, changed: Record<string, unknown>): Promise<unknown[]>;
  upsert(physicalTable: string, rows: Record<string, unknown>[]): Promise<unknown[]>;
  wipe(physicalTable: string): Promise<number>;
}

export interface ActionContext {
  isTest: boolean;
}

export async function runAction(
  req: ApiRequest,
  db: DbExecutor,
  ctx: ActionContext,
): Promise<unknown> {
  const physical = PHYSICAL[req.table];

  switch (req.action) {
    case "read":
      return await db.read(physical, req.since);

    case "batchCreate":
      if (req.rows.length === 0) return [];
      return await db.insert(physical, req.rows);

    case "batchUpsert":
      if (req.rows.length === 0) return [];
      return await db.upsert(physical, req.rows);

    case "batchUpdate": {
      if (req.updates.length === 0) return [];
      const results: unknown[] = [];
      for (const u of req.updates) {
        const { id, ...changed } = u as { id: string } & Record<string, unknown>;
        const rows = await db.update(physical, id, changed);
        results.push(...rows);
      }
      return results;
    }

    case "wipe":
      if (!ctx.isTest) {
        throw new ValidationError("wipe is permitted in test context only.");
      }
      return { wiped: await db.wipe(physical) };
  }
}
