<#
.SYNOPSIS
  Provision one AXIOM Windows 11 (Enterprise Eval) VirtualBox VM that installs
  fully headless from an ISO and, at first logon, enrolls into Fleet (osquery +
  Windows MDM). Reusable + idempotent. The Windows sibling of new-linux-vm.ps1.

.DESCRIPTION
  Drives 'VBoxManage unattended install' against a Windows 11 ISO. VirtualBox
  detects the ISO as OSTypeId Windows11_64 and applies its bundled answer-file
  template (UnattendedTemplates\win_nt6_unattended.xml), which for us does three
  things with ZERO registry hacks on our side:
    * writes the LabConfig BypassTPMCheck/BypassSecureBootCheck/BypassRAMCheck/
      BypassStorageCheck/BypassCPUCheck keys in BOTH the windowsPE and specialize
      passes, so the Win11 hardware gate never blocks the install;
    * creates a local admin account, sets SkipMachineOOBE/SkipUserOOBE + AutoLogon
      (so the Microsoft-account OOBE step is never reached, and the box auto-logs
      in -- which is exactly the interactive session Windows MDM requires); and
    * runs our --post-install-command at first logon (via FirstLogonCommands ->
      VBOXPOST.CMD), which we point at first-logon.ps1 on a provisioning ISO.

  Per invocation it:
    1. Builds a small "provisioning" ISO (label AXIOMWIN) carrying \axiom\ with
       first-logon.ps1 + the fleetd MSI + rootCA.pem (built in a debian container
       with genisoimage -- same mechanism new-linux-vm.ps1 uses; the Windows host
       has no mkisofs). This ISO is how the host-side MSI + CA reach the guest.
    2. Tears down any existing VM/disk of the same Name (idempotent).
    3. Creates a Windows11_64 VM: EFI (efi64) + vTPM 2.0 + Secure Boot + 6GB/2CPU
       + NAT + serial log + --paravirtprovider default (Hyper-V paravirt, best for
       Windows guests). Secure Boot is enrolled via modifynvram while powered off.
    4. Runs 'unattended install' (no --start-vm) so VBox stages the answer file +
       install media, wires our --post-install-command, THEN we attach the
       provisioning ISO on its own controller and boot headless.

  What first-logon.ps1 then does inside the guest (see that file): writes the
  hosts entry 10.0.2.2 fleet.axiom.lab, imports rootCA.pem into LocalMachine\Root
  (the OS MDM stack validates Fleet TLS against the machine store -- SEPARATE from
  the --fleet-certificate CA baked into the MSI for osqueryd), silently installs
  the fleetd MSI, and drops a marker. orbit then auto-triggers programmatic
  Windows MDM enrollment (MS-MDE2), completed in the auto-login session.

  Idempotent: an existing VM of the same Name (and its stale disk) is torn down
  first. Tolerant of the transient 'VirtualBox.xml VERR_ACCESS_DENIED' register
  lock (verifies via 'list vms' rather than trusting createvm's exit code).

  Requires: VirtualBox 7.1, Docker Desktop running (for the ISO build), a Win11
  ISO, the fleetd MSI, and rootCA.pem. PowerShell 5.1 compatible, ASCII-only.
  See runbooks/enroll-windows.md and docs/adr/0005-windows-mdm-enablement.md.

  --- NEM / Hyper-V coexistence caveat -------------------------------------------
  Docker Desktop keeps the Windows Hypervisor Platform on, so VirtualBox runs in
  NEM coexistence: SLOW, and reliably only ONE VM at a time. POWER OFF the Linux
  VMs before running this (the script warns and lists any running VMs). A headless
  Win11 install under NEM can take 20-45+ min. This is expected, not a hang.

.PARAMETER Name        VM / hostname (default corp-win-01). ComputerName max 15 chars.
.PARAMETER IsoPath     Windows 11 install ISO (default C:\vms\win11-eval.iso).
.PARAMETER MemoryMB    RAM in MB (default 6144).
.PARAMETER Cpus        vCPUs (default 2).
.PARAMETER MsiPath     fleetd MSI to install in-guest (default: the built package).
.PARAMETER RootCaPath  mkcert root CA for LocalMachine\Root (default infra/tls/rootCA.pem).
.PARAMETER FirstLogonScript  first-logon.ps1 staged onto the provisioning ISO
                             (default: first-logon.ps1 next to this script).
.PARAMETER User        Local admin account created by the answer file (default axiom).
.PARAMETER Password    Password for that account + AutoLogon (LAB DEFAULT -- change
                       before this VM ever leaves the lab).
.PARAMETER ProductKey  Optional product key. LEAVE EMPTY for Enterprise Eval (no key
                       needed). Only a multi-edition retail ISO needs one.
.PARAMETER ImageIndex  WIM edition index (default 1). Confirm with:
                       VBoxManage unattended detect --iso=<iso> --machine-readable
.PARAMETER DiskMB      System disk size in MB (default 65536 = 64 GB).
.PARAMETER VmDir       VM artifact directory (default C:\vms).
.PARAMETER NoSecureBoot  Skip Secure Boot enrollment (the LabConfig bypass makes it
                         optional polish; skip it if it misbehaves under NEM).

.EXAMPLE
  .\new-windows-vm.ps1
.EXAMPLE
  .\new-windows-vm.ps1 -Name corp-win-02 -IsoPath C:\vms\win11-eval.iso
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 15)]
    [string]$Name = 'corp-win-01',

    [string]$IsoPath = 'C:\vms\win11-eval.iso',
    [int]$MemoryMB = 6144,
    [int]$Cpus = 2,

    [string]$MsiPath = 'C:\Users\Sherlock\Documents\Code\fleetDM_fullLab\provisioning\build\build\fleet-osquery.msi',
    [string]$RootCaPath = 'C:\Users\Sherlock\Documents\Code\fleetDM_fullLab\infra\tls\rootCA.pem',
    [string]$FirstLogonScript = '',

    [string]$User = 'axiom',
    [string]$Password = 'P@ssw0rd!23',
    [string]$ProductKey = '',
    [int]$ImageIndex = 1,
    [int]$DiskMB = 65536,

    [string]$VmDir = 'C:\vms',
    [switch]$NoSecureBoot
)

