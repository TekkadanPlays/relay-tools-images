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
    echo "bitcoin-cli NOT found. Installing via apt..."
    # Since VirtualEthernet=no, CLN shares host network.
    # Install bitcoin-cli from Debian repos or create a wrapper.
    # Method: compile a minimal bitcoin-cli wrapper that uses the host bitcoin-cli
    # OR install from apt if available.
    nsenter -t "$PID" -m -u -i -n -p -- bash -c '
        # Try apt first (Debian may have bitcoin in repos)
        apt-get update -qq
        apt-get install -y -qq bitcoin-bitcoind 2>/dev/null && echo "Installed from apt" && exit 0

        # If apt fails, download a static/compatible bitcoin-cli
        # Use Bitcoin Core 27.1 which has better compatibility
        cd /tmp
        curl -L -o bitcoin.tar.gz \
            "https://bitcoincore.org/bin/bitcoin-core-27.1/bitcoin-27.1-x86_64-linux-gnu.tar.gz"
        mkdir -p /tmp/btc-extract
        tar xf bitcoin.tar.gz -C /tmp/btc-extract
        find /tmp/btc-extract -name bitcoin-cli -exec cp {} /usr/local/bin/bitcoin-cli \;
        chmod +x /usr/local/bin/bitcoin-cli
        rm -rf /tmp/bitcoin.tar.gz /tmp/btc-extract

        # Test it
        /usr/local/bin/bitcoin-cli --version || {
            echo "Binary bitcoin-cli failed. Creating RPC wrapper instead..."
            # Last resort: create a shell wrapper that uses curl for JSON-RPC
            cat > /usr/local/bin/bitcoin-cli << "WRAPPER"
#!/bin/bash
# Minimal bitcoin-cli wrapper using curl for JSON-RPC
# Used by CLN bcli plugin
source /home/lightning/.lightning/config 2>/dev/null

RPCUSER="${bitcoin_rpcuser:-relaytools}"
RPCPASS="${bitcoin_rpcpassword:-}"
RPCHOST="${bitcoin_rpcconnect:-127.0.0.1}"
RPCPORT="${bitcoin_rpcport:-8332}"

# Parse args the way CLN calls bitcoin-cli
METHOD=""
PARAMS="[]"
CONF_ARGS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -conf=*|-datadir=*|-rpcconnect=*|-rpcport=*|-rpcuser=*|-rpcpassword=*)
            # Parse -rpcuser= etc
            KEY="${1%%=*}"
            VAL="${1#*=}"
            case "$KEY" in
                -rpcuser) RPCUSER="$VAL" ;;
                -rpcpassword) RPCPASS="$VAL" ;;
                -rpcconnect) RPCHOST="$VAL" ;;
                -rpcport) RPCPORT="$VAL" ;;
            esac
            shift ;;
        -*)
            shift ;;
        *)
            if [ -z "$METHOD" ]; then
                METHOD="$1"
            else
                PARAMS=$(echo "$PARAMS" | python3 -c "import sys,json; p=json.load(sys.stdin); p.append('$1'); print(json.dumps(p))" 2>/dev/null || echo "[]")
            fi
            shift ;;
    esac
done

curl -sf --user "$RPCUSER:$RPCPASS" \
    --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"cln\",\"method\":\"$METHOD\",\"params\":$PARAMS}" \
    -H "Content-Type: application/json" \
    "http://$RPCHOST:$RPCPORT/" 2>/dev/null | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    if r.get('error'):
        print(json.dumps(r['error']), file=sys.stderr)
        sys.exit(1)
    result = r.get('result')
    if isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)
except:
    sys.exit(1)
"
WRAPPER
            chmod +x /usr/local/bin/bitcoin-cli
            echo "Created curl-based bitcoin-cli wrapper"
        }
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
