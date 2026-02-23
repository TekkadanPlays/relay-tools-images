# relay-tools-desktop

Desktop app for running the relay-tools Nostr stack locally. Built with [Buntralino](https://buntralino.github.io/) (Bun + Neutralino.js).

## Architecture

```
┌──────────────────────────────────────────────┐
│  Buntralino App                              │
│                                              │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Bun Main     │  │ Neutralino WebView   │  │
│  │              │  │                      │  │
│  │ • MariaDB    │◄─┤ • Setup wizard       │  │
│  │ • strfry     │  │ • Service dashboard  │  │
│  │ • API server │  │ • → Admin panel      │  │
│  │ • Health     │  │                      │  │
│  └──────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────┘
```

- **Bun main process** (`src/main.ts`) — manages child processes (MariaDB, strfry, relaycreator API), exposes control methods via Buntralino's method registry
- **Neutralino window** (`frontend/index.html`) — lightweight native WebView shell showing setup wizard or service dashboard, with a button to open the full relaycreator admin panel in the browser
- **Service manager** (`src/services/manager.ts`) — spawns, monitors, and logs all services
- **Setup wizard** (`src/services/setup.ts`) — first-run detection, dependency installation, DB init, cert generation

## Services Managed

| Service | Windows | Linux |
|---|---|---|
| MariaDB | Windows service (`net start/stop`) | systemd (`systemctl`) |
| strfry | WSL2 Ubuntu child process | Native child process |
| relaycreator | Bun child process | Bun child process |

## Development

```bash
# Install dependencies
bun install

# Download Neutralino binaries (first time)
bunx @nicepkg/neu-cli install

# Run in dev mode
bun run dev
```

## Packaging (TODO)

- **Windows**: NSIS or Inno Setup → `.exe` installer
- **Linux**: AppImage or `.deb`
- **macOS**: `.dmg` bundle

## Data Directory

All data lives in `~/relay-tools/`:
- `certs/` — mkcert TLS certificates
- `data/strfry/` — strfry database and config
- `relaycreator/` — cloned repo, `.env`, built frontend
- `logs/` — service log files
