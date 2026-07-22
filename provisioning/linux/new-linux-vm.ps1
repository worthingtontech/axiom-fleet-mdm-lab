<#
.SYNOPSIS
  Provision one AXIOM Ubuntu 24.04 Linux VM under VirtualBox that enrolls into Fleet on
  first boot via cloud-init (NoCloud seed ISO). Reusable + idempotent.

.DESCRIPTION
  Parameterizes the validated gpu-node-1 recipe. Per invocation it:
    1. Picks the tier cloud-init template (standard | elevated).
    2. Substitutes __HOSTNAME__ and inlines the mkcert root CA into __ROOTCA_PEM__.
    3. Writes user-data + meta-data into <VmDir>\seed-<Name>\ and copies the fleetd .deb in.
    4. Builds the CIDATA NoCloud seed ISO in a debian:stable-slim container
       (LF-normalizing user-data/meta-data first). The .deb rides ON the ISO.
    5. Clones the shared base VDI, resizes to 20 GB, creates + configures the VM
       (NAT nic, EFI, serial log, --paravirtprovider kvm), attaches disk + seed, boots headless.

  Idempotent: an existing VM of the same Name (and its stale disk) is torn down first.
  Tolerant of the transient 'VirtualBox.xml VERR_ACCESS_DENIED' register error (verifies
  via showvminfo instead of trusting createvm's exit code).

  Requires: VirtualBox, Docker Desktop running, and the base VDI built by build-base-vdi.ps1.
  PowerShell 5.1 compatible. See provisioning/README.md + docs/adr/0002-*.

.PARAMETER Name        VM / hostname (required). e.g. gpu-node-2
.PARAMETER MemoryMB    RAM in MB (default 2048).
.PARAMETER Cpus        vCPUs (default 2).
.PARAMETER Tier        'standard' or 'elevated' (default 'standard'). Elevated adds the
                       /etc/axiom trust-tier markers for the high-trust-enclave label.
.PARAMETER DebPath     fleetd .deb to bake onto the seed (default: the built package).
.PARAMETER RootCaPath  mkcert root CA to trust at OS level (default infra/tls/rootCA.pem).
.PARAMETER VmDir       VM artifact directory (default C:\vms).

.EXAMPLE
  .\new-linux-vm.ps1 -Name gpu-node-2
.EXAMPLE
  .\new-linux-vm.ps1 -Name ml-workstation -MemoryMB 3072
.EXAMPLE
  .\new-linux-vm.ps1 -Name enclave-01 -Tier elevated
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [int]$MemoryMB = 2048,
    [int]$Cpus = 2,

    [ValidateSet('standard', 'elevated')]
    [string]$Tier = 'standard',

    # Add the host to the canary cohort: drops /etc/axiom/canary, which the `canary`
    # dynamic label + canary-scoped controls key on (ADR-0009 progressive rollout).
    # Independent of -Tier (a host can be standard-tier AND canary).
    [switch]$Canary,

    [string]$DebPath = 'C:\Users\Sherlock\Documents\Code\fleetDM_fullLab\provisioning\build\build\fleet-osquery_1.58.0_amd64.deb',
    [string]$RootCaPath = 'C:\Users\Sherlock\Documents\Code\fleetDM_fullLab\infra\tls\rootCA.pem',
    [string]$VmDir = 'C:\vms'
)

$ErrorActionPreference = 'Stop'

$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Write-TextFileNoBom {
    # cloud-init YAML must be BOM-free or the parser chokes on the first line.
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Invoke-VBox {
    param(
        [Parameter(Mandatory = $true)][string[]]$VBoxArgs,
        [switch]$Tolerate
    )
    Write-Host "    VBoxManage $($VBoxArgs -join ' ')" -ForegroundColor DarkGray
    # PS 5.1 gotcha: a native command's stderr under EAP='Stop' is promoted to a
    # TERMINATING error, which would defeat -Tolerate (e.g. the benign
    # 'VirtualBox.xml VERR_ACCESS_DENIED' lock warning that createvm emits while
    # still registering the VM). Relax EAP and fold stderr into output so the
    # outcome is judged purely by the exit code.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $VBoxManage @VBoxArgs 2>&1 | Out-Host
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($code -ne 0 -and -not $Tolerate) {
        throw "VBoxManage failed (exit $code): $($VBoxArgs -join ' ')"
    }
    return $code
}

function Test-VmExists {
    param([string]$VmName)
    # 'list vms' always exits 0, so it can't throw under EAP='Stop' the way
    # 'showvminfo <absent-vm>' does (stderr + non-zero). Match the quoted name.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $vms = (& $VBoxManage list vms 2>&1 | Out-String) } finally { $ErrorActionPreference = $prevEAP }
    return ($vms -match ('"' + [regex]::Escape($VmName) + '"'))
}

function Remove-FileWithRetry {
    # VBox can hold a brief lock on a disk file after poweroff/unregister.
    param([string]$Path, [int]$Attempts = 12)
    for ($i = 0; $i -lt $Attempts; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (Test-Path -LiteralPath $Path) {
        throw "Could not delete locked file after $Attempts attempts: $Path"
    }
}

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
Write-Host "=== AXIOM new-linux-vm: $Name ($Tier, ${MemoryMB}MB, ${Cpus}cpu) ===" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $VBoxManage)) {
    throw "VBoxManage not found at $VBoxManage. Install VirtualBox 7.1 or fix the path."
}
if (-not (Test-Path -LiteralPath $DebPath)) {
    throw "fleetd .deb not found: $DebPath (build it first, or pass -DebPath)."
}
if (-not (Test-Path -LiteralPath $RootCaPath)) {
    throw "Root CA not found: $RootCaPath (pass -RootCaPath)."
}
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
    throw "Docker not found on PATH. Start Docker Desktop (the seed ISO is built in a container)."
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker engine not responding. Start Docker Desktop and retry."
}

