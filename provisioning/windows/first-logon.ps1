<#
=============================================================================
 Project AXIOM -- provisioning/windows/first-logon.ps1
=============================================================================
 Runs INSIDE the Windows 11 client VM at first logon, launched by VirtualBox's
 unattended-install FirstLogonCommands hook (VBOXPOST.CMD) via the
 --post-install-command wired by new-windows-vm.ps1. It is staged onto the
 AXIOMWIN provisioning ISO alongside the fleetd MSI + rootCA.pem, so this script
 resolves those payload files from its OWN directory ($PSScriptRoot) -- no
 hard-coded drive letter.

 It performs the three things the MSI alone does NOT guarantee, then installs
 fleetd:
   1. hosts entry  10.0.2.2  fleet.axiom.lab   (VirtualBox NAT maps 10.0.2.2 to
      the host loopback, where Caddy publishes :443; TLS still validates on the
      SAN hostname). Idempotent.
   2. import rootCA.pem into Cert:\LocalMachine\Root -- the Windows OS MDM stack
      (omadmclient / MS-MDE2) validates Fleet's TLS against the MACHINE store.
      This is SEPARATE from the --fleet-certificate CA baked into the MSI (which
      only covers osqueryd, which ignores the OS store). Idempotent (thumbprint).
   3. msiexec /i fleet-osquery.msi /quiet /norestart  -- installs orbit +
      osqueryd ('Fleet osquery' service). Because Windows MDM is enabled
      server-side and the enroll secret + CA are baked into the MSI, orbit then
      auto-triggers programmatic Windows MDM enrollment (no 'Access work or
      school' step). MDM completes in the AutoLogon session that is running this.

 Then it writes a marker (C:\axiom\first-logon.done) and prints follow-ups.

 Runs elevated automatically inside FirstLogonCommands. Safe to re-run by hand
 from an elevated shell:
   powershell -ExecutionPolicy Bypass -File <drive>:\axiom\first-logon.ps1

 PowerShell 5.1 compatible, ASCII-only (PS 5.1 reads BOM-less scripts as ANSI).
 See docs/adr/0005-windows-mdm-enablement.md and runbooks/enroll-windows.md.
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$FleetHost = 'fleet.axiom.lab',
    [string]$NatIp     = '10.0.2.2',
    # Payload files (default: siblings of this script on the provisioning ISO).
    [string]$MsiPath   = '',
    [string]$RootCaPath = ''
)

# Never abort the whole first-logon on a single soft failure -- we want the log
# and the marker to reflect exactly how far we got. We track failures ourselves.
$ErrorActionPreference = 'Continue'

# --- Resolve our own location (works under -File and dot-sourcing) --------------
$Here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Here)) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($MsiPath))    { $MsiPath    = Join-Path $Here 'fleet-osquery.msi' }
if ([string]::IsNullOrWhiteSpace($RootCaPath)) { $RootCaPath = Join-Path $Here 'rootCA.pem' }

# --- Working dir + logging ------------------------------------------------------
$Work = 'C:\axiom'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Log = Join-Path $Work 'first-logon.log'

function Log([string]$Message, [string]$Color = 'Gray') {
    $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -Path $Log -Value $line
    Write-Host $line -ForegroundColor $Color
}

Log '=== AXIOM first-logon starting ===' 'Cyan'
Log ("script dir : {0}" -f $Here)
Log ("MSI        : {0}" -f $MsiPath)
Log ("rootCA     : {0}" -f $RootCaPath)

$fail = 0

# Elevation note (FirstLogonCommands already run elevated; matters only for manual re-runs).
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log 'WARNING: not elevated -- hosts edit, CA import and MSI install need admin. Re-run from an elevated shell.' 'Yellow'
}

