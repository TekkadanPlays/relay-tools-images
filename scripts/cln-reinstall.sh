#!/bin/bash
# CLN clean reinstall — nukes the container and rebuilds from scratch
# Run on the HOST as root
# Usage: bash scripts/cln-reinstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== CLN Clean Reinstall ==="
echo "This will destroy the cln container and rebuild it."
echo "The data at /srv/cln will be PRESERVED (hsm_secret, config, etc)."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "--- Stopping CLN container ---"
machinectl stop cln 2>/dev/null || true
sleep 2
systemctl stop systemd-nspawn@cln 2>/dev/null || true

echo ""
echo "--- Removing old container (preserving /srv/cln data) ---"
rm -rf /var/lib/machines/cln

echo ""
echo "--- Reinstalling CLN container ---"
bash "$REPO_DIR/machines/cln/install"

echo ""
echo "--- Generating fresh hsm_secret (32 bytes) ---"
rm -f /srv/cln/bitcoin/hsm_secret
dd if=/dev/urandom of=/srv/cln/bitcoin/hsm_secret bs=32 count=1 2>/dev/null
chmod 400 /srv/cln/bitcoin/hsm_secret

echo ""
echo "--- Writing CLN config ---"
# Get Bitcoin RPC creds from bitcoinknots
BK_PID=$(machinectl show bitcoinknots -p Leader --value 2>/dev/null) || true
if [ -n "$BK_PID" ]; then
    RPC_USER=$(nsenter -t "$BK_PID" -m -u -i -n -p -- grep 'rpcuser=' /home/bitcoin/.bitcoin/bitcoin.conf | cut -d= -f2)
    RPC_PASS=$(nsenter -t "$BK_PID" -m -u -i -n -p -- grep 'rpcpassword=' /home/bitcoin/.bitcoin/bitcoin.conf | cut -d= -f2)
else
    echo "WARNING: bitcoinknots not running, using placeholder creds"
    RPC_USER="relaytools"
    RPC_PASS="PLACEHOLDER"
fi

cat > /srv/cln/config << CONF
network=bitcoin
log-level=info

bitcoin-rpcuser=$RPC_USER
bitcoin-rpcpassword=$RPC_PASS
bitcoin-rpcconnect=127.0.0.1
bitcoin-rpcport=8332

# Disable plugins that need extra deps (flask, etc)
disable-plugin=clnrest
disable-plugin=wss-proxy
CONF

echo ""
echo "--- Starting CLN container ---"
machinectl start cln
sleep 3

echo ""
echo "--- Installing Python deps for clnrest (optional) ---"
PID=$(machinectl show cln -p Leader --value)
nsenter -t "$PID" -m -u -i -n -p -- bash -c 'pip3 install flask flask-cors gunicorn 2>/dev/null || apt -y install python3-flask 2>/dev/null' || echo "WARNING: Could not install flask"

echo ""
echo "--- Starting CLN app service ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl daemon-reload
nsenter -t "$PID" -m -u -i -n -p -- systemctl restart app
sleep 15

echo ""
echo "--- CLN Status ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl status app --no-pager || true

echo ""
echo "--- Last 20 lines of log ---"
tail -20 /srv/cln/bitcoin/cln.log 2>/dev/null || echo "No log"

echo ""
echo "=== Done ==="
