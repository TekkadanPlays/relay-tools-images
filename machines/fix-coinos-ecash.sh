#!/bin/bash
# NO set -e — we want every step to run regardless

echo "=== Step 0: Stop coinos ==="
machinectl terminate coinos 2>/dev/null || true
sleep 2

echo "=== Step 1: Write stubs (ecash, square, mqtt) ==="
APP=/var/lib/machines/coinos/app

cat > "$APP/lib/ecash.ts" << 'EOF'
// ecash/cashu disabled
const fail = (msg: string) => { throw new Error(msg); };
export async function get(_id: string) { fail("ecash disabled"); }
export async function claim(_token: string) { fail("ecash disabled"); return 0; }
export async function mint(_amount: number) { fail("ecash disabled"); return ""; }
export async function check(_token: string) { fail("ecash disabled"); return {}; }
export function request(_uuid: string, _amount: number, _memo: string) { return ""; }
export async function init(_amount?: number) {}
export default { get, claim, mint, check, request, init };
EOF
echo "  lib/ecash.ts: $(wc -c < "$APP/lib/ecash.ts") bytes"

cat > "$APP/routes/ecash.ts" << 'EOF'
// ecash routes disabled
const disabled = (_req: any, res: any) => res.code(404).send({ error: "ecash disabled" });
export default { get: disabled, save: disabled, claim: disabled, mint: disabled, melt: disabled, receive: disabled };
EOF
echo "  routes/ecash.ts: $(wc -c < "$APP/routes/ecash.ts") bytes"

cat > "$APP/lib/square.ts" << 'EOF'
// square disabled
export const squarePayment = async (_p: any, _user: any) => {};
EOF
echo "  lib/square.ts: $(wc -c < "$APP/lib/square.ts") bytes"

cat > "$APP/routes/square.ts" << 'EOF'
// square routes disabled
const disabled = (_req: any, res: any) => res.code(404).send({ error: "square disabled" });
export default { connect: disabled, auth: disabled, payment: disabled };
EOF
echo "  routes/square.ts: $(wc -c < "$APP/routes/square.ts") bytes"

cat > "$APP/lib/mqtt.ts" << 'EOF'
// mqtt disabled
export default { connected: false, reconnect: () => {}, publish: () => {}, subscribe: () => {}, on: () => {} };
EOF
echo "  lib/mqtt.ts: $(wc -c < "$APP/lib/mqtt.ts") bytes"

echo "=== Step 2: Ensure paths ==="
mkdir -p /var/lib/machines/coinos/home/bun
ln -sf /app /var/lib/machines/coinos/home/bun/app 2>/dev/null || true
mkdir -p /srv/coinos/uploads
mkdir -p "$APP/data/sockets"

echo "=== Step 3: Generate nsec keys ==="
# Start container briefly to use bun inside it
machinectl start coinos
sleep 3
PID=$(machinectl show coinos -p Leader --value)
NSEC1=$(nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/bun -e "
import { generateSecretKey } from 'nostr-tools';
import { nip19 } from 'nostr-tools';
console.log(nip19.nsecEncode(generateSecretKey()));
" 2>/dev/null || echo "")
NSEC2=$(nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/bun -e "
import { generateSecretKey } from 'nostr-tools';
import { nip19 } from 'nostr-tools';
console.log(nip19.nsecEncode(generateSecretKey()));
" 2>/dev/null || echo "")
machinectl terminate coinos 2>/dev/null || true
sleep 2

# Fallback to dummy nsec if generation failed
if [ -z "$NSEC1" ]; then NSEC1="nsec1dummy00000000000000000000000000000000000000000000000000000"; fi
if [ -z "$NSEC2" ]; then NSEC2="nsec1dummy00000000000000000000000000000000000000000000000000001"; fi
echo "  NSEC1=${NSEC1:0:15}... NSEC2=${NSEC2:0:15}..."

echo "=== Step 4: Write config.ts ==="
BTC_RPC_PASS=$(grep rpcpassword /srv/bitcoinknots/bitcoin.conf | cut -d= -f2)
JWT=$(openssl rand -hex 32)
ADMINPASS=$(openssl rand -hex 16)

cat > /srv/coinos/config.ts << CFGEOF
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
  jwt: "${JWT}",
  bitcoin: {
    host: "127.0.0.1",
    wallet: "coinos",
    user: "relaytools",
    password: "${BTC_RPC_PASS}",
    network: "bitcoin",
    port: 8332,
  },
  liquid: {
    host: "127.0.0.1",
    wallet: "coinos",
    user: "relaytools",
    password: "${BTC_RPC_PASS}",
    network: "bitcoin",
    port: 7041,
  },
  lightning: "/home/bun/app/data/lightning/bitcoin/lightning-rpc",
  lightningb: "/home/bun/app/data/lightning/bitcoin/lightning-rpc",
  fee: 0.001,
  adminpass: "${ADMINPASS}",
  support: "admin@mycelium.social",
  nostrKey: "${NSEC1}",
  nostrKey2: "${NSEC2}",
  mintUrl: "http://localhost:3338",
  square: {
    environment: "sandbox",
    appId: "disabled",
    url: "https://connect.squareupsandbox.com/",
    scopes: [],
  },
};
CFGEOF
echo "  config.ts: $(wc -c < /srv/coinos/config.ts) bytes"

echo "=== Step 5: Verify stubs before starting ==="
head -1 "$APP/lib/square.ts"
head -1 "$APP/lib/ecash.ts"
head -1 "$APP/lib/mqtt.ts"

echo "=== Step 6: Start coinos ==="
machinectl start coinos
sleep 5

if ss -tlnp | grep -q 3119; then
    echo "=== CoinOS: OK (port 3119) ==="
else
    echo "=== CoinOS: FAILED ==="
    PID2=$(machinectl show coinos -p Leader --value)
    nsenter -t $PID2 -m -u -i -n -p -- bash -c 'cd /app && /usr/local/bin/bun run /app/index.ts 2>&1 | head -30'
fi
