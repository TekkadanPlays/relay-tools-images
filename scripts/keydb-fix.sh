#!/bin/bash
# Fix KeyDB — promote to standalone master if stuck in replica mode
# Run on the HOST as root
set -euo pipefail

echo "=== KeyDB Fix ==="

PID=$(machinectl show keydb -p Leader --value 2>/dev/null) || true
if [ -z "$PID" ]; then
    echo "keydb container not running. Starting..."
    machinectl start keydb
    sleep 3
    PID=$(machinectl show keydb -p Leader --value)
fi

echo ""
echo "--- Current replication status ---"
ROLE=$(nsenter -t "$PID" -m -u -i -n -p -- keydb-cli INFO replication 2>/dev/null | grep "^role:" | tr -d '\r')
echo "$ROLE"

if echo "$ROLE" | grep -q "slave"; then
    echo ""
    echo "KeyDB is in REPLICA mode. Promoting to standalone master..."
    nsenter -t "$PID" -m -u -i -n -p -- keydb-cli REPLICAOF NO ONE
    echo "Done. KeyDB is now a standalone master."
else
    echo "KeyDB is already a master. No action needed."
fi

echo ""
echo "--- Verify ---"
nsenter -t "$PID" -m -u -i -n -p -- keydb-cli INFO replication 2>/dev/null | grep -E "^role:|^connected_slaves:"

echo ""
echo "=== Done ==="
