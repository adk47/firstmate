#!/usr/bin/env bats
# Tests for scripts/lib/ensure-session-budget-headroom.sh — the detect-and-page
# guard for openclaw 7.1's per-agent session disk-budget reaper.
#
# The bug it guards (2026-07-27): once an agent's sessions dir crosses
# session.maintenance.maxDiskBytes and the removable file set is exhausted,
# `enforceSessionDiskBudget` falls through to deleting session store ENTRIES.
# Slack keys are protected, `agent:<id>:cron:<jobId>` keys are not — so ALL of
# that agent's cron sessions get evicted and every fire then dies at setup with
# CronSessionLifecycleClaimError. The `operations` agent lost all 8 crons for
# ~25h before anyone connected the dots.
#
# A whole filesystem is faked under $TEST_TMPDIR (SESSION_BUDGET_STATE_ROOT), so
# no test ever reads /root. `openclaw` is PATH-stubbed for `cron list --all
# --json`; ssh is shadowed so an accidental remote call fails loudly
# (memory/feedback_bats_must_stub_openclaw).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/ensure-session-budget-headroom.sh"

# _mk_profile <profile> <maxDiskBytes|"unset">
#
# NOTE: every `local` below declares ONE variable per statement on purpose.
# `local p="$1" dir="…$p"` expands ALL right-hand sides BEFORE performing any of
# the assignments, so $p is still empty when $dir is built — the paths silently
# land in ".openclaw-" and every assertion fails with no visible error.
_mk_profile() {
  local p="$1"
  local max="$2"
  local dir="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p"
  mkdir -p "$dir"
  if [ "$max" = "unset" ]; then
    echo '{"session":{"maintenance":{"mode":"enforce"}}}' > "$dir/openclaw.json"
  else
    printf '{"session":{"maintenance":{"mode":"enforce","maxDiskBytes":"%s"}}}\n' \
      "$max" > "$dir/openclaw.json"
  fi
}

# _mk_agent <profile> <agent> <padding-bytes> <cron-key-count>
_mk_agent() {
  local p="$1"
  local a="$2"
  local bytes="$3"
  local cronkeys="$4"
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p/agents/$a/sessions"
  mkdir -p "$d"
  # sessions.json with N cron keys plus one protected slack key.
  python3 - "$d/sessions.json" "$cronkeys" "$a" <<'PY'
import json, sys
path, n, agent = sys.argv[1], int(sys.argv[2]), sys.argv[3]
store = {f"agent:{agent}:slack:channel:c123": {"updatedAt": 1}}
for i in range(n):
    store[f"agent:{agent}:cron:job-{i}"] = {"updatedAt": 1}
open(path, "w").write(json.dumps(store))
PY
  [ "$bytes" -gt 0 ] && head -c "$bytes" /dev/zero > "$d/transcript.jsonl"
  return 0
}

# _set_enabled_crons <agent> <count>
_set_enabled_crons() {
  python3 - "$FAKE_CRON_JSON" "$1" "$2" <<'PY'
import json, sys
path, agent, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
jobs = [{"id": f"j{i}", "enabled": True, "agentId": agent} for i in range(n)]
json.dump({"jobs": jobs}, open(path, "w"))
PY
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export SESSION_BUDGET_STATE_ROOT="$TEST_TMPDIR/root"
  export SESSION_BUDGET_PROFILES="main"
  export FAKE_CRON_JSON="$TEST_TMPDIR/cron.json"

  mkdir -p "$TEST_TMPDIR/bin"

  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB

  # Fake openclaw: only `cron list --all --json` is used by the guard.
  # $FAKE_CRON_FAIL makes it fail, exercising the read-error (exit 2) path.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"cron list --all --json"*)
    [ -n "${FAKE_CRON_FAIL:-}" ] && exit 7
    cat "$FAKE_CRON_JSON"
    ;;
  *) echo "unexpected openclaw invocation: $args" >&2; exit 90 ;;
