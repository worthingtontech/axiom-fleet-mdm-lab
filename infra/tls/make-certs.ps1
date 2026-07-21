<#
=============================================================================
 Project AXIOM -- infra/tls/make-certs.ps1          (run on the Windows host)
=============================================================================
 Mints every piece of TLS material the lab needs, using mkcert:

   1. Verifies mkcert is installed (install hint below).
   2. Creates + trusts the mkcert local CA if this machine has none yet.
   3. Detects the host's primary LAN IPv4 dynamically -- never hardcoded.
   4. Issues the Caddy leaf certificate with STABLE filenames:
        infra/tls/fleet.axiom.lab.pem       (leaf certificate)
        infra/tls/fleet.axiom.lab-key.pem   (leaf private key)
      SANs: fleet.axiom.lab, <LAN-IP>, localhost, 127.0.0.1 -- every name a
      client might dial must be in the SAN list or hostname verification
      fails even though the signature is valid.
   5. Copies the CA's PUBLIC cert to infra/tls/rootCA.pem for downstream VM
      provisioning (install-ca-linux.sh / install-ca-windows.ps1) and for
      baking into fleetd packages: fleetctl package --fleet-certificate
      (the flag takes the CA, never the leaf -- osqueryd ignores the OS
      trust store, per the Phase 0/1 research brief).
   6. Prints a SAN summary so the result can be eyeballed.

 Windows PowerShell 5.1 compatible (pure ASCII on purpose: PS 5.1 reads
 BOM-less scripts as ANSI, so non-ASCII characters would corrupt strings).
 Idempotent: re-running simply re-issues the leaf (the CA in mkcert's
 CAROOT persists). Re-run this script and `docker compose restart caddy`
 whenever the LAN IP changes (DHCP) or a new SAN is needed -- an existing
 certificate can never be amended.

 SECURITY NOTES
   - rootCA-key.pem (the CA PRIVATE key -- it can sign a trusted cert for
     ANY name) never leaves mkcert's CAROOT. Only the public rootCA.pem is
     copied into the repo tree.
   - Everything this script writes (*.pem) is covered by .gitignore
     (infra/tls/*.pem); only the scripts themselves are committed.
=============================================================================
#>
[CmdletBinding()]
param(
    # Override LAN-IP auto-detection (multi-homed hosts, unusual setups).
    [string]$LanIp
)

$ErrorActionPreference = 'Stop'

$HostName = 'fleet.axiom.lab'
$TlsDir   = $PSScriptRoot                       # infra/tls -- outputs land here regardless of CWD
$CertFile = Join-Path $TlsDir "$HostName.pem"
$KeyFile  = Join-Path $TlsDir "$HostName-key.pem"

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Get-PrimaryLanIPv4 {
    # The adapter that owns the default route (0.0.0.0/0) is the real LAN
    # NIC. VirtualBox host-only, WSL and Hyper-V virtual switches never
    # carry a default route, so this reliably skips them. Lowest combined
    # metric wins when several default routes exist (e.g. Wi-Fi + Ethernet).
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property { $_.RouteMetric + $_.InterfaceMetric } |
        Select-Object -First 1
    if ($null -eq $route) { return $null }

    $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1
    if ($null -eq $addr) { return $null }
    return $addr.IPAddress
}

# --- 1. mkcert installed? ---------------------------------------------------
$mkcert = Get-Command mkcert -ErrorAction SilentlyContinue
if ($null -eq $mkcert) {
    Fail ("mkcert was not found on PATH. Install it and reopen this terminal:`n" +
          "       winget install FiloSottile.mkcert")
}
Write-Host "[1/5] mkcert found: $($mkcert.Source)"

# --- 2. CA present? (mkcert -install = one-time CA creation + host trust) ---
$caroot = (& mkcert -CAROOT | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($caroot)) {
    Fail 'mkcert -CAROOT failed -- cannot locate the mkcert CA directory.'
}
$rootCaSrc = Join-Path $caroot 'rootCA.pem'
if (-not (Test-Path $rootCaSrc)) {
    # First run on this machine: creates the CA keypair in CAROOT and adds
    # rootCA.pem to the host's OS + NSS trust stores (browser-warning-free).
    Write-Host "[2/5] No CA in '$caroot' -- creating and trusting it (mkcert -install)..."
    & mkcert -install
    if ($LASTEXITCODE -ne 0) { Fail 'mkcert -install failed.' }
} else {
    Write-Host "[2/5] mkcert CA already exists: $rootCaSrc (skipping -install)"
}

# --- 3. Detect the primary LAN IPv4 ------------------------------------------
if ([string]::IsNullOrWhiteSpace($LanIp)) {
    $LanIp = Get-PrimaryLanIPv4
    if ($null -eq $LanIp) {
        Fail ("Could not auto-detect a LAN IPv4 (no default route?).`n" +
              "       Re-run with an explicit address:  .\make-certs.ps1 -LanIp 192.168.x.y")
    }
    Write-Host "[3/5] Primary LAN IPv4 (default-route NIC): $LanIp"
} else {
    Write-Host "[3/5] Using operator-supplied LAN IP: $LanIp"
}

# --- 4. Issue the leaf with STABLE filenames ----------------------------------
# -cert-file / -key-file pin the output names so the Caddyfile and compose
# bind mounts never chase mkcert's default "+N" suffix (it would otherwise
# emit fleet.axiom.lab+3.pem / fleet.axiom.lab+3-key.pem for 3 extra SANs).
# Re-running overwrites in place -- a leaf re-issue is cheap; the CA persists.
Write-Host "[4/5] Issuing leaf (SANs: $HostName, $LanIp, localhost, 127.0.0.1)..."
& mkcert -cert-file $CertFile -key-file $KeyFile $HostName $LanIp localhost 127.0.0.1
if ($LASTEXITCODE -ne 0) { Fail 'mkcert leaf generation failed.' }

# --- 5. Publish the CA's PUBLIC cert for downstream provisioning -------------
# Deliberately rootCA.pem ONLY -- rootCA-key.pem stays in CAROOT, always.
Copy-Item -Path $rootCaSrc -Destination (Join-Path $TlsDir 'rootCA.pem') -Force
Write-Host "[5/5] Copied public CA -> $(Join-Path $TlsDir 'rootCA.pem')"

# --- Summary ------------------------------------------------------------------
Write-Host ''
Write-Host '--- Certificate summary ----------------------------------------------'
try {
    $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertFile)
    Write-Host "  Leaf    : $CertFile"
    Write-Host "  Key     : $KeyFile"
    Write-Host "  Issuer  : $($leaf.Issuer)"
    Write-Host ("  Expires : {0:yyyy-MM-dd}" -f $leaf.NotAfter)
    $sanExt = $leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($null -ne $sanExt) {
        Write-Host '  SANs    :'
        # Format($true) renders one entry per line, e.g. "DNS Name=fleet.axiom.lab"
        ($sanExt.Format($true) -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | ForEach-Object {
            Write-Host "            $($_.Trim())"
        }
    }
} catch {
    Write-Warning "Could not parse the generated certificate for display: $($_.Exception.Message)"
}
Write-Host '------------------------------------------------------------------------'
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. If the stack is running:  docker compose restart caddy'
Write-Host '  2. Map the hostname:         infra\scripts\add-hosts-entry.ps1  (elevated)'
Write-Host '  3. VM provisioning uses infra\tls\rootCA.pem via install-ca-linux.sh /'
Write-Host '     install-ca-windows.ps1 -- and fleetd packages MUST bake it in with'
Write-Host '     fleetctl package --fleet-certificate (osqueryd ignores the OS store).'
Write-Host '  4. Never commit *.pem files -- .gitignore already excludes infra/tls/*.pem.'
