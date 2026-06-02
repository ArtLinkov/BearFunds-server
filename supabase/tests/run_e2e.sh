#!/usr/bin/env bash
# Server E2E runner — brings up the local Supabase stack, applies migrations, ensures the
# Edge Function is served, exports the local keys from `supabase status`, and runs the
# Deno E2E harness. Secrets are read at runtime and never printed or committed.
#
# Prereqs: Docker, Supabase CLI, Deno. Usage: bash supabase/tests/run_e2e.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
SERVE_PID=""
cleanup() { [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

command -v supabase >/dev/null || { echo "ERROR: Supabase CLI not found. Install: https://supabase.com/docs/guides/cli"; exit 1; }
command -v deno     >/dev/null || { echo "ERROR: Deno not found. Install: https://deno.land"; exit 1; }
command -v docker   >/dev/null || { echo "ERROR: Docker not found (required by 'supabase start')."; exit 1; }

echo "==> Starting local Supabase stack (idempotent)…"
supabase start

echo "==> Applying migrations (db reset)…"
supabase db reset

# Export local URLs/keys WITHOUT echoing secrets to the terminal.
echo "==> Reading local keys from 'supabase status'…"
STATUS_ENV="$(supabase status -o env)"
get() { printf '%s\n' "$STATUS_ENV" | sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p"; }
export SUPABASE_URL="$(get API_URL)"
export SUPABASE_ANON_KEY="$(get ANON_KEY)"
export SUPABASE_SERVICE_ROLE_KEY="$(get SERVICE_ROLE_KEY)"
export SUPABASE_JWT_SECRET="$(get JWT_SECRET)"
export FUNCTION_URL="${FUNCTION_URL:-$SUPABASE_URL/functions/v1/api}"
: "${SUPABASE_URL:?could not read API_URL}" "${SUPABASE_JWT_SECRET:?could not read JWT_SECRET}"
echo "    SUPABASE_URL=$SUPABASE_URL"
echo "    FUNCTION_URL=$FUNCTION_URL  (keys loaded, not shown)"

# Ensure the function is reachable; if not, serve it in the background.
probe() { curl -s -o /dev/null -w "%{http_code}" -X POST "$FUNCTION_URL" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" --data '{}' 2>/dev/null || echo 000; }
code="$(probe)"
if [ "$code" = "000" ] || [ "$code" = "404" ]; then
  echo "==> Function not auto-served (HTTP $code); starting 'supabase functions serve api'…"
  supabase functions serve api >/tmp/bf_func_serve.log 2>&1 &
  SERVE_PID=$!
  for i in $(seq 1 30); do
    sleep 1; code="$(probe)"
    [ "$code" != "000" ] && [ "$code" != "404" ] && break
  done
fi
echo "==> Function reachable (HTTP $code)."

echo "==> Running Deno E2E harness…"
deno test --allow-net --allow-env supabase/tests/e2e.test.ts
echo "==> E2E PASSED."