esac
STUB

  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/openclaw"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Default: one agent, no enabled crons, tiny sessions dir.
  echo '{"jobs":[]}' > "$FAKE_CRON_JSON"
  _mk_profile main 4gb
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

@test "clean when every agent is well under the budget" {
  _mk_agent main ops 1024 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "CRITICAL when an agent's sessions dir exceeds maxDiskBytes" {
  _mk_profile main 1mb
  _mk_agent main ops $((2 * 1024 * 1024)) 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"main/ops"* ]]
  [[ "$output" == *"maxDiskBytes"* ]]
}

@test "CRITICAL on the wedge signature: enabled crons but ZERO cron session keys" {
  # Well under budget, so ONLY the eviction signature can fire. This is the
  # exact 2026-07-27 operations state.
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 8
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"8 enabled cron(s) but ZERO"* ]]
  [[ "$output" == *"CronSessionLifecycleClaimError"* ]]
}

@test "no wedge finding when the agent has zero cron keys but no enabled crons" {
  # An agent that simply owns no crons must not be flagged — otherwise every
  # chat-only agent pages forever and the alert becomes noise.
  _mk_agent main chatonly 1024 0
  echo '{"jobs":[]}' > "$FAKE_CRON_JSON"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "WARN fires between the ratio threshold and the hard cap" {
  _mk_profile main 10mb
  _mk_agent main ops $((9 * 1024 * 1024)) 3   # 90% of 10mb, over the 0.8 ratio
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "dormant when maxDiskBytes is unset (reaper returns early upstream)" {
  # enforceSessionDiskBudget: `if (maxBytes == null || highWaterBytes == null)
  # return null`. Nothing can be evicted, so nothing to guard.
  _mk_profile main unset
  _mk_agent main ops $((50 * 1024 * 1024)) 0
  _set_enabled_crons ops 5
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
}

@test "exit 2 when the gateway cron query fails (never a silent all-clear)" {
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 3
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "a read error is not downgraded to a mere violation by a later profile" {
  # Sticky-upwards rc: main errors (gateway down), edge would only WARN.
  # Reporting 1 here would imply the whole fleet was successfully evaluated.
  export SESSION_BUDGET_PROFILES="main edge"
  _mk_profile edge 10mb
  _mk_agent edge sup $((9 * 1024 * 1024)) 1
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 3
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 2 ]
}

@test "report mode always exits 0 so it can never block a gateway start" {
  # It sits in ExecStartPre via openclaw-pre-start-heal.sh; a guard that can
  # refuse to start the gateway is worse than the bug it guards.
  _mk_profile main 1mb
  _mk_agent main ops $((5 * 1024 * 1024)) 0
  _set_enabled_crons ops 8
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CRITICAL"* ]]
}

@test "report mode exits 0 even when the check errors out" {
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 3
  FAKE_CRON_FAIL=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "unreadable sessions.json is not mistaken for the wedge" {
  # A genuine 0 is the outage; unreadable is missing data. Conflating them turns
  # a permissions blip into a false page. Uses an ENOTDIR file-parent rather than
  # a chmod, because CI bats runs as root and root reads 0000 files anyway
  # (memory/reference_ci_selfhosted_runner_root_unwritable_test).
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-main/agents/ops/sessions"
  mkdir -p "$d"
  # sessions.json is a DIRECTORY -> jq read fails, count is -1, not 0.
  mkdir -p "$d/sessions.json"
  _set_enabled_crons ops 4
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZERO"* ]]
}

@test "size units parse with binary multipliers (4gb == 4 GiB)" {
  # 512mb -> 536870912 and 4gb -> 4294967296 are the values openclaw itself
  # reports back in `sessions cleanup --json`; a decimal-multiplier parser would
  # silently mis-threshold.
  _mk_profile main 4gb
  _mk_agent main ops $((3 * 1024 * 1024)) 2   # far under 4GiB, and under 80%
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]

  # 3MiB is over 80% of a 3mb (3145728 B) cap -> WARN, proving mb parsing too.
  _mk_profile main 3mb
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
}
