#!/bin/bash
set -e

# ── Step 1: Rewrite config.ts from scratch ──
BTC_RPC_PASS=$(grep rpcpassword /srv/bitcoinknots/bitcoin.conf | cut -d= -f2)
JWT=$(openssl rand -hex 32)
ADMINPASS=$(openssl rand -hex 16)

# Generate nsec keys using bun+nostr-tools inside the container
PID=$(machinectl show coinos -p Leader --value)
NSEC1=$(nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/bun -e "
import { generateSecretKey } from 'nostr-tools';
import { nip19 } from 'nostr-tools';
console.log(nip19.nsecEncode(generateSecretKey()));
" 2>/dev/null)

NSEC2=$(nsenter -t $PID -m -u -i -n -p -- /usr/local/bin/bun -e "
import { generateSecretKey } from 'nostr-tools';
import { nip19 } from 'nostr-tools';
console.log(nip19.nsecEncode(generateSecretKey()));
" 2>/dev/null)

echo "Generated nsec keys: NSEC1=${NSEC1:0:10}... NSEC2=${NSEC2:0:10}..."

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
};
CFGEOF

echo "Config written. Verifying..."
head -3 /srv/coinos/config.ts
echo "..."
tail -3 /srv/coinos/config.ts

# ── Step 2: Stub ecash files ──
cat > /var/lib/machines/coinos/app/lib/ecash.ts << 'LIBEOF'
// ecash/cashu disabled
const fail = (msg: string) => { throw new Error(msg); };
export async function get(_id: string) { fail("ecash disabled"); }
export async function claim(_token: string) { fail("ecash disabled"); return 0; }
export async function mint(_amount: number) { fail("ecash disabled"); return ""; }
export async function check(_token: string) { fail("ecash disabled"); return {}; }
export function request(_uuid: string, _amount: number, _memo: string) { return ""; }
export async function init(_amount?: number) {}
export default { get, claim, mint, check, request, init };
LIBEOF

cat > /var/lib/machines/coinos/app/routes/ecash.ts << 'RTEOF'
// ecash routes disabled
const disabled = (_req: any, res: any) => res.code(404).send({ error: "ecash disabled" });
export default {
  get: disabled,
  save: disabled,
  claim: disabled,
  mint: disabled,
  melt: disabled,
  receive: disabled,
};
RTEOF

# ── Step 3: Ensure paths exist ──
nsenter -t $PID -m -u -i -n -p -- bash -c 'mkdir -p /home/bun && ln -sf /app /home/bun/app && mkdir -p /app/data/uploads' 2>/dev/null || true

# ── Step 4: Restart ──
machinectl terminate coinos 2>/dev/null || true
sleep 2
machinectl start coinos
sleep 5

if ss -tlnp | grep -q 3119; then
    echo "=== CoinOS: OK (port 3119) ==="
else
    echo "=== CoinOS: FAILED ==="
    PID2=$(machinectl show coinos -p Leader --value)
    nsenter -t $PID2 -m -u -i -n -p -- bash -c 'cd /app && /usr/local/bin/bun run /app/index.ts 2>&1 | head -20'
fi
