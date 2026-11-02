#!/usr/bin/env bats
# caroline-guard-g1: the daily red-team replay (scripts/caroline-safety-daily.sh) and its systemd wiring.
#  - the unit renders as a oneshot + daily timer running the real, executable script, with OnFailure paging;
#  - a clean day posts the digest (no page) and exits 0;
#  - ANY failing case, an unloadable layer, or fewer passing cases than yesterday PAGES (critical) and exits 1.
# The layers are stubbed on PATH (node / python3) so the wrapper's own decisions are what is tested; the layers
# themselves are tested by plugins/intercom/tests/redteam.test.ts and caroline_redteam_docverify.py.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="caroline-safety-daily"
DAILY="$HYDRA_REPO/scripts/caroline-safety-daily.sh"

_render() {
  local snippet="$TEST_TMPDIR/render-$RANDOM.sh"
  awk -v dir="$1" -v name="$2" -v dest="$3/" '
    !on && index($0, "cat > " dir name) == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1
      print "cat > " dest substr($0, length("cat > " dir) + 1); next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="$HYDRA_REPO" bash "$snippet"
}
_kv() {
  awk '/^\[[^]]+\]$/ { sec = substr($0, 2, length($0) - 2); next }
       /^[A-Za-z][A-Za-z0-9]*=/ { i = index($0, "="); print sec "." substr($0, 1, i - 1) "=" substr($0, i + 1) }' "$1"
}
_values() { _kv "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'; }

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  UNITS="$TEST_TMPDIR/units"; mkdir -p "$UNITS"
  _render /etc/systemd/system/ "$NAME." "$UNITS"
  SVC="$UNITS/$NAME.service"; TMR="$UNITS/$NAME.timer"

  # stub layers + a recording muso (slack) on PATH
  STUB="$TEST_TMPDIR/bin"; mkdir -p "$STUB"
  printf '%s' '{"layer":"caroline","cases":52,"failed":0,"failures":{},"guard_version":"g","guard_mode":"enforce","bank_version":"b"}' > "$TEST_TMPDIR/js.default"
  printf '%s' '{"layer":"doc-verify","cases":4,"failed":0,"failures":{}}' > "$TEST_TMPDIR/py.default"
  cat > "$STUB/node" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_JS:-}" ]; then printf '%s\n' "$FAKE_JS"; else cat "$TEST_TMPDIR/js.default"; echo; fi
exit "${FAKE_JS_RC:-0}"
SH
  cat > "$STUB/python3" <<'SH'
#!/usr/bin/env bash
case "$1" in
  *caroline_redteam_docverify.py)
    if [ -n "${FAKE_PY:-}" ]; then printf '%s\n' "$FAKE_PY"; else cat "$TEST_TMPDIR/py.default"; echo; fi
    exit "${FAKE_PY_RC:-0}" ;;
  *injection-watch.py)
    if [ -n "${FAKE_DG:-}" ]; then printf '%s\n' "$FAKE_DG"; exit "${FAKE_DG_RC:-0}"; fi
    printf '%s\n' '{"inbound":{"turns":2,"by_severity":{"high":1},"by_source":{"intercom":2}},"output_guard":{"blocked":1,"by_rule":{"promise/timeframe_within":1},"notes":{}},"classifier_unavailable":3,"watch_candidates":[]}' ;;
esac
SH
  cat > "$STUB/mv" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_MV_FAIL:-}" ] && { echo "mv: cannot move: No space left on device" >&2; exit 1; }
exec /bin/mv "$@"
SH
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_CLASSIFIER:-down}" = up ]
SH
  cat > "$STUB/muso" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = "--text" ] && printf '%s\n---\n' "$2" >> "$TEST_TMPDIR/slack.log"; shift; done
