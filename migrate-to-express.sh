#!/bin/bash
# Migration script: Next.js -> Express API + React SPA
# Run on server as root: bash /root/migrate-to-express.sh
set -e

echo "=== Step 1: Generate JWT_SECRET and update .env ==="
JWT_SECRET=$(openssl rand -base64 32)

# Read existing DATABASE_URL and DEPLOY_PUBKEY from current .env
source /srv/relaycreator/.env 2>/dev/null || true

# Detect domain from existing config
MYDOMAIN=${NEXT_PUBLIC_CREATOR_DOMAIN:-$(hostname -f)}

# Write new .env for Express API server
cat << EOF > /srv/relaycreator/.env
# Express API server settings
DATABASE_URL=$DATABASE_URL
JWT_SECRET=$JWT_SECRET
PORT=4000
CORS_ORIGIN=https://$MYDOMAIN
DEPLOY_PUBKEY=$DEPLOY_PUBKEY
CREATOR_DOMAIN=$MYDOMAIN
INVOICE_AMOUNT=21
INVOICE_PREMIUM_AMOUNT=2100

# Payment settings (preserved from previous config)
PAYMENTS_ENABLED=${PAYMENTS_ENABLED:-false}
LNBITS_ADMIN_KEY=${LNBITS_ADMIN_KEY:-}
LNBITS_INVOICE_READ_KEY=${LNBITS_INVOICE_READ_KEY:-}
LNBITS_ENDPOINT=${LNBITS_ENDPOINT:-}
EOF

echo "New .env written to /srv/relaycreator/.env"
cat /srv/relaycreator/.env

echo ""
echo "=== Step 2: Update app.service inside container ==="
cat > /var/lib/machines/relaycreator/lib/systemd/system/app.service << 'SERVICE'
[Unit]
Description=relaycreator app
Wants=network.target

[Service]
ExecStart=/usr/bin/node /app/api-server/dist/index.js
WorkingDirectory=/app/api-server
Restart=always
User=root
EnvironmentFile=/app/.env
Environment=NODE_ENV=production
Type=simple
TimeoutStopSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
SERVICE

echo "app.service updated"

echo ""
echo "=== Step 3: Update deploy.sh inside container ==="
cat > /var/lib/machines/relaycreator/usr/local/bin/deploy.sh << 'DEPLOY'
#!/bin/bash

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
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
}

cd /app

# Ensure remote points to the correct fork
EXPECTED_REMOTE="https://github.com/TekkadanPlays/relaycreator.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git remote update 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: initializing database schema and building app"
    cd /app/api-server
    npx prisma db push --accept-data-loss 2>/dev/null || true
    cd /app
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi
DEPLOY

echo "deploy.sh updated"

echo ""
echo "=== Step 4: Update HAProxy config ==="
# HAProxy config is bind-mounted from /srv/haproxy/ on host to /etc/haproxy/ in container
sed -i 's/127.0.0.1:3000/127.0.0.1:4000/g' /srv/haproxy/haproxy.cfg
echo "HAProxy backend updated to :4000"

echo ""
echo "=== Step 5: Pull latest code and build inside container ==="
# Use nsenter to run commands inside the running container
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- /bin/bash -c '
set -e
cd /app
git fetch origin
git reset --hard origin/main

echo "--- Building Express API server ---"
cd /app/api-server
pnpm install
npx prisma generate
npx prisma db push --accept-data-loss 2>/dev/null || true
npx tsc

echo "--- Building React SPA ---"
cd /app/web
pnpm install
npx vite build

echo "--- Reloading systemd and restarting app ---"
systemctl daemon-reload
systemctl restart app

echo "--- Build complete ---"
'

echo ""
echo "=== Step 6: Reload HAProxy ==="
PID_HP=$(machinectl show haproxy -p Leader --value)
nsenter -t $PID_HP -m -u -i -n -p -- /bin/bash -c 'systemctl reload haproxy || systemctl restart haproxy'

echo ""
echo "=== Step 7: Verify ==="
sleep 3
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- /bin/bash -c '
echo "=== App status ==="
systemctl status app --no-pager -l | head -15
echo ""
echo "=== Health check ==="
curl -s http://127.0.0.1:4000/health
echo ""
'

echo ""
echo "=== Migration complete! ==="
echo "Test: curl -s https://$MYDOMAIN/health"
echo "Test: open https://$MYDOMAIN in browser"