$ErrorActionPreference = 'Stop'

$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($FirstLogonScript)) {
    $FirstLogonScript = Join-Path $ScriptDir 'first-logon.ps1'
}

# ----------------------------------------------------------------------------
# Helpers (same battle-tested patterns as new-linux-vm.ps1)
# ----------------------------------------------------------------------------
function Invoke-VBox {
    param(
        [Parameter(Mandatory = $true)][string[]]$VBoxArgs,
        [switch]$Tolerate
    )
    # Never echo credentials to the console/transcript: mask the value of any
    # password/product-key flag before printing (the args passed to VBoxManage
    # itself are unchanged). The account password is only a lab default, but it
    # is still a credential and must not land in logs.
    $shown = foreach ($a in $VBoxArgs) {
        if ($a -match '^(--user-password|--admin-password|--user-password-file|--admin-password-file|--key)=') {
            ($a -replace '=.*$', '=<redacted>')
        } else { $a }
    }
    Write-Host "    VBoxManage $($shown -join ' ')" -ForegroundColor DarkGray
    # PS 5.1: a native command's stderr under EAP='Stop' is promoted to a
    # TERMINATING error, which would defeat -Tolerate (e.g. the benign
    # 'VirtualBox.xml VERR_ACCESS_DENIED' lock warning createvm can emit while
    # still registering). Relax EAP and fold stderr into output; judge by exit code.
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
    # 'list vms' always exits 0, so it cannot throw under EAP='Stop' the way
    # 'showvminfo <absent-vm>' does. Match the quoted name.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $vms = (& $VBoxManage list vms 2>&1 | Out-String) } finally { $ErrorActionPreference = $prevEAP }
    return ($vms -match ('"' + [regex]::Escape($VmName) + '"'))
}

