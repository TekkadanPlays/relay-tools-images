#!/bin/bash
# CoinOS Migration Script: KeyDB -> Rust Wallet Service
# This script migrates all CoinOS data from KeyDB to the new Rust + SQLite system

set -e

echo "=== CoinOS Migration Script ==="
echo "Migrating from KeyDB to Rust Wallet Service"

# Check if KeyDB is running
if ! machinectl list | grep -q "keydb"; then
    echo "ERROR: KeyDB container not found. Is KeyDB installed?"
    exit 1
fi

# Get KeyDB container PID
PID=$(machinectl show keydb -p Leader --value 2>/dev/null)
if [ -z "$PID" ]; then
    echo "ERROR: KeyDB container not running. Start it: machinectl start keydb"
    exit 1
fi

echo ""
echo "=== Step 1: Export data from KeyDB ==="

# Export all data from KeyDB
echo "Exporting KeyDB data..."
nsenter -t $PID -m -u -i -n -p -- keydb-cli --scan --pattern "*" > /tmp/keydb_export.json

if [ ! -s /tmp/keydb_export.json ]; then
    echo "ERROR: Failed to export data from KeyDB"
    exit 1
fi

echo "Exported $(wc -l < /tmp/keydb_export.json) keys from KeyDB"

echo ""
echo "=== Step 2: Stop old CoinOS services ==="

# Stop old CoinOS services
machinectl stop coinos 2>/dev/null || echo "CoinOS already stopped"
machinectl stop keydb 2>/dev/null || echo "KeyDB already stopped"

echo ""
echo "=== Step 3: Backup existing data ==="

# Create backup directory
BACKUP_DIR="/backup/coinos-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup existing data
cp -r /srv/coinos "$BACKUP_DIR/" 2>/dev/null || echo "No /srv/coinos to backup"
cp -r /srv/keydb "$BACKUP_DIR/" 2>/dev/null || echo "No /srv/keydb to backup"
cp /tmp/keydb_export.json "$BACKUP_DIR/"

echo "Backup created at: $BACKUP_DIR"

echo ""
echo "=== Step 4: Update relaycreator container ==="

# Get relaycreator container PID
PID=$(machinectl show relaycreator -p Leader --value 2>/dev/null)
if [ -z "$PID" ]; then
    echo "ERROR: relaycreator container not running"
    exit 1
fi

# Copy migration script to container
cat << 'EOF' > /tmp/migrate_in_container.sh
#!/bin/bash
set -e

echo "Running migration inside relaycreator container..."

# Install Rust if not already installed
if ! command -v cargo &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source ~/.cargo/env
fi

# Build and run migration tool
cd /app/wallet-service
~/.cargo/bin/cargo build --bin migrate-keydb --release

# Run migration
~/.cargo/bin/cargo run --bin migrate-keydb --release -- \
    --input /tmp/keydb_export.json \
    --output /app/data/wallet.db

echo "Migration completed inside container"
EOF

# Copy migration script and data to container
nsenter -t $PID -m -u -i -n -p -- mkdir -p /app/data
nsenter -t $PID -m -u -i -n -p -- cp /tmp/keydb_export.json /tmp/
nsenter -t $PID -m -u -i -n -p -- cp /tmp/migrate_in_container.sh /tmp/
nsenter -t $PID -m -u -i -n -p -- chmod +x /tmp/migrate_in_container.sh

echo ""
echo "=== Step 5: Run migration ==="

# Run migration inside container
nsenter -t $PID -m -u -i -n -p -- /tmp/migrate_in_container.sh

echo ""
echo "=== Step 6: Start wallet service ==="

# Start the new wallet service
nsenter -t $PID -m -u -i -n -p -- systemctl start wallet-service

# Wait for service to start
sleep 3

# Check if service is running
if nsenter -t $PID -m -u -i -n -p -- systemctl is-active --quiet wallet-service; then
    echo "✅ Wallet service started successfully"
else
    echo "❌ Wallet service failed to start"
    nsenter -t $PID -m -u -i -n -p -- systemctl status wallet-service
    exit 1
fi

echo ""
echo "=== Step 7: Verify migration ==="

# Test the new wallet service
if curl -sf http://127.0.0.1:8080/health > /dev/null; then
    echo "✅ Wallet service API is responding"
    
    # Check if data was migrated
    USER_COUNT=$(curl -s http://127.0.0.1:8080/users | jq '.data | length' 2>/dev/null || echo "0")
    echo "Migrated $USER_COUNT users"
else
    echo "❌ Wallet service API not responding"
    exit 1
fi

echo ""
echo "=== Migration Complete ==="
echo ""
echo "Next steps:"
echo "1. Update relaycreator .env to use WALLET_ENABLED=true"
echo "2. Restart relaycreator: systemctl restart app"
echo "3. Test wallet functionality in the UI"
echo "4. Remove old containers: machinectl stop coinos keydb"
echo "5. Remove old containers: machinectl remove coinos keydb"
echo ""
echo "Rollback plan if needed:"
echo "- Stop wallet service: systemctl stop wallet-service"
echo "- Restore from backup: cp -r $BACKUP_DIR/* /srv/"
echo "- Start old services: machinectl start keydb coinos"
echo ""
echo "Backup location: $BACKUP_DIR"
