#!/bin/bash

KAJI_DIR="/app/kaji"
KAJI_REMOTE="https://github.com/TekkadanPlays/kaji.git"

ensure_kaji() {
    if [ ! -d "$KAJI_DIR/.git" ]; then
        echo "Cloning kaji library..."
        git clone "$KAJI_REMOTE" "$KAJI_DIR"
        cd "$KAJI_DIR" && pnpm install && cd /app
    else
        cd "$KAJI_DIR"
        git pull origin main 2>/dev/null || true
        pnpm install 2>/dev/null || true
        cd /app
    fi
    # tsconfig paths reference ../../relay-tools-images/kaji from /app/web
    # ../../relay-tools-images = /relay-tools-images (from /app/web)
    mkdir -p /relay-tools-images
    ln -sfn /app/kaji /relay-tools-images/kaji
}

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
    systemctl stop app

    ensure_kaji

    # Build Express API server
    cd /app/api-server
    npm install
    npx prisma generate
    npx prisma db push --accept-data-loss 2>/dev/null || true
    npm run build

    # Build Inferno SPA
    cd /app/web
    pnpm install
    npx vite build

    cd /app
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
    echo "First run: initializing database schema and building app"
    ensure_kaji
    cd /app/api-server
    npx prisma db push --accept-data-loss 2>/dev/null || true
    cd /app
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi