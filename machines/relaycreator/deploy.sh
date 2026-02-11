#!/bin/bash

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
    systemctl stop app
    pnpm install
    npx prisma db push --accept-data-loss 2>/dev/null || npx prisma migrate deploy || true
    pnpm run build
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
    # First run: push schema to DB, build, and start
    echo "First run: initializing database schema and building app"
    npx prisma db push --accept-data-loss 2>/dev/null || true
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi