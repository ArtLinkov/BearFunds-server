#!/usr/bin/env bash
# Test-family isolation suite runner -- pipes test_family.test.sql into the local Supabase
# Postgres with ON_ERROR_STOP. ASSUMES A VIRGIN DB: run `supabase db reset` immediately
# before this (applies migrations 0001-0011). Prereqs: a running local Supabase stack plus
# either psql on PATH or Docker. Usage: bash supabase/tests/run_test_family.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
SUITE="supabase/tests/test_family.test.sql"
[ -f "$SUITE" ] || { echo "ERROR: $SUITE not found."; exit 1; }
command -v supabase >/dev/null || { echo "ERROR: Supabase CLI not found."; exit 1; }
echo "==> Reading DB_URL from 'supabase status'..."
STATUS_ENV="$(supabase status -o env)"
DB_URL="$(printf '%s\n' "$STATUS_ENV" | sed -n 's/^DB_URL="\(.*\)"$/\1/p')"
: "${DB_URL:?could not read DB_URL -- is the local stack running? (supabase start)}"
if command -v psql >/dev/null; then
  echo "==> Running test-family suite via local psql..."
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$SUITE"
else
  echo "==> No local psql; running via the db container..."
  CONTAINER="$(docker ps --filter "name=supabase_db" --format '{{.Names}}' | head -n 1)"
  : "${CONTAINER:?could not find a supabase_db container}"
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$SUITE"
fi
echo "==> Test-family isolation suite PASSED."
