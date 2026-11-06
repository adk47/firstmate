#!/usr/bin/env bats
# Tests for scripts/lib/qa-gh-budget.sh — the shared GitHub REST budget guard.
#
# Why this exists: every QA review spends GitHub REST calls under ONE App
# installation, so N reviewer pods share one budget. Without a guard, scaling
# the reviewers multiplies the burn rate and the fleet discovers the limit
# mid-review, which turns into a CANNOT REVIEW verdict on a real PR.
#
# The guard must therefore be conservative in exactly one direction: "unknown"
# is never "fine".

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
BUDGET="$HYDRA_REPO/scripts/lib/qa-gh-budget.sh"

setup() {
  TMPD="$(mktemp -d)"
  export QA_GH_BUDGET_FILE="$TMPD/gh-budget.json"
  export QA_GH_BUDGET_TTL_S=300
  export QA_GH_BUDGET_FLOOR=800
  # A stub `gh` that answers `api rate_limit` with a controllable number.
  mkdir -p "$TMPD/bin"
  cat >"$TMPD/bin/qa-gh-stub" <<'STUB'
#!/usr/bin/env bash
# Emits a rate_limit payload with $STUB_REMAINING, or fails when $STUB_FAIL=1.
# Records the identity scope it was invoked with, so a test can prove the probe
# measured the installation rather than the host account.
if [ "${1:-}" = "--repo" ]; then
  printf '%s\n' "$2" >"${STUB_SCOPE_LOG:-/dev/null}"
  shift 2
fi
if [ "${STUB_FAIL:-0}" = "1" ]; then
  exit 1
fi
printf '{"resources":{"core":{"remaining":%s,"reset":%s}}}\n' \
  "${STUB_REMAINING:-5000}" "${STUB_RESET:-1999999999}"
STUB
  chmod +x "$TMPD/bin/qa-gh-stub"
  export QA_GH="$TMPD/bin/qa-gh-stub"
  # No policy file by default, so the scope is the host identity unless a test
  # sets QA_GH_BUDGET_REPO or points QA_APPROVAL_POLICY at a fixture.
  export QA_APPROVAL_POLICY="$TMPD/no-policy.json"
  unset QA_GH_BUDGET_REPO
  export STUB_SCOPE_LOG="$TMPD/scope"
}

teardown() {
  rm -rf "$TMPD"
}

@test "budget: a healthy budget reports ok and caches the value" {
  STUB_REMAINING=5000 run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$output" = "ok:5000" ]
  [ -r "$QA_GH_BUDGET_FILE" ]
}

@test "budget: below the floor reports low and exits 1" {
  STUB_REMAINING=799 run "$BUDGET" check
  [ "$status" -eq 1 ]
  [ "$output" = "low:799" ]
}

@test "budget: exactly at the floor is still ok (the floor is inclusive)" {
  STUB_REMAINING=800 run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$output" = "ok:800" ]
}

@test "budget: a probe failure with no cache is unknown, never ok" {
  STUB_FAIL=1 run "$BUDGET" check
  [ "$status" -eq 2 ]
  [ "$output" = "unknown" ]
}

@test "budget: a fresh cache is used without probing again" {
  STUB_REMAINING=5000 run "$BUDGET" check
  [ "$status" -eq 0 ]
  # Now make the probe fail: a fresh cache must still answer from the cache.
  STUB_FAIL=1 run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$output" = "ok:5000" ]
}

@test "budget: a stale cache is refreshed" {
  STUB_REMAINING=5000 run "$BUDGET" check
  [ "$status" -eq 0 ]
  # Age the cache past the TTL.
  python3 - "$QA_GH_BUDGET_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["at"] = d["at"] - 10_000
json.dump(d, open(p, "w"))
PY
  STUB_REMAINING=100 run "$BUDGET" check
  [ "$status" -eq 1 ]
  [ "$output" = "low:100" ]
}

@test "budget: a stale cache survives a transient probe failure" {
  STUB_REMAINING=5000 run "$BUDGET" check
  [ "$status" -eq 0 ]
  python3 - "$QA_GH_BUDGET_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["at"] = d["at"] - 600
json.dump(d, open(p, "w"))
PY
  # Probe fails, but the last known value is still better than "unknown" —
  # past the TTL (300s) yet inside QA_GH_BUDGET_MAX_STALE_S (1800s). Past that
  # bound the answer is `unknown`; see the MAX_STALE test below.
  STUB_FAIL=1 run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$output" = "ok:5000" ]
}

@test "budget: refresh forces a probe even when the cache is fresh" {
  STUB_REMAINING=5000 run "$BUDGET" check
  [ "$status" -eq 0 ]
  STUB_REMAINING=42 run "$BUDGET" refresh
  [ "$status" -eq 0 ]
  [ "$output" = "ok:42" ]
}

@test "scope: the probe uses the App installation identity, not the host account" {
  # qa-gh.sh only picks the App installation when given --repo. An unscoped
  # probe measures the HOST quota, so in App mode the gate could read 5000
  # remaining while the installation the reviews spend is exhausted.
  export QA_GH_BUDGET_REPO="Muso-AI/hydra"
  run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_SCOPE_LOG")" = "Muso-AI/hydra" ]
}

