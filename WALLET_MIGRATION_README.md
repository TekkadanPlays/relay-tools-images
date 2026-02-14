# CoinOS to Rust Wallet Service Migration

This document outlines the complete migration from the CoinOS/KeyDB/CLN stack to a high-performance Rust + SQLite wallet service.

## Overview

The new architecture replaces:
- **CoinOS** (Node.js + KeyDB) → **Rust Wallet Service** (Rust + SQLite)
- **CLN** (Core Lightning) → **Direct Bitcoin RPC** + optional Lightning provider
- **4 containers** → **1 container** (relaycreator + wallet service)

## Performance Benefits

- **10-100x faster** database operations (Rusqlite vs Node.js SQLite)
- **Type safety** and memory safety (Rust vs JavaScript)
- **Connection pooling** and prepared statements
- **Async I/O** for better concurrency
- **gRPC API** for high-performance inter-process communication

## Architecture

### Before (Current)
```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  relaycreator│───▶│   CoinOS    │───▶│   KeyDB     │───▶│     CLN     │
│  (Node.js)   │    │  (Node.js)  │    │  (Redis)    │    │ (Lightning)  │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### After (New)
```
┌─────────────────────────────────────────────────────────────────┐
│                     relaycreator                              │
│  ┌─────────────┐    ┌─────────────────────────────────────┐  │
│  │ Express API  │───▶│        Rust Wallet Service         │  │
│  │  (Node.js)  │    │     (Rust + SQLite)                 │  │
│  └─────────────┘    │  ┌─────────────┐  ┌─────────────┐    │  │
│                     │ │    gRPC     │  │   HTTP API  │    │  │
│                     │ │   (50051)   │  │   (8080)    │    │  │
│                     │ └─────────────┘  └─────────────┘    │  │
│                     └─────────────────────────────────────┘  │
│                           │                                 │
│                           ▼                                 │
│                   ┌─────────────┐                           │
│                   │   SQLite    │                           │
│                   │  Database    │                           │
│                   └─────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                            ┌─────────────────┐
                            │ Bitcoin Knots   │
                            │   (RPC only)    │
                            └─────────────────┘
```

## Migration Steps

### 1. Build and Deploy

```bash
# On the production server
cd /root/relay-tools-images
git pull origin main
git checkout feature/coinos-rust-migration

# Rebuild relaycreator container with wallet service
./machines/relaycreator/install

# Start relaycreator
machinectl start relaycreator
```

### 2. Run Migration

```bash
# Execute the migration script
chmod +x scripts/migrate-coinos.sh
./scripts/migrate-coinos.sh
```

The migration script will:
1. Export all data from KeyDB
2. Stop old CoinOS services
3. Create backup
4. Migrate data to SQLite
5. Start new wallet service
6. Verify migration

### 3. Update Configuration

Add to `/srv/relaycreator/.env`:
```env
# Enable new wallet service
WALLET_ENABLED=true
WALLET_SERVICE_URL=http://127.0.0.1:8080

# Bitcoin RPC settings
BITCOIN_RPC_URL=http://127.0.0.1:8332
BITCOIN_RPC_USER=relaytools
BITCOIN_RPC_PASS=your_password_here

