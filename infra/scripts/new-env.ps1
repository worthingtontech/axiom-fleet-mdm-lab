<#
.SYNOPSIS
    Bootstraps infra\.env for the axiom-core stack (Project AXIOM, Phase 1).

.DESCRIPTION
    1. Copies infra\secrets.example.env to infra\.env -- ONLY if infra\.env
       does not already exist. An existing .env is never touched: it may hold
       a FLEET_SERVER_PRIVATE_KEY that already encrypts MDM assets, and
       regenerating that key would make those assets permanently
       undecryptable.
    2. Replaces every __GENERATE_*__ placeholder token with a fresh
       cryptographically random value (System.Security.Cryptography RNG,
       base64-encoded). A token that appears in multiple lines (the MySQL
       password consumed by both the mysql container and Fleet) is replaced
       with the SAME value everywhere, keeping the pairs in sync.
    3. Writes the result as UTF-8 WITHOUT a BOM and with LF line endings --
       a BOM or stray CR can corrupt the first/every key when docker compose
       parses the env file.

    Windows PowerShell 5.1 compatible (no &&, no ternary, no ::new sugar).

.NOTES
    Run from anywhere; paths are derived from the script's own location:
        powershell -ExecutionPolicy Bypass -File infra\scripts\new-env.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- Resolve paths relative to this script (infra\scripts\ -> infra\) --------
$InfraDir    = Split-Path -Parent $PSScriptRoot
$ExamplePath = Join-Path $InfraDir 'secrets.example.env'
$EnvPath     = Join-Path $InfraDir '.env'

# --- Crypto-random base64 helper ---------------------------------------------
function New-RandomBase64 {
    <#
        Returns Base64($ByteCount random bytes) from the OS CSPRNG.
        24 bytes -> 32-char password (base64 alphabet: A-Za-z0-9+/=, all safe
        inside a docker env file -- no spaces, no '#', no '$').
        32 bytes -> 44-char string, satisfying Fleet's ">= 32 bytes" rule for
        FLEET_SERVER_PRIVATE_KEY.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$ByteCount
    )
    $bytes = New-Object byte[] ($ByteCount)
    $rng   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($bytes)
}

# --- Guard rails --------------------------------------------------------------
if (Test-Path -LiteralPath $EnvPath) {
    Write-Host ''
    Write-Host 'infra\.env already exists -- refusing to overwrite it.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'This is deliberate: the existing file may hold the FLEET_SERVER_PRIVATE_KEY'
    Write-Host 'that encrypts MDM assets already stored in MySQL. Regenerating that key'
    Write-Host 'would make those assets PERMANENTLY undecryptable.'
    Write-Host ''
    Write-Host 'If you truly want a fresh environment (e.g. a brand-new machine with no'
    Write-Host 'MDM state), move the old file out of the way yourself, then re-run:'
    Write-Host ('    Move-Item "{0}" "{0}.bak"' -f $EnvPath)
    Write-Host '    powershell -ExecutionPolicy Bypass -File infra\scripts\new-env.ps1'
    Write-Host ''
    exit 0
}

if (-not (Test-Path -LiteralPath $ExamplePath)) {
    throw "Template not found: $ExamplePath -- is the repo checkout intact?"
}

# --- Load template ------------------------------------------------------------
$content = Get-Content -LiteralPath $ExamplePath -Raw

# --- Token -> generated-value map ---------------------------------------------
# One entry per SECRET, not per line: __GENERATE_MYSQL_FLEET_PASSWORD__ occurs
# twice in the template (MYSQL_PASSWORD + FLEET_MYSQL_PASSWORD) and
# String.Replace substitutes every occurrence with the same value.
$secrets = @(
    @{ Token = '__GENERATE_FLEET_SERVER_PRIVATE_KEY__';      Bytes = 32; Label = 'FLEET_SERVER_PRIVATE_KEY (32 random bytes, base64)' },
    @{ Token = '__GENERATE_MYSQL_ROOT_PASSWORD__';           Bytes = 24; Label = 'MYSQL_ROOT_PASSWORD (24 random bytes, base64)' },
    @{ Token = '__GENERATE_MYSQL_FLEET_PASSWORD__';          Bytes = 24; Label = 'MYSQL_PASSWORD + FLEET_MYSQL_PASSWORD (shared value)' },
    @{ Token = '__GENERATE_FLEET_PROMETHEUS_PASSWORD__';     Bytes = 24; Label = 'FLEET_PROMETHEUS_BASIC_AUTH_PASSWORD (24 random bytes, base64)' },
    @{ Token = '__GENERATE_GRAFANA_ADMIN_PASSWORD__';        Bytes = 24; Label = 'GRAFANA_ADMIN_PASSWORD (24 random bytes, base64)' },
    @{ Token = '__GENERATE_FLEET_EXPORTER_PASSWORD__';       Bytes = 24; Label = 'FLEET_EXPORTER_PASSWORD (24 random bytes, base64)' }
)

$missingTokens = @()
foreach ($secret in $secrets) {
    if ($content.Contains($secret.Token)) {
        $value   = New-RandomBase64 -ByteCount $secret.Bytes
        $content = $content.Replace($secret.Token, $value)
        Write-Host ('  generated  {0}' -f $secret.Label)
    }
    else {
        # Template drift: someone edited secrets.example.env and removed or
        # renamed a token. Surface it loudly rather than shipping a half-filled
        # env file.
        $missingTokens += $secret.Token
        Write-Warning ('Token not found in template: {0} -- {1} was NOT generated.' -f $secret.Token, $secret.Label)
    }
}

# --- Normalize + write (UTF-8, no BOM, LF endings) -----------------------------
$content = $content -replace "`r`n", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($EnvPath, $content, $utf8NoBom)

# --- Report --------------------------------------------------------------------
Write-Host ''
Write-Host ('Wrote {0}' -f $EnvPath) -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. BACK UP the FLEET_SERVER_PRIVATE_KEY line out-of-band (password'
Write-Host '     manager). Once MDM assets exist it must never change, and it is'
Write-Host '     useless without the mysql-data volume (and vice versa).'
Write-Host '  2. Confirm the file is gitignored:  git check-ignore -v infra/.env'
Write-Host '  3. Continue the Phase 1 bring-up:   infra\README.md'
Write-Host ''

if ($missingTokens.Count -gt 0) {
    Write-Warning ('{0} token(s) were missing from the template; fix infra\secrets.example.env, delete infra\.env, and re-run.' -f $missingTokens.Count)
    exit 1
}

exit 0
