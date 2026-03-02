#!/bin/bash
set -e

##
### Upgrade individual services in the relay-tools stack.
### Usage: ./upgrade.sh <service-name> [--rebuild]
###
### Examples:
###   ./upgrade.sh relaycreator          # Pull latest code + rebuild
###   ./upgrade.sh ribbit                # Pull latest code + rebuild
###   ./upgrade.sh strfry --rebuild      # Rebuild from source (recompile)
###   ./upgrade.sh                       # Interactive: list services and pick one
##

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINES_DIR="$SCRIPT_DIR/machines"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root.${NC}"
    exit 1
fi

get_pid() {
    local name=$1
    machinectl show "$name" -p Leader --value 2>/dev/null
}

container_running() {
    local name=$1
    machinectl show "$name" -p State --value 2>/dev/null | grep -q "running"
}

nsrun() {
    local name=$1
    shift
    local pid
    pid=$(get_pid "$name")
    if [ -z "$pid" ]; then
        echo -e "${RED}Container '$name' is not running. Start it first: machinectl start $name${NC}"
        return 1
    fi
    nsenter -t "$pid" -m -u -i -n -p -- bash -c "$*"
}

upgrade_relaycreator() {
    echo -e "${CYAN}Upgrading relaycreator...${NC}"
    nsrun relaycreator '
cd /app && git fetch origin && git reset --hard origin/local
systemctl stop app

# Build Express API server
cd /app/api-server
npm install
npx prisma generate
npx prisma db push --accept-data-loss 2>/dev/null || true
npm run build

# Build InfernoJS SPA
cd /app/web
bun install
bun run build

cd /app
systemctl start app
sleep 2
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}relaycreator upgraded${NC}"
}

upgrade_ribbit() {
    echo -e "${CYAN}Upgrading ribbit...${NC}"
    nsrun ribbit '
cd /app && git pull origin main

# Rebuild frontend
cd /app/ribbit
bun install
NODE_ENV=production bun run build
systemctl restart app

echo "ribbit frontend rebuilt and restarted"
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}ribbit upgraded${NC}"
}

upgrade_mycelium() {
    echo -e "${CYAN}Upgrading mycelium...${NC}"
    nsrun mycelium '
cd /app && git pull origin main

# Rebuild frontend
cd /app/ribbit
bun install
NODE_ENV=production bun run build
systemctl restart app

echo "mycelium frontend rebuilt and restarted"
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}mycelium upgraded${NC}"
}

