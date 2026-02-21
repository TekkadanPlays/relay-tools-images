#!/bin/bash

export TMPDIR=/app/tmp
export PATH=/usr/local/go/bin:/usr/local/bin:$PATH
mkdir -p /app/tmp
git config --global --add safe.directory /app 2>/dev/null

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

deploy_app() {
    echo "deploying oni..."
    git pull origin main
    systemctl stop app

    # Rebuild Inferno frontend FIRST (outputs to static/web/)
    # Must happen before Go build because go:embed bakes static/web/ into the binary
    echo "→ Building Inferno frontend..."
    cd /app/web-inferno
    rm -rf node_modules
    bun install --frozen-lockfile || bun install
    bun run build.ts
    cd /app

    # Rebuild Go binary (embeds the freshly built static/web/)
    echo "→ Building Go binary..."
    TMPDIR=/app/tmp go build -o oni .

    systemctl start app
    echo "→ Oni deploy complete"
}

cd /app

# Ensure remote points to the correct repo
EXPECTED_REMOTE="https://github.com/TekkadanPlays/oni.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git fetch origin 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: cloning and building app"
    if [ ! -f "/app/main.go" ]; then
        git clone https://github.com/TekkadanPlays/oni.git /app/repo-tmp
        mv /app/repo-tmp/* /app/repo-tmp/.* /app/ 2>/dev/null || true
        rm -rf /app/repo-tmp
    fi
    # Build Inferno frontend FIRST (go:embed needs fresh static/web/)
    cd /app/web-inferno
    rm -rf node_modules
    bun install --frozen-lockfile || bun install
    bun run build.ts
    cd /app
    # Build Go binary (embeds the freshly built static/web/)
    TMPDIR=/app/tmp go build -o oni .
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
REMOTE=$(git rev-parse origin/main 2>/dev/null)
if [ "$LOCAL" != "$REMOTE" ]; then
    echo "detected upstream changes ($LOCAL -> $REMOTE)"
    deploy_app
fi
