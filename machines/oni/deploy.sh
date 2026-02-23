#!/bin/bash

export PATH=/usr/local/bin:$PATH
LIVE_DIR=/app/live
REPO_URL="https://github.com/TekkadanPlays/mycelium-live.git"

git config --global --add safe.directory "$LIVE_DIR" 2>/dev/null

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

deploy_app() {
    echo "deploying mycelium-live..."

    cd "$LIVE_DIR"
    git pull origin master || { echo "ERROR: git pull failed"; return 1; }

    echo "→ Installing dependencies..."
    bun install

    echo "→ Building frontend..."
    bun run build.ts

    echo "→ Restarting server..."
    systemctl restart app

    echo "→ Mycelium Live deploy complete"
}

# First run: clone the repo if it doesn't exist
if [ ! -d "$LIVE_DIR/.git" ]; then
    echo "First run: cloning mycelium-live"
    git clone "$REPO_URL" "$LIVE_DIR"
    cd "$LIVE_DIR"
    bun install
    bun run build.ts
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

cd "$LIVE_DIR"

# Ensure remote points to the correct repo
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$REPO_URL" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $REPO_URL"
    git remote set-url origin "$REPO_URL"
fi

git fetch origin 2>/dev/null || true

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