# --- Persist payload to C:\axiom (so it survives the ISO being ejected) ---------
try {
    if (Test-Path -LiteralPath $MsiPath) {
        Copy-Item -LiteralPath $MsiPath -Destination (Join-Path $Work 'fleet-osquery.msi') -Force
        $MsiLocal = Join-Path $Work 'fleet-osquery.msi'
    } else {
        Log "ERROR: MSI not found at $MsiPath" 'Red'; $fail++; $MsiLocal = $MsiPath
    }
    if (Test-Path -LiteralPath $RootCaPath) {
        Copy-Item -LiteralPath $RootCaPath -Destination (Join-Path $Work 'rootCA.pem') -Force
        $CaLocal = Join-Path $Work 'rootCA.pem'
    } else {
        Log "ERROR: rootCA.pem not found at $RootCaPath" 'Red'; $fail++; $CaLocal = $RootCaPath
    }
} catch {
    Log ("ERROR staging payload: {0}" -f $_.Exception.Message) 'Red'; $fail++
}

# --- 1. hosts entry  10.0.2.2  fleet.axiom.lab  (idempotent) --------------------
Log ('[1/3] hosts entry {0} -> {1} ...' -f $FleetHost, $NatIp) 'Cyan'
try {
    $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $lines = @()
    if (Test-Path -LiteralPath $HostsPath) { $lines = @(Get-Content -LiteralPath $HostsPath) }
    $already = $false
    foreach ($l in $lines) {
        $body = $l
        $h = $l.IndexOf('#'); if ($h -ge 0) { $body = $l.Substring(0, $h) }
        $tok = @($body -split '\s+' | Where-Object { $_ -ne '' })
        if ($tok.Count -ge 2 -and ($tok[1..($tok.Count-1)] -contains $FleetHost)) {
            if ($tok[0] -eq $NatIp) { $already = $true }
        }
    }
    if ($already) {
        Log ('      already maps {0} -> {1} -- nothing to do.' -f $FleetHost, $NatIp) 'Green'
    } else {
        # Preserve any lines that mention OTHER hostnames; drop only stale fleet.axiom.lab.
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($l in $lines) {
            $body = $l; $comment = ''
            $h = $l.IndexOf('#'); if ($h -ge 0) { $body = $l.Substring(0, $h); $comment = $l.Substring($h) }
            $tok = @($body -split '\s+' | Where-Object { $_ -ne '' })
            if ($tok.Count -lt 2) { $kept.Add($l); continue }
            if ($tok[1..($tok.Count-1)] -notcontains $FleetHost) { $kept.Add($l); continue }
            $others = @($tok[1..($tok.Count-1)] | Where-Object { $_ -ne $FleetHost })
            if ($others.Count -gt 0) {
                $rebuilt = "$($tok[0])`t$($others -join ' ')"
                if ($comment -ne '') { $rebuilt = "$rebuilt  $comment" }
                $kept.Add($rebuilt)
            }
        }
        $kept.Add("$NatIp`t$FleetHost`t# Project AXIOM (first-logon.ps1)")
        [System.IO.File]::WriteAllLines($HostsPath, $kept.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        & ipconfig /flushdns | Out-Null
        Log ('      wrote {0} -> {1}' -f $FleetHost, $NatIp) 'Green'
    }
} catch {
    Log ("ERROR editing hosts: {0}" -f $_.Exception.Message) 'Red'; $fail++
}

# --- 2. import rootCA.pem into Cert:\LocalMachine\Root  (idempotent) ------------
Log '[2/3] import rootCA.pem into LocalMachine\Root ...' 'Cyan'
try {
    if (-not (Test-Path -LiteralPath $CaLocal)) {
        Log "ERROR: CA file missing: $CaLocal" 'Red'; $fail++
    } else {
        $ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaLocal)
        if ($ca.Subject -ne $ca.Issuer) {
            Log 'ERROR: that is not a self-signed root CA (Subject != Issuer). Refusing to trust a leaf.' 'Red'; $fail++
        } else {
            $installedPath = "Cert:\LocalMachine\Root\$($ca.Thumbprint)"
            if (Test-Path -LiteralPath $installedPath) {
                Log ("      CA already trusted (thumbprint {0}) -- nothing to do." -f $ca.Thumbprint) 'Green'
            } else {
                Import-Certificate -FilePath $CaLocal -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
                if (Test-Path -LiteralPath $installedPath) {
                    Log ("      trusted '{0}' (thumbprint {1}, expires {2})" -f $ca.Subject, $ca.Thumbprint, $ca.NotAfter.ToString('yyyy-MM-dd')) 'Green'
                } else {
                    Log 'ERROR: Import-Certificate ran but the CA is not in LocalMachine\Root.' 'Red'; $fail++
                }
            }
        }
    }
} catch {
    Log ("ERROR importing CA: {0}" -f $_.Exception.Message) 'Red'; $fail++
}