function Get-RunningVms {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& $VBoxManage list runningvms 2>&1 | Out-String) } finally { $ErrorActionPreference = $prevEAP }
    $names = @()
    foreach ($m in [regex]::Matches($out, '"([^"]+)"')) { $names += $m.Groups[1].Value }
    return $names
}

function Remove-FileWithRetry {
    # VBox can hold a brief lock on a disk/ISO file after poweroff/unregister.
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
Write-Host "=== AXIOM new-windows-vm: $Name (${MemoryMB}MB, ${Cpus}cpu, Win11 Eval) ===" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $VBoxManage)) {
    throw "VBoxManage not found at $VBoxManage. Install VirtualBox 7.1 or fix the path."
}
if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "Windows ISO not found: $IsoPath`nDownload the Win11 Enterprise Eval ISO to that path (see runbooks/enroll-windows.md), or pass -IsoPath."
}
if (-not (Test-Path -LiteralPath $MsiPath)) {
    throw "fleetd MSI not found: $MsiPath (build it first, or pass -MsiPath)."
}
if (-not (Test-Path -LiteralPath $RootCaPath)) {
    throw "Root CA not found: $RootCaPath (pass -RootCaPath)."
}
if (-not (Test-Path -LiteralPath $FirstLogonScript)) {
    throw "first-logon.ps1 not found: $FirstLogonScript (it must sit next to this script, or pass -FirstLogonScript)."
}
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
    throw "Docker not found on PATH. Start Docker Desktop (the provisioning ISO is built in a container)."
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker engine not responding. Start Docker Desktop and retry."
}

if (-not (Test-Path -LiteralPath $VmDir)) {
    New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
}

# NEM concurrency ceiling: warn loudly if other VMs are running.
$running = @(Get-RunningVms | Where-Object { $_ -ne $Name })
if ($running.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: other VMs are RUNNING:" -ForegroundColor Yellow
    foreach ($r in $running) { Write-Host "         - $r" -ForegroundColor Yellow }
    Write-Host "Under Hyper-V coexistence (NEM) VirtualBox reliably runs ONE VM at a time." -ForegroundColor Yellow
    Write-Host "A Win11 install alongside a running VM will crawl or wedge. Power them off first:" -ForegroundColor Yellow
    foreach ($r in $running) { Write-Host "         & '$VBoxManage' controlvm '$r' poweroff" -ForegroundColor Yellow }
    Write-Host "Proceeding anyway in 8s (Ctrl+C to abort)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 8
}

# Derived paths
$VmVdi     = Join-Path $VmDir "$Name.vdi"
$SerialLog = Join-Path $VmDir "$Name-serial.log"
$ProvDir   = Join-Path $VmDir "winprov-$Name"
$ProvPayload = Join-Path $ProvDir 'axiom'
$ProvIso   = Join-Path $VmDir "winprov-$Name.iso"
$AuxDir    = Join-Path $VmDir "unattended-$Name"   # VBox aux media (answer file, VBOXPOST.CMD)

# ----------------------------------------------------------------------------
# 1. Idempotent teardown FIRST (a running VM locks its disk + ISOs)
# ----------------------------------------------------------------------------
Write-Host "[1/6] Reconciling any existing VM/disk named '$Name' ..." -ForegroundColor Cyan
if (Test-VmExists -VmName $Name) {
    Invoke-VBox -VBoxArgs @('controlvm', $Name, 'poweroff') -Tolerate | Out-Null
    Start-Sleep -Seconds 2
    Invoke-VBox -VBoxArgs @('unregistervm', $Name, '--delete') -Tolerate | Out-Null
}
if (Test-Path -LiteralPath $VmVdi) {
    Invoke-VBox -VBoxArgs @('closemedium', 'disk', $VmVdi, '--delete') -Tolerate | Out-Null
    if (Test-Path -LiteralPath $VmVdi) { Remove-FileWithRetry -Path $VmVdi }
}
if (Test-Path -LiteralPath $ProvIso) { Remove-FileWithRetry -Path $ProvIso }
if (Test-Path -LiteralPath $ProvDir) { Remove-Item -LiteralPath $ProvDir -Recurse -Force }
if (Test-Path -LiteralPath $AuxDir)  { Remove-Item -LiteralPath $AuxDir  -Recurse -Force }

