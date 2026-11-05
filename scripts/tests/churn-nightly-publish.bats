#!/usr/bin/env bats
# The nightly wrapper's PUBLISH gate (firstmate churn-risk-signal-prevent-p1).
#
# The publisher's own guard only refuses a paying run older than
# thresholds.risk_max_age_hours (36h). Yesterday's successful run is ~24h old, well
# inside that window, so a sweep that dies before finish_run used to be followed by a
# fresh generated_at stamped over yesterday's rows: consumers then trusted a state
# today's run could not confirm (QA #1771, 2026-11-04). The wrapper must not CALL the
# publisher at all in that case, and returning nonzero after publishing would not undo
# the file.
#
# These tests execute nightly.sh with stub sweeps and a stub publisher under HYDRA_ROOT,
# so what is asserted is the wrapper's behaviour, not its text.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
NIGHTLY="$HYDRA_REPO/scripts/churn/nightly.sh"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  ROOT="$TMP/opt/hydra"
  mkdir -p "$ROOT/scripts/churn" "$TMP/state"
  printf '{"store": {"dir": "%s"}, "mrr": {"default_usd": 12.5}}\n' "$TMP/state" > "$TMP/policy.json"
  # the sweeps and the publisher become stubs that record how they were called
  printf 'import os,sys\nmode=next((a for a in sys.argv[1:] if a=="--paying" or a=="--churned-since"),"?")\nopen(os.environ["CALLS"],"a").write("sweep "+mode+"\\n")\nbad=os.environ.get("FAIL_SWEEP","")\nsys.exit(1 if bad and bad==mode else 0)\n' > "$ROOT/scripts/churn/support_state.py"
  printf 'import os,sys\nopen(os.environ["CALLS"],"a").write("publish dry\\n" if "--dry-run" in sys.argv else "publish\\n")\n' > "$ROOT/scripts/churn/risk.py"
  CALLS="$TMP/calls.log"
  : > "$CALLS"
  export CALLS
}

nightly() {
  run env HYDRA_ROOT="$ROOT" CHURN_RISK_POLICY="$TMP/policy.json" CALLS="$CALLS" FAIL_SWEEP="${1:-}" CHURN_LIMIT="${2:-0}" CHURN_DRY_RUN="${3:-0}" MAIN_ENV=/dev/null bash "$NIGHTLY"
}

@test "both sweeps and the publish run on a healthy night" {
  nightly
  [ "$status" -eq 0 ]
  run cat "$CALLS"
  run grep -c . "$CALLS"
  [ "$output" = "3" ]
  run grep -x publish "$CALLS"
  [ "$status" -eq 0 ]
}

@test "a failed PAYING sweep never publishes yesterday's rows as fresh" {
  nightly --paying
  [ "$status" -ne 0 ]
  grep -qx publish "$CALLS" && { echo "published after a failed sweep"; false; }
  grep -qx "sweep --churned-since" "$CALLS"
  grep -q "risk.json NOT published" <<< "$output"
}

@test "a failed CHURNED sweep also withholds the publish" {
  nightly --churned-since
  [ "$status" -ne 0 ]
  run grep -x publish "$CALLS"
  [ "$status" -ne 0 ]
  run grep -x "sweep --paying" "$CALLS"
  [ "$status" -eq 0 ]
}

@test "a canary run still withholds the publish" {
  nightly "" 50
  [ "$status" -eq 0 ]
  run grep -x publish "$CALLS"
  [ "$status" -ne 0 ]
}

@test "a dry run publishes NOTHING, it only renders" {
  # risk.py is still invoked (with --dry-run) so the operator sees what would be
  # written; what must never happen is a real publish on a read-only night
  nightly "" 0 1
  [ "$status" -eq 0 ]
  grep -qx publish "$CALLS" && { echo "a dry run published"; false; }
  grep -qx "publish dry" "$CALLS"
}
