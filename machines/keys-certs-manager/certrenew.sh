#!/bin/bash
# Certificate renewal script for relay-tools
# Runs inside the keys-certs-manager nspawn container.
# Certbot state lives at /etc/haproxy/certs (container-local filesystem).
# The haproxy bundle must be written to /srv/haproxy/certs/bundle.pem (bind mount)
# so that the haproxy container can see it at /etc/haproxy/certs/bundle.pem.

set -euo pipefail

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
    echo "Usage: certrenew.sh <domain>"
    exit 1
fi

CERT_DIR="/etc/haproxy/certs"
LIVE_DIR="$CERT_DIR/live/$DOMAIN"
BUNDLE="/srv/haproxy/certs/bundle.pem"

# Record the current cert fingerprint for comparison
BEFORE_FP=""
if [ -f "$LIVE_DIR/fullchain.pem" ]; then
    BEFORE_FP=$(openssl x509 -noout -fingerprint -in "$LIVE_DIR/fullchain.pem" 2>/dev/null || echo "")
fi

# Attempt renewal
# certbot renew will only actually renew if the cert is within 30 days of expiry
# Use --http-01-port 8080 so certbot doesn't conflict with haproxy on port 80.
# HAProxy forwards /.well-known/acme-challenge/ to 127.0.0.1:8080.
certbot renew \
    --config-dir="$CERT_DIR" \
    --work-dir="$CERT_DIR" \
    --logs-dir="$CERT_DIR" \
    --http-01-port 8080 \
    --non-interactive

# Check if renewal happened
AFTER_FP=""
if [ -f "$LIVE_DIR/fullchain.pem" ]; then
    AFTER_FP=$(openssl x509 -noout -fingerprint -in "$LIVE_DIR/fullchain.pem" 2>/dev/null || echo "")
fi

if [ "$BEFORE_FP" != "$AFTER_FP" ]; then
    echo "Certificate was renewed. Rebuilding haproxy bundle..."

    # Rebuild the bundle for haproxy (written to the bind mount so haproxy can see it)
    if [ -f "$LIVE_DIR/fullchain.pem" ] && [ -f "$LIVE_DIR/privkey.pem" ]; then
        mkdir -p /srv/haproxy/certs
        cat "$LIVE_DIR/fullchain.pem" "$LIVE_DIR/privkey.pem" > "$BUNDLE"
        chmod 0600 "$BUNDLE"
        echo "Bundle updated at $BUNDLE"
    else
        echo "ERROR: Certificate files not found in $LIVE_DIR"
        exit 1
    fi
else
    echo "Certificate not yet due for renewal, no changes needed."
fi
