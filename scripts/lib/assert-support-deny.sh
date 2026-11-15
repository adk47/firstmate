#!/usr/bin/env bash
# assert-support-deny.sh <openclaw-edge.json>: the edge `support` agent (Caroline) must deny exec + the
# 11 verification/merge tools: every write and intake tool, and the profile_credits_status
# diagnosis (captain 2026-10-28 12:1xZ / 12:3xZ). Every deploy that targets edge
# syncs this file over /root/.openclaw-edge/openclaw.json, so a missing entry re-opens that tool to a
# customer-facing agent. Called by deploy.sh Step 1 for EVERY deploy that targets edge (including
# `--target edge`), by validate-shared-config.sh, and mirrored by
# plugins/support-tools/tests/edge-support-deny.test.ts.
# Exit 0 = complete; 1 = missing entries (named on stdout); 2 = cannot read the file.
set -euo pipefail
cfg="${1:?usage: assert-support-deny.sh <openclaw-edge.json>}"
python3 - "$cfg" <<'PY'
import json, sys
NEED = ["exec", "credits_verify", "profiles_claim_self", "profiles_consolidate",
        "profile_credits_status", "dedupe_check", "remove_credits",
        "credit_status_lookup", "document_intake", "merge_request_intake", "credit_trust_handoff",
        "merge_intake"]
# `proof_on_file` is NOT in NEED since 2026-11-14: support-tools registers no tool under that name
# (it is a field of credit_verification_check's result), so denying the name changed nothing
# Caroline could do. Registering a tool under it later fails
# plugins/support-tools/tests/edge-support-deny.test.ts until its deny entry is reviewed.
# Not in NEED since ai-support-quality-v1 (2026-11-12): the two READS that fail closed on the
# conversation's signed-in contact and return that customer's OWN rows only
# (credit_verification_check, profile_claim_status). They write nothing and are the source of the
# open_request fact the output guard needs before the approved status line may be sent.
# profile_credits_status STAYS denied: it does not fail closed, it resolves any profile typed in
# the thread and it scans same-name duplicate candidates, which is the dedupe work the captain
# kept away from her on 2026-10-28. Every write, merge, dedupe, removal and proof-filing tool
# stays denied.
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
