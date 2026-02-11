#!/bin/bash -ex

##
### This script handles the configuration state for a deployment of relay tools.  It assumes that the images have been built or downloaded already.
##

if [ -f ".env" ]; then
    source .env
elif [ -z "$MYDOMAIN" ] && [ -z "$SELF_SIGNED" ]; then
    echo "Please configure a .env file for top level configuration or set MYDOMAIN environment variable"
    echo "MYDOMAIN=root level domain name to use"
    echo "MYEMAIL=<optional> email address for SSL certificate registration"
    echo "-or-"
    echo "for self-signed certificate set:"
    echo "SELF_SIGNED=mydomain.com"
    exit 1
fi

# Launch sequence:

# launch Mysql first.
# configure relaycreator .env
# launch the rest

# on firstrun mysql will drop a credentials URI into /srv/mysql/.creator-mysql-uri.txt
machinectl start mysql

# generate a nostr key for use with API
systemd-nspawn --pipe -M haproxy /bin/bash << EOF
    /usr/local/bin/npub2hex --generate > /srv/relaycreator/.nostrcreds.env
    chmod 0600 /srv/relaycreator/.nostrcreds.env
EOF

# register for SSL certificate with certbot
# for use with: haproxy
# configured in: relaycreator (path), haproxy (bundle.pem file)

if [ -n "$SELF_SIGNED" ]; then
    MYDOMAIN=$SELF_SIGNED
systemd-nspawn --pipe -M haproxy /bin/bash << EOR
    mkdir -p /etc/haproxy/certs
    cd /etc/haproxy/certs

    openssl req -newkey ec:<(openssl ecparam -name secp384r1) -nodes -x509 -keyout ca.key -out ca.pem -days 365000 -subj '/CN=${SELF_SIGNED}/O=MyOrganization/C=US'
    cat ca.key ca.pem > bundle.pem
EOR
    
else

# since haproxy is not started yet, use standalone web mode
# Automatic renewal is handled by certrenew.timer (enabled below after haproxy starts)
systemd-nspawn --pipe -M keys-certs-manager /bin/bash << EOF
    mkdir -p /etc/haproxy/certs

    if [ -z "$MYEMAIL" ]; then
        certbot certonly --config-dir="/etc/haproxy/certs" --work-dir="/etc/haproxy/certs" --logs-dir="/etc/haproxy/certs" -d "$MYDOMAIN" --agree-tos --register-unsafely-without-email --standalone --preferred-challenges http --non-interactive
    else 
        certbot certonly --config-dir="/etc/haproxy/certs" --work-dir="/etc/haproxy/certs" --logs-dir="/etc/haproxy/certs" -d "$MYDOMAIN" --agree-tos -m "$MYEMAIL" --standalone --preferred-challenges http --non-interactive
    fi

    # haproxy needs one file (write to bind mount so haproxy container can see it)
    mkdir -p /srv/haproxy/certs
    cat /etc/haproxy/certs/live/$MYDOMAIN/fullchain.pem /etc/haproxy/certs/live/$MYDOMAIN/privkey.pem > /srv/haproxy/certs/bundle.pem
    chmod 0600 /srv/haproxy/certs/bundle.pem

EOF

fi

echo "$MYDOMAIN"

source /srv/relaycreator/.nostrcreds.env

# wait for mysql configuration to exist (timeout after 120 seconds)
MYSQL_WAIT=0
while [ ! -f "/srv/mysql/.creator-mysql-uri.txt" ]; do
    sleep 1
    MYSQL_WAIT=$((MYSQL_WAIT + 1))
    if [ $MYSQL_WAIT -ge 120 ]; then
        echo "ERROR: MySQL did not initialize within 120 seconds."
        echo "Check: machinectl status mysql"
        exit 1
    fi
done

source /srv/mysql/.creator-mysql-uri.txt

JWT_SECRET=`openssl rand -base64 32`

# Configure relaycreator .env file (Express API server)
cat << EOF > /srv/relaycreator/.env
# Express API server settings
DATABASE_URL=$DATABASE_URL
JWT_SECRET=$JWT_SECRET
PORT=4000
CORS_ORIGIN=https://$MYDOMAIN
DEPLOY_PUBKEY=$NOSTR_PUBLIC_KEY
CREATOR_DOMAIN=$MYDOMAIN
INVOICE_AMOUNT=21
INVOICE_PREMIUM_AMOUNT=2100
HAPROXY_PEM=bundle.pem

