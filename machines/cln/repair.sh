#!/bin/bash
# CLN repair script — diagnose and fix the HSM/binary mismatch crash
# Run on the HOST as root

set -e

echo "=== CLN Repair Script ==="

# Get container PID
PID=$(machinectl show cln -p Leader --value 2>/dev/null)
if [ -z "$PID" ]; then
    echo "ERROR: cln container not running. Start it: machinectl start cln"
    exit 1
fi

echo ""
echo "--- Step 1: Stop CLN app service ---"
nsenter -t $PID -m -u -i -n -p -- systemctl stop app 2>/dev/null || true

echo ""
echo "--- Step 2: Check glibc version in container ---"
nsenter -t $PID -m -u -i -n -p -- ldd --version 2>&1 | head -1

echo ""
echo "--- Step 3: Check lightningd binary dependencies ---"
nsenter -t $PID -m -u -i -n -p -- ldd /usr/local/bin/lightningd 2>&1

echo ""
echo "--- Step 4: Check lightning_hsmd binary exists and dependencies ---"
HSMD_PATH=$(nsenter -t $PID -m -u -i -n -p -- find /usr/local -name "lightning_hsmd" -o -name "lightning_hsmd.so" 2>/dev/null | head -1)
if [ -z "$HSMD_PATH" ]; then
    echo "WARNING: lightning_hsmd not found! Checking libexec..."
    nsenter -t $PID -m -u -i -n -p -- ls -la /usr/local/libexec/c-lightning/ 2>/dev/null || \
    nsenter -t $PID -m -u -i -n -p -- ls -la /usr/local/libexec/core-lightning/ 2>/dev/null || \
    echo "No libexec directory found for CLN"
else
    echo "Found hsmd at: $HSMD_PATH"
    nsenter -t $PID -m -u -i -n -p -- ldd "$HSMD_PATH" 2>&1
fi

echo ""
echo "--- Step 5: List all CLN binaries ---"
nsenter -t $PID -m -u -i -n -p -- ls -la /usr/local/bin/lightning* 2>/dev/null
nsenter -t $PID -m -u -i -n -p -- ls -la /usr/local/libexec/c-lightning/ 2>/dev/null || true
nsenter -t $PID -m -u -i -n -p -- ls -la /usr/local/libexec/core-lightning/ 2>/dev/null || true

echo ""
echo "--- Step 6: Try running hsmd directly to see error ---"
if [ -n "$HSMD_PATH" ]; then
    nsenter -t $PID -m -u -i -n -p -- "$HSMD_PATH" --version 2>&1 || true
fi

echo ""
echo "--- Step 7: Check lightningd version ---"
nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/lightningd --version 2>&1

echo ""
echo "--- Step 8: Try running lightningd in foreground briefly ---"
echo "(Will timeout after 5 seconds)"
timeout 5 nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/lightningd \
    --conf=/home/lightning/.lightning/config \
    --lightning-dir=/home/lightning/.lightning \
    --log-file=/dev/stderr \
    --log-level=debug 2>&1 | tail -30 || true

echo ""
echo "--- Step 9: HSM secret status ---"
ls -la /srv/cln/bitcoin/hsm_secret
xxd /srv/cln/bitcoin/hsm_secret

echo ""
echo "=== Diagnosis complete ==="
echo "If you see 'not found' errors in ldd output, install the missing libraries."
echo "If hsmd binary is missing, re-extract CLN tarball."
echo "If all binaries look fine, the issue may be a version mismatch in the tarball."
