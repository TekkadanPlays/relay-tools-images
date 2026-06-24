#!/bin/bash
set -e

##
### Interactive installer for the relay-tools Nostr stack.
### Guides the user through service selection, builds containers, and configures the deployment.
##

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINES_DIR="$SCRIPT_DIR/machines"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

print_service() {
    local status=$1 name=$2 desc=$3
    if [ "$status" = "on" ]; then
        echo -e "  ${GREEN}[x]${NC} ${BOLD}$name${NC} — $desc"
    else
        echo -e "  ${RED}[ ]${NC} ${BOLD}$name${NC} — $desc"
    fi
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
print_header "relay-tools installer"

echo "  This installer will set up the relay-tools Nostr stack on your server."
echo "  Each service runs in its own systemd-nspawn container."
echo ""
echo "  The stack is organized into tiers:"
echo ""
echo -e "  ${GREEN}CORE${NC}      — Required. Nostr relay + API server + database + TLS."
echo -e "  ${BLUE}FRONTEND${NC}  — Optional. Public-facing web frontend for your relay service."
echo -e "  ${YELLOW}PAYMENTS${NC}  — Optional. Bitcoin Lightning payments for relay subscriptions."
echo -e "  ${CYAN}EXTRAS${NC}    — Optional. Additional services (IRC, monitoring, etc)."
echo ""

# ─── Check prerequisites ───
print_section "Checking prerequisites"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root.${NC}"
    exit 1
fi

if ! command -v debootstrap &>/dev/null || ! command -v systemd-nspawn &>/dev/null; then
    echo "Installing system prerequisites..."
    bash "$MACHINES_DIR/prereqs.sh"
fi
echo -e "${GREEN}Prerequisites OK${NC}"

# ─── Domain configuration ───
print_section "Domain configuration"

if [ -f "$MACHINES_DIR/.env" ]; then
    source "$MACHINES_DIR/.env"
    echo "Found existing .env with MYDOMAIN=$MYDOMAIN"
    if ! confirm "Use this configuration?"; then
        unset MYDOMAIN MYEMAIL
    fi
fi

if [ -z "$MYDOMAIN" ]; then
    read -rp "Enter your domain name (e.g. mycelium.social): " MYDOMAIN
    if [ -z "$MYDOMAIN" ]; then
        echo -e "${RED}ERROR: Domain name is required.${NC}"
        exit 1
    fi
    read -rp "Email for Let's Encrypt (optional, press Enter to skip): " MYEMAIL
    read -rp "Use self-signed certificate instead of Let's Encrypt? [y/N]: " SELF_SIGNED_ANSWER
    if [[ "$SELF_SIGNED_ANSWER" =~ ^[Yy] ]]; then
        SELF_SIGNED="$MYDOMAIN"
    fi
fi

# ─── Service selection ───
print_header "Service Selection"

# Core (always installed)
echo -e "${GREEN}CORE (always installed):${NC}"
print_service "on" "mysql"              "MariaDB — relay provisioning database"
print_service "on" "strfry"             "strfry — Nostr relay engine (C++, WebSocket)"
print_service "on" "haproxy"            "HAProxy — TLS termination + request routing"
print_service "on" "relaycreator"       "Relay Creator — Express API server + InfernoJS admin panel"
print_service "on" "keys-certs-manager" "Certificate manager — Let's Encrypt auto-renewal"

# Next-Gen Core
echo ""
echo -e "${CYAN}NEXT-GEN BACKEND (optional):${NC}"

INSTALL_MERCURY=false
if confirm "Install Mercury Index-Relay (GitCitadel backend)?" "n"; then
    INSTALL_MERCURY=true
    print_service "on" "mercury" "Mercury — Multi-tenant Index-Relay (Elixir/Phoenix)"
fi

# Frontend
echo ""
echo -e "${BLUE}FRONTEND (optional):${NC}"

INSTALL_RIBBIT=false
INSTALL_MYCELIUM=false
INSTALL_RSTATE=false

if confirm "Install a public web frontend?" "n"; then
    echo ""
    echo "  Choose a frontend:"
    echo -e "  ${BOLD}1)${NC} ribbit    — Bun/Hono Nostr client (ribbit.network)"
    echo -e "  ${BOLD}2)${NC} mycelium  — Bun/Hono Nostr client (mycelium.social, successor to ribbit)"
    echo -e "  ${BOLD}3)${NC} both      — Install both (for migration/testing)"
    echo ""
    read -rp "Selection [1/2/3]: " frontend_choice
    case "$frontend_choice" in
        1) INSTALL_RIBBIT=true ;;
        2) INSTALL_MYCELIUM=true ;;
        3) INSTALL_RIBBIT=true; INSTALL_MYCELIUM=true ;;
        *) echo "Skipping frontend." ;;
    esac

    if [ "$INSTALL_RIBBIT" = true ] || [ "$INSTALL_MYCELIUM" = true ]; then
        if confirm "Install rstate (NIP-66 relay discovery API)?" "y"; then
            INSTALL_RSTATE=true
        fi
    fi
fi

echo ""
if [ "$INSTALL_RIBBIT" = true ]; then print_service "on" "ribbit" "Bun/Hono Nostr client"; fi
if [ "$INSTALL_MYCELIUM" = true ]; then print_service "on" "mycelium" "Bun/Hono Nostr client (successor)"; fi
if [ "$INSTALL_RSTATE" = true ]; then print_service "on" "rstate" "NIP-66 relay discovery API"; fi
if [ "$INSTALL_RIBBIT" = false ] && [ "$INSTALL_MYCELIUM" = false ]; then
    echo "  No frontend selected. Relaycreator will serve all traffic."
fi

# Extras
echo ""
echo -e "${CYAN}EXTRAS (optional):${NC}"

INSTALL_ONI=false
INSTALL_HYPHAE=false
INSTALL_ERGO=false

if confirm "Install Oni live streaming server?" "n"; then
    INSTALL_ONI=true
    print_service "on" "oni" "Oni — Owncast-based live streaming (Go + InfernoJS)"
fi

if confirm "Install Hyphae IRC web client + Ergo IRC server?" "n"; then
    INSTALL_HYPHAE=true
    INSTALL_ERGO=true
    print_service "on" "ergo"   "Ergo — IRC server (chat backend)"
    print_service "on" "hyphae" "Hyphae — IRC web client (Bun + HTMX)"
fi

# Payments
echo ""
echo -e "${YELLOW}PAYMENTS (optional):${NC}"

INSTALL_PAYMENTS=false
INSTALL_COINOS=false

if confirm "Install Bitcoin Lightning payment stack?" "n"; then
    INSTALL_PAYMENTS=true
    print_service "on" "bitcoinknots" "Bitcoin Knots v29.3 — pruned node (BIP-110)"
    print_service "on" "cln"          "Core Lightning — payment channels"
    print_service "on" "lnbits"       "LNBits — wallet management UI"

    if confirm "Install CoinOS wallet server?" "n"; then
        INSTALL_COINOS=true
        print_service "on" "keydb"  "KeyDB — Redis-compatible store"
        print_service "on" "coinos" "CoinOS — NIP-07 wallet server"
    fi
else
    echo "  No payment stack. Relay creation will be free (no invoices)."
fi

# ─── Summary ───
print_header "Installation Summary"

SERVICES=("mysql" "strfry" "haproxy" "relaycreator" "keys-certs-manager")
[ "$INSTALL_MERCURY" = true ] && SERVICES+=("mercury")
[ "$INSTALL_RIBBIT" = true ] && SERVICES+=("ribbit")
[ "$INSTALL_MYCELIUM" = true ] && SERVICES+=("mycelium")
[ "$INSTALL_RSTATE" = true ] && SERVICES+=("rstate")
[ "$INSTALL_ONI" = true ] && SERVICES+=("oni")
[ "$INSTALL_HYPHAE" = true ] && SERVICES+=("hyphae")
[ "$INSTALL_ERGO" = true ] && SERVICES+=("ergo")
[ "$INSTALL_PAYMENTS" = true ] && SERVICES+=("bitcoinknots" "cln" "lnbits")
[ "$INSTALL_COINOS" = true ] && SERVICES+=("keydb" "coinos")

echo -e "  ${BOLD}Domain:${NC}   $MYDOMAIN"
echo -e "  ${BOLD}TLS:${NC}      $([ -n "$SELF_SIGNED" ] && echo "Self-signed" || echo "Let's Encrypt")"
echo -e "  ${BOLD}Services:${NC} ${SERVICES[*]}"
echo ""

if ! confirm "Proceed with installation?"; then
    echo "Aborted."
    exit 0
fi

# ─── Save configuration ───
cat > "$MACHINES_DIR/.env" << EOF
MYDOMAIN=$MYDOMAIN
MYEMAIL=$MYEMAIL
$([ -n "$SELF_SIGNED" ] && echo "SELF_SIGNED=$SELF_SIGNED")
RIBBIT_ENABLED=$INSTALL_RIBBIT
MYCELIUM_ENABLED=$INSTALL_MYCELIUM
RSTATE_ENABLED=$INSTALL_RSTATE
ONI_ENABLED=$INSTALL_ONI
HYPHAE_ENABLED=$INSTALL_HYPHAE
ERGO_ENABLED=$INSTALL_ERGO
PAYMENTS_ENABLED=$INSTALL_PAYMENTS
COINOS_ENABLED=$INSTALL_COINOS
EOF

