<#
.SYNOPSIS
  Generate the Windows MDM WSTEP identity CA (cert + key) for Project AXIOM.

.DESCRIPTION
  Fleet's Windows MDM needs a WSTEP identity CA that signs the identity
  certificates issued to enrolling Windows clients. It is SEPARATE from the
  mkcert TLS CA (which secures HTTPS) -- do not reuse that one. Turning Windows
  MDM ON requires this pair; FLEET_SERVER_PRIVATE_KEY alone is not enough.

  Writes infra/mdm/fleet-mdm-win-wstep.{crt,key} (gitignored). The pair is
  bind-mounted read-only into the fleet container at /etc/fleet/mdm and
  referenced by FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT / _KEY in infra/.env.

  Uses OpenSSL inside a Docker container (no host OpenSSL needed). Idempotent:
  refuses to overwrite an existing pair (re-signing would invalidate any
  already-issued client identity certs) unless -Force.

.NOTES
  Windows PowerShell 5.1 compatible. Requires Docker Desktop running.
  After (re)generating: `docker compose -f infra/docker-compose.yml up -d`.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$MdmDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'mdm'   # infra/mdm
$Crt    = Join-Path $MdmDir 'fleet-mdm-win-wstep.crt'
$Key    = Join-Path $MdmDir 'fleet-mdm-win-wstep.key'

if ((Test-Path $Crt) -and -not $Force) {
    Write-Host "WSTEP CA already exists at $Crt -- refusing to overwrite." -ForegroundColor Yellow
    Write-Host "Re-signing invalidates identity certs already issued to enrolled Windows hosts."
    Write-Host "Pass -Force only on a fresh setup with no enrolled Windows MDM hosts."
    exit 0
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) { throw "Docker not found on PATH. Start Docker Desktop." }
New-Item -ItemType Directory -Force -Path $MdmDir | Out-Null

# -traditional => PKCS#1 RSA key (the form Fleet's WSTEP expects). CN/O are cosmetic.
$gen = 'set -e; apt-get update -qq; apt-get install -y -qq openssl >/dev/null; ' +
       'openssl genrsa -traditional -out /mdm/fleet-mdm-win-wstep.key 4096 2>/dev/null; ' +
       "openssl req -x509 -new -nodes -key /mdm/fleet-mdm-win-wstep.key -sha256 -days 3652 " +
       "-out /mdm/fleet-mdm-win-wstep.crt -subj '/CN=Fleet Root CA/C=US/O=Fleet.'; " +
       # 0644 so Fleet (non-root uid 100) can read the bind-mounted key -- genrsa
       # writes 0600 root, which crashes fleet with 'permission denied' on the key.
       "chmod 0644 /mdm/fleet-mdm-win-wstep.key /mdm/fleet-mdm-win-wstep.crt; ls -la /mdm"

& docker run --rm -v "${MdmDir}:/mdm" debian:stable-slim sh -c $gen
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Crt) -or -not (Test-Path $Key)) {
    throw "WSTEP CA generation failed (docker exit $LASTEXITCODE)."
}

Write-Host ""
Write-Host "WSTEP identity CA generated:" -ForegroundColor Green
Write-Host "  $Crt"
Write-Host "  $Key   (SECRET -- gitignored, never commit)"
Write-Host ""
Write-Host "Next: docker compose -f infra/docker-compose.yml up -d   (recreate fleet), then enable"
Write-Host "Windows MDM: PATCH /api/latest/fleet/config {\"mdm\":{\"windows_enabled_and_configured\":true}}"
