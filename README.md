# relay-tools-images

Containerized deployment infrastructure for the **relay-tools** Nostr stack using `systemd-nspawn`. Each service runs in its own lightweight container with bind-mounted persistent storage.

## Architecture

```
                          ┌─────────────────────────────────────────────────┐
                          │                   Internet                      │
                          └────────────────────┬────────────────────────────┘
                                               │ :443 (HTTPS)
                          ┌────────────────────▼────────────────────────────┐
                          │              haproxy container                   │
                          │                                                  │
                          │  /api/* /admin/* /.well-known/* ──► :4000        │
                          │  /relays/*  (everything else)  ──► :3000        │
                          └──────┬──────────────────────────────┬───────────┘
                                 │                              │
                    ┌────────────▼──────────┐     ┌─────────────▼───────────┐
                    │  relaycreator :4000    │     │     ribbit :3000        │
                    │                       │     │                         │
                    │  Express API server    │     │  Bun/Hono SPA server   │
                    │  Admin panel           │     │  Kaji Nostr library    │
                    │  Relay provisioning    │     │  /relays/* proxy ──────┼──┐
                    └───────────────────────┘     └─────────────────────────┘  │
                                                                               │
                    ┌──────────────────────┐      ┌────────────────────────────▼┐
                    │    strfry :7777       │      │     rstate :3100            │
                    │                      │      │     (inside ribbit)         │
                    │  Nostr relay (C++)   │      │                             │
                    │  WebSocket server    │      │  NIP-66 relay discovery     │
                    └──────────────────────┘      │  Ingests from nostr.watch   │
                                                  │  REST API for relay state   │
                    ┌──────────────────────┐      └─────────────────────────────┘
                    │    mysql :3306        │
                    │                      │      ┌─────────────────────────────┐
                    │  MariaDB             │      │  keys-certs-manager         │
                    │  Relay provisioning   │      │                             │
                    │  data store          │      │  Let's Encrypt certbot      │
                    └──────────────────────┘      │  Auto-renewal timer         │
                                                  └─────────────────────────────┘

    ─── Optional Payment Stack ───

    ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
    │ bitcoinknots      │  │ cln               │  │ lnbits            │  │ coinos            │
    │ :8332 (RPC)       │  │ :3010 (CLNRest)   │  │ :5000             │  │ :3119             │
    │                   │  │                   │  │                   │  │                   │
    │ Pruned Bitcoin    │──│ Core Lightning    │──│ LNBits wallet     │  │ CoinOS wallet     │
    │ node              │  │ payment channels  │  │ management        │  │ NIP-07 auth       │
    └──────────────────┘  └──────────────────┘  └──────────────────┘  └──────────────────┘
    │                                                                   │
    └───────────────────── keydb :6379 (Redis) ─────────────────────────┘
```

## Repository Map

This stack spans multiple repositories:

