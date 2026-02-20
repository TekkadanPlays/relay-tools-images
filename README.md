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
                    │  relaycreator :4000    │     │   frontend :3000        │
                    │                       │     │   (ribbit or mycelium)  │
                    │  Express API server    │     │  Bun/Hono SPA server   │
                    │  InfernoJS admin panel │     │  Kaji Nostr library    │
                    │  Relay provisioning    │     │                         │
                    └───────────────────────┘     └─────────────────────────┘
                                                                              
                    ┌──────────────────────┐      ┌─────────────────────────┐
                    │    strfry :7777       │      │     rstate :3100        │
                    │                      │      │     (standalone)        │
                    │  Nostr relay (C++)   │      │                         │
                    │  WebSocket server    │      │  NIP-66 relay discovery │
                    └──────────────────────┘      │  Ingests from nostr.watch│
                                                  │  REST API for relay state│
                    ┌──────────────────────┐      └─────────────────────────┘
                    │    mysql :3306        │
                    │                      │      ┌─────────────────────────┐
                    │  MariaDB             │      │  keys-certs-manager     │
                    │  Relay provisioning   │      │                         │
                    │  data store          │      │  Let's Encrypt certbot  │
                    └──────────────────────┘      │  Auto-renewal timer     │
                                                  └─────────────────────────┘

    ─── Optional Services ───

    ┌──────────────────┐
    │ oni               │  live.mycelium.social
    │ :8085 (web)       │  HAProxy proxies HTTPS → 8085
    │ :1935 (RTMP)      │  RTMP exposed directly on host
    │                   │
    │ Owncast fork      │  Go binary + InfernoJS frontend
    │ Live streaming    │  Nostr auth (NIP-07/NIP-53)
    │ SQLite DB         │  Bun builds Inferno → static/web/
    └──────────────────┘

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

## Service Tiers

The stack is organized into tiers. The interactive installer lets you choose which to deploy.

### CORE (required)

These services are always installed. They provide the Nostr relay, API server, database, and TLS.

| Container | Port | Description |
|---|---|---|
| `mysql` | 3306 | MariaDB — relay provisioning database |
| `strfry` | 7777 | strfry — Nostr relay engine (C++, WebSocket) |
| `haproxy` | 443/80 | HAProxy — TLS termination + request routing |
| `relaycreator` | 4000 | Express API server + InfernoJS admin panel + relay provisioning |
| `keys-certs-manager` | — | Let's Encrypt certbot + auto-renewal timer |

### FRONTEND (optional)

A public-facing web frontend for your relay service. Choose one or both.

| Container | Port | Description |
|---|---|---|
| `ribbit` | 3000 | Bun/Hono Nostr client (ribbit.network) |
| `mycelium` | 3000 | Bun/Hono Nostr client (mycelium.social — successor to ribbit) |
| `rstate` | 3100 | NIP-66 relay discovery API (standalone, from nostr-watch) |

### PAYMENTS (optional)

Bitcoin Lightning payments for relay subscriptions. Without this, relay creation is free.

| Container | Port | Description |
|---|---|---|
| `bitcoinknots` | 8332 | Bitcoin Knots v29.3 — pruned node (BIP-110) |
| `cln` | 3010 | Core Lightning — payment channels (CLNRest) |
| `lnbits` | 5000 | LNBits — wallet management UI |
| `keydb` | 6379 | KeyDB — Redis-compatible store (for CoinOS) |
| `coinos` | 3119 | CoinOS — NIP-07 wallet server |

### STREAMING (optional)

Live streaming server for `live.<yourdomain>`.

| Container | Port | Description |
|---|---|---|
| `oni` | 8085 (web), 1935 (RTMP) | Oni — Owncast fork with Nostr auth, NIP-53 live events, InfernoJS frontend |

Oni is a self-contained Go binary. HAProxy routes `live.<domain>` → port 8085. RTMP port 1935 is exposed directly (not proxied). SQLite database in `data/oni.db`. Frontend built with InfernoJS + Blazecn + Tailwind, compiled into `static/web/` and embedded by the Go binary.

