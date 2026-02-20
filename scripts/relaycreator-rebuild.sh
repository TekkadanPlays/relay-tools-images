#!/bin/bash
# Rebuild relaycreator — pull from GitHub, install deps, build, restart
# Run on the HOST as root
set -euo pipefail

echo "=== Relaycreator Rebuild ==="

PID=$(machinectl show relaycreator -p Leader --value 2>/dev/null) || true
if [ -z "$PID" ]; then
    echo "relaycreator container not running. Starting..."
    machinectl start relaycreator
    sleep 5
    PID=$(machinectl show relaycreator -p Leader --value)
fi

echo ""
echo "--- Pulling latest from GitHub ---"
nsenter -t "$PID" -m -u -i -n -p -- bash -c 'cd /app && git pull origin main'

echo ""
echo "--- Building API server ---"
nsenter -t "$PID" -m -u -i -n -p -- bash -c '
cd /app/api-server
npm install
npx prisma generate
npx prisma db push --accept-data-loss 2>/dev/null || npx prisma db push
npm run build
'

echo ""
echo "--- Building Web SPA ---"
nsenter -t "$PID" -m -u -i -n -p -- bash -c '
cd /app/web
bun install
bun run build
'

echo ""
echo "--- Restarting app service ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl restart app
sleep 3

echo ""
echo "--- Status ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl status app --no-pager || true

echo ""
echo -n "Health check: "
curl -sf http://127.0.0.1:4000/health 2>/dev/null || echo "UNREACHABLE"
echo ""

echo ""
echo "=== Done ==="
