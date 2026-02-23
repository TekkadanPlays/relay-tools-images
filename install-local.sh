#!/bin/bash
set -e

##
### Local installer for relay-tools.
### Runs relaycreator + strfry + MariaDB directly on the host (no containers).
### Designed for development, testing, and personal use on Ubuntu/Debian.
###
### Usage: sudo ./install-local.sh
###
### This does NOT use systemd-nspawn containers. Everything runs as native
### systemd services or foreground processes. TLS is handled via mkcert
### (locally-trusted certificates) instead of Let's Encrypt.
##

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}── $1 ──${NC}"
    echo ""
}

confirm() {
    local prompt=$1
    local default=${2:-y}
    if [ "$default" = "y" ]; then
        read -rp "$(echo -e "${YELLOW}$prompt [Y/n]:${NC} ")" answer
        answer=${answer:-y}
    else
        read -rp "$(echo -e "${YELLOW}$prompt [y/N]:${NC} ")" answer
        answer=${answer:-n}
    fi
    [[ "$answer" =~ ^[Yy] ]]
}

# ─── Welcome ───
print_header "relay-tools local installer"

echo "  This installer sets up relay-tools for local/personal use."
echo "  Everything runs directly on this machine — no containers."
echo ""
echo "  Components:"
echo -e "  ${GREEN}●${NC} MariaDB        — database"
echo -e "  ${GREEN}●${NC} strfry         — Nostr relay engine"
echo -e "  ${GREEN}●${NC} relaycreator   — API server + admin panel"
echo -e "  ${GREEN}●${NC} mkcert         — locally-trusted TLS certificates"
echo ""
echo "  Relay connections use ws://localhost:<port> (no subdomains needed)."
echo "  The admin panel is served at https://localhost:4000"
echo ""

# ─── Check prerequisites ───
print_section "Checking prerequisites"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
    exit 1
fi

# Detect the real user (who ran sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

if [ "$REAL_USER" = "root" ]; then
    echo -e "${YELLOW}WARNING: Running as root directly. Install directory will be /root/relay-tools.${NC}"
    REAL_HOME="/root"
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
else
    echo -e "${RED}ERROR: Cannot detect OS. This script supports Ubuntu/Debian.${NC}"
    exit 1
fi

case "$OS_ID" in
    ubuntu|debian)
        echo -e "${GREEN}Detected: $PRETTY_NAME${NC}"
        PKG_MANAGER="apt"
        ;;
    *)
        echo -e "${RED}ERROR: Unsupported OS: $OS_ID. This script supports Ubuntu/Debian.${NC}"
        echo "For other distributions, see the manual installation guide."
        exit 1
        ;;
esac

# ─── Configuration ───
print_section "Configuration"

INSTALL_DIR="${REAL_HOME}/relay-tools"
DATA_DIR="/var/lib/relay-tools"
CERTS_DIR="${INSTALL_DIR}/certs"

echo -e "  ${BOLD}Install directory:${NC} $INSTALL_DIR"
echo -e "  ${BOLD}Data directory:${NC}   $DATA_DIR"
echo -e "  ${BOLD}User:${NC}             $REAL_USER"
echo ""

INSTALL_COINOS=false
if confirm "Install CoinOS wallet server?" "n"; then
    INSTALL_COINOS=true
fi

echo ""
if ! confirm "Proceed with installation?"; then
    echo "Aborted."
    exit 0
fi

# ─── Install system dependencies ───
print_section "Installing system dependencies"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# Core dependencies
apt-get install -y -qq \
    git curl wget unzip build-essential \
    mariadb-server mariadb-client \
    libnss3-tools \
    openssl \
    jq \
    2>&1 | tail -1

echo -e "${GREEN}System packages installed${NC}"

# ─── Install Bun ───
if ! command -v bun &>/dev/null; then
    echo "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    export BUN_INSTALL="$REAL_HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    # Also make it available system-wide
    ln -sf "$REAL_HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true
    ln -sf "$REAL_HOME/.bun/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true
    echo -e "${GREEN}Bun installed${NC}"
else
    echo -e "${GREEN}Bun already installed: $(bun --version)${NC}"
fi

# ─── Install Node.js (for Prisma CLI) ───
if ! command -v node &>/dev/null; then
    echo "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs 2>&1 | tail -1
    echo -e "${GREEN}Node.js installed: $(node --version)${NC}"
else
    echo -e "${GREEN}Node.js already installed: $(node --version)${NC}"
fi

# ─── Install mkcert ───
print_section "Setting up locally-trusted TLS certificates"

if ! command -v mkcert &>/dev/null; then
    echo "Installing mkcert..."
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|arm64) MKCERT_ARCH="arm64" ;;
        x86_64) MKCERT_ARCH="amd64" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
    MKCERT_VERSION="v1.4.4"
    wget -q "https://dl.filippo.io/mkcert/latest?for=linux/${MKCERT_ARCH}" -O /usr/local/bin/mkcert
    chmod +x /usr/local/bin/mkcert
    echo -e "${GREEN}mkcert installed${NC}"
else
    echo -e "${GREEN}mkcert already installed${NC}"
fi

# Install the local CA into the system trust store
echo "Installing local CA root certificate..."
sudo -u "$REAL_USER" mkcert -install 2>/dev/null || mkcert -install
echo -e "${GREEN}Local CA installed — browsers on this machine will trust our certs${NC}"

# Generate certificates for localhost
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

if [ ! -f "$CERTS_DIR/localhost.pem" ]; then
    echo "Generating TLS certificate for localhost..."
    mkcert -cert-file localhost.pem -key-file localhost-key.pem \
        localhost 127.0.0.1 ::1 \
        "*.localhost" \
        relay.localhost app.localhost
    # Create HAProxy-style bundle (cert + key in one file)
    cat localhost.pem localhost-key.pem > bundle.pem
    chmod 0600 bundle.pem localhost-key.pem
    echo -e "${GREEN}TLS certificates generated${NC}"
else
    echo "TLS certificates already exist, skipping."
fi

# ─── Configure MariaDB ───
print_section "Configuring MariaDB"

# Ensure MariaDB is running
systemctl enable mariadb
systemctl start mariadb

# Create database and user
DB_NAME="relaycreator"
DB_USER="relaycreator"
DB_PASS=$(openssl rand -hex 16)

# Check if database already exists
if mariadb -u root -e "USE $DB_NAME" 2>/dev/null; then
    echo "Database '$DB_NAME' already exists."
    # Try to read existing password from .env
    if [ -f "$INSTALL_DIR/relaycreator/.env" ]; then
        EXISTING_URL=$(grep "^DATABASE_URL=" "$INSTALL_DIR/relaycreator/.env" | cut -d= -f2-)
        if [ -n "$EXISTING_URL" ]; then
            DB_PASS=$(echo "$EXISTING_URL" | sed -n 's|mysql://[^:]*:\([^@]*\)@.*|\1|p')
            echo "Using existing database credentials."
        fi
    fi
else
    echo "Creating database and user..."
    mariadb -u root << SQLEOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
    echo -e "${GREEN}Database created${NC}"
fi

DATABASE_URL="mysql://${DB_USER}:${DB_PASS}@localhost:3306/${DB_NAME}"

# ─── Build strfry from source ───
print_section "Building strfry"

STRFRY_DIR="$INSTALL_DIR/strfry"
STRFRY_DATA="$DATA_DIR/strfry"

if [ -f "$STRFRY_DIR/strfry" ]; then
    echo "strfry binary already exists, skipping build."
