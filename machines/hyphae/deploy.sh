#!/bin/bash

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
    systemctl stop app

    # Rebuild hyphae
    cd /app
    bun install
    bun run build:css
    bun run build:client

    systemctl start app
}

cd /app

# Ensure remote points to the correct repo
EXPECTED_REMOTE="https://github.com/nickkadutskyi/hyphae.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git remote update 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    echo "First run: cloning and building app"
    # Clone repo onto the bind mount (first time only)
    if [ ! -f "/app/package.json" ]; then
        git clone https://github.com/nickkadutskyi/hyphae.git /app/repo-tmp
        mv /app/repo-tmp/* /app/repo-tmp/.* /app/ 2>/dev/null || true
        rm -rf /app/repo-tmp
    fi
    cd /app
    bun install
    bun run build:css
    bun run build:client
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi
