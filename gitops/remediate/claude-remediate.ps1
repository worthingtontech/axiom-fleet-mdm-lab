<#
.SYNOPSIS
  Claude-in-the-loop remediation: turn a FAILING Fleet policy into a triaged,
  human-reviewable remediation PR. Closes the detect -> triage -> fix loop.

.DESCRIPTION
  1. Pulls the live compliance state from the Fleet API (policies with failing hosts).
  2. For each failing policy, hands Claude (headless `claude -p`) a tightly-scoped
     brief -- the policy name, its osquery SQL, description, resolution, failing-host
     count, and the repo's remediation conventions -- and asks for: a root-cause
     triage, a concrete remediation (a run-script for Linux, a CSP/profile note for
     Windows/macOS), and a risk/rollback note.
  3. Writes each draft to gitops/remediate/drafts/<slug>.md. With -OpenPr it branches,
     commits the drafts, and opens ONE PR -- a human reviews and merges; Claude never
     applies to the fleet directly.

  Claude is the teammate that does the first-draft toil; the engineer keeps the
  judgement and the merge button. Runnable locally (needs the `claude` CLI signed in);
  wrapped by .github/workflows/claude-remediate.yml on CI (CLAUDE_CODE_OAUTH_TOKEN
  from a Pro/Max subscription, or ANTHROPIC_API_KEY for API billing).

  Design + a worked example: gitops/remediate/README.md.

.PARAMETER MaxPolicies  Cap how many failing policies to draft for in one run (default 5).
.PARAMETER OpenPr       Branch + commit the drafts and open a PR (needs `gh`).
.PARAMETER FleetUrl     Fleet base URL (default https://fleet.axiom.lab).
#>
[CmdletBinding()]
param(
    [int]$MaxPolicies = 5,
    [switch]$OpenPr,
    [string]$FleetUrl = 'https://fleet.axiom.lab'
)
$ErrorActionPreference = 'Stop'

$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($null -eq $claude) { throw "The 'claude' CLI is not on PATH. Install Claude Code, or run this in the claude-remediate.yml workflow." }

# --- Fleet auth: prefer FLEET_API_TOKEN (CI/api-only user), else the fleetctl session token.
$token = $env:FLEET_API_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    $cfg = Get-Content "$env:USERPROFILE\.fleet\config" -Raw -ErrorAction SilentlyContinue
    if ($cfg) { $token = ([regex]::Match($cfg, 'token:\s*(\S+)')).Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($token)) { throw "No Fleet API token (set FLEET_API_TOKEN or run fleetctl login)." }

function Fleet($path) {
    $u = "$FleetUrl/api/latest/fleet$path"
    (& curl.exe -s --ssl-no-revoke -H "Authorization: Bearer $token" $u) | ConvertFrom-Json
}

Write-Host "=== Claude-in-the-loop remediation ===" -ForegroundColor Cyan
$policies = (Fleet '/policies').policies
$failing = @($policies | Where-Object { [int]($_.failing_host_count) -gt 0 } |
    Sort-Object { [int]$_.failing_host_count } -Descending | Select-Object -First $MaxPolicies)

if ($failing.Count -eq 0) {
    Write-Host "No failing policies -- fleet is green. Nothing to remediate." -ForegroundColor Green
    exit 0
}
Write-Host ("Failing policies to triage: {0}" -f $failing.Count) -ForegroundColor Yellow

$draftDir = Join-Path $PSScriptRoot 'drafts'
New-Item -ItemType Directory -Force -Path $draftDir | Out-Null
$drafts = @()

foreach ($p in $failing) {
    $slug = ($p.name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
    Write-Host ("  triaging: {0}  ({1} failing)" -f $p.name, $p.failing_host_count) -ForegroundColor Cyan

    $prompt = @"
You are a client-platform engineer triaging a FAILING FleetDM compliance policy in the AXIOM lab
(self-hosted Fleet Free, osquery via fleetd; policy PASSES when its query returns >=1 row).

Remediation conventions in this repo:
- Linux fixes are idempotent POSIX /bin/sh scripts delivered via Fleet's run-script API (root),
  living under gitops/lib/linux/scripts/ (see install-auditd.sh for the house style).
- Windows/macOS fixes are MDM configuration profiles under gitops/lib/<os>/configuration-profiles/
  (Windows CSP delivery is Premium on Free -- note that if relevant).
- Prefer the smallest change that makes the policy's SQL return a row; never fake the signal.

FAILING POLICY
  name:        $($p.name)
  platform:    $($p.platform)
  failing_hosts: $($p.failing_host_count)
  description: $($p.description)
  resolution:  $($p.resolution)
  osquery SQL: $($p.query)

Produce a concise markdown remediation brief with exactly these sections:
## Triage  (root cause: what the SQL observes and why it's returning 0 rows)
## Remediation  (the concrete fix -- a fenced script or profile snippet, house style)
## Risk & rollback  (blast radius, idempotency, how to revert)
Keep it tight and actionable. No preamble.
"@

    $draft = & $claude.Source -p $prompt --output-format text 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace($draft)) { $draft = "_(claude returned no output; check CLI auth -- CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY)_" }

    $file = Join-Path $draftDir "$slug.md"
    $header = "# Remediation draft: $($p.name)`n`n" +
              "> Auto-drafted by Claude (claude-remediate.ps1) from live Fleet state. " +
              "$($p.failing_host_count) host(s) failing. **Review before merging** -- Claude drafts, a human decides.`n`n" +
              "- platform: ``$($p.platform)```n- policy SQL: ``$($p.query)```n`n---`n`n"
    Set-Content -LiteralPath $file -Value ($header + $draft) -Encoding UTF8
    Write-Host ("    wrote {0}" -f $file) -ForegroundColor Green
    $drafts += $file
}

Write-Host ""
Write-Host ("Drafted {0} remediation brief(s) in {1}" -f $drafts.Count, $draftDir) -ForegroundColor Green

if ($OpenPr) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) { throw "-OpenPr needs the GitHub CLI (gh)." }
    $branch = "remediate/claude-$(Get-Date -Format yyyyMMdd-HHmmss)"
    git checkout -b $branch
    git add gitops/remediate/drafts
    git commit -m "remediate(claude): draft fixes for $($drafts.Count) failing policy(ies)`n`nAuto-drafted by claude-remediate.ps1 from live Fleet state. Human review required."
    git push origin $branch
    gh pr create --fill --base main --head $branch `
        --title "remediate(claude): drafts for $($drafts.Count) failing policy(ies)" `
        --body "Claude triaged the currently-failing Fleet policies and drafted remediation briefs (gitops/remediate/drafts/). **Review, adjust, and merge** the ones you accept -- Claude drafts the toil, you keep the judgement and the merge button."
    Write-Host "Opened PR on $branch." -ForegroundColor Green
}
