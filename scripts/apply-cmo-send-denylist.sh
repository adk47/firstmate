#!/bin/bash
# Remove gog gmail send capabilities from the CMO agent's tool
# allow-list, so the outreach sender worker is the only path that
# can send. Idempotent: safe to re-run.
#
# Usage: ssh root@node-8 'bash -s' < apply-cmo-send-denylist.sh

set -euo pipefail

CONFIG=/root/.openclaw-main/openclaw.json
BACKUP="/root/openclaw.json.bak.$(date -u +%Y%m%dT%H%M%SZ)"

cp "$CONFIG" "$BACKUP"
echo "Backup: $BACKUP"

python3 - <<'PY'
import json
path = "/root/.openclaw-main/openclaw.json"
with open(path) as f:
    c = json.load(f)

# Find the CMO agent config.
cmo = next(a for a in c["agents"]["list"] if a.get("id") == "cmo")

deny = cmo.setdefault("toolDenyList", [])
for pattern in (
    "bash:gog gmail drafts send",
    "bash:gog gmail messages send",
    "bash:source ~/.zshrc && gog gmail drafts send",
    "bash:source ~/.zshrc && gog gmail messages send",
):
    if pattern not in deny:
        deny.append(pattern)

with open(path, "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
print("CMO toolDenyList:", deny)
PY

systemctl restart openclaw-gateway-main
echo "openclaw-gateway-main restarted."
