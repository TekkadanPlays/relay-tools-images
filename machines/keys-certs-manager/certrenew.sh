#!/bin/bash
# Certificate renewal script for relay-tools
# Runs inside the keys-certs-manager nspawn container.
# Certbot state lives at /etc/haproxy/certs (container-local filesystem).
# The haproxy bundle must be written to /srv/haproxy/certs/bundle.pem (bind mount)
# so that the haproxy container can see it at /etc/haproxy/certs/bundle.pem.
#
# Domain list: /srv/haproxy/cert-domains.txt (one domain per line, # comments OK)
# When adding a new subdomain, just append it to that file and the next
# renewal run will expand the cert automatically.

set -euo pipefail

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
    echo "Usage: certrenew.sh <domain>"
    exit 1
fi

CERT_DIR="/etc/haproxy/certs"
LIVE_DIR="$CERT_DIR/live/$DOMAIN"
BUNDLE="/srv/haproxy/certs/bundle.pem"
DOMAIN_LIST="/srv/haproxy/cert-domains.txt"

# ---------------------------------------------------------------------------
# Build the list of domains the cert should cover
# ---------------------------------------------------------------------------

DESIRED_DOMAINS=()

if [ -f "$DOMAIN_LIST" ]; then
    # Read domains from file (skip comments and blank lines)
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -n "$line" ] && DESIRED_DOMAINS+=("$line")
    done < "$DOMAIN_LIST"
else
    # Fallback: just the base domain + app subdomain
    echo "WARNING: $DOMAIN_LIST not found. Using defaults: $DOMAIN, app.$DOMAIN"
    DESIRED_DOMAINS=("$DOMAIN" "app.$DOMAIN")
fi

if [ ${#DESIRED_DOMAINS[@]} -eq 0 ]; then
    echo "ERROR: No domains found in $DOMAIN_LIST"
    exit 1
fi

echo "Desired domains (${#DESIRED_DOMAINS[@]}): ${DESIRED_DOMAINS[*]}"

# ---------------------------------------------------------------------------
# Check what domains the current cert covers
# ---------------------------------------------------------------------------

CURRENT_SANS=""
NEEDS_REISSUE=false

if [ -f "$LIVE_DIR/fullchain.pem" ]; then
    CURRENT_SANS=$(openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -text 2>/dev/null \
        | grep -A1 "Subject Alternative Name" \
        | tail -1 \
        | sed 's/DNS://g; s/,/ /g' \
        | xargs)
    echo "Current cert SANs: $CURRENT_SANS"

    # Check if every desired domain is in the current cert
    for d in "${DESIRED_DOMAINS[@]}"; do
        if ! echo "$CURRENT_SANS" | grep -qw "$d"; then
            echo "Domain '$d' is NOT in current cert — reissue needed"
            NEEDS_REISSUE=true
            break
        fi
    done
else
    echo "No existing cert found at $LIVE_DIR — initial issue needed"
    NEEDS_REISSUE=true
fi

# Record the current cert fingerprint for comparison
BEFORE_FP=""
if [ -f "$LIVE_DIR/fullchain.pem" ]; then
    BEFORE_FP=$(openssl x509 -noout -fingerprint -in "$LIVE_DIR/fullchain.pem" 2>/dev/null || echo "")
fi

# ---------------------------------------------------------------------------
# Issue, expand, or renew
# ---------------------------------------------------------------------------

# Build -d flags
DOMAIN_FLAGS=""
for d in "${DESIRED_DOMAINS[@]}"; do
    DOMAIN_FLAGS="$DOMAIN_FLAGS -d $d"
done

if [ "$NEEDS_REISSUE" = true ]; then
    echo "Issuing/expanding cert for: ${DESIRED_DOMAINS[*]}"
    certbot certonly \
        --config-dir="$CERT_DIR" \
        --work-dir="$CERT_DIR" \
        --logs-dir="$CERT_DIR" \
        $DOMAIN_FLAGS \
        --standalone \
        --preferred-challenges http \
        --http-01-port 8080 \
        --agree-tos \
        --register-unsafely-without-email \
        --expand \
        --non-interactive
else
    echo "All domains covered. Running normal renewal check..."
    certbot renew \
        --config-dir="$CERT_DIR" \
        --work-dir="$CERT_DIR" \
        --logs-dir="$CERT_DIR" \
        --http-01-port 8080 \
        --non-interactive
fi

# ---------------------------------------------------------------------------
# Rebuild bundle if cert changed
# ---------------------------------------------------------------------------

AFTER_FP=""
if [ -f "$LIVE_DIR/fullchain.pem" ]; then
    AFTER_FP=$(openssl x509 -noout -fingerprint -in "$LIVE_DIR/fullchain.pem" 2>/dev/null || echo "")
fi

if [ "$BEFORE_FP" != "$AFTER_FP" ]; then
    echo "Certificate was renewed/issued. Rebuilding haproxy bundle..."

    if [ -f "$LIVE_DIR/fullchain.pem" ] && [ -f "$LIVE_DIR/privkey.pem" ]; then
        mkdir -p /srv/haproxy/certs
        cat "$LIVE_DIR/fullchain.pem" "$LIVE_DIR/privkey.pem" > "$BUNDLE"
        chmod 0600 "$BUNDLE"
        echo "Bundle updated at $BUNDLE"

        # Show new cert details
        openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -dates 2>/dev/null || true
        openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -text 2>/dev/null \
            | grep -A1 "Subject Alternative Name" || true
    else
        echo "ERROR: Certificate files not found in $LIVE_DIR"
        exit 1
    fi
else
    echo "Certificate not changed, no bundle update needed."
fi
