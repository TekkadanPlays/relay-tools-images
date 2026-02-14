# Rusqlite Wallet Service Architecture

## Overview

- **Goal**: Replace CoinOS (bun + KeyDB + CLN) with a single Rust binary providing wallet/storage logic using rusqlite.
- **Interfaces**:
  - gRPC (tonic) for internal calls from relaycreator if needed (port 50051).
  - REST (axum) mirroring `/api/coinos/*` so frontend + admin panel continue to work via `/api/wallet/*` proxy.
  - Direct Bitcoin RPC client for on-chain operations; Lightning optional provider abstraction.

## Modules

| Module | Responsibility | Notes |
|--------|----------------|-------|
| `database` | rusqlite connection pool, migrations, repository functions | use WAL mode, foreign keys ON, connection pool via `r2d2` or tokio spawn blocking. |
| `grpc_service` | tonic service definitions (`wallet.proto`) | Methods: GetUser, CreatePayment, ListPayments, CreateInvoice, GetBalance, AdminOps. |
| `http_service` | axum routes exposing REST | Maps current CoinOS endpoints to internal service calls. |
| `bitcoin` | RPC client for Bitcoin Knots | Methods: getbalance, getnewaddress, sendtoaddress, estimatesmartfee, decodepsbt (future). |
| `lightning` (future) | Optional provider trait (CLN, LND, LNBits, external API) | Start with no-op/on-chain only. |
| `migration` | CLI to import KeyDB exports into sqlite | `cargo run --bin migrate-keydb -- --input export.json --output wallet.db`. |

## Data Schema

### Tables

- `users`: id (TEXT PK), username UNIQUE, pubkey, npub, balance SATS, currency, profile fields, created_at, verified.
- `payments`: id, user_id FK, amount (signed), fee, memo, hash, type (`sent|received|internal|ecash`), created_at, confirmed, with_user_id, metadata json.
- `invoices`: id, user_id FK, hash UNIQUE, bolt11, amount, memo, created_at, expires_at, paid_at.
- `accounts`: id, user_id, name, type, balance, created_at.
- `credits`: id, user_id, network (`bitcoin|lightning|liquid`), amount, updated_at.
- `contacts`: id, user_id, contact_user_id, pinned, trusted, created_at.
- `apps`: id, user_id, pubkey, secret, budget, notify, created_at.
- `funds`: id, name, owner_user_id, balance, currency, created_at.
- `fund_managers`: id, fund_id, user_id, role, added_at.
- `pins`, `trusts`, `ecash_tokens`, `wallet_sessions`, `nostr_auth_challenges`, `config` key/value.

### Indices

- `users(username)`, `users(pubkey)`.
- `payments(user_id, created_at)`, `payments(hash)`.
- `invoices(user_id, created_at)`, `invoices(hash)`.
- `accounts(user_id)`, `credits(user_id, network)`.
- `contacts(user_id)`, `contacts(contact_user_id)`.

## API Mapping

| Existing Endpoint | New Handling |
|-------------------|--------------|
| `/api/coinos/status` | Rust service `/health` + Bitcoin info; Express proxies to `/api/wallet/status`. |
| `/api/coinos/payments` | HTTP -> `payments::list` (limit/offset/aid). |
| `/api/coinos/payments` POST | Validate invoice/internal transfer → `payments::create`. |
| `/api/coinos/invoice` | Create invoice entry + return bolt11 placeholder (Lightning provider). |
| `/api/coinos/send/:lnaddress/:amount` | For now, stub or route via future Lightning adapter. |
| `/api/coinos/credits` | Query `credits` table. |
| `/api/coinos/info` | Compose from `config` + Bitcoin RPC (alias, block height). |
| `/api/coinos/challenge` + `/nostrAuth` | Use `nostr_auth_challenges` + secp256k1 verify to mint wallet JWT (stored locally). |

## Environment Variables

```
WALLET_ENABLED=true
WALLET_DB_PATH=/app/data/wallet.db
WALLET_SERVICE_URL=http://127.0.0.1:8080
WALLET_GRPC_URL=grpc://127.0.0.1:50051
BITCOIN_RPC_URL=http://127.0.0.1:8332
BITCOIN_RPC_USER=relaytools
BITCOIN_RPC_PASS=***
LIGHTNING_PROVIDER=none|lnd|lnbits|external
LIGHTNING_API_KEY=optional
JWT_SECRET=relaycreator shared secret (for wallet tokens)
```

## Service Lifecycle

1. **Startup**:
   - Read config/env, open sqlite connection (run migrations if needed).
   - Start gRPC server + HTTP server concurrently.
   - Provide `/health` endpoint reporting DB + Bitcoin RPC connectivity.
2. **Shutdown**:
   - Graceful stop on SIGTERM; close DB connections; flush WAL.

## Integration Points

- **Relaycreator Express**: Replace `/api/coinos` router with `/api/wallet` proxy; maintain legacy path behind flag until frontend updates.
- **Frontend**: Update `web/src/lib/coinos.ts` to default to `/api/wallet` once backend verified.
- **Systemd**: `wallet-service.service` run inside relaycreator container alongside API server; logs in journald.

## Migration CLI Workflow

1. `keydb-cli --scan --pattern '*' > keydb_export.json`.
2. `cargo run --bin migrate-keydb -- --input keydb_export.json --output /app/data/wallet.db`.
3. Verify row counts vs. KeyDB key counts.
4. Backup `wallet.db` and old `/srv/coinos` before enabling service.

## Testing Strategy

- **Unit**: Database repositories, Bitcoin client mocks.
- **Integration**: gRPC/REST endpoints using sqlite in-memory DB.
- **Regression**: Replay sample KeyDB export, ensure API responses match previous CoinOS outputs (focus on status, payments list, credits, info).
- **Load**: Simulate concurrent payment/invoice creation to ensure rusqlite handles locking (use WAL + busy_timeout).

## Security Considerations

- Store sensitive configs (JWT secret, Bitcoin creds) via `.env` + systemd `EnvironmentFile`.
- Ensure wallet JWTs have expiration, stored hashed in sqlite if long-lived.
- HTTPS termination remains at HAProxy; wallet service stays on localhost.
- Backups: schedule sqlite snapshot (via `.backup` or LVM) + KeyDB export archive until decommission complete.