SH
  chmod +x "$STUB"/*
  export PATH="$STUB:$PATH" MUSO_BIN="$STUB/muso" MUSO_SLACK_BOT_TOKEN_DEVOPS=x MUSO_SLACK_ENV_FILE=/nonexistent
  STATE="$TEST_TMPDIR/state"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

daily() { run bash "$DAILY" --state-dir "$STATE" --plugin-dir "$TEST_TMPDIR/plugin"; }

@test "unit: a oneshot running the real, executable daily script; daily timer; OnFailure paging registered" {
  [ "$(_values "$SVC" Service.Type)" = "oneshot" ]
  [ "$(_values "$SVC" Service.ExecStart)" = "/bin/bash $HYDRA_REPO/scripts/$NAME.sh" ]
  [ -x "$DAILY" ]
  [ "$(_values "$TMR" Timer.OnCalendar)" = "*-*-* 06:10:00 UTC" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  grep -qx "  $NAME.service" "$INSTALLER"   # in AUX_ONFAILURE_UNITS
  run grep -E 'xoxb-|TOKEN=' "$SVC" "$TMR"
  [ "$status" -eq 1 ]
}

@test "a clean day posts the digest, pages nobody, records the day, exits 0" {
  daily
  [ "$status" -eq 0 ]
  [[ "$output" == *"red-team 52/52"* ]]
  [[ "$output" == *"doc-verify 4/4"* ]]
  [ -s "$STATE/$(date -u +%F).json" ]
  [ "$(stat -c %a "$STATE/$(date -u +%F).json" 2>/dev/null || stat -f %Lp "$STATE/$(date -u +%F).json")" = "600" ]
  grep -q ":shield: Caroline safety daily" "$TEST_TMPDIR/slack.log"
  run grep -q "<@" "$TEST_TMPDIR/slack.log"
  [ "$status" -eq 1 ]
}

@test "the digest always states classifier availability (s1: absence never looks like 0 hits)" {
  daily
  [[ "$output" == *"classifier=unavailable"* ]]
  [ "$(jq -r .classifier "$STATE/$(date -u +%F).json")" = "unavailable" ]
  rm -rf "$STATE"
  FAKE_CLASSIFIER=up daily
  [[ "$output" == *"classifier=available"* ]]
}

@test "CAN FAIL: one red-team case through pages critical and exits 1" {
  FAKE_JS='{"layer":"caroline","cases":52,"failed":1,"failures":{"RT28":["bad reply PASSED the output guard"]}}' FAKE_JS_RC=1 daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"REGRESSION"*"RT28"* ]]
  grep -q "<@U0AL36NADEY> <@U7RP6HKUZ> :rotating_light: Caroline safety REGRESSION" "$TEST_TMPDIR/slack.log"
}

@test "CAN FAIL: an unloadable deployed layer pages" {
  FAKE_JS='{"layer":"caroline","error":"cannot load the deployed safety layer"}' FAKE_JS_RC=2 daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot load the deployed safety layer"* ]]
}

@test "CAN FAIL: a doc-verify case through pages" {
  FAKE_PY='{"layer":"doc-verify","cases":4,"failed":1,"failures":{"RT19":["gate returned verified"]}}' FAKE_PY_RC=1 daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc-verify layer rc=1"*"RT19"* ]]
}

@test "CAN FAIL: a digest that could not refresh the watch candidates pages and exits 1" {
  FAKE_DG='{"inbound":{"turns":0},"output_guard":{},"watch_candidates":[],"candidates_written":false,"candidates_error":"PermissionError: denied"}' FAKE_DG_RC=1 daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"injection digest failed rc=1"*"PermissionError"* ]]
  grep -q "REGRESSION" "$TEST_TMPDIR/slack.log"
}

@test "CAN FAIL: a digest that printed garbage pages even with rc 0" {
  FAKE_DG='Traceback (most recent call last): boom' FAKE_DG_RC=0 daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"injection digest failed"* ]]
}

@test "CAN FAIL: a day record that cannot be written pages and exits 1, even when every layer passed" {
  FAKE_MV_FAIL=1 daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be written"* ]]
  [[ "$output" != *"red-team 52/52"* ]]          # no green summary from a record that does not exist
  grep -q "REGRESSION" "$TEST_TMPDIR/slack.log"
  run grep -q ":shield:" "$TEST_TMPDIR/slack.log"
  [ "$status" -eq 1 ]
}

@test "CAN FAIL: an unwritable injection ledger pages (hits are being lost, not absent)" {
  FAKE_DG='{"inbound":{"turns":0},"output_guard":{},"watch_candidates":[],"candidates_written":true,"ledger_writable":false,"ledger_error":"PermissionError: read-only"}' daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"ledger NOT WRITABLE"*"PermissionError"* ]]
}

@test "CAN FAIL: fewer passing cases than yesterday pages even when every case today passes" {
  mkdir -p "$STATE"
  echo '{"caroline":{"cases":60,"failed":0},"docverify":{"cases":4,"failed":0}}' > "$STATE/2000-01-01.json"
  daily
  [ "$status" -eq 1 ]
  [[ "$output" == *"passing cases fell from 64 to 56"* ]]
}

@test "the red-team corpus lives on a path the deploy rsync ships (no tests/ segment)" {
  # deploy.sh RSYNC_EXCLUDES drops every tests/ dir: a corpus there never reaches node-8 and the daily pages
  # 'cannot load' forever (found on the first deploy of #1628).
  grep -q -- "--exclude='tests/'" "$HYDRA_REPO/scripts/deploy.sh"
  [ -s "$HYDRA_REPO/plugins/intercom/redteam/caroline-redteam-cases.json" ]
  run grep -n "tests/redteam/caroline-redteam-cases" "$HYDRA_REPO/scripts/caroline-redteam.mjs" "$DAILY"
  [ "$status" -eq 1 ]
  grep -q '"redteam/caroline-redteam-cases.json"' "$HYDRA_REPO/scripts/caroline-redteam.mjs"
}
