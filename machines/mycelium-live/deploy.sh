#!/bin/bash

export PATH=/usr/local/bin:$PATH
git config --global --add safe.directory /app 2>/dev/null

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

deploy_app() {
    echo "deploying mycelium-live..."
    git pull origin master || { echo "ERROR: git pull failed"; return 1; }
    systemctl stop app

    echo "→ Installing dependencies..."
    bun install --frozen-lockfile || bun install

    echo "→ Building frontend..."
    bun run build.ts

    systemctl start app
    echo "→ Mycelium Live deploy complete"
}

cd /app

# Ensure remote points to the correct repo
EXPECTED_REMOTE="https://github.com/TekkadanPlays/mycelium-live.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git fetch origin 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: cloning and building app"
    if [ ! -f "/app/server.ts" ]; then
        git clone https://github.com/TekkadanPlays/mycelium-live.git /app/repo-tmp
        mv /app/repo-tmp/* /app/repo-tmp/.* /app/ 2>/dev/null || true
        rm -rf /app/repo-tmp
    fi
    bun install --frozen-lockfile || bun install
    bun run build.ts
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if [ "$FORCE" = "1" ]; then
    echo "forced rebuild requested"
    deploy_app
    exit 0
fi

LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse origin/master 2>/dev/null)
if [ "$LOCAL" != "$REMOTE" ]; then
    echo "detected upstream changes ($LOCAL -> $REMOTE)"
    deploy_app
fi
