# Server E2E runner (PowerShell) — Windows-native equivalent of run_e2e.sh, so the suite
# runs in your PowerShell session without needing bash/Git-Bash on PATH.
# Brings up the local Supabase stack, applies migrations, ensures the Edge Function is
# served, exports the local keys from `supabase status` (never printed), and runs the
# Deno E2E harness. Prereqs: Docker, Supabase CLI, Deno. Usage:  ./supabase/tests/run_e2e.ps1
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location $RepoRoot

foreach ($tool in 'supabase','deno','docker') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Write-Error "$tool not found on PATH. Install it, reopen the terminal, and retry."
  }
}

$serveProc = $null
try {
  Write-Host "==> Starting local Supabase stack (idempotent)..."
  supabase start | Out-Host

  Write-Host "==> Applying migrations (db reset)..."
  supabase db reset | Out-Host

  Write-Host "==> Reading local keys from 'supabase status'..."
  $statusEnv = supabase status -o env
  function Get-StatusVal([string]$name) {
    $m = $statusEnv | Select-String "^$name=`"(.*)`"$"
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return $null }
  }
  $env:SUPABASE_URL              = Get-StatusVal 'API_URL'
  $env:SUPABASE_ANON_KEY         = Get-StatusVal 'ANON_KEY'
  $env:SUPABASE_SERVICE_ROLE_KEY = Get-StatusVal 'SERVICE_ROLE_KEY'
  $env:SUPABASE_JWT_SECRET       = Get-StatusVal 'JWT_SECRET'
  if (-not $env:FUNCTION_URL) { $env:FUNCTION_URL = "$($env:SUPABASE_URL)/functions/v1/api" }
  if (-not $env:SUPABASE_URL -or -not $env:SUPABASE_JWT_SECRET) {
    Write-Error "Could not read API_URL/JWT_SECRET from 'supabase status -o env'."
  }
  Write-Host "    SUPABASE_URL=$($env:SUPABASE_URL)"
  Write-Host "    FUNCTION_URL=$($env:FUNCTION_URL)  (keys loaded, not shown)"

  # Probe the function; a 401 (verify_jwt gate) counts as reachable. Serve only if needed.
  function Probe {
    return (curl.exe -s -o NUL -w "%{http_code}" -X POST $env:FUNCTION_URL `
      -H "apikey: $($env:SUPABASE_ANON_KEY)" -H "Content-Type: application/json" --data '{}' 2>$null)
  }
  $code = Probe
  if ($code -eq '000' -or $code -eq '404') {
    Write-Host "==> Function not auto-served (HTTP $code); starting 'supabase functions serve api'..."
    $serveProc = Start-Process supabase -ArgumentList 'functions','serve','api' -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 1; $code = Probe
      if ($code -ne '000' -and $code -ne '404') { break }
    }
  }
  Write-Host "==> Function reachable (HTTP $code)."

  Write-Host "==> Running Deno E2E harness..."
  deno test --allow-net --allow-env supabase/tests/e2e.test.ts
  Write-Host "==> E2E PASSED."
}
finally {
  if ($serveProc) { Stop-Process -Id $serveProc.Id -ErrorAction SilentlyContinue }
}
