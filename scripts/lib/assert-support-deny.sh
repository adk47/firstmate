#!/usr/bin/env bash
# assert-support-deny.sh <openclaw-edge.json>: the edge `support` agent (Caroline) must deny exec + the
# 14 verification/merge tools (captain 2026-10-28 12:1xZ / 12:3xZ). Every deploy that targets edge
# syncs this file over /root/.openclaw-edge/openclaw.json, so a missing entry re-opens that tool to a
# customer-facing agent. Called by deploy.sh Step 1 for EVERY deploy that targets edge (including
# `--target edge`), by validate-shared-config.sh, and mirrored by
# plugins/support-tools/tests/edge-support-deny.test.ts.
# Exit 0 = complete; 1 = missing entries (named on stdout); 2 = cannot read the file.
set -euo pipefail
cfg="${1:?usage: assert-support-deny.sh <openclaw-edge.json>}"
python3 - "$cfg" <<'PY'
import json, sys
NEED = ["exec", "credits_verify", "credit_verification_check", "profiles_claim_self", "profiles_consolidate",
        "profile_claim_status", "profile_credits_status", "dedupe_check", "remove_credits",
        "credit_status_lookup", "document_intake", "merge_request_intake", "credit_trust_handoff",
        "merge_intake", "proof_on_file"]
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError) as exc:
    print(f"cannot read {sys.argv[1]}: {exc}")
    sys.exit(2)
sup = [a for a in (cfg.get("agents") or {}).get("list", []) if a.get("id") == "support"]
if not sup:
    print("openclaw-edge.json has no `support` agent")
    sys.exit(1)
deny = set(((sup[0].get("tools") or {}).get("deny") or []))
missing = [t for t in NEED if t not in deny]
if missing:
    print(f"support tools.deny is missing {missing}")
    sys.exit(1)
print(f"support denies exec + {len(NEED) - 1} verification/merge tools")
PY
