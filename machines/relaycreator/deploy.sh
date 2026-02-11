#!/bin/bash

deploy_app() {
    echo "detected upstream changes, deploying"
    git pull
    systemctl stop app
    pnpm install
    npx prisma db push --accept-data-loss 2>/dev/null || npx prisma migrate deploy || true
    pnpm run build
    systemctl start app
}

cd /app
git remote update 2>/dev/null || true

if [ ! -f "/firstrun.txt" ]; then
    # First run: push schema to DB, build, and start
    echo "First run: initializing database schema and building app"
    npx prisma db push --accept-data-loss 2>/dev/null || true
    touch /firstrun.txt
    systemctl restart app
    exit 0
fi

if git status -uno 2>/dev/null | grep -q "is behind"
then
    deploy_app
fi