# --- 3. silent fleetd MSI install ----------------------------------------------
Log '[3/3] installing fleetd MSI (silent) ...' 'Cyan'
try {
    if (-not (Test-Path -LiteralPath $MsiLocal)) {
        Log "ERROR: MSI missing: $MsiLocal" 'Red'; $fail++
    } else {
        # MSI is prebaked with the enroll secret + mkcert CA -> NO MSI properties
        # (no FLEET_URL / ENROLL_SECRET). Just install elevated + verbose log.
        $msiLog = Join-Path $Work 'fleetd-install.log'
        $mArgs = "/i `"$MsiLocal`" /quiet /norestart /l*v `"$msiLog`""
        $p = Start-Process msiexec.exe -ArgumentList $mArgs -Wait -PassThru
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Log ("      msiexec exit {0} (OK). Verbose log: {1}" -f $p.ExitCode, $msiLog) 'Green'
        } else {
            Log ("ERROR: msiexec exit {0} (see {1})" -f $p.ExitCode, $msiLog) 'Red'; $fail++
        }
        # The 'Fleet osquery' service can take a few seconds to register.
        $svc = $null
        for ($i = 0; $i -lt 12; $i++) {
            $svc = Get-Service -Name 'Fleet osquery' -ErrorAction SilentlyContinue
            if ($null -eq $svc) { $svc = Get-Service -DisplayName 'Fleet osquery' -ErrorAction SilentlyContinue }
            if ($null -ne $svc) { break }
            Start-Sleep -Seconds 5
        }
        if ($null -ne $svc) { Log ("      service 'Fleet osquery' present -- status {0}" -f $svc.Status) 'Green' }
        else { Log "      NOTE: 'Fleet osquery' service not visible yet (may still be starting)." 'Yellow' }
    }
} catch {
    Log ("ERROR installing MSI: {0}" -f $_.Exception.Message) 'Red'; $fail++
}

# --- Reachability sanity check (non-fatal) -------------------------------------
try {
    $t = Test-NetConnection -ComputerName $FleetHost -Port 443 -WarningAction SilentlyContinue
    if ($t.TcpTestSucceeded) { Log ("      TCP {0}:443 reachable." -f $FleetHost) 'Green' }
    else { Log ("      NOTE: {0}:443 not reachable yet (NAT/host?). orbit will retry." -f $FleetHost) 'Yellow' }
} catch { Log ("      (reachability probe skipped: {0})" -f $_.Exception.Message) 'DarkGray' }

# --- Marker ---------------------------------------------------------------------
$marker = Join-Path $Work 'first-logon.done'
$summary = @(
    "AXIOM first-logon completed $(Get-Date -Format o)",
    "failures: $fail",
    "hosts: $FleetHost -> $NatIp",
    "CA: $CaLocal",
    "MSI: $MsiLocal",
    "log: $Log"
) -join "`r`n"
Set-Content -Path $marker -Value $summary -Encoding ASCII

if ($fail -eq 0) {
    Log '=== AXIOM first-logon DONE (0 failures) ===' 'Green'
    Log 'MDM completes in this AutoLogon session ~30s after orbit checks in.' 'Green'
    Log "Verify from the host:  fleetctl get hosts  /  fleetctl get hosts --mdm" 'Green'
} else {
    Log ("=== AXIOM first-logon finished with {0} failure(s) -- see above ===" -f $fail) 'Yellow'
    Log 'Fix the flagged step and re-run this script from an elevated shell.' 'Yellow'
}

exit $fail