# Disable old CoinOS
COINOS_ENABLED=false
```

### 4. Restart Services

```bash
# Restart relaycreator to pick up new config
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- systemctl restart app
```

### 5. Update Frontend

Update frontend to use new endpoints:
- `/api/coinos/*` → `/api/wallet/*`
- Same API structure, better performance

### 6. Cleanup (Optional)

```bash
# Remove old containers once verified working
machinectl stop coinos keydb
machinectl remove coinos keydb
```

## API Endpoints

The new wallet service provides the same API structure:

### Wallet Service (HTTP)
```
GET  /api/wallet/health
GET  /api/wallet/users/:id
POST /api/wallet/users
GET  /api/wallet/payments
POST /api/wallet/payments
GET  /api/wallet/invoices
POST /api/wallet/invoices
GET  /api/wallet/balance/:user_id
```

### Bitcoin Integration
```
POST /api/wallet/bitcoin/send
GET  /api/wallet/bitcoin/address
GET  /api/wallet/bitcoin/balance
```

### gRPC Service (High-performance)
```
wallet.WalletService {
    rpc GetUser(GetUserRequest) returns (User);
    rpc CreatePayment(PaymentRequest) returns (Payment);
    rpc ListPayments(PaginationRequest) returns (PaymentList);
    rpc CreateInvoice(InvoiceRequest) returns (Invoice);
    rpc GetBalance(BalanceRequest) returns (Balance);
}
```

## Data Migration

The migration script handles all data transfer:

1. **Users**: usernames, pubkeys, balances, profiles
2. **Payments**: transactions, fees, memos, confirmations
3. **Invoices**: Lightning invoices, amounts, status
4. **Accounts**: sub-wallets
5. **Contacts**: trusted/pinned contacts

### Manual Migration (if needed)

```bash
# Export from KeyDB
PID=$(machinectl show keydb -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- keydb-cli --scan --pattern "*" > keydb_export.json

# Import to SQLite
cd /app/wallet-service
cargo run --bin migrate-keydb --release -- \
    --input keydb_export.json \
    --output /app/data/wallet.db
```

## Testing

### Health Check
```bash
curl http://127.0.0.1:8080/health
```

### API Test
```bash
# Test wallet service
curl http://127.0.0.1:8080/users

# Test via relaycreator
curl -H "Authorization: Bearer $TOKEN" \
     http://127.0.0.1:4000/api/wallet/status
```

### Performance Test
```bash
# Benchmark database operations
cd /app/wallet-service
cargo test --release -- --nocapture
```

## Rollback Plan

If issues occur:

1. **Stop wallet service**:
   ```bash
   PID=$(machinectl show relaycreator -p Leader --value)
   nsenter -t $PID -m -u -i -n -p -- systemctl stop wallet-service
   ```

2. **Restore from backup**:
   ```bash
   cp -r /backup/coinos-YYYYMMDD-HHMMSS/* /srv/
   ```

3. **Restart old services**:
   ```bash
   machinectl start keydb coinos
   ```

4. **Update config**:
   ```bash
   # In /srv/relaycreator/.env
   WALLET_ENABLED=false
   COINOS_ENABLED=true
   ```

## Troubleshooting

### Wallet Service Won't Start
```bash
# Check logs
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- journalctl -u wallet-service -n 50

# Check database permissions
nsenter -t $PID -m -u -i -n -p -- ls -la /app/data/wallet.db
```

### Migration Fails
```bash
# Check KeyDB export
PID=$(machinectl show keydb -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- keydb-cli ping

# Verify export file
head -20 /tmp/keydb_export.json
```

### API Not Responding
```bash
# Check if service is running
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- systemctl status wallet-service

# Check network connectivity
nsenter -t $PID -m -u -i -n -p -- netstat -tlnp | grep 8080
```

## Development

### Local Development
```bash
cd wallet-service
cargo run
# Runs on http://127.0.0.1:8080 and gRPC on 50051
```

### Building
```bash
cargo build --release
# Binary at target/release/wallet-service
```

### Testing
```bash
cargo test
cargo test --release
```

## Security

- **Database**: SQLite with WAL mode for concurrency
- **API**: Authentication via relaycreator JWT tokens
- **Bitcoin**: RPC authentication with dedicated user
- **Network**: Services only bind to localhost

## Monitoring

### Metrics
- Response times (gRPC <10ms, HTTP <50ms)
- Database connection pool usage
- Bitcoin RPC call latency
- Error rates by endpoint

### Logs
```bash
# Wallet service logs
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- journalctl -u wallet-service -f

# API logs
nsenter -t $PID -m -u -i -n -p -- journalctl -u app -f | grep wallet
```

## Future Enhancements

1. **Lightning Integration**: Add LND or external Lightning provider
2. **Multi-currency**: Support for other cryptocurrencies
3. **Advanced Features**: Escrow, multi-sig, time-locked transactions
4. **Performance**: Connection pooling, caching layer
5. **Monitoring**: Prometheus metrics, health checks

## Support

For issues or questions:
1. Check logs in the troubleshooting section
2. Verify configuration in .env files
3. Test with the provided curl commands
4. Check the rollback plan if needed
