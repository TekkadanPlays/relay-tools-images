#!/bin/bash
# Quick rebuild + deploy relaycreator frontend from latest git
# Usage: bash ~/relay-tools-images/machines/relaycreator/rebuild-frontend.sh

set -e

echo "→ Pulling latest code..."
machinectl shell relaycreator /bin/bash -c "cd /app && git fetch origin && git reset --hard origin/main"

echo "→ Building frontend..."
machinectl shell relaycreator /bin/bash -c "cd /app/web && bun install && bun run build"

echo "→ Restarting app..."
machinectl shell relaycreator /bin/bash -c "systemctl restart app"

echo "✓ Relaycreator frontend deployed"