# to enable payments you must run LNBITS and set these settings:
PAYMENTS_ENABLED=false
LNBITS_ADMIN_KEY=
LNBITS_INVOICE_READ_KEY=
LNBITS_ENDPOINT=
EOF

# Launch relaycreator
machinectl start relaycreator

# Configure haproxy management daemon (cookiecutter)
cat << EOF > /srv/haproxy/.cookiecutter.env
BASE_URL=https://$MYDOMAIN
PRIVATE_KEY=$NOSTR_PRIVATE_KEY
EOF

# Launch haproxy
machinectl start haproxy

# Enable automatic certificate renewal (skip for self-signed)
if [ -z "$SELF_SIGNED" ]; then
    systemctl daemon-reload
    systemctl enable --now certrenew.timer
    echo "Certificate auto-renewal timer enabled (runs twice daily)"
fi

# Configure strfry management daemon (cookiecutter)
cat << EOF > /srv/strfry/.cookiecutter.env
BASE_URL=https://$MYDOMAIN
PRIVATE_KEY=$NOSTR_PRIVATE_KEY
EOF

cat << EOF > /srv/strfry/.interceptor.env
INTERCEPTOR_CONFIG_URL=https://$MYDOMAIN/api/sconfig/relays
EOF

# Launch strfry
machinectl start strfry

# ─── OPTIONAL: Bitcoin Knots + Core Lightning + LNBits payment stack ───
# Set PAYMENTS_ENABLED=true in .env to activate this section.
# Requires: machines/bitcoinknots, machines/cln, machines/lnbits to be installed.

if [ "${PAYMENTS_ENABLED:-false}" = "true" ]; then
    echo "=== Setting up payment stack: Bitcoin Knots → Core Lightning → LNBits ==="

    # Generate shared Bitcoin RPC credentials
    BTC_RPC_USER="relaytools"
    BTC_RPC_PASS=$(openssl rand -hex 24)

    # ── Bitcoin Knots ──
    mkdir -p /srv/bitcoinknots
    cat << BTCEOF > /srv/bitcoinknots/bitcoin.conf
# Bitcoin Knots v29.3 — BIP-110 compliant (pruned mode)
server=1
listen=1
prune=550

rpcuser=$BTC_RPC_USER
rpcpassword=$BTC_RPC_PASS
rpcallowip=127.0.0.1
rpcallowip=10.0.0.0/8
rpcbind=0.0.0.0
rpcport=8332

# BIP-110 policy defaults
datacarriersize=42
permitbaremultisig=0

# Performance (tuned for small server)
dbcache=450
maxmempool=300
maxconnections=40

printtoconsole=0
debuglogfile=/home/bitcoin/.bitcoin/debug.log
BTCEOF

    machinectl start bitcoinknots
    echo "Bitcoin Knots started (pruned mode, BIP-110). IBD will take 1-3 days."

    # Wait for bitcoind RPC to become available (up to 60s)
    BTC_WAIT=0
    while ! systemd-nspawn --pipe -q -M bitcoinknots /usr/local/bin/bitcoin-cli -rpcuser=$BTC_RPC_USER -rpcpassword=$BTC_RPC_PASS getblockchaininfo >/dev/null 2>&1; do
        sleep 2
        BTC_WAIT=$((BTC_WAIT + 2))
        if [ $BTC_WAIT -ge 60 ]; then
            echo "WARNING: Bitcoin Knots RPC not ready after 60s. CLN will retry on its own."
            break
        fi
    done

    # ── Core Lightning ──
    mkdir -p /srv/cln
    cat << CLNEOF > /srv/cln/config
# Core Lightning — connected to Bitcoin Knots
network=bitcoin
log-level=info

bitcoin-rpcuser=$BTC_RPC_USER
bitcoin-rpcpassword=$BTC_RPC_PASS
bitcoin-rpcconnect=127.0.0.1
bitcoin-rpcport=8332

