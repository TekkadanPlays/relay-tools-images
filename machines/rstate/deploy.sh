#!/bin/bash

deploy_rstate() {
    echo "updating rstate relay discovery API"
    systemctl stop app 2>/dev/null || true

    cd /app/nostr-watch
    git pull 2>/dev/null || true
    cd /app/nostr-watch/apps/rstate
    bun install
    bun run build
    mkdir -p /app/rstate
    cp -r dist/* /app/rstate/
    cp package.json /app/rstate/
    cd /app/rstate
    bun install --production

    systemctl start app
}

cd /app

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: building rstate"
    deploy_rstate
    touch /firstrun.txt
    exit 0
fi

# Check for nostr-watch upstream updates
if [ -d "/app/nostr-watch/.git" ]; then
    cd /app/nostr-watch
    git remote update 2>/dev/null || true
    if git status -uno 2>/dev/null | grep -q "is behind"; then
        deploy_rstate
    fi
fi