echo -e "${GREEN}Configuration saved to machines/.env${NC}"

# ─── Build base image ───
print_section "Building base Debian image"

if [ ! -d "$MACHINES_DIR/debian" ]; then
    cd "$MACHINES_DIR"

    # Detect arch
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|arm64) ARCH="arm64" ;;
        x86_64) ARCH="amd64" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac

    PASSWORD=creator
    echo "$PASSWORD" > "$MACHINES_DIR/.passwd"

    debootstrap --include=systemd,dbus stable "$MACHINES_DIR/debian"
    cat "$MACHINES_DIR/bash.bashrc" >> "$MACHINES_DIR/debian/etc/bash.bashrc"

    systemd-nspawn --pipe -q -D "$MACHINES_DIR/debian" /usr/bin/bash << EOF
	apt -y full-upgrade
	apt -y install wget micro
	wget https://go.dev/dl/go1.23.6.linux-${ARCH}.tar.gz
	tar xvf go1.23.6.linux-${ARCH}.tar.gz
	mv go /usr/local/
	echo -e "$PASSWORD\n$PASSWORD" | passwd
EOF
    rm -rf "$MACHINES_DIR/debian/var/cache/apt/archives/"*
    echo -e "${GREEN}Base image built${NC}"
else
    echo "Base image already exists, skipping."
fi

# Create bind mount directories
mkdir -p /etc/systemd/nspawn
mkdir -p /srv/strfry /srv/haproxy /srv/mysql /srv/relaycreator
[ "$INSTALL_RIBBIT" = true ] && mkdir -p /srv/ribbit
[ "$INSTALL_MYCELIUM" = true ] && mkdir -p /srv/mycelium
[ "$INSTALL_RSTATE" = true ] && mkdir -p /srv/rstate
[ "$INSTALL_ONI" = true ] && mkdir -p /srv/oni
[ "$INSTALL_HYPHAE" = true ] && mkdir -p /srv/hyphae
[ "$INSTALL_ERGO" = true ] && mkdir -p /srv/ergo

# Strip CRLF from all scripts (Windows clone protection)
find "$MACHINES_DIR" -type f \( -name "*.sh" -o -name "*.service" -o -name "*.timer" -o -name "*.nspawn" -o -name "*.cfg" -o -name "*.http" -o -name "install" -o -name "configure.sh" -o -name "build" -o -name "clean" -o -name "console" -o -name "start" -o -name "stop" -o -name "status" \) -exec sed -i 's/\r$//' {} +

# ─── Install containers ───
print_section "Installing core containers"

cd "$MACHINES_DIR"

for svc in strfry haproxy mysql relaycreator keys-certs-manager; do
    echo -e "${CYAN}Installing $svc...${NC}"
    cd "$MACHINES_DIR/$svc"
    ./install
    echo -e "${GREEN}$svc installed${NC}"
done

if [ "$INSTALL_MERCURY" = true ]; then
    print_section "Installing mercury backend"
    cd "$MACHINES_DIR/mercury"
    ./install
    echo -e "${GREEN}mercury installed${NC}"
fi

if [ "$INSTALL_RIBBIT" = true ]; then
    print_section "Installing ribbit frontend"
    cd "$MACHINES_DIR/ribbit"
    ./install
    echo -e "${GREEN}ribbit installed${NC}"
fi

if [ "$INSTALL_MYCELIUM" = true ]; then
    print_section "Installing mycelium frontend"
    cd "$MACHINES_DIR/mycelium"
    ./install
    echo -e "${GREEN}mycelium installed${NC}"
fi

if [ "$INSTALL_RSTATE" = true ]; then
    print_section "Installing rstate (NIP-66 relay discovery)"
    cd "$MACHINES_DIR/rstate"
    ./install
    echo -e "${GREEN}rstate installed${NC}"
fi

if [ "$INSTALL_ONI" = true ]; then
    print_section "Installing Oni live streaming"
    cd "$MACHINES_DIR/oni"
    ./install
    echo -e "${GREEN}oni installed${NC}"
fi

if [ "$INSTALL_ERGO" = true ]; then
    print_section "Installing Ergo IRC server"
    cd "$MACHINES_DIR/ergo"
    ./install
    echo -e "${GREEN}ergo installed${NC}"
fi

