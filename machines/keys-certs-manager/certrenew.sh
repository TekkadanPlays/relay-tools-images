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
BUNDLE="/srv/haproxy/certs/bundle.pem"
DOMAIN_LIST="/srv/haproxy/cert-domains.txt"

# ---------------------------------------------------------------------------
# Find the active cert live directory
# Certbot may create numbered lineages (mycelium.social-0001, -0002, etc.)
# We want the most recent one.
# ---------------------------------------------------------------------------

LIVE_DIR=""
if [ -d "$CERT_DIR/live" ]; then
    for d in $(ls -d "$CERT_DIR/live/$DOMAIN"* 2>/dev/null | sort -V | tac); do
        if [ -f "$d/fullchain.pem" ]; then
            LIVE_DIR="$d"
            break
        fi
    done
fi

if [ -n "$LIVE_DIR" ]; then
    echo "Using cert lineage: $LIVE_DIR"
else
    echo "No existing cert found — will issue new cert"
fi

# ---------------------------------------------------------------------------
# Build the list of domains the cert should cover
# ---------------------------------------------------------------------------

DESIRED_DOMAINS=()

if [ -f "$DOMAIN_LIST" ]; then
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -n "$line" ] && DESIRED_DOMAINS+=("$line")
    done < "$DOMAIN_LIST"
else
    echo "WARNING: $DOMAIN_LIST not found. Using defaults: $DOMAIN, app.$DOMAIN"
    DESIRED_DOMAINS=("$DOMAIN" "app.$DOMAIN")
fi

if [ ${#DESIRED_DOMAINS[@]} -eq 0 ]; then
    echo "ERROR: No domains found in $DOMAIN_LIST"
    exit 1
fi

echo "Desired domains (${#DESIRED_DOMAINS[@]}): ${DESIRED_DOMAINS[*]}"

# ---------------------------------------------------------------------------
# Check cert status: domains covered, expiry
# ---------------------------------------------------------------------------

CURRENT_SANS=""
NEEDS_REISSUE=false
FORCE_RENEWAL=false

if [ -n "$LIVE_DIR" ] && [ -f "$LIVE_DIR/fullchain.pem" ]; then
    CURRENT_SANS=$(openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -text 2>/dev/null \
        | grep -A1 "Subject Alternative Name" \
        | tail -1 \
        | sed 's/DNS://g; s/,/ /g' \
        | xargs)
    echo "Current cert SANs: $CURRENT_SANS"

    # Check expiry
    EXPIRY=$(openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//')
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    echo "Cert expires: $EXPIRY ($DAYS_LEFT days remaining)"

    if [ "$DAYS_LEFT" -le 0 ]; then
        echo "Certificate is EXPIRED — forcing renewal"
        FORCE_RENEWAL=true
        NEEDS_REISSUE=true
    elif [ "$DAYS_LEFT" -le 30 ]; then
        echo "Certificate expires within 30 days — renewal needed"
        NEEDS_REISSUE=true
    fi

    # Check if every desired domain is covered
    for d in "${DESIRED_DOMAINS[@]}"; do
        if ! echo "$CURRENT_SANS" | grep -qw "$d"; then
            PARENT=$(echo "$d" | sed 's/^[^.]*\.//')
            if ! echo "$CURRENT_SANS" | grep -qw "\*.$PARENT"; then
                echo "Domain '$d' is NOT in current cert — reissue needed"
                NEEDS_REISSUE=true
                FORCE_RENEWAL=true
                break
            fi
        fi
    done
else
    echo "No existing cert found — initial issue needed"
    NEEDS_REISSUE=true
fi

BEFORE_FP=""
if [ -n "$LIVE_DIR" ] && [ -f "$LIVE_DIR/fullchain.pem" ]; then
    BEFORE_FP=$(openssl x509 -noout -fingerprint -in "$LIVE_DIR/fullchain.pem" 2>/dev/null || echo "")
fi

# ---------------------------------------------------------------------------
# Issue, expand, or renew
# ---------------------------------------------------------------------------

DOMAIN_FLAGS=""
for d in "${DESIRED_DOMAINS[@]}"; do
    DOMAIN_FLAGS="$DOMAIN_FLAGS -d $d"
done

if [ "$NEEDS_REISSUE" = true ]; then
    EXTRA_FLAGS=""
    [ "$FORCE_RENEWAL" = true ] && EXTRA_FLAGS="--force-renewal"

    echo "Issuing/expanding cert for: ${DESIRED_DOMAINS[*]}"
    [ -n "$EXTRA_FLAGS" ] && echo "Using flags: $EXTRA_FLAGS"

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
        $EXTRA_FLAGS \
        --non-interactive
else
    echo "All domains covered and cert is valid. Running normal renewal check..."
    certbot renew \
        --config-dir="$CERT_DIR" \
        --work-dir="$CERT_DIR" \
        --logs-dir="$CERT_DIR" \
        --http-01-port 8080 \
        --non-interactive
fi

# ---------------------------------------------------------------------------
# Re-detect live dir (certbot may have created a new lineage)
# ---------------------------------------------------------------------------

NEW_LIVE_DIR=""
for d in $(ls -d "$CERT_DIR/live/$DOMAIN"* 2>/dev/null | sort -V | tac); do
    if [ -f "$d/fullchain.pem" ]; then
        NEW_LIVE_DIR="$d"
        break
    fi
done

if [ -z "$NEW_LIVE_DIR" ]; then
    echo "ERROR: No cert found after certbot run"
    exit 1
fi

[ "$NEW_LIVE_DIR" != "${LIVE_DIR:-}" ] && echo "New lineage detected: $NEW_LIVE_DIR"

# ---------------------------------------------------------------------------
# Rebuild bundle if cert changed
# ---------------------------------------------------------------------------

AFTER_FP=""
if [ -f "$NEW_LIVE_DIR/fullchain.pem" ]; then
    AFTER_FP=$(openssl x509 -noout -fingerprint -in "$NEW_LIVE_DIR/fullchain.pem" 2>/dev/null || echo "")
fi

if [ "$BEFORE_FP" != "$AFTER_FP" ]; then
    echo "Certificate was renewed/issued. Rebuilding haproxy bundle..."

    if [ -f "$NEW_LIVE_DIR/fullchain.pem" ] && [ -f "$NEW_LIVE_DIR/privkey.pem" ]; then
        mkdir -p /srv/haproxy/certs
        cat "$NEW_LIVE_DIR/fullchain.pem" "$NEW_LIVE_DIR/privkey.pem" > "$BUNDLE"
        chmod 0600 "$BUNDLE"
        echo "Bundle updated at $BUNDLE"
        openssl x509 -in "$NEW_LIVE_DIR/fullchain.pem" -noout -dates 2>/dev/null || true
        openssl x509 -in "$NEW_LIVE_DIR/fullchain.pem" -noout -text 2>/dev/null \
            | grep -A1 "Subject Alternative Name" || true
    else
        echo "ERROR: Certificate files not found in $NEW_LIVE_DIR"
        exit 1
    fi
else
    echo "Certificate not changed, no bundle update needed."
fi
