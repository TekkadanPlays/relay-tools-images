# TLS Certificate Management for relay-tools

## Architecture

```
┌─────────────────────┐     ┌──────────────────────┐
│  keys-certs-manager │     │       haproxy         │
│  (nspawn container) │     │   (nspawn container)  │
│                     │     │                       │
│  certbot state:     │     │  reads bundle.pem     │
│  /etc/haproxy/certs │     │  from /etc/haproxy/   │
│                     │     │  certs/bundle.pem     │
│  writes bundle to:  │     │  (bind-mounted from   │
│  /srv/haproxy/certs/│────▶│  /srv/haproxy/certs/) │
│  bundle.pem         │     │                       │
└─────────────────────┘     └──────────────────────┘
```

### Key paths

| What | Path | Container |
|------|------|-----------|
| Certbot config/state | `/etc/haproxy/certs/` | keys-certs-manager |
| Cert live dir | `/etc/haproxy/certs/live/$DOMAIN/` | keys-certs-manager |
| HAProxy PEM bundle | `/srv/haproxy/certs/bundle.pem` | keys-certs-manager (writes) |
| HAProxy reads PEM | `/etc/haproxy/certs/bundle.pem` | haproxy (bind mount) |

### How the PEM bundle is built

HAProxy needs a single PEM file containing both the full certificate chain and the private key:

```bash
cat fullchain.pem privkey.pem > bundle.pem
```

## ACME Challenge Flow

### Initial setup (configure.sh, HAProxy not running yet)
- Certbot runs standalone on **port 80** directly
- No port conflict because HAProxy hasn't started

### Renewal (certrenew.sh, HAProxy IS running)
- HAProxy listens on port 80
- HAProxy routes `/.well-known/acme-challenge/` → `127.0.0.1:8080`
- Certbot runs with `--http-01-port 8080`
- HAProxy forwards the ACME challenge to certbot's standalone server

### Important: Port mapping
- **relay-tools-images HAProxy skel**: ACME → `127.0.0.1:8080`
- **relaycreator-generated HAProxy**: ACME → `127.0.0.1:10000`
- Always check which config is active: `grep -A2 certbot /etc/haproxy/haproxy.cfg`

## Common Operations

### Check current cert domains
```bash
systemd-nspawn --pipe -M keys-certs-manager /bin/bash -c '
  openssl x509 -in /etc/haproxy/certs/live/mycelium.social/fullchain.pem \
    -noout -text | grep -A1 "Subject Alternative Name"
'
```

### Add a new subdomain to the cert
**You must include ALL existing domains plus the new one.** Certbot replaces the cert entirely.

```bash
# 1. Check existing domains first (see above)

# 2. Expand cert (with HAProxy running, using port 8080)
systemd-nspawn --pipe -M keys-certs-manager /bin/bash -c '
  certbot certonly \
    --config-dir="/etc/haproxy/certs" \
    --work-dir="/etc/haproxy/certs" \
    --logs-dir="/etc/haproxy/certs" \
    -d "mycelium.social" \
    -d "app.mycelium.social" \
    -d "chat.mycelium.social" \
    -d "live.mycelium.social" \
    --expand \
    --standalone \
    --preferred-challenges http \
    --http-01-port 8080 \
    --non-interactive
'

# 3. Rebuild bundle
systemd-nspawn --pipe -M keys-certs-manager /bin/bash -c '
  cat /etc/haproxy/certs/live/mycelium.social/fullchain.pem \
      /etc/haproxy/certs/live/mycelium.social/privkey.pem \
      > /srv/haproxy/certs/bundle.pem
  chmod 0600 /srv/haproxy/certs/bundle.pem
'

# 4. Reload HAProxy
machinectl shell haproxy /bin/bash -c "systemctl reload haproxy || systemctl restart haproxy"

# 5. Verify
echo | openssl s_client -connect 127.0.0.1:443 -servername live.mycelium.social 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
```

### If ACME challenge fails (503 or connection refused)

The ACME challenge can fail if:
1. **Wrong port**: Check which port HAProxy forwards to vs which port certbot listens on
2. **Port already in use**: `ss -tlnp | grep ':8080\|:10000'`
3. **Container networking**: The keys-certs-manager container must be able to bind the port

**Nuclear option** (brief downtime, ~10s):
```bash
# Stop HAProxy so certbot can use port 80 directly
machinectl shell haproxy /bin/bash -c "systemctl stop haproxy"

systemd-nspawn --pipe -M keys-certs-manager /bin/bash -c '
  certbot certonly \
    --config-dir="/etc/haproxy/certs" \
    --work-dir="/etc/haproxy/certs" \
    --logs-dir="/etc/haproxy/certs" \
    -d "mycelium.social" \
    -d "app.mycelium.social" \
    -d "chat.mycelium.social" \
    -d "live.mycelium.social" \
    --expand \
    --standalone \
    --preferred-challenges http \
    --non-interactive
'

# Rebuild bundle and restart
systemd-nspawn --pipe -M keys-certs-manager /bin/bash -c '
  cat /etc/haproxy/certs/live/mycelium.social/fullchain.pem \
      /etc/haproxy/certs/live/mycelium.social/privkey.pem \
      > /srv/haproxy/certs/bundle.pem
  chmod 0600 /srv/haproxy/certs/bundle.pem
'

machinectl start haproxy
```

### Force renewal (cert not expiring yet)
```bash
# Add --force-renewal to the certbot command
certbot certonly ... --force-renewal
```

### Check cert expiry
```bash
systemd-nspawn --pipe -M keys-certs-manager /bin/bash -c '
  openssl x509 -in /etc/haproxy/certs/live/mycelium.social/fullchain.pem \
    -noout -dates
'
```

## Auto-renewal

- **Timer**: `certrenew.timer` runs twice daily with 1h random delay
- **Service**: `certrenew.service` runs `certrenew.sh $CREATOR_DOMAIN` inside keys-certs-manager
- **Post-action**: Reloads HAProxy after successful renewal
- Certbot only actually renews when cert is within 30 days of expiry

### Check timer status
```bash
systemctl status certrenew.timer
systemctl list-timers certrenew.timer
```

### Manual renewal trigger
```bash
systemctl start certrenew.service
journalctl -u certrenew.service -f
```