### EXTRAS (WIP)

These are work-in-progress and not yet wired into the installer.

| Container | Description |
|---|---|
| `hyphae` | IRC client gateway (connects to any IRC server) |
| `ergo` | IRC daemon (WIP — config files only, no install script yet) |
| `influx` | InfluxDB time-series database (intended for metrics/monitoring) |

## Repository Map

| Repository | Purpose | Deployed To |
|---|---|---|
| [`relay-tools-images`](https://github.com/TekkadanPlays/relay-tools-images) | Container definitions, systemd services, deployment scripts | Host server |
| [`ribbit.network`](https://github.com/TekkadanPlays/ribbit.network) | Monorepo: Bun/Hono frontend + Kaji + Oni + BlazeCSS | `ribbit`/`mycelium` container at `/app` |
| [`relaycreator`](https://github.com/TekkadanPlays/relaycreator) | Express API + InfernoJS admin panel + web SPA | `relaycreator` container at `/app` |
| [`nostr-watch`](https://github.com/sandwichfarm/nostr-watch) | rstate NIP-66 relay discovery engine | `rstate` container at `/app` |
| [`oni`](https://github.com/TekkadanPlays/oni) | Owncast fork — live streaming with Nostr auth + InfernoJS frontend | `oni` container at `/app` |

## Quick Start

```bash
# Clone the repo
git clone https://github.com/TekkadanPlays/relay-tools-images.git
cd relay-tools-images

# Run the interactive installer (as root)
sudo bash install.sh
```

The installer will:
1. Check and install system prerequisites (`systemd-nspawn`, `debootstrap`)
2. Ask for your domain name and TLS preference
3. Let you select which service tiers to install
4. Build the base Debian image and all selected containers
5. Configure services (`.env` files, certificates, database)
6. Enable containers to start on boot

### Manual setup (advanced)

If you prefer manual control:

```bash
cd machines

# Install prerequisites
./prereqs.sh

# Build base image + all core containers
./build

# Configure (set env vars first)
export MYDOMAIN=example.com
export MYEMAIL=you@example.com
export RIBBIT_ENABLED=true        # optional
export PAYMENTS_ENABLED=true      # optional
export COINOS_ENABLED=true        # optional
./configure.sh

# Enable on boot
machinectl enable mysql strfry relaycreator haproxy
```

## Upgrading Services

Upgrade individual services without affecting the rest of the stack:

```bash
# Interactive — shows running services and lets you pick
sudo bash upgrade.sh

# Direct — upgrade a specific service
sudo bash upgrade.sh relaycreator
sudo bash upgrade.sh ribbit
sudo bash upgrade.sh mycelium
sudo bash upgrade.sh rstate
sudo bash upgrade.sh strfry --rebuild    # recompile from source
sudo bash upgrade.sh haproxy             # update cookiecutter
sudo bash upgrade.sh coinos
```

### Manual update commands

**Relaycreator (API + admin):**
```bash
PID=$(machinectl show relaycreator -p Leader --value)
nsenter -t "$PID" -m -u -i -n -p -- bash -c '
cd /app && git fetch origin && git reset --hard origin/main
systemctl stop app
cd /app/api-server && npm install && npx prisma generate && npx prisma db push --accept-data-loss 2>/dev/null || true && npm run build
cd /app/web && bun install && bun run build
systemctl start app
'
```

**Ribbit / Mycelium (frontend):**
```bash
PID=$(machinectl show ribbit -p Leader --value)
nsenter -t "$PID" -m -u -i -n -p -- bash -c '
cd /app && git pull origin main
cd /app/ribbit && bun install && NODE_ENV=production bun run build
systemctl restart app
'
```

Or use the rebuild script:
```bash
bash scripts/relaycreator-rebuild.sh
```

## Common Container Scripts

Every container subfolder has the same set of management scripts:

| Script | Description |
|---|---|
| `install` | Build the container image, install dependencies, enable services |
| `start` | `machinectl start <name>` |
| `stop` | `systemctl stop systemd-nspawn@<name>` |
| `console` | Print password, start container, `machinectl login` |
| `status` | `machinectl status <name>` |
| `clean` | Delete the image and deployment files (preserves bind mounts) |

## HAProxy Routing

HAProxy terminates TLS and routes requests based on path:

| Path pattern | Backend | Port |
|---|---|---|
| `/api/*` | relaycreator | 4000 |
| `/admin/*` | relaycreator | 4000 |
| `/.well-known/*` | relaycreator | 4000 |
| `/rc/*` | relaycreator | 4000 |
| Everything else | frontend (ribbit/mycelium) | 3000 |

If the frontend container is down, HAProxy falls back to relaycreator for all traffic.

## Auto-deployment

Containers with a `deploy.timer` check for upstream git changes every 60 seconds and rebuild automatically:

| Container | Git remote | Build tools |
|---|---|---|
| `relaycreator` | `TekkadanPlays/relaycreator.git` | npm (api-server) + bun (web SPA) |
| `ribbit` | `TekkadanPlays/ribbit.network.git` | bun |
| `mycelium` | `TekkadanPlays/ribbit.network.git` | bun |
| `rstate` | `sandwichfarm/nostr-watch.git` | bun |
| `coinos` | `TekkadanPlays/coinos-server.git` | bun |
| `oni` | `TekkadanPlays/oni.git` | go build + bun (Inferno frontend) |

Push to the relevant repo and changes deploy within ~60 seconds.

## Monitoring & Debugging

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

### Health checks

| Service | Test command |
|---|---|
| relaycreator | `curl http://127.0.0.1:4000/health` |
| ribbit / mycelium | `curl http://127.0.0.1:3000/api/health` |
| rstate | `curl http://127.0.0.1:3100/health/ping` |
| oni | `curl http://127.0.0.1:8085/api/status` |

### Key file locations (host-side)

| Path | Contents |
|---|---|
| `/srv/relaycreator/.env` | Express API config (DATABASE_URL, JWT, payments) |
| `/srv/mycelium/ribbit/.env` | Mycelium Hono server config (PORT, CREATOR_DOMAIN) |
| `/srv/ribbit/ribbit/.env` | Ribbit Hono server config (PORT, RSTATE_URL) |
| `/srv/rstate/.env` | rstate config (REST_PORT, CVM_SERVER_NSEC, ingest relays) |
| `/srv/haproxy/certs/bundle.pem` | TLS certificate |
| `/srv/mysql/.creator-mysql-uri.txt` | MySQL connection string |
| `/srv/oni/data/oni.db` | Oni SQLite database (stream config, chat, users) |

## rstate (NIP-66 Relay Discovery)

rstate is a relay state aggregation engine from the [nostr-watch](https://github.com/sandwichfarm/nostr-watch) project. It:

1. Connects to monitor relays (nostr.watch) via WebSocket
2. Ingests NIP-66 relay metadata events (kind 10166 + 30166)
3. Aggregates relay state (software, NIPs, RTT, geo, uptime)
4. Serves a REST API for relay discovery and search

### rstate REST API (via HAProxy `/relays/*`)

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
- [x] Add mycelium machine (successor to ribbit, no rstate sidecar)
- [x] Add standalone rstate machine (extracted from ribbit)
- [x] MYCELIUM_ENABLED + RSTATE_ENABLED flags in configure.sh
- [x] HAProxy: mycelium → ribbit fallback, direct rstate routing
- [x] Migrate relaycreator frontend to InfernoJS + Tailwind
- [x] Interactive install script with service selection
- [x] Per-service upgrade script
- [x] Add Oni container (live streaming, Owncast fork with Nostr + InfernoJS)
- [ ] Add Oni to configure.sh interactive installer (ONI_ENABLED flag)
- [ ] Add HAProxy `live.<domain>` routing to configure.sh
- [ ] Wire up hyphae + ergo (IRC gateway + daemon)
- [ ] Remove legacy ribbit container after mycelium migration verified
- [ ] Evaluate relaymon for independent RTT monitoring
