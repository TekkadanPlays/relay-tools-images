<#
.SYNOPSIS
    Local installer for relay-tools on Windows.
    Runs relaycreator + MariaDB natively, strfry via WSL2.

.DESCRIPTION
    This script sets up relay-tools for local/personal use on Windows.
    - MariaDB: native Windows install via winget/choco
    - strfry: compiled inside WSL2 (Ubuntu)
    - relaycreator: native Node.js + Bun
    - mkcert: locally-trusted TLS certificates

.NOTES
    Run as Administrator in PowerShell.
    Usage: .\install-local.ps1
#>

$ErrorActionPreference = "Stop"

# --- Colors ---
function Write-Header($text) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor White -NoNewline
    Write-Host "" -ForegroundColor White
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section($text) {
    Write-Host ""
    Write-Host "-- $text --" -ForegroundColor Blue
    Write-Host ""
}

function Write-Ok($text) {
    Write-Host "  [OK] $text" -ForegroundColor Green
}

function Write-Warn($text) {
    Write-Host "  [!!] $text" -ForegroundColor Yellow
}

function Write-Err($text) {
    Write-Host "  [XX] $text" -ForegroundColor Red
}

function Confirm-Action($prompt, $default = "y") {
    if ($default -eq "y") {
        $answer = Read-Host "$prompt [Y/n]"
        if ([string]::IsNullOrEmpty($answer)) { $answer = "y" }
    } else {
        $answer = Read-Host "$prompt [y/N]"
        if ([string]::IsNullOrEmpty($answer)) { $answer = "n" }
    }
    return $answer -match "^[Yy]"
}

# --- Check admin ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator."
    Write-Host "Right-click PowerShell -> Run as Administrator, then re-run this script."
    exit 1
}

# --- Welcome ---
Write-Header "relay-tools local installer (Windows)"

Write-Host "  This installer sets up relay-tools for local/personal use on Windows."
Write-Host "  strfry runs inside WSL2 (Ubuntu). Everything else runs natively."
Write-Host ""
Write-Host "  Components:"
Write-Ok "MariaDB        - database (native Windows)"
Write-Ok "strfry         - Nostr relay engine (WSL2 Ubuntu)"
Write-Ok "relaycreator   - API server + admin panel (native Node.js)"
Write-Ok "mkcert         - locally-trusted TLS certificates"
Write-Host ""

# --- Configuration ---
Write-Section "Configuration"

$InstallDir = "$env:USERPROFILE\relay-tools"
$DataDir = "$InstallDir\data"
$CertsDir = "$InstallDir\certs"

Write-Host "  Install directory: $InstallDir"
Write-Host "  Data directory:    $DataDir"
Write-Host ""

$InstallCoinos = $false
if (Confirm-Action "Install CoinOS wallet server?" "n") {
    $InstallCoinos = $true
}

Write-Host ""
if (-not (Confirm-Action "Proceed with installation?")) {
    Write-Host "Aborted."
    exit 0
}

# --- Create directories ---
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $CertsDir | Out-Null

# --- Install package managers ---
Write-Section "Checking package managers"

# Check for winget
$hasWinget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $hasWinget) {
    Write-Warn "winget not found. Please install App Installer from the Microsoft Store."
    Write-Host "  https://aka.ms/getwinget"
    exit 1
}
Write-Ok "winget available"

# --- Install Git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing Git..."
    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
    $env:PATH = "$env:ProgramFiles\Git\cmd;$env:PATH"
}
Write-Ok "Git: $(git --version)"

# --- Install Node.js ---
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing Node.js 20 LTS..."
    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
}
Write-Ok "Node.js: $(node --version)"

# --- Install Bun ---
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing Bun..."
    Invoke-RestMethod bun.sh/install.ps1 | Invoke-Expression
    $env:PATH = "$env:USERPROFILE\.bun\bin;$env:PATH"
}
Write-Ok "Bun: $(bun --version)"

# --- Install MariaDB ---
Write-Section "Installing MariaDB"

$mariadbInstalled = Get-Command mysql -ErrorAction SilentlyContinue
if (-not $mariadbInstalled) {
    Write-Host "  Installing MariaDB..."
    winget install --id MariaDB.Server -e --accept-source-agreements --accept-package-agreements

    # Add MariaDB to PATH
    $mariadbPaths = @(
        "${env:ProgramFiles}\MariaDB 11.4\bin",
        "${env:ProgramFiles}\MariaDB 11.3\bin",
        "${env:ProgramFiles}\MariaDB 11.2\bin",
        "${env:ProgramFiles}\MariaDB 11.1\bin",
        "${env:ProgramFiles}\MariaDB 11.0\bin",
        "${env:ProgramFiles}\MariaDB 10.11\bin"
    )
    foreach ($p in $mariadbPaths) {
        if (Test-Path $p) {
            $env:PATH = "$p;$env:PATH"
            break
        }
    }
    Write-Ok "MariaDB installed"
} else {
    Write-Ok "MariaDB already installed"
}

# Create database
$DbName = "relaycreator"
$DbUser = "relaycreator"
$DbPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })

$dbExists = $false
try {
    $result = mysql -u root -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DbName'" 2>$null
    if ($result -match $DbName) { $dbExists = $true }
} catch {}

if (-not $dbExists) {
    Write-Host "  Creating database..."
    $sql = @"
CREATE DATABASE IF NOT EXISTS $DbName CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$DbPass';
GRANT ALL PRIVILEGES ON $DbName.* TO '$DbUser'@'localhost';
FLUSH PRIVILEGES;
"@
    $sql | mysql -u root
    Write-Ok "Database created"
} else {
    Write-Host "  Database already exists."
    # Try to read existing password
    $envFile = "$InstallDir\relaycreator\.env"
    if (Test-Path $envFile) {
        $existingUrl = (Get-Content $envFile | Where-Object { $_ -match "^DATABASE_URL=" }) -replace "^DATABASE_URL=", ""
        if ($existingUrl -match "mysql://[^:]+:([^@]+)@") {
            $DbPass = $Matches[1]
            Write-Host "  Using existing credentials."
        }
    }
}

$DatabaseUrl = "mysql://${DbUser}:${DbPass}@localhost:3306/${DbName}"

# --- Install mkcert ---
Write-Section "Setting up TLS certificates"

if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing mkcert..."
    winget install --id FiloSottile.mkcert -e --accept-source-agreements --accept-package-agreements
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

# Install local CA
Write-Host "  Installing local CA root certificate..."
mkcert -install 2>$null

# Generate certs
if (-not (Test-Path "$CertsDir\localhost.pem")) {
    Write-Host "  Generating TLS certificate for localhost..."
    Push-Location $CertsDir
    mkcert -cert-file localhost.pem -key-file localhost-key.pem `
        localhost 127.0.0.1 "::1" `
        "*.localhost" relay.localhost app.localhost
    # Create bundle
    Get-Content localhost.pem, localhost-key.pem | Set-Content bundle.pem
    Pop-Location
    Write-Ok "TLS certificates generated"
} else {
    Write-Host "  TLS certificates already exist."
}

# --- Setup WSL2 + strfry ---
Write-Section "Setting up strfry via WSL2"

$wslInstalled = $false
try {
    $wslList = wsl --list --quiet 2>$null
    if ($wslList -match "Ubuntu") { $wslInstalled = $true }
} catch {}

if (-not $wslInstalled) {
    Write-Host "  Installing WSL2 with Ubuntu..."
    Write-Warn "This may require a restart. Re-run this script after restarting."
    wsl --install -d Ubuntu --no-launch
    Write-Host ""
    Write-Host "  WSL2 Ubuntu is installing. After it finishes:"
    Write-Host "  1. Open Ubuntu from the Start menu and create a user"
    Write-Host "  2. Re-run this script to continue setup"
    Write-Host ""
    exit 0
}

