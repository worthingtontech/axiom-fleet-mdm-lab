<#
.SYNOPSIS
  Build the AXIOM fleetd agent packages (.deb for Linux, .msi for Windows) --
  reproducibly, from Git, via the fleetdm/fleetctl Docker image.

.DESCRIPTION
  The Windows host's own `fleetctl package` can ONLY build .msi and trips over
  Defender staging osqueryd; the fleetdm/fleetctl Linux container builds every
  type cleanly. Each package bakes in:
    --fleet-certificate  the mkcert ROOT CA (infra/tls/rootCA.pem) -- so osqueryd,
                         which ignores the OS trust store, trusts fleet.axiom.lab.
    --enable-scripts     REQUIRED for Fleet's run-script API + Phase 8
                         auto-remediation (without it: "deploy fleetd with
                         --enable-scripts").
    --fleet-desktop      the Fleet Desktop tray app.

  Output: provisioning/build/build/fleet-osquery_<ver>_amd64.deb + fleet-osquery.msi
  (gitignored -- they carry the enroll secret).

.PARAMETER EnrollSecret
  The global enroll secret. Omit to read it live from the Fleet server via fleetctl
  (requires a configured fleetctl session).

.PARAMETER Types
  Which package types to build (default deb + msi).

.NOTES
  Requires Docker Desktop running. The enroll secret is NEVER written to Git; it is
  only embedded in the (gitignored) package binaries.
#>
[CmdletBinding()]
param(
    [string]$EnrollSecret,
    [string[]]$Types = @('deb', 'msi'),
    [string]$FleetUrl = 'https://fleet.axiom.lab',
    [string]$Image = 'fleetdm/fleetctl'
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Build = Join-Path $PSScriptRoot 'build'
$Tls = Join-Path $Repo 'infra\tls'

if (-not (Test-Path (Join-Path $Tls 'rootCA.pem'))) {
    throw "infra/tls/rootCA.pem not found -- run infra/tls/make-certs.ps1 first."
}
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) { throw "Docker not found on PATH. Start Docker Desktop." }
New-Item -ItemType Directory -Force -Path $Build | Out-Null

# Resolve the enroll secret (param, else read live from Fleet).
if ([string]::IsNullOrWhiteSpace($EnrollSecret)) {
    $fleetctl = Get-Command fleetctl -ErrorAction SilentlyContinue
    if ($null -eq $fleetctl) { throw "No -EnrollSecret and fleetctl not on PATH to read one." }
    $es = (& $fleetctl.Source get enroll_secret) | Out-String
    $EnrollSecret = ([regex]::Match($es, 'secret:\s*(\S+)')).Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($EnrollSecret)) { throw "Could not read enroll secret from Fleet." }
    Write-Host "Read enroll secret from the live Fleet server."
}

foreach ($t in $Types) {
    Write-Host "=== building $t package (--enable-scripts, CA baked) ===" -ForegroundColor Cyan
    & docker run --rm -v "${Build}:/build" -v "${Tls}:/certs:ro" -w /build $Image package `
        --type $t --fleet-desktop --enable-scripts `
        --fleet-url $FleetUrl `
        --enroll-secret $EnrollSecret `
        --fleet-certificate /certs/rootCA.pem
    if ($LASTEXITCODE -ne 0) { throw "$t package build failed (exit $LASTEXITCODE)." }
}

Write-Host ""
Write-Host "Built packages:" -ForegroundColor Green
Get-ChildItem $Build -Recurse -Include *.deb, *.msi | ForEach-Object { Write-Host ("  " + $_.FullName) }