@test "scope: the default scope comes from the policy's first app_repos entry" {
  cat >"$TMPD/policy.json" <<'JSON'
{"identity":{"app_repos":["Muso-AI/core-backend","Muso-AI/hydra"]}}
JSON
  export QA_APPROVAL_POLICY="$TMPD/policy.json"
  run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_SCOPE_LOG")" = "Muso-AI/core-backend" ]
}

@test "scope: with no app_repos the probe stays unscoped (host identity)" {
  cat >"$TMPD/policy.json" <<'JSON'
{"identity":{"app_repos":[]}}
JSON
  export QA_APPROVAL_POLICY="$TMPD/policy.json"
  run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_SCOPE_LOG" ]
}

@test "scope: a reading taken under another identity is a miss, not an answer" {
  # A host-identity ok:5000 must never authorize an App-mode review.
  run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_SCOPE_LOG" ]
  # Now switch to the App identity: the cached host reading must not be reused.
  export QA_GH_BUDGET_REPO="Muso-AI/hydra"
  STUB_REMAINING=12 run "$BUDGET" check
  [ "$status" -eq 1 ]
  [[ "$output" == "low:12" ]]
  [ "$(cat "$STUB_SCOPE_LOG")" = "Muso-AI/hydra" ]
}

@test "config: a malformed floor is unknown, never ok" {
  # `[ "$remaining" -lt bad ]` prints "integer expression expected" and
  # evaluates FALSE, so a typo in the floor made the gate answer `ok:0` against
  # an exhausted budget and every worker claimed reviews it could not finish.
  # A config error is a stop, not a permission slip.
  STUB_REMAINING=0 run "$BUDGET" check
  [ "$status" -eq 1 ]
  [ "$output" = "low:0" ]
  QA_GH_BUDGET_FLOOR=bad run "$BUDGET" check
  [ "$status" -eq 2 ]
  # bats merges stderr into $output, so assert on the last line.
  [ "${lines[-1]}" = "unknown" ]
  [[ "$output" == *"QA_GH_BUDGET_FLOOR=bad"* ]]
}

@test "config: a negative floor is unknown, never ok" {
  STUB_REMAINING=0 QA_GH_BUDGET_FLOOR=-1 run "$BUDGET" check
  [ "$status" -eq 2 ]
  [ "${lines[-1]}" = "unknown" ]
}

@test "config: a malformed TTL or MAX_STALE is unknown, never ok" {
  # A bad TTL makes `age -ge TTL` false, so the cache would read as fresh
  # forever; a bad MAX_STALE disables the staleness bound entirely.
  STUB_REMAINING=5000 QA_GH_BUDGET_TTL_S=bad run "$BUDGET" check
  [ "$status" -eq 2 ]
  [ "${lines[-1]}" = "unknown" ]
  STUB_REMAINING=5000 QA_GH_BUDGET_MAX_STALE_S=bad run "$BUDGET" check
  [ "$status" -eq 2 ]
  [ "${lines[-1]}" = "unknown" ]
}

@test "config: a floor of 0 is a real setting, not a malformed one" {
  STUB_REMAINING=0 QA_GH_BUDGET_FLOOR=0 run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$output" = "ok:0" ]
}

@test "budget: show renders one line with the state" {
  STUB_REMAINING=5000 run "$BUDGET" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh_rest_remaining=5000"* ]]
  [[ "$output" == *"state=ok"* ]]
}

@test "budget: an unreadable cache file is unknown, not a crash" {
  printf 'not json' >"$QA_GH_BUDGET_FILE"
  STUB_FAIL=1 run "$BUDGET" check
  [ "$status" -eq 2 ]
  [ "$output" = "unknown" ]
}

@test "a permanently failing probe stops trusting the cache after MAX_STALE" {
  # A revoked token, DNS failure or a proxy answering 500 makes the probe fail
  # forever. Without a bound, the last good `ok:5000` would authorize claims
  # indefinitely while the real budget drained to zero.
  export QA_GH_BUDGET_MAX_STALE_S=1800
  run "$BUDGET" refresh
  [ "$status" -eq 0 ]
  # Age the cache past the bound, then make every probe fail.
  python3 -c "
import json,os,time
p=os.environ['QA_GH_BUDGET_FILE']
d=json.load(open(p)); d['at']=int(time.time())-4000
json.dump(d,open(p,'w'))"
  export STUB_FAIL=1
  run "$BUDGET" check
  [ "$status" -eq 2 ]
  [ "$output" = "unknown" ]
}

@test "a stale-but-bounded cache is still trusted (transient probe failure)" {
  export QA_GH_BUDGET_MAX_STALE_S=1800
  run "$BUDGET" refresh
  [ "$status" -eq 0 ]
  python3 -c "
import json,os,time
p=os.environ['QA_GH_BUDGET_FILE']
d=json.load(open(p)); d['at']=int(time.time())-600
json.dump(d,open(p,'w'))"
  export STUB_FAIL=1
  run "$BUDGET" check
  [ "$status" -eq 0 ]
  [ "$output" = "ok:5000" ]
}
