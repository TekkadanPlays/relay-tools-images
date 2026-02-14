#!/bin/bash
# CLN diagnostic script — run on the HOST as root
set -euo pipefail

echo "=== CLN Diagnostic ==="

PID=$(machinectl show cln -p Leader --value 2>/dev/null) || true
if [ -z "$PID" ]; then
    echo "ERROR: cln container not running. Run: machinectl start cln"
    exit 1
fi

echo ""
echo "--- Container glibc ---"
nsenter -t "$PID" -m -u -i -n -p -- ldd --version 2>&1 | head -1

echo ""
echo "--- lightningd version ---"
nsenter -t "$PID" -m -u -i -n -p -- /usr/local/bin/lightningd --version 2>&1

echo ""
echo "--- lightning_hsmd version ---"
nsenter -t "$PID" -m -u -i -n -p -- /usr/local/libexec/c-lightning/lightning_hsmd --version 2>&1

echo ""
echo "--- Binary search (duplicates?) ---"
nsenter -t "$PID" -m -u -i -n -p -- bash -c 'find / -name lightningd -o -name lightning_hsmd 2>/dev/null'

echo ""
echo "--- lightningd library deps ---"
nsenter -t "$PID" -m -u -i -n -p -- ldd /usr/local/bin/lightningd 2>&1

echo ""
echo "--- lightning_hsmd library deps ---"
HSMD=$(nsenter -t "$PID" -m -u -i -n -p -- find /usr/local -name lightning_hsmd 2>/dev/null | head -1)
if [ -n "$HSMD" ]; then
    nsenter -t "$PID" -m -u -i -n -p -- ldd "$HSMD" 2>&1
fi

echo ""
echo "--- CLN data directory ---"
ls -la /srv/cln/bitcoin/

echo ""
echo "--- hsm_secret ---"
ls -la /srv/cln/bitcoin/hsm_secret 2>/dev/null || echo "NOT FOUND"
wc -c /srv/cln/bitcoin/hsm_secret 2>/dev/null || true

echo ""
echo "--- CLN config ---"
cat /srv/cln/config

echo ""
echo "--- Bitcoin RPC creds (from bitcoinknots) ---"
BK_PID=$(machinectl show bitcoinknots -p Leader --value 2>/dev/null) || true
if [ -n "$BK_PID" ]; then
    nsenter -t "$BK_PID" -m -u -i -n -p -- grep -E 'rpcuser|rpcpassword' /home/bitcoin/.bitcoin/bitcoin.conf 2>/dev/null || echo "Could not read bitcoin.conf"
else
    echo "bitcoinknots container not running"
fi

echo ""
echo "--- Python / Flask (for clnrest) ---"
nsenter -t "$PID" -m -u -i -n -p -- python3 --version 2>&1 || echo "python3 not found"
nsenter -t "$PID" -m -u -i -n -p -- python3 -c "import flask; print('flask OK')" 2>&1 || echo "flask MISSING"

echo ""
echo "--- App service status ---"
nsenter -t "$PID" -m -u -i -n -p -- systemctl status app --no-pager 2>&1 || true

echo ""
echo "--- Last 40 lines of CLN log ---"
tail -40 /srv/cln/bitcoin/cln.log 2>/dev/null || echo "No log file"

echo ""
echo "=== Diagnosis complete ==="
