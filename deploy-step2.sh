#!/bin/bash
systemd-nspawn --pipe -q -M relaycreator /bin/bash << 'EOF'
cd /app
git remote set-url origin https://github.com/TekkadanPlays/relaycreator.git
git fetch origin
git reset --hard origin/main
systemctl stop app

# Build Express API server
cd /app/api-server
pnpm install
npx prisma generate
npx prisma db push --accept-data-loss 2>/dev/null || true
npx tsc

# Build React SPA
cd /app/web
pnpm install
npx vite build

cd /app
systemctl start app
echo "Step 2 done: Deploy complete"
EOF
