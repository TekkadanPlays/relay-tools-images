#!/bin/bash
# Rebuild + deploy relaycreator from latest git
# Usage: bash ~/relay-tools-images/machines/relaycreator/rebuild-frontend.sh
#   --full    also rebuild API server (npm install, prisma, build)
#   (default) frontend only (bun install + bun run build + restart)

set -e

FULL=false
if [ "$1" = "--full" ]; then FULL=true; fi

PID=$(machinectl show relaycreator -p Leader --value)
run() { nsenter -t "$PID" -m -u -i -n -p -- bash -c "$1"; }

echo "→ Pulling latest code..."
run "cd /app && git fetch origin && git reset --hard origin/main"

if [ "$FULL" = true ]; then
  echo "→ Building API server..."
  run "cd /app/api-server && npm install && npx prisma generate && npm run build"
fi

echo "→ Building frontend..."
run "cd /app/web && bun install && bun run build"

echo "→ Restarting app..."
run "systemctl restart app"

echo "✓ Relaycreator deployed"