# ----------------------------------------------------------------------------
# 2. Build the provisioning ISO (\axiom\ = first-logon.ps1 + MSI + rootCA.pem)
#    This is how the host-side MSI + CA reach the guest at first logon.
# ----------------------------------------------------------------------------
Write-Host "[2/6] Building provisioning ISO ($ProvIso) ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $ProvPayload | Out-Null
Copy-Item -LiteralPath $FirstLogonScript -Destination (Join-Path $ProvPayload 'first-logon.ps1') -Force
Copy-Item -LiteralPath $MsiPath          -Destination (Join-Path $ProvPayload 'fleet-osquery.msi') -Force
Copy-Item -LiteralPath $RootCaPath       -Destination (Join-Path $ProvPayload 'rootCA.pem') -Force

# genisoimage inside a throwaway debian container (Windows host has no mkisofs).
# -J (Joliet) so Windows sees the long/mixed-case names; contents land at ISO root
# so the guest sees \axiom\... exactly. Binary MSI is copied verbatim.
$mkiso = @'
set -e
apt-get update -qq
apt-get install -y -qq genisoimage >/dev/null
genisoimage -quiet -volid AXIOMWIN -joliet -rock -output "/work/winprov-__NAME__.iso" "/work/winprov-__NAME__"
'@
$mkiso = $mkiso.Replace('__NAME__', $Name)
$mkiso = $mkiso.Replace("`r`n", "`n").Replace("`r", "`n")

& docker run --rm -v "${VmDir}:/work" debian:stable-slim sh -c $mkiso
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ProvIso)) {
    throw "Provisioning ISO build failed (docker exit $LASTEXITCODE)."
}
Write-Host "      Provisioning ISO OK (label AXIOMWIN; \axiom\ = first-logon.ps1 + MSI + CA)." -ForegroundColor Green

# ----------------------------------------------------------------------------
# 3. Create the VM + system disk + SATA controller
# ----------------------------------------------------------------------------
Write-Host "[3/6] Creating VM '$Name' (Windows11_64) ..." -ForegroundColor Cyan

# createvm can print 'Failed to replace ...VirtualBox.xml VERR_ACCESS_DENIED'
# (transient VBoxSVC lock) yet still register. Verify with 'list vms', not exit code.
Invoke-VBox -VBoxArgs @('createvm', '--name', $Name, '--ostype', 'Windows11_64', '--register') -Tolerate | Out-Null
if (-not (Test-VmExists -VmName $Name)) {
    throw "createvm did not register '$Name'. If you saw VirtualBox.xml VERR_ACCESS_DENIED, close the VirtualBox GUI and retry."
}
Write-Host "      VM registered (verified via 'list vms')." -ForegroundColor Green

# EFI + vTPM 2.0 + 6GB/2CPU + NAT + serial-to-file + Hyper-V paravirt (best for Windows).
# Exact tokens confirmed on VBoxManage 7.1.4: --tpm-type 2.0, --firmware efi64,
# --paravirtprovider default, --graphicscontroller vboxsvga.
Invoke-VBox -VBoxArgs @('modifyvm', $Name,
    '--memory', "$MemoryMB",
    '--cpus', "$Cpus",
    '--ioapic', 'on',
    '--firmware', 'efi64',
    '--tpm-type', '2.0',
    '--nic1', 'nat',
    '--graphicscontroller', 'vboxsvga',
    '--vram', '128',
    '--uart1', '0x3F8', '4',
    '--uartmode1', 'file', $SerialLog,
    '--paravirtprovider', 'default') | Out-Null

