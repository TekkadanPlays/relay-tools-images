# CoinOS Baseline Assessment

## Topology Overview

- **Containers**: `coinos` (bun server), `keydb` (data), `cln` (Core Lightning), `bitcoinknots` (Bitcoin RPC), all orchestrated via `systemd-nspawn` definitions under `machines/*`.
- **Data paths**:
  - `/srv/coinos` → bind-mounted into container as `/app/config.ts` plus uploads.
  - `/srv/cln` → mounted inside CLN container for `hsm_secret` + sqlite state.
  - `/srv/keydb` → mounted as `/home/keydb/data`.
- **Relaycreator touch points**:
  - `/api/coinos/*` Express router proxies to `COINOS_ENDPOINT` (default `http://127.0.0.1:3119`).
  - Frontend `web/src/lib/coinos.ts` consumes proxy for dashboard + wallet UI.
  - `/srv/relaycreator/.env` flags: `COINOS_ENABLED`, `COINOS_API_KEY`, `BITCOIN_IMPLEMENTATION`, `BITCOIN_PRUNED`.

## Stack Components

| Component | Location | Notes |
|-----------|----------|-------|
| CoinOS bun server | `machines/coinos` | `app.service` runs `bun run /app/index.ts`; config generated via `configure.sh` into `/srv/coinos/config.ts`. |
| KeyDB | `machines/keydb` | Redis-compatible; compiled from source; stores users, payments, credits, ecash tokens. |
| Core Lightning | `machines/cln` | Provides LN RPC at `/app/data/lightning/bitcoin/lightning-rpc`; fragile due to glibc mismatch/daemon issues. |
| Bitcoin Knots | `machines/bitcoinknots` | Provides on-chain RPC; CLN + CoinOS rely on credentials here. |
| Relaycreator API | `relaycreator/api-server/src/routes/coinos.ts` | Proxy layer + feature flag controlling wallet exposure. |

## Pain Points

1. **Reliability**: CLN service frequently crashes (`exit-code 20`) due to daemonization and `hsm_secret` corruption; bind mounts amplify blast radius.
2. **Complexity**: Four tightly coupled containers; updates require coordinated `/srv/*` edits and restarts.
3. **Observability**: Logs dispersed across containers; requires `machinectl` + `nsenter` gymnastics.
4. **Deployment friction**: `machines/coinos/install` clones & builds inside container manually; no consistent CI/CD.
5. **State format**: Critical ledger data sits in KeyDB without schema/migrations → hard to back up or audit.

## API Surface Snapshot

- **Auth**: `/challenge`, `/nostrAuth`, `/login`, `/register`.
- **User profile**: `/me`, `/user`, `/users/:key`, `/credits`.
- **Payments**: `/payments` (list/create), `/payments/:hash`, `/parse`, `/send`, `/send/:lnaddress/:amount`.
- **Invoices**: `/invoice`, `/invoices`, `/invoice/:id`.
- **Accounts**: `/accounts`, `/account/:id`, `/account/delete`.
- **Contacts & Trust**: `/contacts`, `/pins`, `/trust`.
- **Funds**: `/fund/:id`, `/fund/:name/managers`, `/fund/managers`, `/authorize`, `/take`.
- **Node info**: `/info`, `/rates`, `/credits`.

## Data Model Sketch (KeyDB-derived)

- `user:*` → username, pubkey, nostr profile, balances, credits, fee flags.
- `payment:*` → amount, memo, hash, type, timestamp, counterparty.
- `invoice:*` → bolt11, hash, amount, status.
- `account:*` → subwallet metadata.
- `credit:*` / `fee:*` → per-network fee credits.
- `cashu:*` → ecash token blobs.
- `fund:*` → pooled accounts with managers and authorizations.

## Migration Targets

- Replace KeyDB datasets with normalized rusqlite schema (Users, Payments, Invoices, Accounts, Credits, Contacts, Apps, Funds, Pins, Trust links).
- Replace CLN dependency with direct Bitcoin RPC + optional Lightning provider abstraction.
- Decommission bun-based CoinOS service; re-implement API via Rust service fronted by relaycreator Express proxy.

## Next Steps

1. Finalize rusqlite schema + tonic gRPC spec for wallet service.
2. Build migration tooling (KeyDB export → SQLite import).
3. Integrate wallet service binary + systemd unit into relaycreator container and CI pipeline.
