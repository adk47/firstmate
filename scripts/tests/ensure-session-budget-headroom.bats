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
  # $FAKE_CRON_FAIL fails for every profile; $FAKE_CRON_FAIL_PROFILE fails for
  # just one (so a multi-profile run can have one good and one unreachable
  # gateway). Both exercise the read-error path.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"cron list --all --json"*)
    [ -n "${FAKE_CRON_FAIL:-}" ] && exit 7
    if [ -n "${FAKE_CRON_FAIL_PROFILE:-}" ]; then
      case "$args" in *"--profile ${FAKE_CRON_FAIL_PROFILE} "*) exit 7 ;; esac
    fi
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

@test "a confirmed violation still PAGES when another profile cannot be evaluated" {
  # THE regression this guard exists to avoid. An earlier sticky-upwards rc made
  # a read error outrank a violation, so with edge unreachable and main/ops
  # genuinely over budget the script returned 2 — which the watchdog treats as
  # log-only — and the confirmed outage never paged (it wasn't even printed).
  # Completeness and severity are independent axes.
  export SESSION_BUDGET_PROFILES="main edge"
  _mk_profile main 1mb
  _mk_agent main ops $((5 * 1024 * 1024)) 2     # real CRITICAL on main
  _set_enabled_crons ops 1
  _mk_profile edge 1mb
  mkdir -p "$SESSION_BUDGET_STATE_ROOT/.openclaw-edge/agents/sup/sessions"
  FAKE_CRON_FAIL_PROFILE=edge run "$SCRIPT" --check   # edge gateway unreachable
  [ "$status" -eq 1 ]                       # pages, does NOT collapse to 2
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"main/ops"* ]]           # the confirmed finding is PRINTED
  [[ "$output" == *"UNEVALUATED"* ]]        # and edge is named, not swallowed
  [[ "$output" == *"edge"* ]]
}

@test "a failed cron inventory does not suppress that SAME profile's size checks" {
  # The intra-profile twin of the test above. The cron inventory is needed ONLY
  # for the zero-cron-key correlation; the disk-size checks are independent. An
  # earlier `continue` on inventory failure skipped them too, so an agent already
  # over maxDiskBytes reported as merely UNEVALUATED (exit 2 -> watchdog logs,
  # never pages) — the same confirmed-violation suppression, one scope down.
  _mk_profile main 1mb
  _mk_agent main ops $((5 * 1024 * 1024)) 0
  _set_enabled_crons ops 4
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 1 ]                       # pages, does NOT collapse to 2
  [[ "$output" == *"CRITICAL"* ]]           # the size violation IS reported
  [[ "$output" == *"main/ops"* ]]
  [[ "$output" == *"UNEVALUATED"* ]]        # and the unknown signal is named
  # The zero-cron-key correlation is the ONE thing that must be skipped: without
  # the inventory we cannot know the agent owns enabled crons, and claiming the
  # wedge on that basis would be a fabricated outage.
  [[ "$output" != *"ZERO"* ]]
}

@test "an unevaluated profile is reported, never silently dropped" {
  # Exit 2 must still SAY which profile it could not evaluate — a bare
  # "could not evaluate" with no detail is not actionable.
  export SESSION_BUDGET_PROFILES="main"
  _mk_agent main ops 1024 3
  _set_enabled_crons ops 1
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"main"* ]]
  # Match the real all-clear phrase, not the bare word — the exit-2 log line
  # legitimately contains "NOT clean".
  [[ "$output" != *"clean: every agent"* ]]
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

@test "unreadable sessions.json is a READ ERROR, not a wedge and not an all-clear" {
  # Three-way distinction that has to hold:
  #   0 cron keys  -> the outage (page)
  #   unreadable   -> exit 2, "could not evaluate" (do NOT page a permissions
  #                   blip as an outage, but do NOT report clean either — that
  #                   would be a false all-clear on the decisive signal)
  # Uses an ENOTDIR file-parent rather than a chmod, because CI bats runs as
  # root and root reads 0000 files anyway
  # (memory/reference_ci_selfhosted_runner_root_unwritable_test).
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-main/agents/ops/sessions"
  mkdir -p "$d"
  # sessions.json is a DIRECTORY -> jq read fails, count is -1, not 0.
  mkdir -p "$d/sessions.json"
  _set_enabled_crons ops 4
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" != *"ZERO"* ]]                  # not misreported as the wedge
  [[ "$output" != *"clean: every agent"* ]]    # never a silent all-clear
  [[ "$output" == *"UNEVALUATED"* ]]
}

