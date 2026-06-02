// Schema Contract v1.6.0 — the single source of allowed tables, logical->physical
// table mapping, and per-table writable column allowlists (snake_case logical keys).
// Keys the client must never set (tenancy/sync-internal) are stripped, not errored.

export type LogicalTable =
  | "TRANSACTIONS" | "CATEGORIES" | "WALLETS" | "ENTITIES" | "MEMBERS";

export const PHYSICAL: Record<LogicalTable, string> = {
  TRANSACTIONS: "transactions",
  CATEGORIES: "categories",
  WALLETS: "wallets",
  ENTITIES: "entities",
  MEMBERS: "members",
};

// Server-managed / client-derived keys: silently removed from any inbound row.
// family_id & user_id are server-derived (never trusted); updated_at is trigger-managed;
// isDirty is a client-only transient flag that is never persisted.
export const STRIPPED_KEYS = new Set<string>([
  "family_id", "user_id", "updated_at", "isDirty", "is_dirty",
]);

const GLOBAL_WRITABLE = ["id", "deleted", "is_immutable"];

export const WRITABLE: Record<LogicalTable, Set<string>> = {
  TRANSACTIONS: new Set([
    ...GLOBAL_WRITABLE,
    "date", "amount", "currency", "type", "category_id", "sub_category",
    "entity_id", "wallet_id", "member_id", "description", "tags", "status",
  ]),
  CATEGORIES: new Set([
    ...GLOBAL_WRITABLE, "name", "type", "sub_categories", "icon", "color",
  ]),
  WALLETS: new Set([
    ...GLOBAL_WRITABLE, "name", "currency", "icon", "color", "description", "is_default",
  ]),
  ENTITIES: new Set([
    ...GLOBAL_WRITABLE, "name", "aliases", "match_patterns",
    "default_category_id", "default_sub_category", "icon", "color",
  ]),
  MEMBERS: new Set([
    ...GLOBAL_WRITABLE, "name", "role", "is_me", "avatar", "color",
  ]),
};

export const ACTIONS = new Set([
  "read", "batchCreate", "batchUpdate", "batchUpsert", "wipe",
]);

export function isLogicalTable(t: unknown): t is LogicalTable {
  return typeof t === "string" && t in PHYSICAL;
}
