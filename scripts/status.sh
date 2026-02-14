#!/bin/bash
# Quick status check for all containers and services
set -euo pipefail

echo "=== Container Status ==="
machinectl list
echo ""

for MACHINE in cln coinos keydb relaycreator bitcoinknots haproxy strfry mysql keys-certs-manager; do
    PID=$(machinectl show "$MACHINE" -p Leader --value 2>/dev/null) || true
    if [ -z "$PID" ] || [ "$PID" = "" ]; then
        echo "[$MACHINE] NOT RUNNING"
    else
        STATUS=$(nsenter -t "$PID" -m -u -i -n -p -- systemctl is-active app 2>/dev/null || echo "no app service")
        echo "[$MACHINE] running (PID leader=$PID) | app=$STATUS"
    fi
done

echo ""
echo "=== Quick Health Checks ==="
echo -n "CoinOS (port 3119): "
curl -sf http://127.0.0.1:3119/health 2>/dev/null || echo "UNREACHABLE"
echo ""
echo -n "Relaycreator (port 4000): "
curl -sf http://127.0.0.1:4000/health 2>/dev/null || echo "UNREACHABLE"
echo ""