| Repository | Purpose | Deployed To |
|---|---|---|
| [`relay-tools-images`](https://github.com/TekkadanPlays/relay-tools-images) | Container definitions, systemd services, deployment scripts | Host server |
| [`ribbit.network`](https://github.com/TekkadanPlays/ribbit.network) | Bun/Hono frontend + Kaji Nostr library | `ribbit` container at `/app` |
| [`relaycreator`](https://github.com/TekkadanPlays/relaycreator) | Express API + React admin panel | `relaycreator` container at `/app` |
| [`nostr-watch`](https://github.com/sandwichfarm/nostr-watch) | rstate NIP-66 relay discovery engine | `ribbit` container at `/app/nostr-watch` |

### ribbit container internal layout

The `ribbit` nspawn container runs **two services** from a single bind mount (`/srv/ribbit:/app`):

| Service | Port | systemd unit | Working directory | Runtime |
|---|---|---|---|---|
| ribbit.network (Hono) | 3000 | `app.service` | `/app/ribbit` | Bun |
| rstate (Fastify) | 3100 | `rstate.service` | `/app/rstate` | Bun |

rstate listens on `127.0.0.1:3100` (internal only). The Hono server proxies `/relays/*` requests to rstate, making the relay discovery API available at `https://yourdomain.com/relays/*`.

### Frontend migration status

The stack is migrating from relaycreator's React SPA to InfernoJS frontends built with **BlazeCSS**:

| Frontend | Status | Served by |
|---|---|---|
| ribbit.network (Nostr client) | **Active** — InfernoJS + Kaji + Tailwind | `ribbit` container |
| relaycreator admin panel | Legacy — React SPA | `relaycreator` container |
| mycelium.social | Planned — will share ribbit frontend | Future |

## Containers

### Core containers (required)

| Container | Bind mount | Description |
|---|---|---|
| `mysql` | `/srv/mysql:/var/lib/mysql` | MariaDB for relay provisioning data |
| `strfry` | `/srv/strfry:/app` | strfry Nostr relay (C++) |
| `haproxy` | `/srv/haproxy:/srv/haproxy` | TLS termination + request routing |
| `relaycreator` | `/srv/relaycreator:/app` | Express API + admin panel |
| `keys-certs-manager` | shared cert paths | Let's Encrypt certificate management |

### Optional: ribbit frontend

| Container | Bind mount | Description |
|---|---|---|
| `ribbit` | `/srv/ribbit:/app` | Bun/Hono SPA + rstate relay discovery |

### Optional: payment stack

| Container | Bind mount | Description |
|---|---|---|
| `bitcoinknots` | `/srv/bitcoinknots:/home/bitcoin/.bitcoin` | Pruned Bitcoin node (BIP-110) |
| `cln` | `/srv/cln:/app/data/lightning` | Core Lightning payment channels |
| `lnbits` | `/srv/lnbits:/app/data` | LNBits wallet management |
| `keydb` | `/srv/keydb:/data` | Redis-compatible store for CoinOS |
| `coinos` | `/srv/coinos:/app/data` | CoinOS wallet server |

## Common container scripts

Every container subfolder has the same set of management scripts. The container name is derived from the directory name automatically.

| Script | Description |
|---|---|
| `install` | Build the container image, install dependencies, enable services |
| `start` | `machinectl start <name>` |
| `stop` | `systemctl stop systemd-nspawn@<name>` |
| `console` | Print password, start container, `machinectl login` |
| `status` | `machinectl status <name>` |
| `clean` | Delete the image and deployment files (preserves bind mounts) |

## Quick start

```bash
cd relay-tools-images/machines

# Install systemd-nspawn prerequisites
./prereqs.sh

# Build all container images (creates debian rootfs + installs each container)
./build

# Configure DNS to point at this server, then:
export MYDOMAIN=example.com
export MYEMAIL=you@example.com    # optional, for Let's Encrypt notifications

# For ribbit.network frontend + rstate relay discovery:
export RIBBIT_ENABLED=true

# For Bitcoin Lightning payments:
# export PAYMENTS_ENABLED=true
# export COINOS_ENABLED=true

./configure.sh

# Enable containers to start on boot
machinectl enable mysql && machinectl enable strfry && machinectl enable relaycreator && machinectl enable haproxy
# If ribbit enabled:
machinectl enable ribbit
```

## HAProxy routing

HAProxy terminates TLS and routes requests based on path:

| Path pattern | Backend | Port |
|---|---|---|
| `/api/*` | relaycreator | 4000 |
| `/admin/*` | relaycreator | 4000 |
| `/.well-known/*` | relaycreator | 4000 |
| `/rc/*` | relaycreator | 4000 |
| Everything else | ribbit | 3000 |

If the ribbit container is down, HAProxy falls back to relaycreator for all traffic.

The ribbit Hono server handles these paths internally:
- `/relays/*` → proxied to rstate on `127.0.0.1:3100`
- `/api/health` → ribbit health check
- `/.well-known/nostr.json` → NIP-05 identity mapping
- `/assets/*`, `/favicon.ico` → static files
- `/*` → SPA fallback (index.html)

## Auto-deployment

Both `ribbit` and `relaycreator` containers have a `deploy.timer` that runs every minute. It checks for upstream git changes and rebuilds automatically.

### Manual update commands

**Ribbit (frontend + rstate):**
```bash
machinectl shell ribbit /bin/bash -c '
cd /app && git pull origin main
cd /app/ribbit && bun install && NODE_ENV=production bun run build
systemctl restart app
systemctl restart rstate
'
```

**Relaycreator (API + admin):**
```bash
machinectl shell relaycreator /bin/bash -c '
cd /app && git fetch origin && git reset --hard origin/main
systemctl stop app
cd /app/api-server && pnpm install && npx prisma generate && npx prisma db push --accept-data-loss 2>/dev/null || true && npx tsc
cd /app/web && pnpm install && npx vite build
systemctl start app
'
```

## Monitoring & debugging

| Action | Command |
|---|---|
| List running containers | `machinectl list` |
| Shell into container | `machinectl shell <name> /bin/bash` |
| Interactive login | `machinectl login <name>` (password: `creator`) |
| View service logs | `machinectl shell <name> /bin/bash -c 'journalctl -u <unit> -n 50 --no-pager'` |
| Check service status | `machinectl shell <name> /bin/bash -c 'systemctl status <unit> --no-pager -l'` |
| Check listening ports | `machinectl shell <name> /bin/bash -c 'ss -tlnp'` |
| Edit config (host-side) | `nano /srv/<name>/.env` |
| Restart service | `machinectl shell <name> /bin/bash -c 'systemctl restart <unit>'` |

### ribbit container services

| Unit | Logs | Test |
|---|---|---|
| `app.service` | `journalctl -u app` | `curl http://127.0.0.1:3000/api/health` |
| `rstate.service` | `journalctl -u rstate` | `curl http://127.0.0.1:3100/health/ping` |

### Key file locations (host-side)

| Path | Contents |
|---|---|
| `/srv/ribbit/ribbit/.env` | Hono server config (PORT, RSTATE_URL) |
| `/srv/ribbit/rstate/.env` | rstate config (REST_PORT, CVM_SERVER_NSEC, ingest relays) |
| `/srv/relaycreator/.env` | Express API config (DATABASE_URL, JWT, payments) |
| `/srv/haproxy/certs/bundle.pem` | TLS certificate |
| `/srv/mysql/.creator-mysql-uri.txt` | MySQL connection string |

## rstate (NIP-66 relay discovery)

rstate is a relay state aggregation engine from the [nostr-watch](https://github.com/sandwichfarm/nostr-watch) project. It:

1. Connects to monitor relays (nostr.watch) via WebSocket
2. Ingests NIP-66 relay metadata events (kind 10166 + 30166)
3. Aggregates relay state (software, NIPs, RTT, geo, uptime)
4. Serves a REST API for relay discovery and search

### rstate REST API (via `/relays/*` proxy)

| Endpoint | Method | Description |
|---|---|---|
| `/relays/health` | GET | Health check + ingestion metrics |
| `/relays` | GET | List relays (pagination via `?limit=&offset=`) |
| `/relays/state?relayUrl=` | GET | Single relay state |
| `/relays/search` | POST | Search by filter (nips, software, network, country) |
| `/relays/online` | POST | Online relays |
| `/relays/nearby` | POST | Geospatial search |
| `/relays/by/software` | GET | Group by software |
| `/relays/by/nip` | GET | Group by NIP support |
| `/relays/by/country` | GET | Group by country |
| `/relays/compare` | POST | Compare multiple relays |

### rstate `.env` reference

| Variable | Required | Description |
|---|---|---|
| `REST_PORT` | Yes | Port for REST API (default: 3100) |
| `REST_HOST` | Yes | Bind address (use `127.0.0.1` for internal only) |
| `REST_CORS_ORIGINS` | Yes | Allowed CORS origins |
| `CVM_SERVER_NSEC` | Yes | Nostr private key (hex) for CVM protocol |
| `CVM_ENCRYPTION_MODE` | No | `DISABLED` / `OPTIONAL` / `REQUIRED` (default: OPTIONAL) |
| `CVM_RELAYS` | Yes | Relays for CVM protocol communication |
| `INGEST_RELAYS` | Yes | Monitor relays to ingest NIP-66 events from |
| `LOG_LEVEL` | No | `debug` / `info` / `warn` / `error` |
| `CACHE_TTL` | No | Aggregation cache TTL in seconds |

## Todo

- [x] Implement certificate and keys automatic config/rotation
- [x] Fix bundle.pem path mismatch in configure.sh
- [x] Fix missing haproxy bind mount for /srv/relaycreator
- [x] Add keys-certs-manager to build script
- [x] Add mysql wait timeout in configure.sh
- [x] Upgrade Node.js 18 to 20, pin pnpm to v9
- [x] Add .gitattributes for LF line endings
- [x] Set executable permissions on all scripts
- [x] Add ribbit machine (Bun/Hono frontend for ribbit.network)
- [x] HAProxy split routing: API → relaycreator, frontend → ribbit
- [x] RIBBIT_ENABLED flag in configure.sh
- [x] rstate NIP-66 relay discovery integration (Bun runtime)
- [x] Auto-generate CVM_SERVER_NSEC in configure.sh
- [ ] Migrate relaycreator frontend to InfernoJS + BlazeCSS
- [ ] Add mycelium.social as second ribbit deployment
- [ ] Evaluate relaymon for independent RTT monitoring
