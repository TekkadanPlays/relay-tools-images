#!/bin/bash
# Quick fix: install bitcoin-cli into the running CLN container
# This is the missing piece — CLN's bcli plugin needs bitcoin-cli to talk to bitcoind
# Run on the HOST as root
set -euo pipefail

echo "=== Install bitcoin-cli into CLN container ==="

PID=$(machinectl show cln -p Leader --value 2>/dev/null) || true
if [ -z "$PID" ]; then
    echo "ERROR: cln container not running. Run: machinectl start cln"
    exit 1
fi

echo ""
echo "--- Checking if bitcoin-cli already exists ---"
if nsenter -t "$PID" -m -u -i -n -p -- which bitcoin-cli &>/dev/null; then
    echo "bitcoin-cli already installed:"
    nsenter -t "$PID" -m -u -i -n -p -- bitcoin-cli --version
else
    echo "bitcoin-cli NOT found. Installing..."
    nsenter -t "$PID" -m -u -i -n -p -- bash -c '
        cd /tmp
        # Download Bitcoin Core (simpler, well-known tarball structure)
        curl -L -o bitcoin.tar.gz \
            "https://bitcoincore.org/bin/bitcoin-core-28.0/bitcoin-28.0-x86_64-linux-gnu.tar.gz"
        
        # Extract, find bitcoin-cli, copy to /usr/local/bin
        mkdir -p /tmp/btc-extract
        tar xf bitcoin.tar.gz -C /tmp/btc-extract
        find /tmp/btc-extract -name bitcoin-cli -exec cp {} /usr/local/bin/bitcoin-cli \;
        chmod +x /usr/local/bin/bitcoin-cli
        rm -rf /tmp/bitcoin.tar.gz /tmp/btc-extract
        
        echo "Installed:"
        /usr/local/bin/bitcoin-cli --version
    '
fi

echo ""
echo "--- Stopping CLN app service ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl stop app 2>/dev/null || true
sleep 2

echo ""
echo "--- Restarting CLN app service ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl daemon-reload
nsenter -t "$PID" -m -u -i -n -p -- systemctl restart app
sleep 15

echo ""
echo "--- CLN Status ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl status app --no-pager || true

echo ""
echo "--- Last 30 lines of log ---"
tail -30 /srv/cln/bitcoin/cln.log 2>/dev/null || echo "No log"

echo ""
echo "=== Done ==="
