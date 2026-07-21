<#
=============================================================================
 Project AXIOM -- infra/scripts/add-hosts-entry.ps1            (run elevated)
=============================================================================
 Adds or updates the hosts-file mapping for fleet.axiom.lab -- the lab's
 zero-dollar substitute for DNS. Every machine that talks to Fleet must
 resolve fleet.axiom.lab to the Docker host; this script manages the Windows
 side (the Docker host itself and any Windows VM). Linux VMs get the
 equivalent /etc/hosts line from cloud-init during provisioning.

 Usage (elevated PowerShell):
   .\add-hosts-entry.ps1                          # -> auto-detected LAN IPv4
   .\add-hosts-entry.ps1 -Loopback                # -> 127.0.0.1
   .\add-hosts-entry.ps1 -IPAddress 192.168.1.50  # -> explicit address

 Which target to use:
   default    On the Docker host: the primary LAN IPv4, auto-detected from
              the default route (never hardcoded -- DHCP can move it; just
              re-run after a lease change). Caddy publishes 443 on all host
              interfaces, so the LAN IP works from the host itself too.
   -Loopback  On the Docker host only: pin to 127.0.0.1 (survives LAN IP
              changes, but that mapping would be wrong on any other device).
   -IPAddress REQUIRED inside a Windows VM: auto-detection there would find
              the VM's own address, but the VM must point at the *Docker
              host's* LAN IP. (-IPAddress wins over -Loopback if both given.)

 Idempotence and safety:
   - Re-running with the same target is a no-op (exit 0, file untouched).
   - A changed target replaces the previous fleet.axiom.lab mapping.
   - Hosts lines that mention OTHER hostnames are preserved -- only the
     fleet.axiom.lab token is managed.
   - A timestamped backup of the hosts file is written to %TEMP% before any
     modification.

 Requires elevation: the hosts file is admin-writable only. The script
 self-checks and exits with a clear message instead of a cryptic
 access-denied error. Windows PowerShell 5.1 compatible (pure ASCII on
 purpose: PS 5.1 reads BOM-less scripts as ANSI, so non-ASCII characters
 would corrupt strings).
=============================================================================
#>
[CmdletBinding()]
param(
    # Map fleet.axiom.lab to 127.0.0.1 instead of the LAN IP (host-only use).
    [switch]$Loopback,

    # Explicit target IP (use inside Windows VMs: the Docker HOST's LAN IP).
    [string]$IPAddress
)

$ErrorActionPreference = 'Stop'

$HostName  = 'fleet.axiom.lab'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Marker    = '# Project AXIOM (managed by infra/scripts/add-hosts-entry.ps1)'

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Get-PrimaryLanIPv4 {
    # The adapter that owns the default route (0.0.0.0/0) is the real LAN
    # NIC -- VirtualBox host-only, WSL and Hyper-V virtual switches never
    # carry a default route, so this reliably skips them.
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

# --- Elevation self-check -----------------------------------------------------
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail ("The hosts file is admin-writable only -- run this from an elevated PowerShell.`n" +
          "       Right-click PowerShell -> 'Run as administrator', then re-run:`n" +
          "       powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"")
}

# --- Resolve the target IP ------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) {
        Fail "'$IPAddress' is not a valid IP address."
    }
    $TargetIp = $parsed.IPAddressToString
    Write-Host "Target: $HostName -> $TargetIp (explicit -IPAddress)"
} elseif ($Loopback) {
    $TargetIp = '127.0.0.1'
    Write-Host "Target: $HostName -> 127.0.0.1 (-Loopback; valid on the Docker host only)"
} else {
    $TargetIp = Get-PrimaryLanIPv4
    if ($null -eq $TargetIp) {
        Fail ("Could not auto-detect a LAN IPv4 (no default route?).`n" +
              "       Re-run with:  .\add-hosts-entry.ps1 -IPAddress 192.168.x.y   (or -Loopback)")
    }
    Write-Host "Target: $HostName -> $TargetIp (auto-detected from the default-route NIC)"
}

# --- Rewrite the hosts file in memory --------------------------------------------
if (-not (Test-Path -Path $HostsPath -PathType Leaf)) {
    Fail "Hosts file not found at '$HostsPath'."
}
$lines   = @(Get-Content -Path $HostsPath)
$kept    = New-Object System.Collections.Generic.List[string]
$found   = $false      # exact desired mapping already present
$changed = $false      # anything dropped/rewritten/appended

foreach ($line in $lines) {
    # Split off any inline comment, then tokenize "IP name1 name2 ...".
    $body    = $line
    $comment = ''
    $hashAt  = $line.IndexOf('#')
    if ($hashAt -ge 0) {
        $body    = $line.Substring(0, $hashAt)
        $comment = $line.Substring($hashAt)
    }
    $tokens = @($body -split '\s+' | Where-Object { $_ -ne '' })

    # Blank lines, pure comments, malformed lines: keep verbatim.
    if ($tokens.Count -lt 2) {
        $kept.Add($line)
        continue
    }

    $ip    = $tokens[0]
    $names = @($tokens[1..($tokens.Count - 1)])

    # Lines that don't mention fleet.axiom.lab pass through untouched.
    # (-contains is case-insensitive for strings, matching hosts semantics.)
    if ($names -notcontains $HostName) {
        $kept.Add($line)
        continue
    }

    # First line that already maps exactly what we want: keep as-is.
    if (($ip -eq $TargetIp) -and ($names.Count -eq 1) -and (-not $found)) {
        $kept.Add($line)
        $found = $true
        continue
    }

    # Stale or duplicate mapping: strip only OUR hostname token; preserve any
    # other hostnames that share the line (drop the line if ours was alone).
    $others = @($names | Where-Object { $_ -ne $HostName })
    if ($others.Count -gt 0) {
        $rebuilt = "$ip`t$($others -join ' ')"
        if ($comment -ne '') { $rebuilt = "$rebuilt  $comment" }
        $kept.Add($rebuilt)
    }
    $changed = $true
}

if (-not $found) {
    $kept.Add("$TargetIp`t$HostName`t$Marker")
    $changed = $true
}

if (-not $changed) {
    Write-Host "OK: hosts file already maps $HostName -> $TargetIp -- nothing to do."
    exit 0
}

# --- Backup, write, flush DNS cache ------------------------------------------------
$backup = Join-Path $env:TEMP ("hosts.axiom-backup-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
Copy-Item -Path $HostsPath -Destination $backup -Force

try {
    # UTF-8 without BOM: byte-identical to ASCII for standard hosts content,
    # and a BOM would break Windows' hosts-file parsing of the first line.
    [System.IO.File]::WriteAllLines($HostsPath, $kept.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Fail ("Failed writing '$HostsPath': $($_.Exception.Message)`n" +
          "       Backup preserved at: $backup")
}

& ipconfig /flushdns | Out-Null

Write-Host "OK: $HostName -> $TargetIp written to hosts file (backup: $backup)."
Write-Host "    Verify:  ping $HostName    then browse https://$HostName once the stack is up."
