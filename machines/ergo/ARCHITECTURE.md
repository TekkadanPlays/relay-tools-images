# Ergo IRC Architecture — Mycelium Platform

## Overview

Ergo IRC server provides real-time chat for the Mycelium platform. Users connect via **Hyphae** (web IRC client at `chat.mycelium.social`) which bridges to Ergo on `127.0.0.1:6667`.

## Network Topology

```
Browser → HAProxy (TLS) → Hyphae (port 5173) → Ergo (port 6667)
                                                    ↑
Mycelium Live (port 8085) ──── channel-mgmt.sh ─────┘
```

- **HAProxy** terminates TLS for `chat.mycelium.social`, routes to Hyphae
- **Hyphae** serves the web UI and bridges WebSocket ↔ IRC
- **Ergo** listens on loopback only (no public exposure)
- **Mycelium Live** manages per-stream channels via `channel-mgmt.sh`

## Channel Structure

| Pattern | Purpose | Lifecycle |
|---------|---------|-----------|
| `#lobby` | Public lobby, auto-joined | Permanent |
| `#live-<stream>` | Per-stream chat | Created on stream start, closed on end |
| `#relay-<domain>` | Per-relay operator chat | Created on relay provision |
| `#<custom>` | User-created channels | User-managed |

## Authentication

1. **NIP-07 via Hyphae**: User signs a challenge with their Nostr extension. Hyphae verifies the signature and registers the user with Ergo using their npub as nick.
2. **SASL PLAIN**: Traditional IRC auth for non-Nostr clients.
3. **Nostr verification**: Ergo's built-in `nostr-verification` validates npub ownership during registration.

## Per-Stream Channel Lifecycle

When a streamer clicks "Broadcast to Nostr" on `live.mycelium.social`:

1. **Stream starts** → Mycelium Live calls `channel-mgmt.sh create #live-stream "Stream Title"`
2. **Hyphae** auto-joins viewers to `#live-stream` when they open the live page
3. **Stream ends** → Mycelium Live calls `channel-mgmt.sh destroy #live-stream`

## Per-Relay Channels (Future)

For relay operators authenticated via NIP-42:

1. Relay provisioned → `channel-mgmt.sh create #relay-example-com "example.com relay operators"`
2. Only NIP-42 authenticated users from that relay can join (enforced by Hyphae bridge)
3. Relay deprovisioned → channel archived/destroyed

## Files

- `ircd.yaml` — Ergo server config
- `ircd.motd` — Message of the day
- `app.service` — systemd service unit
- `nspawn` — systemd-nspawn container config
- `install` — Container setup script
- `channel-mgmt.sh` — Channel lifecycle management
- `start/stop/status/console` — Management scripts

## Environment Variables

Set in the Ergo container or on the host:

- `ERGO_OPER_PASS` — Oper password for channel-mgmt.sh (generate with `ergo genpasswd`)

Set in the Mycelium Live container:

- `ALLOWED_PUBKEYS` — Comma-separated hex pubkeys allowed to broadcast/admin
- `ERGO_OPER_PASS` — Passed through for channel management calls
