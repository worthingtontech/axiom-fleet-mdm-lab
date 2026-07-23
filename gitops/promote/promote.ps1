<#
.SYNOPSIS
  Canary -> production promotion gate (ADR-0009). Promotes a canary-scoped control
  to the whole fleet ONLY if the telemetry we built says the canary cohort is healthy.

.DESCRIPTION
  Queries Prometheus (the Phase 5 stack) and promotes only when ALL hold for the
  control under test:
    1. telemetry is alive          axiom_exporter_up == 1
    2. the canary cohort exists     axiom_label_hosts{label="canary"} >= MinCanaryHosts
    3. zero canary failures, soaked max_over_time(axiom_policy_failing_hosts{policy=P}[soak]) == 0

  Because the control is canary-scoped (auto-passes on non-canary hosts, ADR-0009),
  axiom_policy_failing_hosts{policy=P} already equals the CANARY failing-host count --
  so the gate reads the global gauge directly.

  PASS  -> (with -Apply) rewrites the control's `query:` in its lib file to the promoted,
           unscoped form and prints the before/after; commit + PR -> CI applies fleet-wide.
        -> (without -Apply) prints "WOULD PROMOTE" and the exact rewrite. Exit 0.
  HOLD  -> prints why (which check failed) and does not touch the file. Exit 1.
  ERROR -> Prometheus unreachable / bad args. Exit 2.

  Runnable locally against the loopback Prometheus; wrapped by .github/workflows/promote.yml
  on the self-hosted runner. PowerShell 5.1 compatible, ASCII-only.

.EXAMPLE
  # dry run (report only):
  ./promote.ps1
.EXAMPLE
  # promote for real (rewrites the lib policy file):
  ./promote.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$Policy        = 'Linux -- auditd running (canary)',
    [string]$PolicyFile    = 'gitops/lib/linux/policies/canary-auditd.yml',
    [string]$PromotedQuery = "SELECT 1 FROM processes WHERE name = 'auditd';",
    [double]$SoakHours     = 2,
    [int]   $MinCanaryHosts = 1,
    [string]$PrometheusUrl = 'http://127.0.0.1:9090',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Invoke-Prom {
    param([string]$Query)
    $u = "$PrometheusUrl/api/v1/query?query=$([uri]::EscapeDataString($Query))"
    try { return (Invoke-RestMethod -TimeoutSec 15 $u).data.result }
    catch { Write-Host "ERROR: Prometheus query failed ($PrometheusUrl): $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
}
function Scalar {
    # PS 5.1 unwraps a 1-element JSON array to a scalar; @() forces an array so
    # single-series instant-vector results read correctly.
    param($result)
    $arr = @($result)
    if ($arr.Count -lt 1 -or $null -eq $arr[0]) { return $null }
    $v = @($arr[0].value)
    if ($v.Count -lt 2) { return $null }
    return [double]$v[1]
}

Write-Host "=== AXIOM canary promotion gate ===" -ForegroundColor Cyan
Write-Host "  control : $Policy"
Write-Host "  soak    : ${SoakHours}h    prometheus: $PrometheusUrl"
Write-Host ""

$reasons = New-Object System.Collections.Generic.List[string]

# 1. telemetry alive
$up = Scalar (Invoke-Prom 'axiom_exporter_up')
Write-Host ("  [1] telemetry alive           axiom_exporter_up = {0}" -f $(if ($null -eq $up) {'<no data>'} else {$up}))
if ($up -ne 1) { $reasons.Add('telemetry not reporting (axiom_exporter_up != 1)') }

# 2. canary cohort populated
$canary = Scalar (Invoke-Prom 'axiom_label_hosts{label="canary"}')
Write-Host ("  [2] canary cohort populated   axiom_label_hosts{{label=canary}} = {0}  (need >= {1})" -f $(if ($null -eq $canary) {0} else {$canary}), $MinCanaryHosts)
if (($null -eq $canary) -or ($canary -lt $MinCanaryHosts)) { $reasons.Add("canary cohort has < $MinCanaryHosts host(s) -- nothing to gate on") }

# 3. zero canary failures, sustained over the soak window
# Prometheus range durations must be INTEGER units -- '0.05h' is a 400. Emit seconds.
$soak = ('{0}s' -f [int]($SoakHours * 3600))
$failQ = 'max_over_time(axiom_policy_failing_hosts{policy="' + $Policy + '"}[' + $soak + '])'
$fail = Scalar (Invoke-Prom $failQ)
Write-Host ("  [3] no canary failures (soak)  max_over_time(failing[{0}]) = {1}" -f $soak, $(if ($null -eq $fail) {'<no data>'} else {$fail}))
if ($null -eq $fail) { $reasons.Add("no failing-host samples for this policy in the last $soak (is it applied? are canary hosts reporting?)") }
elseif ($fail -gt 0) { $reasons.Add("$fail canary host(s) FAILING the control over the soak window") }

Write-Host ""
if ($reasons.Count -gt 0) {
    Write-Host "RESULT: HOLD -- not promoting." -ForegroundColor Yellow
    foreach ($r in $reasons) { Write-Host "  - $r" -ForegroundColor Yellow }
    exit 1
}

Write-Host "RESULT: PROMOTE -- canary healthy over the soak window." -ForegroundColor Green

# Resolve the policy file relative to the repo root (this script lives in gitops/promote/).
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$pf = Join-Path $repoRoot $PolicyFile
if (-not (Test-Path -LiteralPath $pf)) { Write-Host "ERROR: policy file not found: $pf" -ForegroundColor Red; exit 2 }

$content = Get-Content -LiteralPath $pf -Raw
$before = [regex]::Match($content, '(?m)^\s*query:.*$')
$promotedLine = '  query: "' + $PromotedQuery + '"'
# Scriptblock replacement so a `$` in the promoted SQL is never treated as a regex
# substitution token.
$after = [regex]::Replace($content, '(?m)^\s*query:.*$', { param($m) $promotedLine })

Write-Host ""
Write-Host "PROMOTION rewrite for $PolicyFile :" -ForegroundColor Cyan
Write-Host ("  - {0}" -f $before.Value.Trim()) -ForegroundColor DarkGray
Write-Host ("  + {0}" -f $promotedLine.Trim()) -ForegroundColor Green

if ($Apply) {
    Set-Content -LiteralPath $pf -Value $after -NoNewline -Encoding UTF8
    Write-Host ""
    Write-Host "APPLIED: widened the control to fleet-wide scope in $PolicyFile." -ForegroundColor Green
    Write-Host "Next: commit on a branch + open a PR -> CI gitops apply promotes it to production." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "(dry run -- re-run with -Apply to rewrite the file. Nothing changed.)" -ForegroundColor Yellow
}
exit 0
