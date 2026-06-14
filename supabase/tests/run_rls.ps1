# RLS isolation suite runner (PowerShell) - Windows-native equivalent of run_rls.sh, so the
# suite runs in your PowerShell session without needing bash/Git-Bash on PATH.
# Brings up the local Supabase stack, resets to a virgin DB (the suite assumes one - see brain
# Hygiene 2026-06-05), reads DB_URL from 'supabase status' (never printed), and pipes
# rls_isolation.test.sql into Postgres with ON_ERROR_STOP. Prefers a local psql; falls back to
# the supabase_db Docker container. Prereqs: Docker, Supabase CLI (+ optionally psql).
# Usage:  ./supabase/tests/run_rls.ps1
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location $RepoRoot
$Suite = "supabase/tests/rls_isolation.test.sql"
if (-not (Test-Path $Suite)) { Write-Error "Suite not found: $Suite" }

foreach ($tool in 'supabase','docker') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Write-Error "$tool not found on PATH. Install it, reopen the terminal, and retry."
  }
}

Write-Host "==> Starting local Supabase stack (idempotent)..."
supabase start | Out-Host

Write-Host "==> Resetting to a virgin DB (the RLS suite assumes one)..."
supabase db reset | Out-Host

Write-Host "==> Reading DB_URL from 'supabase status'..."
$statusEnv = supabase status -o env
$m = $statusEnv | Select-String '^DB_URL="(.*)"$'
if (-not $m) { Write-Error "Could not read DB_URL from 'supabase status -o env' - is the stack running?" }
$DbUrl = $m.Matches[0].Groups[1].Value

if (Get-Command psql -ErrorAction SilentlyContinue) {
  Write-Host "==> Running RLS suite via local psql..."
  psql $DbUrl -v ON_ERROR_STOP=1 -q -f $Suite
} else {
  Write-Host "==> No local psql; running RLS suite via the db container..."
  $Container = (docker ps --filter "name=supabase_db" --format "{{.Names}}" | Select-Object -First 1)
  if (-not $Container) { Write-Error "Could not find a supabase_db container." }
  Get-Content $Suite | docker exec -i $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
}

if ($LASTEXITCODE -ne 0) { Write-Error "RLS isolation suite FAILED (psql exit $LASTEXITCODE)." }
Write-Host "==> RLS isolation suite PASSED."