if [ "$INSTALL_HYPHAE" = true ]; then
    print_section "Installing Hyphae IRC web client"
    cd "$MACHINES_DIR/hyphae"
    ./install
    echo -e "${GREEN}hyphae installed${NC}"
fi

if [ "$INSTALL_PAYMENTS" = true ]; then
    print_section "Installing payment stack"
    for svc in bitcoinknots cln lnbits; do
        echo -e "${CYAN}Installing $svc...${NC}"
        cd "$MACHINES_DIR/$svc"
        ./install
        echo -e "${GREEN}$svc installed${NC}"
    done
fi

if [ "$INSTALL_COINOS" = true ]; then
    print_section "Installing CoinOS stack"
    for svc in keydb coinos; do
        echo -e "${CYAN}Installing $svc...${NC}"
        cd "$MACHINES_DIR/$svc"
        ./install
        echo -e "${GREEN}$svc installed${NC}"
    done
fi

# ─── Configure ───
print_section "Configuring services"

echo "Running configure.sh..."
cd "$MACHINES_DIR"
./configure.sh

# ─── Enable on boot ───
print_section "Enabling services on boot"

for svc in mysql strfry relaycreator haproxy; do
    machinectl enable "$svc" 2>/dev/null || true
    echo -e "  ${GREEN}Enabled${NC} $svc"
done

[ "$INSTALL_MERCURY" = true ] && machinectl enable mercury 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} mercury"
[ "$INSTALL_RIBBIT" = true ] && machinectl enable ribbit 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} ribbit"
[ "$INSTALL_MYCELIUM" = true ] && machinectl enable mycelium 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} mycelium"
[ "$INSTALL_RSTATE" = true ] && machinectl enable rstate 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} rstate"
[ "$INSTALL_ONI" = true ] && machinectl enable oni 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} oni"
[ "$INSTALL_ERGO" = true ] && machinectl enable ergo 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} ergo"
[ "$INSTALL_HYPHAE" = true ] && machinectl enable hyphae 2>/dev/null && echo -e "  ${GREEN}Enabled${NC} hyphae"
[ "$INSTALL_PAYMENTS" = true ] && {
    for svc in bitcoinknots cln lnbits; do
        machinectl enable "$svc" 2>/dev/null || true
        echo -e "  ${GREEN}Enabled${NC} $svc"
    done
}
[ "$INSTALL_COINOS" = true ] && {
    for svc in keydb coinos; do
        machinectl enable "$svc" 2>/dev/null || true
        echo -e "  ${GREEN}Enabled${NC} $svc"
    done
}

# ─── Done ───
print_header "Installation Complete!"

echo -e "  ${BOLD}Your relay-tools stack is running at:${NC}"
echo ""
echo -e "  ${GREEN}https://$MYDOMAIN${NC}           — Main site"
echo -e "  ${GREEN}https://app.$MYDOMAIN${NC}       — Relay Creator admin"
if [ "$INSTALL_ONI" = true ]; then
    echo -e "  ${GREEN}https://live.$MYDOMAIN${NC}      — Oni live streaming"
fi
if [ "$INSTALL_HYPHAE" = true ]; then
    echo -e "  ${GREEN}https://chat.$MYDOMAIN${NC}      — Hyphae IRC web client"
fi
echo ""
echo -e "  ${BOLD}Installed services:${NC}"
for svc in "${SERVICES[@]}"; do
    echo -e "    ${GREEN}●${NC} $svc"
done

echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo ""
echo "  machinectl list                          — List running containers"
echo "  machinectl shell <name> /bin/bash        — Shell into a container"
echo "  machinectl status <name>                 — Container status"
echo "  bash scripts/relaycreator-rebuild.sh     — Manual relaycreator rebuild"
echo ""

if [ "$INSTALL_PAYMENTS" = true ]; then
    echo -e "  ${YELLOW}PAYMENT STACK NEXT STEPS:${NC}"
    echo "  1. Wait for Bitcoin Knots to finish IBD (1-3 days for pruned mode)"
    echo "  2. Open a Lightning channel"
    echo "  3. Create a wallet in LNBits UI and copy Admin Key + Invoice Read Key"
    echo "  4. Set LNBITS_ADMIN_KEY and LNBITS_INVOICE_READ_KEY in /srv/relaycreator/.env"
    echo "  5. Restart relaycreator: machinectl shell relaycreator systemctl restart app"
    echo ""
fi

echo -e "  ${BOLD}Auto-deploy:${NC} relaycreator checks for git updates every 60 seconds."
echo "  Push to TekkadanPlays/relaycreator.git and changes deploy automatically."
echo ""
echo -e "${GREEN}All done!${NC}"
