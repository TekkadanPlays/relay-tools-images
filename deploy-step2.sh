#!/bin/bash
# Hotfix: force-deploy the latest relaycreator code inside the running container.
machinectl shell relaycreator /bin/bash -c '
cd /app
git remote set-url origin https://github.com/TekkadanPlays/relaycreator.git
git fetch origin
git reset --hard origin/main
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
echo "Step 2 done: Deploy complete"
'
