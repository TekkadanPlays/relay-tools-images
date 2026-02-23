# relay-tools Local Installation

Run your own Nostr relay stack locally — no cloud server, no domain, no containers.

## What You Get

| Component | Purpose | Port |
|-----------|---------|------|
| **strfry** | Nostr relay engine (C++) | `ws://localhost:7777` |
| **relaycreator** | API server + admin panel | `http://localhost:4000` |
| **MariaDB** | Database | `localhost:3306` |
| **mkcert** | Locally-trusted TLS certs | — |
| **CoinOS** *(optional)* | Bitcoin Lightning wallet | `localhost:3119` |

## How It Differs From Server Install

| | Server (`install.sh`) | Local (`install-local.sh`) |
|---|---|---|
| **Containers** | systemd-nspawn per service | None — native processes |
| **TLS** | Let's Encrypt + HAProxy | mkcert (locally-trusted) |
| **Relay routing** | Subdomain per relay (`relay.domain.com`) | Port per relay (`ws://localhost:7777`) |
| **DNS** | Wildcard DNS required | No DNS needed |
| **Cert provisioning** | cookiecutter daemon | Not needed |
| **HAProxy** | Required | Not needed |
| **Root access** | Required (nspawn) | Required (systemd services) |

## Quick Start

### Linux (Ubuntu/Debian)

```bash
git clone https://github.com/TekkadanPlays/relay-tools-images.git
cd relay-tools-images
sudo ./install-local.sh
```

The installer will:
1. Install MariaDB, Node.js, Bun, mkcert
2. Build strfry from source (~5 min)
3. Clone and build relaycreator
4. Create systemd services
5. Generate locally-trusted TLS certificates
6. Start everything

After install:
```bash
~/relay-tools/status.sh    # Check service status
~/relay-tools/start.sh     # Start services
~/relay-tools/stop.sh      # Stop services
~/relay-tools/upgrade.sh   # Pull latest + rebuild
```

### Windows

Requires PowerShell as Administrator. strfry runs inside WSL2 (Ubuntu).

```powershell
git clone https://github.com/TekkadanPlays/relay-tools-images.git
cd relay-tools-images
.\install-local.ps1
```

The installer will:
1. Install Git, Node.js, Bun, MariaDB, mkcert via winget
2. Install WSL2 + Ubuntu (may require restart)
3. Build strfry inside WSL2
4. Clone and build relaycreator natively
5. Create start/stop/status batch scripts

After install:
```
%USERPROFILE%\relay-tools\start.bat     # Start services
%USERPROFILE%\relay-tools\stop.bat      # Stop services
%USERPROFILE%\relay-tools\status.bat    # Check status
```

## Connecting Nostr Clients

Add this relay in any Nostr client:

```
ws://localhost:7777
```

From other devices on your LAN:

```
ws://YOUR_IP:7777
```

## Admin Panel

Open `http://localhost:4000` in your browser and log in with a Nostr browser extension (NIP-07) like nos2x or Alby.

## TLS Certificates

The installer uses [mkcert](https://github.com/FiloSottile/mkcert) to generate certificates trusted by your local machine. This means:

- `https://localhost:4000` works without browser warnings
- No Let's Encrypt, no public DNS, no port forwarding needed
- Certificates are stored in `~/relay-tools/certs/`

To trust certs on other LAN devices, copy the CA root cert:
```bash
mkcert -CAROOT   # Shows the CA directory
# Copy the rootCA.pem to other devices and install it
```

## Architecture

```
┌─────────────────────────────────────────────┐
│                  Your Machine               │
│                                             │
│  ┌──────────┐    ┌──────────────────────┐   │
│  │  strfry  │    │    relaycreator      │   │
│  │  :7777   │    │    :4000             │   │
│  │  (relay) │    │  ┌────────┐ ┌─────┐  │   │
│  └──────────┘    │  │Express │ │ SPA │  │   │
│                  │  │  API   │ │(web)│  │   │
│  ┌──────────┐    │  └───┬────┘ └─────┘  │   │
│  │ MariaDB  │◄───┤      │              │   │
│  │  :3306   │    │  Prisma ORM          │   │
│  └──────────┘    └──────────────────────┘   │
│                                             │
│  Nostr clients connect to ws://localhost:7777│
│  Admin panel at http://localhost:4000       │
└─────────────────────────────────────────────┘
```

## Upgrading

### Linux
```bash
~/relay-tools/upgrade.sh
```

### Windows
```powershell
cd $env:USERPROFILE\relay-tools\relaycreator
git pull origin main
cd api-server; npm install; npx prisma db push; npm run build; cd ..
cd web; bun install; bun run build; cd ..
```
Then restart via `stop.bat` + `start.bat`.

## Troubleshooting

**MariaDB won't start**
```bash
sudo systemctl status mariadb
sudo journalctl -u mariadb -n 50
```

**strfry won't start**
```bash
sudo systemctl status relay-tools-strfry
# Check if port 7777 is in use:
ss -tlnp | grep 7777
```

**relaycreator won't start**
```bash
sudo systemctl status relay-tools-api
sudo journalctl -u relay-tools-api -n 50
# Common: DATABASE_URL wrong in ~/relay-tools/relaycreator/.env
```

**Windows: WSL2 not available**
- Enable "Virtual Machine Platform" in Windows Features
- Run `wsl --install` and restart
- Re-run the installer

**Browser shows certificate warning**
```bash
mkcert -install   # Re-install the local CA
```

## Uninstalling

### Linux
```bash
sudo systemctl stop relay-tools-api relay-tools-strfry
sudo systemctl disable relay-tools-api relay-tools-strfry
sudo rm /etc/systemd/system/relay-tools-*.service
sudo systemctl daemon-reload
rm -rf ~/relay-tools
sudo rm -rf /var/lib/relay-tools
# Optionally drop the database:
sudo mariadb -e "DROP DATABASE relaycreator; DROP USER 'relaycreator'@'localhost';"
```

### Windows
```powershell
# Stop services
.\stop.bat
# Remove files
Remove-Item -Recurse -Force "$env:USERPROFILE\relay-tools"
# Optionally remove WSL strfry
wsl -d Ubuntu -- sudo rm /usr/local/bin/strfry
# Optionally drop the database
mysql -u root -e "DROP DATABASE relaycreator; DROP USER 'relaycreator'@'localhost';"
```
