#!/bin/bash

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
    systemctl stop app

    # Rebuild the frontend
    cd /app/ribbit
    bun install
    NODE_ENV=production bun run build

    cd /app
    systemctl start app
}

deploy_rstate() {
    echo "updating rstate relay discovery API"
    systemctl stop rstate 2>/dev/null || true

    cd /app/nostr-watch
    git pull 2>/dev/null || true
    cd /app/nostr-watch/apps/rstate
    npm install
    npm run build
    mkdir -p /app/rstate
    cp -r dist/* /app/rstate/
    cp package.json /app/rstate/
    cd /app/rstate
    npm install --omit=dev

    systemctl start rstate
}

cd /app

# Ensure remote points to the correct repo
EXPECTED_REMOTE="https://github.com/TekkadanPlays/ribbit.network.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git remote update 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: building app"
    cd /app/ribbit
    NODE_ENV=production bun run build
    cd /app
    deploy_rstate
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi

# Check for rstate updates independently
if [ -d "/app/nostr-watch/.git" ]; then
    cd /app/nostr-watch
    git remote update 2>/dev/null || true
    if git status -uno 2>/dev/null | grep -q "is behind"; then
        deploy_rstate
    fi
fi