Write-Ok "WSL2 Ubuntu available"

# Build strfry inside WSL
wsl -d Ubuntu -- test -f /usr/local/bin/strfry 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Building strfry inside WSL2 (this takes a few minutes)..."

    $wslScript = @'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -qq
sudo apt-get install -y -qq git build-essential \
    libsecp256k1-dev libzstd-dev liblmdb-dev libflatbuffers-dev \
    libssl-dev zlib1g-dev 2>&1 | tail -1

if [ ! -d /tmp/strfry ]; then
    git clone https://github.com/hoytech/strfry.git /tmp/strfry
    cd /tmp/strfry
    git checkout tags/1.0.4
    git submodule update --init
fi

cd /tmp/strfry
make setup-golpe
make -j$(nproc)
sudo cp strfry /usr/local/bin/strfry
echo "strfry built successfully"
'@
    $wslScript | wsl -d Ubuntu -- bash
    Write-Ok "strfry built in WSL2"
} else {
    Write-Ok "strfry already built in WSL2"
}

# Create strfry data dir in WSL
$wslDataDir = "/mnt/c/Users/$env:USERNAME/relay-tools/data/strfry"
wsl -d Ubuntu -- bash -c "mkdir -p '$wslDataDir'"

# Write strfry config
$strfryConf = @'
db = "./strfry-db/"
dbParams {
    maxreaders = 256
    mapsize = 10995116277760
    noReadAhead = false
}
relay {
    bind = "0.0.0.0"
    port = 7777
    realIpHeader = ""
    info {
        name = "Local Relay"
        description = "relay-tools local instance"
        pubkey = ""
        contact = ""
    }
    maxWebsocketPayloadSize = 262200
    maxReqFilterSize = 1000
    autoPingSeconds = 55
    enableTcpKeepalive = true
    queryTimesliceBudgetMicroseconds = 10000
    maxFilterLimit = 10000
    maxSubsPerConnection = 80
    writePolicy {
        plugin = ""
        lookbackSeconds = 0
    }
    compression {
        enabled = true
        slidingWindow = true
    }
    logging {
        dumpInAll = false
        dumpInEvents = false
        dumpInReqs = false
        dbScanPerf = false
        invalidEvents = false
    }
    numThreads {
        ingester = 3
        reqWorker = 3
        reqMonitor = 3
        negentropy = 2
    }
    negentropy {
        enabled = true
        maxSyncEvents = 1000000
    }
}
events {
    maxEventSize = 262140
    rejectEventsNewerThanSeconds = 900
    rejectEventsOlderThanSeconds = 94608000
    rejectEphemeralEventsOlderThanSeconds = 60
    ephemeralEventsLifetimeSeconds = 300
    maxNumTags = 10000
    maxTagValSize = 4096
}
'@
$strfryConf | Set-Content "$DataDir\strfry\strfry.conf" -Force

# --- Install relaycreator ---
Write-Section "Installing relaycreator"

$RcDir = "$InstallDir\relaycreator"

if (-not (Test-Path "$RcDir\.git")) {
    Write-Host "  Cloning relaycreator..."
    git clone https://github.com/TekkadanPlays/relaycreator.git $RcDir
} else {
    Write-Host "  relaycreator already cloned, pulling latest..."
    Push-Location $RcDir
    git pull origin main 2>$null
    Pop-Location
}

# Generate JWT secret
$JwtSecret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 44 | ForEach-Object { [char]$_ })

# Write .env
$envContent = @"
# relay-tools local configuration (Windows)
# Generated by install-local.ps1 on $(Get-Date -Format "o")

DATABASE_URL=$DatabaseUrl
JWT_SECRET=$JwtSecret
PORT=4000
CORS_ORIGIN=https://localhost:4000,http://localhost:4000,https://localhost:3000,http://localhost:3000
CREATOR_DOMAIN=localhost
INVOICE_AMOUNT=21
INVOICE_PREMIUM_AMOUNT=2100
HAPROXY_PEM=bundle.pem