# System disk on a SATA controller (leave spare ports for the install DVD that
# 'unattended install' will attach itself).
Invoke-VBox -VBoxArgs @('createmedium', 'disk', '--filename', $VmVdi, '--size', "$DiskMB", '--format', 'VDI') | Out-Null
Invoke-VBox -VBoxArgs @('storagectl', $Name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '6') | Out-Null
Invoke-VBox -VBoxArgs @('storageattach', $Name, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $VmVdi) | Out-Null

# ----------------------------------------------------------------------------
# 4. Secure Boot enrollment (VM powered off, AFTER firmware efi64). Optional
#    polish: the LabConfig bypass in the answer file makes the install resilient
#    even if the emulated Secure Boot misbehaves under NEM, so tolerate failures.
# ----------------------------------------------------------------------------
if (-not $NoSecureBoot) {
    Write-Host "[4/6] Enrolling Secure Boot keys (modifynvram; tolerated) ..." -ForegroundColor Cyan
    $sbOk = $true
    if ((Invoke-VBox -VBoxArgs @('modifynvram', $Name, 'inituefivarstore')  -Tolerate) -ne 0) { $sbOk = $false }
    if ((Invoke-VBox -VBoxArgs @('modifynvram', $Name, 'enrollmssignatures') -Tolerate) -ne 0) { $sbOk = $false }
    if ((Invoke-VBox -VBoxArgs @('modifynvram', $Name, 'enrollorclpk')       -Tolerate) -ne 0) { $sbOk = $false }
    Invoke-VBox -VBoxArgs @('modifynvram', $Name, 'secureboot', '--enable')  -Tolerate | Out-Null
    if ($sbOk) { Write-Host "      Secure Boot enrolled." -ForegroundColor Green }
    else { Write-Host "      Secure Boot enrollment reported errors (expected under NEM) -- continuing; LabConfig bypass covers the install." -ForegroundColor Yellow }
} else {
    Write-Host "[4/6] Skipping Secure Boot enrollment (-NoSecureBoot)." -ForegroundColor Cyan
}

# ----------------------------------------------------------------------------
# 5. Unattended install (stage only; do NOT auto-start yet). VBox selects the
#    win_nt6_unattended.xml template for a Windows11_64 ISO -> LabConfig bypass +
#    local admin + AutoLogon + our --post-install-command wired into VBOXPOST.CMD.
# ----------------------------------------------------------------------------
Write-Host "[5/6] Staging unattended install from $IsoPath ..." -ForegroundColor Cyan

# The post-install-command runs at FIRST LOGON as one line inside VBOXPOST.CMD
# (a batch file), so use %%d for the FOR variable. It locates the AXIOMWIN
# provisioning ISO by looking for \axiom\first-logon.ps1 across drive letters and
# runs it. No spaces/quotes in the paths -> no PS 5.1 native-arg quoting hazard.
$postCmd = 'for %%d in (D E F G H I J K) do @if exist %%d:\axiom\first-logon.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %%d:\axiom\first-logon.ps1'

$installArgs = @('unattended', 'install', $Name,
    "--iso=$IsoPath",
    "--user=$User",
    "--user-password=$Password",
    "--admin-password=$Password",
    '--full-user-name=AXIOM Admin',
    "--hostname=$Name.axiom.lab",
    '--locale=en_US',
    '--country=US',
    '--language=en-US',
    '--time-zone=UTC',
    "--image-index=$ImageIndex",
    '--no-install-additions',
    "--auxiliary-base-path=$AuxDir\",
    "--post-install-command=$postCmd")
