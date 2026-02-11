#!/bin/bash
systemd-nspawn --pipe -q -M relaycreator /bin/bash << 'EOF'
cd /app
git remote set-url origin https://github.com/TekkadanPlays/relaycreator.git
git fetch origin
git reset --hard origin/main
systemctl stop app
pnpm install
npx prisma db push --accept-data-loss 2>/dev/null || true
pnpm run build
systemctl start app
echo "Step 2 done: Deploy complete"
EOF
