#!/bin/bash

deploy_app() {
    echo "detected upstream changes, deploying coinos-server"
    git pull
    bun install
    # Restart handled by systemd
}

cd /app

# Ensure remote points to the correct fork
EXPECTED_REMOTE="https://github.com/TekkadanPlays/coinos-server.git"
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "Updating git remote from $CURRENT_REMOTE to $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

git remote update 2>/dev/null || true

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi
