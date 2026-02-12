#!/bin/bash
sed -i 's|};|  mintUrl: "http://localhost:3338",\n};|' /srv/coinos/config.ts
echo '// ecash disabled
export default {};' > /var/lib/machines/coinos/app/lib/ecash.ts
echo '// ecash routes disabled
export default {
  get: (_req, res) => res.code(404).send({ error: "ecash disabled" }),
  save: (_req, res) => res.code(404).send({ error: "ecash disabled" }),
  claim: (_req, res) => res.code(404).send({ error: "ecash disabled" }),
  mint: (_req, res) => res.code(404).send({ error: "ecash disabled" }),
  melt: (_req, res) => res.code(404).send({ error: "ecash disabled" }),
  receive: (_req, res) => res.code(404).send({ error: "ecash disabled" }),
};' > /var/lib/machines/coinos/app/routes/ecash.ts
machinectl terminate coinos
sleep 2
machinectl start coinos
sleep 5
ss -tlnp | grep 3119 && echo "CoinOS: OK" || echo "CoinOS: FAILED"
