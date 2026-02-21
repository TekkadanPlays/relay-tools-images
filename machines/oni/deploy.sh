#!/bin/bash

export PATH=/usr/local/bin:$PATH
git config --global --add safe.directory /app/live 2>/dev/null

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

deploy_app() {
    echo "deploying mycelium live..."

    cd /app/live

    # Discard local changes (build artifacts from previous bun run build)
    git reset --hard HEAD
    git clean -fd dist/ 2>/dev/null

    git pull origin main || { echo "ERROR: git pull failed"; return 1; }

    # Rebuild Inferno frontend
    echo "→ Building Inferno frontend..."
    bun install --frozen-lockfile || bun install
    bun run build

    # Restart services
    echo "→ Restarting services..."
    systemctl restart app

    # Pull latest OME image if available (non-blocking)
    docker pull airensoft/ovenmediaengine:latest 2>/dev/null && systemctl restart ome || true

    echo "→ Mycelium Live deploy complete"
}

# Ensure /app/live exists
if [ ! -d "/app/live" ]; then
    mkdir -p /app/live
fi

cd /app/live

# First run: clone the repo
if [ ! -f "/firstrun.txt" ]; then
    echo "First run: cloning and building app"
    if [ ! -f "/app/live/package.json" ]; then
        git clone https://github.com/TekkadanPlays/mycelium-live.git /app/live-tmp
        mv /app/live-tmp/* /app/live-tmp/.* /app/live/ 2>/dev/null || true
        rm -rf /app/live-tmp
    fi
    cd /app/live
    bun install --frozen-lockfile || bun install
    bun run build
    touch /firstrun.txt
    systemctl restart ome
    systemctl restart app
    exit 0
fi

# Ensure remote points to the correct repo
EXPECTED_REMOTE="https://github.com/TekkadanPlays/mycelium-live.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git fetch origin 2>/dev/null || true

if [ "$FORCE" = "1" ]; then
    echo "forced rebuild requested"
    deploy_app
    exit 0
fi

LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse origin/main 2>/dev/null)
if [ "$LOCAL" != "$REMOTE" ]; then
    echo "detected upstream changes ($LOCAL -> $REMOTE)"
    deploy_app
fi
