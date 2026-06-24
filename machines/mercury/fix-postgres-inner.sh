#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y postgresql postgresql-server-dev-all git build-essential curl wget gnupg flex bison

PG_VER=17
PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config

echo "Using PostgreSQL Version: ${PG_VER}"
echo "Using pg_config at: ${PG_CONFIG}"

rm -rf /age-src
git clone https://github.com/apache/age.git /age-src
cd /age-src
git checkout release/PG${PG_VER}/1.7.0
make PG_CONFIG=${PG_CONFIG} install

grep -q "shared_preload_libraries = 'age'" /etc/postgresql/${PG_VER}/main/postgresql.conf || echo "shared_preload_libraries = 'age'" >> /etc/postgresql/${PG_VER}/main/postgresql.conf

/etc/init.d/postgresql restart
su - postgres -c "psql -c \"CREATE USER postgres WITH SUPERUSER PASSWORD 'postgres';\"" || true
su - postgres -c "psql -c \"CREATE DATABASE gc_index_relay_dev;\"" || true
su - postgres -c "psql -d gc_index_relay_dev -c \"CREATE EXTENSION IF NOT EXISTS age;\""

export HOME=/root
cd /app
export MIX_ENV=prod
export DATABASE_URL=ecto://postgres:postgres@localhost:5432/gc_index_relay_dev
export SECRET_KEY_BASE=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)

mix ecto.setup

if ! grep -q DATABASE_URL /lib/systemd/system/mercury.service; then
  echo "Environment=\"SECRET_KEY_BASE=${SECRET_KEY_BASE}\"" >> /lib/systemd/system/mercury.service
  echo "Environment=\"DATABASE_URL=${DATABASE_URL}\"" >> /lib/systemd/system/mercury.service
  systemctl daemon-reload
fi

systemctl restart mercury
