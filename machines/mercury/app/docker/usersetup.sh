#!/bin/sh
set -eu

export PGPASSWORD="${POSTGRES_PASSWORD}"

echo "Waiting for PostgreSQL at ${POSTGRES_HOST}..."
until psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c '\q' 2>/dev/null; do
    echo "  not ready, retrying in 2s..."
    sleep 2
done
echo "PostgreSQL is ready."

USER_EXISTS=$(psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_RUNTIME_USER}'")

if [ "${USER_EXISTS}" != "1" ]; then
    echo "Creating user '${POSTGRES_RUNTIME_USER}'..."
    psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        -c "CREATE USER \"${POSTGRES_RUNTIME_USER}\" WITH PASSWORD '${POSTGRES_RUNTIME_PASSWORD}'"
else
    echo "User '${POSTGRES_RUNTIME_USER}' already exists, ensuring password is current..."
    psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        -c "ALTER USER \"${POSTGRES_RUNTIME_USER}\" WITH PASSWORD '${POSTGRES_RUNTIME_PASSWORD}'"
fi

echo "Granting privileges on '${POSTGRES_DB}'..."
psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -c "GRANT CONNECT ON DATABASE \"${POSTGRES_DB}\" TO \"${POSTGRES_RUNTIME_USER}\";" \
    -c "GRANT USAGE ON SCHEMA public TO \"${POSTGRES_RUNTIME_USER}\";" \
    -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"${POSTGRES_RUNTIME_USER}\";" \
    -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"${POSTGRES_RUNTIME_USER}\";" \
    -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"${POSTGRES_RUNTIME_USER}\";" \
    -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO \"${POSTGRES_RUNTIME_USER}\";"

echo "Done. User '${POSTGRES_RUNTIME_USER}' has read/write access to '${POSTGRES_DB}'."
