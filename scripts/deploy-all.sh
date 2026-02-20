#!/bin/bash
# Pull latest relay-tools-images, then rebuild/restart all services
# Run on the HOST as root
# Usage: bash scripts/deploy-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Full Stack Deploy ==="
echo ""

echo "--- 1. Pull latest relay-tools-images ---"
cd "$(dirname "$SCRIPT_DIR")"
git pull origin main

echo ""
echo "--- 2. Fix KeyDB (if needed) ---"
bash "$SCRIPT_DIR/keydb-fix.sh"

echo ""
echo "--- 3. Restart CoinOS ---"
bash "$SCRIPT_DIR/coinos-restart.sh"

echo ""
echo "--- 4. Rebuild Relaycreator ---"
bash "$SCRIPT_DIR/relaycreator-rebuild.sh"

echo ""
echo "--- 5. Rebuild Oni (if running) ---"
if machinectl show oni &>/dev/null; then
    PID=$(machinectl show oni -p Leader --value)
    nsenter -t "$PID" -m -u -i -n -p -- bash /usr/local/bin/deploy.sh --force
else
    echo "Oni container not running, skipping."
fi

echo ""
echo "--- 6. Final Status ---"
bash "$SCRIPT_DIR/status.sh"

echo ""
echo "=== Full Stack Deploy Complete ==="