$BaseVdi = Join-Path $VmDir 'noble-base.vdi'
if (-not (Test-Path -LiteralPath $BaseVdi)) {
    throw "Base image missing: $BaseVdi`nRun build-base-vdi.ps1 first (one-time)."
}

$TemplateName = "user-data.$Tier.yaml"
$TemplatePath = Join-Path (Join-Path $ScriptDir 'cloud-init') $TemplateName
if (-not (Test-Path -LiteralPath $TemplatePath)) {
    throw "cloud-init template not found: $TemplatePath"
}

if (-not (Test-Path -LiteralPath $VmDir)) {
    New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
}

# Derived paths
$SeedDir    = Join-Path $VmDir "seed-$Name"
$IsoPath    = Join-Path $VmDir "seed-$Name.iso"
$VmVdi      = Join-Path $VmDir "$Name.vdi"
$SerialLog  = Join-Path $VmDir "$Name-serial.log"

# ----------------------------------------------------------------------------
# 1-2. Render cloud-init (substitute hostname + inline root CA)
# ----------------------------------------------------------------------------
Write-Host "[1/5] Rendering cloud-init ($TemplateName)..." -ForegroundColor Cyan

$userData = Get-Content -LiteralPath $TemplatePath -Raw
$userData = $userData.Replace('__HOSTNAME__', $Name)

# -Canary: inject the canary cohort sentinel (ADR-0009). Appended as the first
# write_files entry (no `$` in the block, so regex replacement is literal-safe).
if ($Canary) {
    $canaryBlock = "write_files:`n  # AXIOM canary cohort sentinel (ADR-0009 progressive rollout).`n  - path: /etc/axiom/canary`n    content: `"`"`n    permissions: '0644'"
    $userData = [regex]::Replace($userData, '(?m)^write_files:\s*$', $canaryBlock)
    if ($userData -notmatch '/etc/axiom/canary') {
        throw "Canary marker injection failed (no 'write_files:' anchor in $TemplateName)."
    }
    Write-Host "      [canary] host will join the canary cohort (/etc/axiom/canary)." -ForegroundColor Yellow
}

# NOTE: the mkcert CA is baked into the fleetd .deb at build time
# (fleetctl package --fleet-certificate), which is all enrollment needs. We do NOT
# inline it into cloud-init ca_certs -- an earlier attempt did, but the placeholder
# also appeared in template comments and the global replace corrupted the YAML.

if ($userData.Contains('__HOSTNAME__')) {
    throw "Template substitution incomplete - __HOSTNAME__ remains in user-data."
}

$metaData = "instance-id: $Name`nlocal-hostname: $Name`n"

# ----------------------------------------------------------------------------
# 2. Idempotent teardown FIRST -- a running VM holds a lock on its seed ISO, so it
#    must be powered off before we (re)build the seed. Phase 6 destroy-&-recreate
#    depends on this ordering.
# ----------------------------------------------------------------------------
Write-Host "[2/5] Reconciling any existing VM/disk named '$Name' ..." -ForegroundColor Cyan
if (Test-VmExists -VmName $Name) {
    Invoke-VBox -VBoxArgs @('controlvm', $Name, 'poweroff') -Tolerate | Out-Null
    Invoke-VBox -VBoxArgs @('unregistervm', $Name, '--delete') -Tolerate | Out-Null
}
if (Test-Path -LiteralPath $VmVdi) {
    Invoke-VBox -VBoxArgs @('closemedium', 'disk', $VmVdi, '--delete') -Tolerate | Out-Null
    if (Test-Path -LiteralPath $VmVdi) { Remove-FileWithRetry -Path $VmVdi }
}

# ----------------------------------------------------------------------------
# 3. Assemble the seed directory
# ----------------------------------------------------------------------------
Write-Host "[3/5] Writing seed files to $SeedDir ..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

Write-TextFileNoBom -Path (Join-Path $SeedDir 'user-data') -Content $userData
Write-TextFileNoBom -Path (Join-Path $SeedDir 'meta-data') -Content $metaData
Copy-Item -LiteralPath $DebPath -Destination (Join-Path $SeedDir 'fleet-osquery.deb') -Force

