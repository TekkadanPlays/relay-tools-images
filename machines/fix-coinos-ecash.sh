#!/bin/bash
# Add mintUrl to config if not already present
grep -q mintUrl /srv/coinos/config.ts || sed -i 's|};|  mintUrl: "http://localhost:3338",\n};|' /srv/coinos/config.ts

# Stub lib/ecash.ts with all named exports the codebase uses
cat > /var/lib/machines/coinos/app/lib/ecash.ts << 'LIBEOF'
// ecash/cashu disabled — no shitcoins
const fail = (msg: string) => { throw new Error(msg); };
export async function get(_id: string) { fail("ecash disabled"); }
export async function claim(_token: string) { fail("ecash disabled"); return 0; }
export async function mint(_amount: number) { fail("ecash disabled"); return ""; }
export async function check(_token: string) { fail("ecash disabled"); return {}; }
export function request(_uuid: string, _amount: number, _memo: string) { return ""; }
export async function init(_amount?: number) {}
export default { get, claim, mint, check, request, init };
LIBEOF

# Stub routes/ecash.ts
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

machinectl terminate coinos 2>/dev/null || true
sleep 2
machinectl start coinos
sleep 5
ss -tlnp | grep 3119 && echo "CoinOS: OK" || echo "CoinOS: FAILED"
