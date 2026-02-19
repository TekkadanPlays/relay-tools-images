# Mycelium Stack Migration Plan

## Current State (as of 2026-02-18)

### Repository Map

| Repo | What it contains | Runtime | Status |
|---|---|---|---|
| `relay-tools-images` | systemd-nspawn container defs, deploy scripts, machine configs | bash/systemd | Active — deploys everything |
| `ribbit.network` | Bun/Hono server + InfernoJS SPA + Kaji nostr lib + SQLite cache + rstate proxy + nos2x-fox signer + docs | Bun | Active — serves mycelium.social |
| `relaycreator` | Express API + Prisma/MySQL + React admin panel + relay provisioning | Node 22 + pnpm | Active — serves /api/*, /admin/* |
| `nostr-watch` (sandwichfarm) | rstate NIP-66 relay discovery engine (Fastify) | Bun | Active — cloned into ribbit container |
| `mycelium-android` | Android app (Jetpack Compose) | Kotlin/Gradle | Active — separate |
| `cybin` | Kotlin Multiplatform Nostr protocol library | Kotlin/Gradle | Active — JitPack |
| `nos2x-fox` | Browser signer extension (InfernoJS fork) | esbuild | Active — lives inside ribbit.network repo |
| `blazecn` | UI component library for InfernoJS | (no runtime) | Documented in ribbit.network |

### Current Container Architecture

```
Internet :443
    │
    ▼
┌─────────────────────────────────────────────┐
│  haproxy                                     │
│  /api/* /admin/* /.well-known/* → :4000      │
│  everything else → :3000                     │
└──────┬──────────────────────────────┬────────┘
       │                              │
┌──────▼──────────┐     ┌─────────────▼────────┐
│ relaycreator     │     │ ribbit               │
│ :4000            │     │ :3000                │
│                  │     │                      │
│ Express API      │     │ Bun/Hono SPA         │
│ Prisma + MySQL   │     │ Kaji nostr lib       │
│ React admin      │     │ SQLite event cache   │
│ Relay provision  │     │ rstate proxy → :3100 │
└──────────────────┘     └──────────────────────┘
                         │
                         │ internal
                    ┌────▼─────────────────────┐
                    │ rstate :3100              │
                    │ NIP-66 relay discovery    │
                    │ (nostr-watch/rstate)      │
                    └──────────────────────────┘
```

### Problems with Current State

1. **rstate lives inside ribbit.network** — The relay discovery API is proxied through the Hono server but is a completely separate process (nostr-watch clone). It should be a first-class service in the container stack, not a side-car hidden inside the ribbit repo.

2. **Two separate web servers** — relaycreator (Express/Node) and ribbit (Bun/Hono) serve different path prefixes via HAProxy. The relay provisioning API and admin panel are in a completely different tech stack (Express + React + Prisma + MySQL) from the main site (Bun + Hono + Inferno).

3. **The "ribbit" name** — The domain is mycelium.social. The repo is ribbit.network. The container is ribbit. Confusing.

4. **Frontend split** — relaycreator has a React admin panel that's being migrated to InfernoJS. The marketing/home page should be the relay tools landing page, not the Nostr social client.

5. **Documentation centralized** — All project docs (Kaji, Cybin, Mycelium Android, Blazecn, nos2x-frog, NIPs) live inside ribbit.network. They should live in their respective repos.

6. **SQLite cache is server-side state** — The Hono server has a full SQLite event cache with materialized views for profiles, relay lists, and contacts. This is real application state, not just a frontend.

---

## Target State

### Design Principles

- **Pure Bun + Hono + InfernoJS** on top of mycelium core (relay-tools-images)
- **One container, one concern** — rstate gets its own container definition
- **Repo = deployable unit** — each repo maps to exactly one container or library
- **Documentation lives with code** — each repo has its own `/docs` that the website can pull from

### Target Repository Map

| Repo | Purpose | Container | Runtime |
|---|---|---|---|
| `relay-tools-images` | Container orchestration, systemd services, deploy scripts | Host | bash/systemd |
| `mycelium.social` *(rename ribbit.network)* | Primary website: Bun/Hono server + InfernoJS SPA + Kaji + SQLite cache | `mycelium` | Bun |
| `relaycreator` | Express API + Prisma/MySQL relay provisioning (API only, no frontend) | `relaycreator` | Node 22 |
| `nostr-watch` (upstream) | rstate NIP-66 relay discovery | `rstate` *(new container)* | Bun |
| `mycelium-android` | Android app | N/A (mobile) | Kotlin |
| `cybin` | Kotlin Nostr protocol library | N/A (JitPack) | Kotlin |
| `nos2x-frog` *(extract from ribbit.network)* | Browser signer extension | N/A (extension) | esbuild |
| `blazecn` | UI component library | N/A (npm) | N/A |
| `kaji` | Nostr protocol library (TypeScript) | N/A (bundled) | N/A |

### Target Container Architecture

```
Internet :443
    │
    ▼
┌──────────────────────────────────────────────────┐
│  haproxy                                          │
│                                                   │
│  /api/* /admin/* /.well-known/acme* → :4000       │
│  /relays/* /monitors/* → :3100                    │
│  everything else → :3000                          │
└──────┬──────────────────┬──────────────┬──────────┘
       │                  │              │
┌──────▼──────┐  ┌────────▼────────┐  ┌──▼──────────────┐
│ relaycreator │  │ mycelium :3000  │  │ rstate :3100    │
│ :4000        │  │                 │  │                 │
│              │  │ Bun/Hono SPA    │  │ NIP-66 relay    │
│ Express API  │  │ InfernoJS       │  │ discovery       │
│ Prisma+MySQL │  │ Kaji nostr lib  │  │ (nostr-watch)   │
│ Relay provis │  │ SQLite cache    │  │                 │
└──────────────┘  │ NIP-05          │  └─────────────────┘
                  │                 │
                  │ Pages:          │
                  │  / → relay tools│
                  │    home/landing │
                  │  /app → nostr   │
                  │    social client│
                  │  /docs → docs   │
                  │  /admin → admin │
                  │    panel (inferno│
                  │    migration)   │
                  └─────────────────┘
```

### Key Changes

#### 1. Rename `ribbit` → `mycelium` container
- Rename machine dir: `machines/ribbit/` → `machines/mycelium/`
- Update all systemd units, nspawn configs, deploy scripts
- Update HAProxy backend names
- Update configure.sh flags

#### 2. Extract rstate into its own container
- New `machines/rstate/` container definition
- HAProxy routes `/relays/*` and `/monitors/*` directly to rstate:3100
- Remove rstate proxy from the Hono server (relays.ts route becomes unnecessary)
- rstate gets its own deploy.timer for nostr-watch updates

#### 3. Website serves relay tools as home page
- The landing page (`/`) becomes the relay tools marketing page
- The Nostr social client moves to `/app` or similar sub-path
- The admin panel (currently React in relaycreator) gets migrated to InfernoJS and served from the mycelium container
- relaycreator becomes API-only (no frontend serving)

#### 4. Documentation strategy
Each repo gets a `/docs` directory with markdown:
```
mycelium-android/docs/    → Android app docs
cybin/docs/               → Cybin library docs
nos2x-frog/docs/          → Signer extension docs
blazecn/docs/             → UI component docs
kaji/docs/                → Nostr library docs
mycelium.social/docs/     → Website-specific docs + renders all of the above
```

The website can either:
- **Git submodule** each repo's docs (complex, brittle)
- **Build-time fetch** from GitHub API (simple, works with mirrors)
- **Manual sync** for now, migrate to automated later

**Recommendation**: For now, keep docs in the website repo (it works). When you set up Gitea/Codeberg, add a CI hook that syncs each repo's `/docs` to the website on push. This gives you self-sovereign mirroring AND centralized rendering.

#### 5. Self-hosted git mirroring (future)
```
GitHub (primary) ──push──► Gitea/Codeberg (mirror)
                              │
                              ├── CI: sync docs to website
                              ├── CI: build & deploy containers
                              └── Public read access (sovereign)
```

This is the right move for sovereignty but not urgent. GitHub remains primary for discoverability; the self-hosted instance is your backup and CI runner.

---

## Migration Phases

### Phase 1: Container rename + rstate extraction (relay-tools-images)
- [ ] Copy `machines/ribbit/` → `machines/mycelium/`
- [ ] Create `machines/rstate/` with its own install, nspawn, service files
- [ ] Update `machines/configure.sh` — rename RIBBIT_ENABLED → MYCELIUM_ENABLED
- [ ] Update `machines/build` script
- [ ] Update HAProxy config to route `/relays/*` directly to rstate
- [ ] Update all README references

### Phase 2: Website repo migration (ribbit.network → mycelium.social)
- [ ] Rename GitHub repo `ribbit.network` → `mycelium.social` (or create new, archive old)
- [ ] Update server health endpoint: `ribbit.network` → `mycelium.social`
- [ ] Remove rstate proxy route (relays.ts) — HAProxy handles this now
- [ ] Update deploy.sh git remote URLs
- [ ] Update container install script to clone from new repo

### Phase 3: Route restructuring (website)
- [ ] Move current landing page to relay tools home
- [ ] Move Nostr social client to `/app` sub-path
- [ ] Begin InfernoJS migration of relaycreator admin panel
- [ ] Consolidate NIP-05 serving

### Phase 4: Documentation per-repo (future)
- [ ] Create `/docs` dirs in each library repo
- [ ] Set up build-time doc aggregation or submodule strategy
- [ ] Self-hosted Gitea/Codeberg instance
- [ ] CI hooks for doc sync

---

## What NOT to change right now

- **No page modifications** — existing pages stay as-is
- **relaycreator Express API** — stays Node/Express/Prisma/MySQL, it works
- **nostr-watch upstream** — keep using sandwichfarm's repo, just containerize it properly
- **Payment stack** — untouched (bitcoinknots, cln, lnbits, coinos, keydb)
- **nos2x-fox** — stays in ribbit.network repo for now (extract later)

---

## File Inventory: What lives where

### ribbit.network/ribbit/src/server/ (Hono backend — KEEP)
| File | Purpose | Migration note |
|---|---|---|
| `index.ts` | Hono app entry, static serving, SPA fallback | Rename service identity |
| `routes/health.ts` | Health check | Update service name |
| `routes/nip05.ts` | NIP-05 identity mapping | Keep |
| `routes/relays.ts` | rstate proxy (194 lines) | **DELETE** — HAProxy routes directly |
| `routes/cache.ts` | SQLite cache API (296 lines) | Keep |
| `db/` | SQLite schema, events, profiles, relay-lists, contacts | Keep |

### ribbit.network/ribbit/src/app/ (InfernoJS frontend — KEEP)
| Dir | Purpose | Migration note |
|---|---|---|
| `pages/Landing.tsx` | Home page | Will become relay tools landing |
| `pages/Home.tsx` | Authenticated feed | Moves to /app route |
| `pages/docs/` | All documentation | Keep for now |
| `pages/RelayDiscovery.tsx` | Relay discovery UI | Keep |
| `pages/RelayDetail.tsx` | Relay detail page | Keep |
| `store/` | Client-side state | Keep |
| `components/` | Shared components | Keep |
| `ui/` | Blazecn components | Keep |

### ribbit.network/ribbit/src/nostr/ (Kaji — KEEP)
All 14 files — the TypeScript Nostr protocol library. Stays bundled.

### relay-tools-images/machines/ (containers — UPDATE)
| Dir | Current | Target |
|---|---|---|
| `ribbit/` | Bun/Hono + rstate sidecar | → `mycelium/` (Bun/Hono only) |
| *(new)* `rstate/` | — | rstate standalone container |
| `relaycreator/` | Express API + React frontend | Express API only (frontend migrates) |
| `haproxy/` | Routes to ribbit + relaycreator | Routes to mycelium + relaycreator + rstate |
| Others | Unchanged | Unchanged |
