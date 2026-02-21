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
cd /app && git fetch origin && git reset --hard origin/main
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
cd /app/nostr-watch && git pull origin main
cd /app/nostr-watch/apps/rstate
bun install
bun run build
cp -r dist/* /app/rstate/
cp package.json /app/rstate/
cd /app/rstate
bun install --production
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
    echo -e "${CYAN}Upgrading Mycelium Live (oni)...${NC}"
    nsrun oni '
cd /app/live
git reset --hard HEAD
git clean -fd dist/ 2>/dev/null
git pull origin main

# Rebuild Inferno frontend
bun install --frozen-lockfile || bun install
bun run build

# Restart web server
systemctl restart app

# Pull latest OME Docker image if available
docker pull airensoft/ovenmediaengine:latest 2>/dev/null && systemctl restart ome || true

echo "Mycelium Live rebuilt and restarted"
systemctl status app --no-pager -l || true
systemctl status ome --no-pager -l || true
'
    echo -e "${GREEN}oni (Mycelium Live) upgraded${NC}"
}

# ─── Interactive mode ───
if [ -z "$1" ]; then
    echo -e "${BOLD}Available services to upgrade:${NC}"
    echo ""

    # Check which containers are running
    for svc in relaycreator ribbit mycelium rstate oni strfry haproxy coinos; do
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
    relaycreator) upgrade_relaycreator ;;
    ribbit)       upgrade_ribbit ;;
    mycelium)     upgrade_mycelium ;;
    rstate)       upgrade_rstate ;;
    strfry)       upgrade_strfry "$REBUILD" ;;
    haproxy)      upgrade_haproxy ;;
    coinos)       upgrade_coinos ;;
    oni)          upgrade_oni ;;
    *)
        echo -e "${RED}Unknown service: $SERVICE${NC}"
        echo "Available: relaycreator, ribbit, mycelium, rstate, oni, strfry, haproxy, coinos"
        exit 1
        ;;
esac
