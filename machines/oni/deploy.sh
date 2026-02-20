#!/bin/bash

export TMPDIR=/app/tmp
export PATH=/usr/local/go/bin:/usr/local/bin:$PATH
mkdir -p /app/tmp
git config --global --add safe.directory /app 2>/dev/null

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
    systemctl stop app

    # Rebuild Go binary
    echo "→ Building Go binary..."
    TMPDIR=/app/tmp go build -o oni .

    # Rebuild Inferno frontend (outputs to static/web/)
    echo "→ Building Inferno frontend..."
    cd /app/web-inferno
    rm -rf node_modules
    bun install --frozen-lockfile || bun install
    bun run build.ts
    cd /app

    systemctl start app
}

cd /app

# Ensure remote points to the correct repo
EXPECTED_REMOTE="https://github.com/TekkadanPlays/oni.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git remote update 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: cloning and building app"
    if [ ! -f "/app/main.go" ]; then
        git clone https://github.com/TekkadanPlays/oni.git /app/repo-tmp
        mv /app/repo-tmp/* /app/repo-tmp/.* /app/ 2>/dev/null || true
        rm -rf /app/repo-tmp
    fi
    # Build Go binary
    TMPDIR=/app/tmp go build -o oni .
    # Build Inferno frontend
    cd /app/web-inferno
    rm -rf node_modules
    bun install --frozen-lockfile || bun install
    bun run build.ts
    cd /app
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi
