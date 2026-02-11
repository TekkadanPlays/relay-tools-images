#!/bin/bash
systemd-nspawn --pipe -q -M relaycreator /bin/bash << 'EOF'
cd /app
echo "=== Git remote ==="
git remote get-url origin
echo "=== Last commit ==="
git log --oneline -1
echo "=== Prisma version ==="
npx prisma --version 2>/dev/null | head -3
echo "=== App status ==="
systemctl status app --no-pager -l
EOF