upgrade_rstate() {
    echo -e "${CYAN}Upgrading rstate...${NC}"
    nsrun rstate '
cd /app/nostr-watch && git fetch origin && git reset --hard origin/main

# Install from monorepo root so workspace deps resolve
bun install

# Build rstate app
cd /app/nostr-watch/apps/rstate
bun run build
mkdir -p /app/rstate
cp -r dist/* /app/rstate/
cp package.json /app/rstate/

# Install production deps — link workspace packages from monorepo
cd /app/rstate
bun install --production 2>/dev/null || true

systemctl restart app
echo "rstate rebuilt and restarted"
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}rstate upgraded${NC}"
}

upgrade_strfry() {
    local rebuild=$1
    echo -e "${CYAN}Upgrading strfry...${NC}"
    if [ "$rebuild" = "--rebuild" ]; then
        echo -e "${YELLOW}Full rebuild from source (this may take a while)...${NC}"
        nsrun strfry '
cd /app
git fetch origin
git checkout tags/1.0.4
git submodule update --init
make setup-golpe
make -j4
systemctl restart strfry 2>/dev/null || true
echo "strfry rebuilt from source"
'
    else
        echo "strfry is a compiled binary — use --rebuild to recompile from source."
        echo "To update cookiecutter/spamblaster/interceptor:"
        nsrun strfry '
cd /cookiecutter && git pull origin main && go build -x && cp cookiecutter /usr/local/bin/
cd /spamblaster && git pull origin main && go build -x && cp spamblaster /usr/local/bin/
cd /interceptor && git pull origin main && go build -x && cp interceptor /usr/local/bin/
echo "cookiecutter, spamblaster, interceptor updated"
'
    fi
    echo -e "${GREEN}strfry upgraded${NC}"
}

upgrade_haproxy() {
    echo -e "${CYAN}Upgrading haproxy config tools...${NC}"
    nsrun haproxy '
cd /app && git pull origin main
go build -x
cp cookiecutter /usr/local/bin/cookiecutter
echo "cookiecutter updated"
'
    echo -e "${GREEN}haproxy upgraded${NC}"
}

upgrade_coinos() {
    echo -e "${CYAN}Upgrading coinos...${NC}"
    nsrun coinos '
cd /app && git pull origin main
bun install
systemctl restart app
sleep 2
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}coinos upgraded${NC}"
}

upgrade_oni() {
    local force=$1
    echo -e "${CYAN}Upgrading oni...${NC}"
    if [ "$force" = "--force" ]; then
        nsrun oni 'bash /usr/local/bin/deploy.sh --force'
    else
        nsrun oni 'bash /usr/local/bin/deploy.sh --force'
    fi
    echo -e "${GREEN}oni upgraded${NC}"
}

upgrade_hyphae() {
    echo -e "${CYAN}Upgrading hyphae...${NC}"
    nsrun hyphae '
cd /app && git pull origin main
systemctl stop app
bun install
bun run build:css
bun run build:client
systemctl start app
sleep 2
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}hyphae upgraded${NC}"
}

upgrade_ergo() {
    echo -e "${CYAN}Upgrading ergo...${NC}"
    echo "ergo is a pre-built binary. To update:"
    echo "  1. Download new release from https://github.com/ergochat/ergo/releases"
    echo "  2. Copy binary into container: machinectl copy-to ergo /path/to/ergo /usr/local/bin/ergo"
    echo "  3. Restart: nsrun ergo 'systemctl restart app'"
    echo ""
    echo "To reload config without upgrading:"
    nsrun ergo 'systemctl restart app'
    echo -e "${GREEN}ergo config reloaded${NC}"
}

upgrade_bitcoinknots() {
    echo -e "${CYAN}Restarting bitcoinknots...${NC}"
    nsrun bitcoinknots 'systemctl restart app && sleep 3 && systemctl status app --no-pager -l || true'
    echo -e "${GREEN}bitcoinknots restarted${NC}"
}

upgrade_cln() {
    echo -e "${CYAN}Restarting Core Lightning...${NC}"
    nsrun cln 'systemctl restart app && sleep 3 && systemctl status app --no-pager -l || true'
    echo -e "${GREEN}cln restarted${NC}"
}

upgrade_lnbits() {
    echo -e "${CYAN}Upgrading lnbits...${NC}"
    nsrun lnbits '
cd /app && git pull origin main
poetry install 2>/dev/null || pip install -r requirements.txt 2>/dev/null || true
systemctl restart app
sleep 2
systemctl status app --no-pager -l || true
'
    echo -e "${GREEN}lnbits upgraded${NC}"
}

upgrade_keydb() {
    echo -e "${CYAN}Restarting keydb...${NC}"
    nsrun keydb 'systemctl restart app && sleep 2 && systemctl status app --no-pager -l || true'
    echo -e "${GREEN}keydb restarted${NC}"
}

# ─── Interactive mode ───
if [ -z "$1" ]; then
    echo -e "${BOLD}Available services to upgrade:${NC}"
    echo ""

    # Check which containers are running
    for svc in relaycreator ribbit mycelium rstate strfry haproxy oni hyphae ergo coinos bitcoinknots cln lnbits keydb; do
        if container_running "$svc"; then
            echo -e "  ${GREEN}●${NC} $svc"
        else
            echo -e "  ${RED}○${NC} $svc (not running)"
        fi
    done

    echo ""
    read -rp "Service to upgrade: " SERVICE
    if [ -z "$SERVICE" ]; then
        echo "No service selected."
        exit 0
    fi
else
    SERVICE=$1
fi

REBUILD=${2:-}

case "$SERVICE" in
    relaycreator)  upgrade_relaycreator ;;
    ribbit)        upgrade_ribbit ;;
    mycelium)      upgrade_mycelium ;;
    rstate)        upgrade_rstate ;;
    strfry)        upgrade_strfry "$REBUILD" ;;
    haproxy)       upgrade_haproxy ;;
    coinos)        upgrade_coinos ;;
    oni)           upgrade_oni "$REBUILD" ;;
    hyphae)        upgrade_hyphae ;;
    ergo)          upgrade_ergo ;;
    bitcoinknots)  upgrade_bitcoinknots ;;
    cln)           upgrade_cln ;;
    lnbits)        upgrade_lnbits ;;
    keydb)         upgrade_keydb ;;
    *)
        echo -e "${RED}Unknown service: $SERVICE${NC}"
        echo "Available: relaycreator, ribbit, mycelium, rstate, strfry, haproxy, coinos, oni, hyphae, ergo, bitcoinknots, cln, lnbits, keydb"
        exit 1
        ;;
esac
