<#
=============================================================================
 Project AXIOM -- infra/tls/install-ca-windows.ps1     (Windows VMs, elevated)
=============================================================================
 Installs the lab's mkcert root CA (rootCA.pem, produced on the Docker host
 by infra/tls/make-certs.ps1) into the machine-wide trusted-root store
 (Cert:\LocalMachine\Root), so that orbit, Fleet Desktop, browsers, Edge
 WebView and PowerShell on this VM trust https://fleet.axiom.lab.

 Usage (elevated PowerShell):
   .\install-ca-windows.ps1                     # rootCA.pem next to script
   .\install-ca-windows.ps1 -CertPath C:\provision\rootCA.pem

 Idempotent: the CA's thumbprint is checked first; if it is already present
 in LocalMachine\Root the script exits 0 without touching the store -- safe
 to run repeatedly and from unattend/provisioning pipelines.

 Why LocalMachine\Root (not CurrentUser\Root): the machine store applies to
 every user AND every service on the box and imports silently; the per-user
 store pops an interactive consent dialog -- useless for zero-touch
 provisioning. Machine-store writes are what require elevation.

 --- CRITICAL CAVEAT: osqueryd DOES NOT READ THIS TRUST STORE ---------------
 Per the Phase 0/1 research brief
 (docs/research/2026-07-20-phase0-1-fleet-brief.md): "osqueryd does not use
 the OS system CA store". Inside the fleetd bundle, orbit and Fleet Desktop
 consult the Windows store this script populates -- but osqueryd validates
 TLS only against its own bundled certs.pem. The CA must therefore ALSO be
 baked into the fleetd package at build time:

     fleetctl package --type msi ... --fleet-certificate C:\path\to\rootCA.pem

 Running this script alone produces the classic half-working host: orbit
 checks in, but osquery enrollment fails with a TLS error and no query data
 ever arrives. This script + the baked cert together cover every client.

 Windows PowerShell 5.1 compatible (pure ASCII on purpose: PS 5.1 reads
 BOM-less scripts as ANSI, so non-ASCII characters would corrupt strings).
=============================================================================
#>
[CmdletBinding()]
param(
    # Path to the mkcert PUBLIC root certificate (never rootCA-key.pem).
    [string]$CertPath = (Join-Path $PSScriptRoot 'rootCA.pem')
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# --- Elevation self-check -----------------------------------------------------
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail ("Writing to Cert:\LocalMachine\Root requires elevation.`n" +
          "       Right-click PowerShell -> 'Run as administrator', then re-run:`n" +
          "       powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"")
}

# --- Load + sanity-check the CA file -------------------------------------------
if (-not (Test-Path -Path $CertPath -PathType Leaf)) {
    Fail ("CA file not found: $CertPath`n" +
          "       Generate it on the Docker host with infra\tls\make-certs.ps1 and copy" +
          " rootCA.pem to this VM (or pass -CertPath).")
}

try {
    # X509Certificate2 accepts both PEM and DER encodings of a certificate.
    $ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
} catch {
    Fail "Could not parse '$CertPath' as a certificate: $($_.Exception.Message)"
}

# A root CA is self-signed (Subject == Issuer). Anything else means the
# operator grabbed the fleet.axiom.lab LEAF by mistake -- trusting a leaf in
# the Root store is wrong (breaks on every leaf re-issue) and hides the bug.
if ($ca.Subject -ne $ca.Issuer) {
    Fail ("'$CertPath' is not a self-signed root CA (Subject != Issuer).`n" +
          "       Pass mkcert's rootCA.pem -- NOT the fleet.axiom.lab leaf certificate.")
}

# --- Idempotence: already trusted? ---------------------------------------------
$installedPath = "Cert:\LocalMachine\Root\$($ca.Thumbprint)"
if (Test-Path -Path $installedPath) {
    Write-Host "OK: CA already trusted (thumbprint $($ca.Thumbprint)) -- nothing to do."
    exit 0
}

# --- Import into the machine-wide trusted-root store ----------------------------
Import-Certificate -FilePath $CertPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
if (-not (Test-Path -Path $installedPath)) {
    Fail 'Import-Certificate ran but the CA is not visible in Cert:\LocalMachine\Root.'
}

Write-Host "OK: installed '$($ca.Subject)' into Cert:\LocalMachine\Root"
Write-Host "    Thumbprint: $($ca.Thumbprint)"
Write-Host "    Expires   : $($ca.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host ''
Write-Host 'REMINDER: this trusts orbit / Fleet Desktop / browsers only. osqueryd'
Write-Host 'ignores the OS store -- the CA must ALSO be baked into the fleetd MSI:'
Write-Host '    fleetctl package --type msi ... --fleet-certificate C:\path\to\rootCA.pem'
