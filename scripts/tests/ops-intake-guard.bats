#!/usr/bin/env bats
# The Ops summarize/resolve surface's cross-language contracts (jan-summarize-resolve-s1):
#
#   1. the Python side runs the plugin's REAL output guard, not a copy of it. A blocking rule added
#      to plugins/intercom/src/caroline-output-guard.ts must reach an Ops customer reply the moment
#      it merges — if the bridge stopped resolving `.js` -> `.ts`, or someone ported the guard into
#      Python, this is what goes red;
#   2. every answer-bank line named by policies/ops-resolutions.json EXISTS in the real bank. A
#      typo'd line id would otherwise fail at send time, on a customer, at 3am;
#   3. the Python bridge REFUSES a promise line and PASSES an approved bank line, so the guard is
#      exercised end to end rather than inferred from source text.
#
# Hermetic: no network, no token, no store. Node is required (the whole point), and a missing node
# is a FAIL here, never a skip.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
BRIDGE="$HYDRA_REPO/scripts/ops_intake/guard_bridge.mjs"
HOOKS="$HYDRA_REPO/scripts/ops_intake/ts_resolve_hooks.mjs"
POLICY="$HYDRA_REPO/policies/ops-resolutions.json"

setup() {
  T="$BATS_TEST_TMPDIR"
  export OPS_INTAKE_LEDGER="$T/resolutions.sqlite"
}

@test "the guard bridge loads the plugin's own guard (not a copy)" {
  command -v node >/dev/null || { echo "node is required"; false; }
  run node --experimental-strip-types --no-warnings --import "$HOOKS" "$BRIDGE" --bank
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok":true'
  # BANK_VERSION is exported by answer-bank.ts; a copy would not have it.
  echo "$output" | grep -q '"bankVersion"'
}

@test "the real guard BLOCKS a promise of an outcome on an Ops reply" {
  run bash -c "echo '{\"reply\":\"I have approved your credits.\"}' | node --experimental-strip-types --no-warnings --import '$HOOKS' '$BRIDGE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict":"block"'
  echo "$output" | grep -q '"family":"promise"'
  # The enforced fallback is the bank's own blocked-reply line, read from the real bank rather
  # than spelled here. Since 2026-11-11 a blocked reply assigns nobody, so that line must not say
  # a person is coming (it was the hand-off line while a block also reassigned the thread). The
  # Ops path never sends this body: a block proposes nothing (answer._reply_request).
  blocked="$output"
  run node --experimental-strip-types --no-warnings --import "$HOOKS" "$BRIDGE" --bank
  [ "$status" -eq 0 ]
  run python3 -c '
import json, sys
blocked = json.loads(sys.argv[1].strip().splitlines()[-1])
bank = json.loads(sys.argv[2].strip().splitlines()[-1])
lines = {e["id"]: e["text"] for e in bank["entries"]}
body = blocked["body"]
assert body == lines["ai_queue_fallback"], body
assert body != lines["handoff_line"], body
assert "teammate" not in body.lower(), body
print("fallback-is-the-bank-line")
' "$blocked" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback-is-the-bank-line" ]
}

@test "the real guard PASSES an approved bank line verbatim" {
  run bash -c "cd '$HYDRA_REPO' && python3 scripts/ops_intake/output_guard.py --bank"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^status_chase requiresFact=open_request$'
}

@test "the output guard version reaches the caller (so the ledger can record it)" {
  run bash -c "echo '{\"reply\":\"Thanks for the documents.\"}' | node --experimental-strip-types --no-warnings --import '$HOOKS' '$BRIDGE'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"guardVersion":"g'
}

@test "a fact-conditioned line is refused unless the fact is MEASURED true" {
  run bash -c "cd '$HYDRA_REPO' && python3 - <<'PY'
import sys
sys.path.insert(0, 'scripts')
from ops_intake import output_guard
lines = output_guard.bank()
for state in (None, False):
    try:
        output_guard.line('status_chase', open_request=state, bank_lines=lines)
    except output_guard.LineRefused:
        print('refused')
    else:
        print('SENT-ANYWAY')
print('ok' if output_guard.line('status_chase', open_request=True, bank_lines=lines) == lines['status_chase'].text else 'MISMATCH')
PY"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c refused)" -eq 2 ]
  echo "$output" | grep -q '^ok$'
}

@test "every answer-bank line named by the shipped policy exists in the real bank" {
  command -v node >/dev/null || { echo "node is required"; false; }
  run bash -c "cd '$HYDRA_REPO' && python3 - <<'PY'
import sys
sys.path.insert(0, 'scripts')
from ops_intake import output_guard, resolutions
bank = output_guard.bank()
# The real bank is the authority: Policy.load raises on an unknown line id, and only when it is
# HANDED the ids. Handing it the real ones is the whole check.
policy = resolutions.Policy.load(bank_ids=list(bank))
refs = sorted({(r.get('line') or policy.actions[r['action']].line or '') for r in policy.rules} - {''})
missing = [r for r in refs if r not in bank]
print('MISSING', missing if missing else 'none')
print('LINES', len(refs))
sys.exit(1 if missing else 0)
PY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'MISSING none'
}

@test "a guard that cannot be loaded exits non-zero so the caller fails closed" {
  run bash -c "echo '{\"reply\":\"hi\"}' | OPS_INTAKE_NODE=/bin/false python3 '$HYDRA_REPO/scripts/ops_intake/output_guard.py' --check hi"
  [ "$status" -ne 0 ]
}

@test "the summarize CLI refuses a broken policy instead of guessing" {
  cat >"$T/policy.json" <<'J'
{ "version": "test", "intent_labels": ["other"], "actions": { "unknown": {"tier": "handoff"} },
  "default_action": "unknown",
  "rules": [ { "key": "bad", "intents": ["nope"], "when": {}, "action": "unknown" } ] }
J
  run bash -c "cd '$HYDRA_REPO' && python3 scripts/ops_intake/summarize.py conv-1 --policy '$T/policy.json' --no-model"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'POLICY ERROR'
}

@test "the Python guard bridge REFUSES a promise line" {
  # The answerer's customer copy goes through the plugin's real guard via output_guard.py. A
  # promise of an outcome must be blocked here, not merely absent from a source file.
  run bash -c "cd '$HYDRA_REPO' && python3 scripts/ops_intake/output_guard.py --check 'I have approved your credits.'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict": "block"'
  echo "$output" | grep -q '"family": "promise"'
}

@test "the Python guard bridge PASSES an approved bank line" {
  run bash -c "cd '$HYDRA_REPO' && python3 scripts/ops_intake/output_guard.py --check \"I'm pulling in a teammate to take this from here.\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"verdict": "pass"'
  echo "$output" | grep -q '"bank_version"'
}

@test "the Ops reply path refuses a body that leaks internal surfaces" {
  # Validation runs before the POST, so a fake token + --dry-run exercises the real refusal.
  run env MUSOAI_INTERCOM_TOKEN=fake-not-a-token \
    bash "$HYDRA_REPO/scripts/intercom-ops-write.sh" reply --conversation 215476670359602 \
    --requested-by U038BM16T7W --customer-facing --approved-by U038BM16T7W --dry-run \
    --body "We filed this as ticket 12345, see github.com/Muso-AI/hydra for progress."
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'REFUSED'
  echo "$output" | grep -qi 'customer'
}
