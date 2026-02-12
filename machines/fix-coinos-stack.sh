#!/bin/bash
# One-shot fix script for KeyDB + CoinOS stack
# Run on server: bash /root/relay-tools-images/machines/fix-coinos-stack.sh

set -e

echo "=== Step 1: Fix KeyDB ==="
sed -i 's/\r$//' /srv/keydb/keydb.conf
machinectl terminate keydb 2>/dev/null || true
sleep 2
machinectl start keydb
sleep 3

if ss -tlnp | grep -q 6379; then
    echo "KeyDB is listening on port 6379"
else
    echo "ERROR: KeyDB not listening on 6379. Check: machinectl shell keydb /bin/bash -c 'journalctl -u app -n 20'"
    exit 1
fi

echo "=== Step 2: Fix CoinOS paths ==="
# Create symlink for hardcoded /home/bun/app path in coinos source
PID=$(machinectl show coinos -p Leader --value)
nsenter -t $PID -m -u -i -n -p -- bash -c 'mkdir -p /home/bun && ln -sf /app /home/bun/app && mkdir -p /app/data/uploads'

echo "=== Step 3: Generate nsec keys ==="
NSEC1=$(nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/bun -e "
import { generateSecretKey } from 'nostr-tools';
import { nip19 } from 'nostr-tools';
const sk = generateSecretKey();
console.log(nip19.nsecEncode(sk));
" 2>/dev/null)

NSEC2=$(nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/bun -e "
import { generateSecretKey } from 'nostr-tools';
import { nip19 } from 'nostr-tools';
const sk = generateSecretKey();
console.log(nip19.nsecEncode(sk));
" 2>/dev/null)

if [ -z "$NSEC1" ] || [ -z "$NSEC2" ]; then
    echo "ERROR: Failed to generate nsec keys"
    exit 1
fi
echo "nsec keys generated"

echo "=== Step 4: Rewrite CoinOS config ==="
BTC_RPC_PASS=$(grep rpcpassword /srv/bitcoinknots/bitcoin.conf | cut -d= -f2)
JWT=$(openssl rand -hex 32)
ADMINPASS=$(openssl rand -hex 16)

cat > /srv/coinos/config.ts << EOF
export default {
  db: "redis://127.0.0.1:6379",
  archive: "redis://127.0.0.1:6379",
  nostr: "ws://127.0.0.1:7777",
  relays: [
    "ws://127.0.0.1:7777",
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nos.lol"
  ],
  jwt: "$JWT",
  bitcoin: {
    host: "127.0.0.1",
    wallet: "coinos",
    user: "relaytools",
    password: "$BTC_RPC_PASS",
    network: "bitcoin",
    port: 8332,
  },
  lightning: "/home/bun/app/data/lightning/bitcoin/lightning-rpc",
  fee: 0.001,
  adminpass: "$ADMINPASS",
  support: "admin@mycelium.social",
  nostrKey: "$NSEC1",
  nostrKey2: "$NSEC2",
};
EOF

echo "=== Step 5: Restart CoinOS ==="
machinectl terminate coinos 2>/dev/null || true
sleep 2
machinectl start coinos
sleep 5

echo "=== Step 6: Verify ==="
if ss -tlnp | grep -q 6379; then
    echo "KeyDB: OK (port 6379)"
else
    echo "KeyDB: FAILED"
fi

if ss -tlnp | grep -q 3119; then
    echo "CoinOS: OK (port 3119)"
else
    echo "CoinOS: FAILED — checking logs..."
    PID2=$(machinectl show coinos -p Leader --value)
    nsenter -t $PID2 -m -u -i -n -p -- bash -c 'cd /app && /usr/local/bin/bun run /app/index.ts 2>&1 | head -20'
fi

echo ""
machinectl list
echo ""
echo "=== Done ==="
