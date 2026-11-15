#!/usr/bin/env bats
# The resolution lookup's safety contract (jan-summarize-resolve-s1).
#
# `policies/ops-resolutions.json` is the ONLY thing that decides what the Ops bot does with a
# summarize/resolve ask, and a wrong mapping is meant to be a one-line PR. That makes the table a
# security surface: a rule that selects a W2 action, or an action that executes a merge / erasure /
# refund, or a hand-off that reaches no human, is a silent regression that no Python test would
# catch because the Python tests load the table as data.
#
# These cases mutate a COPY of the real policy and assert the checker refuses it. They are the
# negative half of `scripts/check-ops-resolutions.sh`; the positive half is the checker running
# clean against the shipped table (case 1).
#
# Hermetic: no network, no store, no token. Only python3 and jq-free stdlib.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
CHECK="$HYDRA_REPO/scripts/check-ops-resolutions.sh"
POLICY="$HYDRA_REPO/policies/ops-resolutions.json"

setup() {
  T="$BATS_TEST_TMPDIR"
  cp "$POLICY" "$T/policy.json"
}

# mutate <python-expression operating on `d`> — rewrite the copy, then run the checker on it.
mutate() {
  python3 - "$T/policy.json" "$1" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path))
exec(expr, {"d": d, "json": json})
json.dump(d, open(path, "w"), indent=2)
PY
}

run_check() {
  run env OPS_RESOLUTIONS="$T/policy.json" bash "$CHECK"
}

@test "the shipped policy is clean" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'clean'
}

@test "an action that executes at a tier above W1 is refused" {
  # `billing` is a legitimate MAPPED action (the answerer hands it to a human); what must never
  # happen is an action that both executes here and is not W1.
  mutate 'd["actions"]["billing"]["executes_here"] = True'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'W1'
}

@test "an action that executes a merge is refused" {
  mutate 'd["actions"]["merge-candidate"]["executes_here"] = True'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'merge'
}

@test "an action that executes an erasure is refused" {
  mutate 'd["actions"]["erasure"]["executes_here"] = True'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'eras'
}

@test "an action that executes a refund is refused" {
  mutate 'd["actions"]["billing"]["executes_here"] = True'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'refund'
}

@test "a handoff action that neither pages nor refuses is refused" {
  mutate 'd["actions"]["unknown"]["page"] = False'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'reaches no human'
}

@test "a non-executing W1 action that does not page is refused" {
  # `gap-ask` and `uvn-status` are W1 but `executes_here: false`. Keying the page check on
  # `tier == "handoff"` let `page: false` on either of them pass clean, and the answerer then
  # emitted no human page at all.
  mutate 'd["actions"]["gap-ask"]["page"] = False'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'reaches no human'
}

@test "a non-executing W1 action that does not page is refused (uvn-status)" {
  mutate 'd["actions"]["uvn-status"]["page"] = False'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'reaches no human'
}

@test "a refusing action that names a customer line is refused" {
  mutate 'd["actions"]["requester-linked-refusal"]["line"] = "status_chase"'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'refusal sends no customer copy'
}

@test "a non-boolean page flag is refused" {
  mutate 'd["actions"]["unknown"]["page"] = "yes"'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'non-boolean'
}

@test "a rule naming an action that does not exist is refused" {
  mutate 'd["rules"].insert(0, {"key": "dangling", "why": "x", "intents": ["*"], "when": {}, "action": "no-such-action"})'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'no-such-action'
}

@test "a policy whose last rule is not the catch-all is refused" {
  mutate 'd["rules"].append(d["rules"].pop(0))'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "fallthrough"
}