if (-not [string]::IsNullOrWhiteSpace($ProductKey)) {
    $installArgs += "--key=$ProductKey"
}
New-Item -ItemType Directory -Force -Path $AuxDir | Out-Null
Invoke-VBox -VBoxArgs $installArgs | Out-Null

# Attach the provisioning ISO on its OWN controller so it can never collide with
# whatever port 'unattended install' used for the install DVD / aux media.
Invoke-VBox -VBoxArgs @('storagectl', $Name, '--name', 'prov', '--add', 'ide', '--controller', 'PIIX4') | Out-Null
Invoke-VBox -VBoxArgs @('storageattach', $Name, '--storagectl', 'prov', '--port', '0', '--device', '0', '--type', 'dvddrive', '--medium', $ProvIso) | Out-Null

# ----------------------------------------------------------------------------
# 6. Boot headless
# ----------------------------------------------------------------------------
Write-Host "[6/6] Booting '$Name' headless ..." -ForegroundColor Cyan
Invoke-VBox -VBoxArgs @('startvm', $Name, '--type', 'headless') | Out-Null

# ----------------------------------------------------------------------------
# Guidance
# ----------------------------------------------------------------------------
$fleetctl = 'C:\Users\Sherlock\.axiom-tools\fleetctl_v4.89.1_windows_amd64\fleetctl.exe'
Write-Host ""
Write-Host "VM '$Name' booting headless." -ForegroundColor Green
Write-Host ""
Write-Host "TIMELINE (Hyper-V coexistence / NEM is SLOW -- one VM at a time):" -ForegroundColor Yellow
Write-Host "  * Windows Setup + reboots: ~20-45+ min headless. This is expected, not a hang."
Write-Host "  * Then AutoLogon fires -> FirstLogonCommands run first-logon.ps1 from the AXIOMWIN"
Write-Host "    ISO: hosts entry + rootCA into LocalMachine\Root + silent fleetd MSI install."
Write-Host "  * orbit auto-triggers Windows MDM enrollment (MS-MDE2); the AutoLogon session IS"
Write-Host "    the signed-in session MDM requires, so no human sign-in is strictly needed."
Write-Host ""
Write-Host "WATCH IT (headless):"
Write-Host "  Screenshot:   & '$VBoxManage' controlvm $Name screenshotpng '$VmDir\$Name.png'"
Write-Host "  Open a window: close this headless session first, or start with --type gui / separate."
Write-Host "  In-guest logs (after it is up): C:\vboxpostinstall.log , C:\axiom-firstlogon.log"
Write-Host ""
Write-Host "VERIFY ENROLLMENT (from the host, fleetctl already --rootca-configured):"
Write-Host "  & '$fleetctl' get hosts                 # $Name appears (platform windows)"
Write-Host "  & '$fleetctl' get hosts --mdm           # lists MDM-enrolled hosts"
Write-Host "  & '$fleetctl' get host $Name            # MDM status should read On"
Write-Host ""
Write-Host "MANUAL FOLLOW-UPS (only if MDM stays Off):" -ForegroundColor Yellow
Write-Host "  * A VM sitting at the LOCK screen reports MDM Off -- sign in (AutoLogon should"
Write-Host "    handle this; if it did not, log in as '$User' once). MDM flips On ~30s after."
Write-Host "  * Confirm the CA landed:  Get-ChildItem Cert:\LocalMachine\Root | ? Subject -like '*mkcert*'"
Write-Host "  * Confirm the service:    Get-Service 'Fleet osquery'"
Write-Host "  * Re-run in-guest if needed:  powershell -ExecutionPolicy Bypass -File <drive>:\axiom\first-logon.ps1"
Write-Host ""
Write-Host "TEARDOWN:  & '$VBoxManage' controlvm $Name poweroff ;  & '$VBoxManage' unregistervm $Name --delete"
Write-Host "           (then delete $ProvIso , $ProvDir\ , $AuxDir\ , $SerialLog if you want a clean slate)"
