<#
.SYNOPSIS
  One-time: build the shared Ubuntu 24.04 base VDI that every AXIOM Linux VM clones from.

.DESCRIPTION
  Step 1  Download the official Ubuntu 24.04 (noble) cloud image (QCOW2) to <VmDir>\noble.img.
          Skipped if a file with a valid QCOW2 magic already exists.
  Step 2  Convert QCOW2 -> VDI (<VmDir>\noble-base.vdi) using qemu-img inside a throwaway
          debian:stable-slim Docker container. The Windows host has no qemu-img, and
          'VBoxManage convertfromraw' rejects qcow2, so the conversion is containerized.
          Skipped if <VmDir>\noble-base.vdi already exists.

  Idempotent. PowerShell 5.1 compatible. Requires Docker Desktop running.

  Per-VM disks are made later by new-linux-vm.ps1 (clonemedium of this base -> resize 20 GB).
  See provisioning/README.md and docs/adr/0002-vm-backend-virtualbox-cloudinit.md.

.PARAMETER VmDir
  Directory that holds VM artifacts (default C:\vms).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\build-base-vdi.ps1
#>
[CmdletBinding()]
param(
    [string]$VmDir = 'C:\vms'
)

$ErrorActionPreference = 'Stop'

# Validated source (the 'noble-server-cloudimg' name 404s under /releases/ - use this one):
$ImageUrl  = 'https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img'
$ImagePath = Join-Path $VmDir 'noble.img'
$BaseVdi   = Join-Path $VmDir 'noble-base.vdi'

function Test-Qcow2Magic {
    # QCOW2 magic bytes: 0x51 0x46 0x49 0xFB ("QFI\xfb")
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4
            $read = $fs.Read($buf, 0, 4)
            if ($read -lt 4) { return $false }
            return ($buf[0] -eq 0x51 -and $buf[1] -eq 0x46 -and $buf[2] -eq 0x49 -and $buf[3] -eq 0xFB)
        } finally {
            $fs.Close()
        }
    } catch {
        return $false
    }
}

Write-Host "=== AXIOM base VDI builder ===" -ForegroundColor Cyan
Write-Host "  VmDir : $VmDir"

# --- Preconditions -----------------------------------------------------------
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
    throw "Docker not found on PATH. Start Docker Desktop and retry (the QCOW2->VDI conversion runs in a container)."
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker is installed but the engine is not responding. Start Docker Desktop and retry."
}

if (-not (Test-Path -LiteralPath $VmDir)) {
    New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
    Write-Host "  Created $VmDir"
}

# --- Step 1: download the cloud image ---------------------------------------
if (Test-Qcow2Magic -Path $ImagePath) {
    Write-Host "[1/2] noble.img present with valid QCOW2 magic - skipping download." -ForegroundColor Green
} else {
    if (Test-Path -LiteralPath $ImagePath) {
        Write-Host "[1/2] noble.img exists but is not a valid QCOW2 - re-downloading." -ForegroundColor Yellow
        Remove-Item -LiteralPath $ImagePath -Force
    } else {
        Write-Host "[1/2] Downloading Ubuntu 24.04 cloud image (~600 MB)..." -ForegroundColor Cyan
    }
    Write-Host "      $ImageUrl"

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $downloaded = $false
    # Prefer BITS (resumable, reliable, shows progress) then fall back to Invoke-WebRequest.
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            Start-BitsTransfer -Source $ImageUrl -Destination $ImagePath -Description 'Ubuntu 24.04 cloud image'
            $downloaded = $true
        } catch {
            Write-Host "      BITS transfer failed ($($_.Exception.Message)); falling back to Invoke-WebRequest." -ForegroundColor Yellow
        }
    }
    if (-not $downloaded) {
        $oldPref = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $ImageUrl -OutFile $ImagePath -UseBasicParsing
        } finally {
            $ProgressPreference = $oldPref
        }
    }

    if (-not (Test-Qcow2Magic -Path $ImagePath)) {
        throw "Downloaded file is not a valid QCOW2 image: $ImagePath"
    }
    Write-Host "      Download OK (valid QCOW2)." -ForegroundColor Green
}

# --- Step 2: convert QCOW2 -> VDI in a container -----------------------------
if (Test-Path -LiteralPath $BaseVdi) {
    Write-Host "[2/2] noble-base.vdi already exists - skipping conversion." -ForegroundColor Green
    Write-Host "      (Delete $BaseVdi and re-run to rebuild.)"
} else {
    Write-Host "[2/2] Converting QCOW2 -> VDI in debian:stable-slim (qemu-img)..." -ForegroundColor Cyan

    # sh script run inside the container. Single-quoted here-string so PowerShell does
    # not expand $ tokens; CRLF is stripped to LF below so /bin/sh does not choke on \r.
    $convert = @'
set -e
apt-get update -qq
apt-get install -y -qq qemu-utils >/dev/null
qemu-img convert -p -f qcow2 -O vdi /work/noble.img /work/noble-base.vdi
'@
    $convert = $convert.Replace("`r`n", "`n").Replace("`r", "`n")

    & docker run --rm -v "${VmDir}:/work" debian:stable-slim sh -c $convert
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $BaseVdi)) {
        throw "qemu-img conversion failed (docker exit $LASTEXITCODE)."
    }
    Write-Host "      Conversion OK." -ForegroundColor Green
}

Write-Host ""
Write-Host "Base image ready: $BaseVdi" -ForegroundColor Green
Write-Host "Next: provision nodes with new-linux-vm.ps1 (see provisioning/README.md)."