# ----------------------------------------------------------------------------
# 4. Build the CIDATA seed ISO in a container (LF-normalize, then genisoimage)
# ----------------------------------------------------------------------------
Write-Host "[4/5] Building CIDATA seed ISO ($IsoPath) ..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $IsoPath) { Remove-Item -LiteralPath $IsoPath -Force }

# Single-quoted here-string (no PowerShell expansion of $f). __NAME__ is filled below;
# CRLF is stripped to LF so /bin/sh does not choke on \r.
$mkiso = @'
set -e
apt-get update -qq
apt-get install -y -qq genisoimage >/dev/null
cd "/work/seed-__NAME__"
for f in user-data meta-data; do tr -d '\r' < "$f" > "$f.lf" && mv "$f.lf" "$f"; done
genisoimage -quiet -volid CIDATA -joliet -rock -output "/work/seed-__NAME__.iso" "/work/seed-__NAME__"
'@
$mkiso = $mkiso.Replace('__NAME__', $Name)
$mkiso = $mkiso.Replace("`r`n", "`n").Replace("`r", "`n")

& docker run --rm -v "${VmDir}:/work" debian:stable-slim sh -c $mkiso
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $IsoPath)) {
    throw "Seed ISO build failed (docker exit $LASTEXITCODE)."
}
Write-Host "      Seed ISO OK (label CIDATA, fleetd .deb baked in)." -ForegroundColor Green

# ----------------------------------------------------------------------------
# 5. Create + boot (teardown already done in step 2)
# ----------------------------------------------------------------------------
Write-Host "[5/5] Creating VM '$Name' ..." -ForegroundColor Cyan

# Unique per-VM disk (own UUID) from the shared base, then grow (cloud-init growpart extends).
Invoke-VBox -VBoxArgs @('clonemedium', 'disk', $BaseVdi, $VmVdi) | Out-Null
Invoke-VBox -VBoxArgs @('modifymedium', 'disk', $VmVdi, '--resize', '20480') | Out-Null

# createvm can print 'Failed to replace ...VirtualBox.xml VERR_ACCESS_DENIED' (transient
# VBoxSVC lock) yet still register the VM. Do NOT trust the exit code - verify below.
Invoke-VBox -VBoxArgs @('createvm', '--name', $Name, '--ostype', 'Ubuntu_64', '--register') -Tolerate | Out-Null
if (-not (Test-VmExists -VmName $Name)) {
    throw "createvm did not register '$Name'. If you saw VirtualBox.xml VERR_ACCESS_DENIED, close the VirtualBox GUI and retry."
}
Write-Host "      VM registered (verified via showvminfo)." -ForegroundColor Green

# NAT nic + EFI + serial-to-file + KVM paravirt (better Linux clock/timing under Hyper-V NEM).
Invoke-VBox -VBoxArgs @('modifyvm', $Name,
    '--memory', "$MemoryMB",
    '--cpus', "$Cpus",
    '--ioapic', 'on',
    '--firmware', 'efi',
    '--nic1', 'nat',
    '--uart1', '0x3F8', '4',
    '--uartmode1', 'file', $SerialLog,
    '--paravirtprovider', 'kvm') | Out-Null

Invoke-VBox -VBoxArgs @('storagectl', $Name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '2') | Out-Null
Invoke-VBox -VBoxArgs @('storageattach', $Name, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $VmVdi) | Out-Null
Invoke-VBox -VBoxArgs @('storageattach', $Name, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $IsoPath) | Out-Null

Invoke-VBox -VBoxArgs @('startvm', $Name, '--type', 'headless') | Out-Null

# ----------------------------------------------------------------------------
# Guidance
# ----------------------------------------------------------------------------
$fleetctl = 'C:\Users\Sherlock\.axiom-tools\fleetctl_v4.89.1_windows_amd64\fleetctl.exe'
Write-Host ""
Write-Host "VM '$Name' booted headless." -ForegroundColor Green
Write-Host ""
Write-Host "First boot under Hyper-V coexistence (NEM) is SLOW: expect enrollment in ~5-8 min."
Write-Host "A one-time CPU soft-lockup warning on the serial console is EXPECTED and recovers."
Write-Host ""
Write-Host "Watch boot / cloud-init:   Get-Content -Wait '$SerialLog'"
Write-Host "Poll enrollment (up to ~600s):"
Write-Host "    `$deadline=(Get-Date).AddSeconds(600)"
Write-Host "    do { & '$fleetctl' get hosts | Select-String '$Name'; Start-Sleep 20 } until ((Get-Date) -gt `$deadline)"
if ($Tier -eq 'elevated') {
    Write-Host ""
    Write-Host "Elevated tier: apply the dynamic label ONCE (re-evals hourly):" -ForegroundColor Yellow
    Write-Host "    & '$fleetctl' apply -f '$($ScriptDir)\labels\high-trust-enclave.label.yaml'"
}
Write-Host ""
Write-Host "Teardown:  & '$VBoxManage' controlvm $Name poweroff ;  & '$VBoxManage' unregistervm $Name --delete"