@test "unreadable sessions.json still exits 0 in report mode (never blocks start)" {
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-main/agents/ops/sessions"
  mkdir -p "$d/sessions.json"
  _set_enabled_crons ops 4
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not evaluate"* ]]
}

# _mk_sparse_agent <profile> <agent> <apparent-bytes>
# Sparse file: multi-GiB APPARENT size at ~zero disk cost. _dir_bytes measures
# apparent size (stat), which is also what the reaper sums, so this exercises
# the real code path without writing gigabytes in CI.
_mk_sparse_agent() {
  local p="$1"
  local a="$2"
  local bytes="$3"
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p/agents/$a/sessions"
  mkdir -p "$d"
  printf '{"agent:%s:cron:j0":{"updatedAt":1}}\n' "$a" > "$d/sessions.json"
  dd if=/dev/null of="$d/big.jsonl" bs=1 seek="$bytes" 2>/dev/null
}

# _stub_clamping_awk — PATH-shadow awk with one that emulates OLDER mawk, where
# `printf "%d"` goes through a 32-bit integer conversion and clamps at
# INT32_MAX. Every other awk program delegates to the real binary untouched.
#
# Without this the three tests below are VACUOUS on our hosts: node-8 runs
# mawk 1.3.4 and macOS runs BWK awk, and neither clamps, so they would pass just
# as happily against the `printf "%d"` this change replaced. With it, reverting
# _parse_bytes to "%d" makes them fail — which is the only thing that makes them
# a real regression guard.
_stub_clamping_awk() {
  cat > "$TEST_TMPDIR/bin/awk" <<'STUB'
#!/bin/bash
real=/usr/bin/awk
out="$("$real" "$@")"
for a in "$@"; do
  case "$a" in
    *'printf "%d"'*)
      case "$out" in
        ''|*[!0-9]*) : ;;
        *) if [ "$out" -gt 2147483647 ] 2>/dev/null; then out=2147483647; fi ;;
      esac
      ;;
  esac
done
printf '%s' "$out"
STUB
  chmod +x "$TEST_TMPDIR/bin/awk"
}

@test "parsing survives an awk whose printf %d clamps at INT32_MAX" {
  # The non-vacuous version of the overflow guard. Under a clamping awk a "%d"
  # parser reads 4gb as 2147483647 (~2GiB) and this 3GiB agent reports CRITICAL.
  _stub_clamping_awk
  _mk_profile main 4gb
  _mk_sparse_agent main ops $((3 * 1024 * 1024 * 1024))
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "a 4gb cap is not truncated to 2GiB by 32-bit awk integer conversion" {
  # Regression guard for awk `printf "%d"`, which clamps at INT32_MAX on older
  # mawk builds. If maxDiskBytes parsed as ~2GiB instead of 4GiB, a 3GiB agent
  # would trip CRITICAL here. It must read as clean: 3GiB < 80% of 4GiB (3.2GiB).
  _mk_profile main 4gb
  _mk_sparse_agent main ops $((3 * 1024 * 1024 * 1024))
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "the 80% warn line sits at 3.2GiB for a 4gb cap, not 1.6GiB" {
  # Pins the threshold arithmetic end to end: 3.5GiB is over 80% of 4GiB but
  # under the cap => WARN, never CRITICAL. Under a clamped parse this agent
  # would be far over the (mis-parsed) cap and report CRITICAL instead.
  _mk_profile main 4gb
  _mk_sparse_agent main ops $(( (7 * 1024 * 1024 * 1024) / 2 ))   # 3.5GiB
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"4.0GiB"* ]]     # the cap is REPORTED as 4GiB, not 2GiB
}

@test "a 4gb cap still detects a genuinely over-budget agent above 4GiB" {
  # The other side of the same boundary — proves the cap wasn't just raised out
  # of reach by the parse change.
  _mk_profile main 4gb
  _mk_sparse_agent main ops $((5 * 1024 * 1024 * 1024))
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"5.0GiB"* ]]
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