PAYMENTS_ENABLED=false
COINOS_ENABLED=false
WALLET_ENABLED=false
INTERCEPTOR_PORT=9696
"@
$envContent | Set-Content "$RcDir\.env"
Write-Ok "relaycreator .env configured"

# Build API server
Write-Host "  Building API server..."
Push-Location "$RcDir\api-server"
npm install --legacy-peer-deps 2>&1 | Select-Object -Last 3
npx prisma generate
npx prisma db push --accept-data-loss 2>$null
if ($LASTEXITCODE -ne 0) { npx prisma db push }
npm run build
Pop-Location
Write-Ok "API server built"

# Build web frontend
Write-Host "  Building web frontend..."
Push-Location "$RcDir\web"
bun install
bun run build
Pop-Location
Write-Ok "Web frontend built"

# --- Create convenience scripts ---
Write-Section "Creating convenience scripts"

# Start script
@"
@echo off
echo Starting relay-tools...

echo Starting strfry (WSL2)...
start "strfry" wsl -d Ubuntu -- bash -c "cd '$wslDataDir' && /usr/local/bin/strfry relay"
timeout /t 2 /nobreak >nul

echo Starting relaycreator...
start "relaycreator" cmd /c "cd /d $RcDir\api-server && node dist/index.js"
timeout /t 2 /nobreak >nul

echo.
echo relay-tools is running!
echo   Admin panel: http://localhost:4000
echo   Relay:       ws://localhost:7777
echo.
pause
"@ | Set-Content "$InstallDir\start.bat"

# Stop script
@"
@echo off
echo Stopping relay-tools...
taskkill /FI "WINDOWTITLE eq strfry" /F 2>nul
taskkill /FI "WINDOWTITLE eq relaycreator" /F 2>nul
wsl -d Ubuntu -- bash -c "pkill strfry 2>/dev/null" 2>nul
echo relay-tools stopped.
pause
"@ | Set-Content "$InstallDir\stop.bat"

# Status script
@"
@echo off
echo === relay-tools status ===
echo.
tasklist /FI "IMAGENAME eq node.exe" /FO TABLE /NH 2>nul | findstr /i "node" >nul && (echo   [OK] relaycreator) || (echo   [--] relaycreator not running)
wsl -d Ubuntu -- bash -c "pgrep strfry >/dev/null 2>&1" 2>nul && (echo   [OK] strfry) || (echo   [--] strfry not running)
echo.
echo Admin panel: http://localhost:4000
echo Relay:       ws://localhost:7777
echo.
pause
"@ | Set-Content "$InstallDir\status.bat"

Write-Ok "Convenience scripts created"

# --- Done ---
Write-Header "Local Installation Complete!"

Write-Host "  relay-tools is ready!" -ForegroundColor White
Write-Host ""
Write-Ok "Admin panel: http://localhost:4000"
Write-Ok "Relay:       ws://localhost:7777"
Write-Host ""
Write-Host "  Files:" -ForegroundColor White
Write-Host "    Install dir:  $InstallDir" -ForegroundColor Cyan
Write-Host "    Config:       $RcDir\.env" -ForegroundColor Cyan
Write-Host "    TLS certs:    $CertsDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Scripts:" -ForegroundColor White
Write-Host "    $InstallDir\start.bat   — Start all services" -ForegroundColor Cyan
Write-Host "    $InstallDir\stop.bat    — Stop all services" -ForegroundColor Cyan
Write-Host "    $InstallDir\status.bat  — Check service status" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To start: double-click start.bat or run:" -ForegroundColor White
Write-Host "    $InstallDir\start.bat" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Connecting Nostr clients:" -ForegroundColor White
Write-Host "    Add relay: ws://localhost:7777" -ForegroundColor Yellow
Write-Host ""
Write-Host "All done!" -ForegroundColor Green