else
    echo "Installing strfry build dependencies..."
    apt-get install -y -qq \
        libsecp256k1-dev libzstd-dev liblmdb-dev libflatbuffers-dev \
        libssl-dev zlib1g-dev \
        2>&1 | tail -1

    mkdir -p "$STRFRY_DIR"

    if [ ! -d "$STRFRY_DIR/.git" ]; then
        echo "Cloning strfry..."
        git clone https://github.com/hoytech/strfry.git "$STRFRY_DIR"
        cd "$STRFRY_DIR"
        git checkout tags/1.0.4
        git submodule update --init
    else
        cd "$STRFRY_DIR"
    fi

    echo "Compiling strfry (this takes a few minutes)..."
    make setup-golpe
    make -j$(nproc)
    echo -e "${GREEN}strfry built successfully${NC}"
fi

# Create strfry data directory
mkdir -p "$STRFRY_DATA"

# Write default strfry config
cat > "$STRFRY_DATA/strfry.conf" << 'STRFRYEOF'
db = "./strfry-db/"

dbParams {
    maxreaders = 256
    mapsize = 10995116277760
    noReadAhead = false
}

relay {
    bind = "127.0.0.1"
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
STRFRYEOF

chown -R "$REAL_USER:$REAL_USER" "$STRFRY_DATA"

# ─── Install relaycreator ───
print_section "Installing relaycreator"

RC_DIR="$INSTALL_DIR/relaycreator"

if [ ! -d "$RC_DIR/.git" ]; then
    echo "Cloning relaycreator..."
    mkdir -p "$INSTALL_DIR"
    git clone https://github.com/TekkadanPlays/relaycreator.git "$RC_DIR"
else
    echo "relaycreator already cloned, pulling latest..."
    cd "$RC_DIR"
    git pull origin main || git pull origin master || true
fi

cd "$RC_DIR"

# Generate JWT secret
JWT_SECRET=$(openssl rand -base64 32)

# Write .env
cat > "$RC_DIR/.env" << ENVEOF
# relay-tools local configuration
# Generated by install-local.sh on $(date -Iseconds)

DATABASE_URL=$DATABASE_URL
JWT_SECRET=$JWT_SECRET
PORT=4000
CORS_ORIGIN=https://localhost:4000,http://localhost:4000,https://localhost:3000,http://localhost:3000
CREATOR_DOMAIN=localhost
INVOICE_AMOUNT=21
INVOICE_PREMIUM_AMOUNT=2100
HAPROXY_PEM=bundle.pem

# Local mode: no payments, no HAProxy, no cookiecutter
PAYMENTS_ENABLED=false
COINOS_ENABLED=false
WALLET_ENABLED=false

# strfry listens on localhost ports (no interceptor needed locally)
INTERCEPTOR_PORT=9696
ENVEOF

echo -e "${GREEN}relaycreator .env configured${NC}"

# Build API server
echo "Building API server..."
cd "$RC_DIR/api-server"
npm install --legacy-peer-deps 2>&1 | tail -3
npx prisma generate
npx prisma db push --accept-data-loss 2>/dev/null || npx prisma db push
npm run build
echo -e "${GREEN}API server built${NC}"

# Build web frontend
echo "Building web frontend..."
cd "$RC_DIR/web"
bun install
bun run build
echo -e "${GREEN}Web frontend built${NC}"

# Set ownership
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

# ─── Create systemd services ───
print_section "Creating systemd services"

# strfry service
cat > /etc/systemd/system/relay-tools-strfry.service << SVCEOF
[Unit]
Description=relay-tools strfry (local)
After=network.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$STRFRY_DATA
ExecStart=$STRFRY_DIR/strfry relay
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# relaycreator service
cat > /etc/systemd/system/relay-tools-api.service << SVCEOF
[Unit]
Description=relay-tools relaycreator API (local)
After=network.target mariadb.service relay-tools-strfry.service
Requires=mariadb.service

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$RC_DIR/api-server
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
EnvironmentFile=$RC_DIR/.env

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable relay-tools-strfry relay-tools-api
systemctl start relay-tools-strfry
sleep 2
systemctl start relay-tools-api

echo -e "${GREEN}Services created and started${NC}"

# ─── Optional: CoinOS ───
if [ "$INSTALL_COINOS" = true ]; then
    print_section "Installing CoinOS"

    echo -e "${YELLOW}CoinOS requires Bitcoin Knots + Core Lightning.${NC}"
    echo "This is a complex setup. For local testing, CoinOS runs in mock mode."
    echo ""

    # Install KeyDB (Redis-compatible)
    if ! command -v keydb-server &>/dev/null; then
        echo "Installing KeyDB..."
        echo "deb https://download.keydb.dev/open-source-dist $(lsb_release -sc) main" > /etc/apt/sources.list.d/keydb.list
        wget -qO - https://download.keydb.dev/open-source-dist/keyring.gpg | apt-key add - 2>/dev/null
        apt-get update -qq
        apt-get install -y -qq keydb 2>&1 | tail -1 || {
            echo -e "${YELLOW}KeyDB not available from repo, falling back to Redis...${NC}"
            apt-get install -y -qq redis-server 2>&1 | tail -1
        }
    fi

    COINOS_DIR="$INSTALL_DIR/coinos"
    if [ ! -d "$COINOS_DIR/.git" ]; then
        echo "Cloning coinos-server..."
        git clone https://github.com/coinos/coinos-server.git "$COINOS_DIR"
    fi

    cd "$COINOS_DIR"
    bun install

    COINOS_JWT=$(openssl rand -hex 32)
    cat > "$COINOS_DIR/config.ts" << COINEOF
export default {
  db: "redis://127.0.0.1:6379",
  archive: "redis://127.0.0.1:6379",
  nostr: "ws://127.0.0.1:7777",
  relays: ["ws://127.0.0.1:7777"],
  jwt: "$COINOS_JWT",
  bitcoin: {
    host: "127.0.0.1",
    wallet: "coinos",
    user: "relaytools",
    password: "",
    network: "regtest",
    port: 18443,
  },
  lightning: "",
  fee: 0,
  adminpass: "$(openssl rand -hex 16)",
  support: "admin@localhost",
  nostrKey: "",
  nostrKey2: "",
};
COINEOF

    # Update relaycreator .env
    sed -i 's/^COINOS_ENABLED=false/COINOS_ENABLED=true/' "$RC_DIR/.env"

    chown -R "$REAL_USER:$REAL_USER" "$COINOS_DIR"

    # CoinOS service
    cat > /etc/systemd/system/relay-tools-coinos.service << SVCEOF
[Unit]
Description=relay-tools CoinOS (local)
After=network.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$COINOS_DIR
ExecStart=/usr/local/bin/bun run index.ts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable relay-tools-coinos
    echo -e "${GREEN}CoinOS installed (start manually when Bitcoin stack is ready)${NC}"
fi

# ─── Create admin user ───
print_section "Creating admin user"

echo "To make yourself an admin, you'll need your Nostr public key (hex format)."
echo "You can find this in your Nostr client settings, or convert your npub at:"
echo "  https://nostr.band/npub-to-hex"
echo ""
read -rp "Enter your Nostr hex pubkey (or press Enter to skip): " ADMIN_PUBKEY

if [ -n "$ADMIN_PUBKEY" ]; then
    # Insert admin user via Prisma
    cd "$RC_DIR/api-server"
    node -e "
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();
(async () => {
  try {
    const user = await prisma.user.upsert({
      where: { pubkey: '$ADMIN_PUBKEY' },
      update: { admin: true },
      create: { pubkey: '$ADMIN_PUBKEY', admin: true },
    });
    console.log('Admin user created/updated:', user.id);
  } catch (e) {
    console.error('Error:', e.message);
  } finally {
    await prisma.\$disconnect();
  }
})();
" 2>/dev/null && echo -e "${GREEN}Admin user configured${NC}" || echo -e "${YELLOW}Could not set admin user. You can do this later via the database.${NC}"
fi

# ─── Create convenience scripts ───
print_section "Creating convenience scripts"

# Start all services
cat > "$INSTALL_DIR/start.sh" << 'STARTEOF'
#!/bin/bash
echo "Starting relay-tools..."
sudo systemctl start mariadb
sudo systemctl start relay-tools-strfry
sleep 1
sudo systemctl start relay-tools-api
echo "relay-tools is running!"
echo "  Admin panel: http://localhost:4000"
echo "  Relay:       ws://localhost:7777"
STARTEOF
chmod +x "$INSTALL_DIR/start.sh"

# Stop all services
cat > "$INSTALL_DIR/stop.sh" << 'STOPEOF'
#!/bin/bash
echo "Stopping relay-tools..."
sudo systemctl stop relay-tools-api
sudo systemctl stop relay-tools-strfry
echo "relay-tools stopped."
STOPEOF
chmod +x "$INSTALL_DIR/stop.sh"

# Status check
cat > "$INSTALL_DIR/status.sh" << 'STATUSEOF'
#!/bin/bash
echo "=== relay-tools status ==="
echo ""
for svc in mariadb relay-tools-strfry relay-tools-api; do
    if systemctl is-active --quiet "$svc"; then
        echo -e "  \033[0;32m●\033[0m $svc"
    else
        echo -e "  \033[0;31m○\033[0m $svc (stopped)"
    fi
done
echo ""
echo "Admin panel: http://localhost:4000"
echo "Relay:       ws://localhost:7777"
STATUSEOF
chmod +x "$INSTALL_DIR/status.sh"

# Upgrade script
cat > "$INSTALL_DIR/upgrade.sh" << UPGRADEEOF
#!/bin/bash
set -e
echo "Upgrading relay-tools..."

cd "$RC_DIR"
git pull origin main || git pull origin master

cd "$RC_DIR/api-server"
npm install --legacy-peer-deps
npx prisma generate
npx prisma db push --accept-data-loss 2>/dev/null || npx prisma db push
npm run build

cd "$RC_DIR/web"
bun install
bun run build

sudo systemctl restart relay-tools-api
echo "relay-tools upgraded!"
UPGRADEEOF
chmod +x "$INSTALL_DIR/upgrade.sh"

chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

# ─── Done ───
print_header "Local Installation Complete!"

echo -e "  ${BOLD}relay-tools is running at:${NC}"
echo ""
echo -e "  ${GREEN}http://localhost:4000${NC}      — Admin panel + API"
echo -e "  ${GREEN}ws://localhost:7777${NC}        — Nostr relay (strfry)"
if [ "$INSTALL_COINOS" = true ]; then
    echo -e "  ${GREEN}http://localhost:3119${NC}     — CoinOS (when started)"
fi
echo ""
echo -e "  ${BOLD}Files:${NC}"
echo -e "    Install dir:  ${CYAN}$INSTALL_DIR${NC}"
echo -e "    Config:       ${CYAN}$RC_DIR/.env${NC}"
echo -e "    Relay data:   ${CYAN}$STRFRY_DATA${NC}"
echo -e "    TLS certs:    ${CYAN}$CERTS_DIR${NC}"
echo ""
echo -e "  ${BOLD}Convenience scripts:${NC}"
echo -e "    ${CYAN}$INSTALL_DIR/start.sh${NC}    — Start all services"
echo -e "    ${CYAN}$INSTALL_DIR/stop.sh${NC}     — Stop all services"
echo -e "    ${CYAN}$INSTALL_DIR/status.sh${NC}   — Check service status"
echo -e "    ${CYAN}$INSTALL_DIR/upgrade.sh${NC}  — Pull latest + rebuild"
echo ""
echo -e "  ${BOLD}Connecting Nostr clients:${NC}"
echo "    Add relay: ws://localhost:7777"
echo "    Or from LAN: ws://<your-ip>:7777"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "    1. Open http://localhost:4000 in your browser"
echo "    2. Log in with your Nostr extension (NIP-07)"
echo "    3. Create your first relay from the admin panel"
echo ""
echo -e "${GREEN}All done!${NC}"
