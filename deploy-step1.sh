#!/bin/bash
cat > /var/lib/machines/relaycreator/usr/local/bin/deploy.sh << 'SCRIPT'
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
SCRIPT
echo "Step 1 done: deploy.sh updated"
