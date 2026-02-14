# Wallet Migration Runbook

## Preconditions
- relaytools repo up to date on branch `feature/coinos-rust-migration`.
- Rust toolchain installed on host (`cargo --version`).
- Sufficient disk for sqlite db (`/srv/wallet` or `/app/data`).
- Maintenance window scheduled; no active CoinOS traffic.

## Step 1: Prep & Backup
1. `cd /root/relay-tools-images && git fetch origin && git checkout feature/coinos-rust-migration`.
2. Stop CoinOS-related containers:
   ```bash
   machinectl stop coinos keydb cln
   ```
3. Backup data:
   ```bash
   BACKUP=/backup/coinos-$(date +%Y%m%d-%H%M%S)
   mkdir -p "$BACKUP"
   cp -r /srv/coinos "$BACKUP/"
   cp -r /srv/keydb "$BACKUP/"
   ```
4. Export KeyDB dataset:
   ```bash
   PID=$(machinectl show keydb -p Leader --value)
   nsenter -t $PID -m -u -i -n -p -- keydb-cli --scan --pattern '*' > "$BACKUP/keydb_export.json"
   ```

## Step 2: Build Wallet Service
1. On host:
   ```bash
   cd /root/relay-tools-images/wallet-service
   cargo build --release
   ```
2. Copy binary into relaycreator container:
   ```bash
   PID=$(machinectl show relaycreator -p Leader --value)
   nsenter -t $PID -m -u -i -n -p -- mkdir -p /usr/local/bin
   cp target/release/wallet-service /var/lib/machines/relaycreator/usr/local/bin/
   ```
3. Copy systemd unit:
   ```bash
   cp machines/relaycreator/wallet-service.service /var/lib/machines/relaycreator/lib/systemd/system/
   ```

## Step 3: Deploy Database
1. Enter relaycreator container:
   ```bash
   machinectl shell relaycreator /bin/bash
   ```
2. Create data dir:
   ```bash
   mkdir -p /app/data
   ```
3. Run migration tool:
   ```bash
   cd /app/wallet-service
   cargo run --bin migrate-keydb --release -- \
     --input /backup/.../keydb_export.json \
     --output /app/data/wallet.db
   ```
4. Set permissions:
   ```bash
   chown root:root /app/data/wallet.db
   chmod 600 /app/data/wallet.db
   ```

## Step 4: Configure Env + Systemd
1. Update `/srv/relaycreator/.env`:
   ```env
   WALLET_ENABLED=true
   WALLET_SERVICE_URL=http://127.0.0.1:8080
   WALLET_DB_PATH=/app/data/wallet.db
   BITCOIN_RPC_URL=http://127.0.0.1:8332
   BITCOIN_RPC_USER=relaytools
   BITCOIN_RPC_PASS=... (from configure.sh)
   COINOS_ENABLED=false
   ```
2. Reload systemd inside container:
   ```bash
   systemctl daemon-reload
   systemctl enable wallet-service
   ```

## Step 5: Restart Services
1. Restart relaycreator API + start wallet service:
   ```bash
   systemctl restart app
   systemctl start wallet-service
   ```
2. Exit container; ensure host sees service running:
   ```bash
   PID=$(machinectl show relaycreator -p Leader --value)
   nsenter -t $PID -m -u -i -n -p -- systemctl status wallet-service
   ```

## Step 6: Verification
1. Health check:
   ```bash
   curl -sf http://127.0.0.1:8080/health
   curl -sf http://127.0.0.1:4000/api/wallet/status
   ```
2. Regression tests:
   - List payments `/api/wallet/payments`.
   - Create invoice `/api/wallet/invoice`.
   - Fetch credits `/api/wallet/credits`.
   - Check admin dashboard cards.
3. Bitcoin RPC smoke tests via wallet service endpoints (`/bitcoin/address`, `/bitcoin/balance`).

## Step 7: Cleanup
- After 48h stable ops, remove old containers:
  ```bash
  machinectl stop coinos keydb cln
  machinectl remove coinos keydb cln
  ```
- Archive backups for rollback window.

## Rollback Plan
1. Stop wallet service + relaycreator:
   ```bash
   machinectl stop relaycreator
   ```
2. Restore `/srv/coinos` + `/srv/keydb` + KeyDB data from backup.
3. Re-enable `COINOS_ENABLED=true`, `WALLET_ENABLED=false` in `.env`.
4. Restart original containers (`machinectl start keydb coinos cln relaycreator`).
