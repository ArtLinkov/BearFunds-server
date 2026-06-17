#!/usr/bin/env bash
# google_avatar suite runner -- pipes google_avatar.test.sql into the local
# Supabase Postgres with ON_ERROR_STOP, resolving the connection the same way
# in CI and locally. The suite ASSUMES A VIRGIN DB: run `supabase db reset`
# immediately before this script (see brain Hygiene 2026-06-05).
#
# Prereqs: a running local Supabase stack (`supabase start`), plus either a
# psql client on the PATH or Docker (falls back to exec into the db container).
# Usage: bash supabase/tests/run_rls.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
SUITE="supabase/tests/google_avatar.test.sql"
[ -f "$SUITE" ] || { echo "ERROR: $SUITE not found."; exit 1; }

command -v supabase >/dev/null || { echo "ERROR: Supabase CLI not found."; exit 1; }

echo "==> Reading DB_URL from 'supabase status'..."
STATUS_ENV="$(supabase status -o env)"
DB_URL="$(printf '%s\n' "$STATUS_ENV" | sed -n 's/^DB_URL="\(.*\)"$/\1/p')"
: "${DB_URL:?could not read DB_URL -- is the local stack running? (supabase start)}"

if command -v psql >/dev/null; then
  echo "==> Running google_avatar suite via local psql..."
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$SUITE"
else
  echo "==> No local psql; running google_avatar suite via the db container..."
  CONTAINER="$(docker ps --filter "name=supabase_db" --format '{{.Names}}' | head -n 1)"
  : "${CONTAINER:?could not find a supabase_db container}"
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$SUITE"
fi

echo "==> google_avatar suite PASSED."