# CLNRest plugin — used by LNBits
clnrest-port=3010
clnrest-host=0.0.0.0
CLNEOF

    machinectl start cln
    echo "Core Lightning started."

    # Wait for CLN to be ready (up to 90s)
    CLN_WAIT=0
    while ! systemd-nspawn --pipe -q -M cln /usr/local/bin/lightning-cli getinfo >/dev/null 2>&1; do
        sleep 3
        CLN_WAIT=$((CLN_WAIT + 3))
        if [ $CLN_WAIT -ge 90 ]; then
            echo "WARNING: CLN not ready after 90s. LNBits config will use placeholder runes."
            break
        fi
    done

    # Generate CLN runes for LNBits
    CLN_READONLY_RUNE=""
    CLN_INVOICE_RUNE=""
    CLN_PAY_RUNE=""
    if systemd-nspawn --pipe -q -M cln /usr/local/bin/lightning-cli getinfo >/dev/null 2>&1; then
        CLN_READONLY_RUNE=$(systemd-nspawn --pipe -q -M cln /usr/local/bin/lightning-cli createrune restrictions='[["method=listfunds","method=listpays","method=listinvoices","method=getinfo","method=summary","method=waitanyinvoice"]]' 2>/dev/null | grep -o '"rune": "[^"]*"' | cut -d'"' -f4)
        CLN_INVOICE_RUNE=$(systemd-nspawn --pipe -q -M cln /usr/local/bin/lightning-cli createrune restrictions='[["method=invoice"],["pnamelabel^LNbits"],["rate=60"]]' 2>/dev/null | grep -o '"rune": "[^"]*"' | cut -d'"' -f4)
        CLN_PAY_RUNE=$(systemd-nspawn --pipe -q -M cln /usr/local/bin/lightning-cli createrune restrictions='[["method=pay"],["pnamelabel^LNbits"],["rate=10"]]' 2>/dev/null | grep -o '"rune": "[^"]*"' | cut -d'"' -f4)
        echo "CLN runes generated for LNBits."
    else
        echo "WARNING: Could not generate CLN runes. Set them manually in /srv/lnbits/.env"
    fi

    # ── LNBits ──
    mkdir -p /srv/lnbits
    cat << LNEOF > /srv/lnbits/.env
LNBITS_BACKEND_WALLET_CLASS=CLNRestWallet
CLNREST_URL=https://127.0.0.1:3010
CLNREST_READONLY_RUNE=$CLN_READONLY_RUNE
CLNREST_INVOICE_RUNE=$CLN_INVOICE_RUNE
CLNREST_PAY_RUNE=$CLN_PAY_RUNE
LNEOF

    machinectl start lnbits
    echo "LNBits started with CLNRest funding source."

    # Update relaycreator .env to enable payments
    # Note: LNBITS_ADMIN_KEY and LNBITS_INVOICE_READ_KEY must be set manually
    # after creating a wallet in the LNBits admin UI.
    sed -i 's/^PAYMENTS_ENABLED=false/PAYMENTS_ENABLED=true/' /srv/relaycreator/.env
    echo "" >> /srv/relaycreator/.env
    echo "# LNBits endpoint (auto-configured)" >> /srv/relaycreator/.env
    echo "LNBITS_ENDPOINT=http://127.0.0.1:5000" >> /srv/relaycreator/.env

    echo ""
    echo "=== Payment stack deployed ==="
    echo "Bitcoin Knots: syncing (pruned mode, ~10GB)"
    echo "Core Lightning: connected to Knots"
    echo "LNBits: http://127.0.0.1:5000"
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Wait for Bitcoin Knots to finish IBD (check: machinectl shell bitcoinknots /usr/local/bin/bitcoin-cli -rpcuser=$BTC_RPC_USER -rpcpassword=$BTC_RPC_PASS getblockchaininfo)"
    echo "  2. Open a Lightning channel (machinectl shell cln /usr/local/bin/lightning-cli fundchannel <node_id> <amount>)"
    echo "  3. Create a wallet in LNBits UI and copy the Admin Key + Invoice Read Key"
    echo "  4. Set LNBITS_ADMIN_KEY and LNBITS_INVOICE_READ_KEY in /srv/relaycreator/.env"
    echo "  5. Restart relaycreator: machinectl shell relaycreator systemctl restart app"
fi

echo "All done!"
