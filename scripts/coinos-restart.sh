#!/bin/bash
# Restart CoinOS and verify health
# Run on the HOST as root
set -euo pipefail

echo "=== CoinOS Restart ==="

PID=$(machinectl show coinos -p Leader --value 2>/dev/null) || true
if [ -z "$PID" ]; then
    echo "coinos container not running. Starting..."
    machinectl start coinos
    sleep 5
    PID=$(machinectl show coinos -p Leader --value)
fi

echo ""
echo "--- Restarting app service ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl restart app
sleep 5

echo ""
echo "--- Status ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl status app --no-pager || true

echo ""
echo -n "Health check (port 3119): "
curl -sf http://127.0.0.1:3119/health 2>/dev/null || echo "UNREACHABLE"
echo ""

echo ""
echo "=== Done ==="
