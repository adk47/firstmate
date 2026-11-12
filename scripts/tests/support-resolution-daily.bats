#!/usr/bin/env bats
# ai-support-quality-v1: the daily resolution line (scripts/support-resolution-daily.sh) and its systemd wiring.
#  - the unit renders as a oneshot + daily timer running the real, executable wrapper, with OnFailure paging;
#  - a measured day posts the line as it stands and exits 0;
#  - an UNMEASURED day (rc 3) posts that it is unmeasured, prints no rate, and exits 3 (the unit fails);
#  - a crashed run says FAILED and exits with the crash's code: never a quiet day, never a made-up number.
# The measurement itself is tests/test_support_resolution_daily.py; python3 is stubbed here so the wrapper's own
# decisions are what is tested.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="support-resolution-daily"
DAILY="$HYDRA_REPO/scripts/$NAME.sh"

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

  STUB="$TEST_TMPDIR/bin"; mkdir -p "$STUB"
  cat > "$STUB/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMPDIR/py.argv"
printf '%s\n' "${FAKE_OUT:-Caroline, last 24h to 2026-11-12T00:45Z: resolved 63 of 417 (15.1%). Three buckets that add up to 417: resolved by Caroline 63, answered by a person 0, waiting on us 354.}"
[ -n "${FAKE_ERR:-}" ] && printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
SH
  cat > "$STUB/muso" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = "--text" ] && printf '%s\n---\n' "$2" >> "$TEST_TMPDIR/slack.log"; shift; done
SH
  chmod +x "$STUB"/*
  export PATH="$STUB:$PATH" MUSO_BIN="$STUB/muso" MUSO_SLACK_BOT_TOKEN_DEVOPS=x MUSO_SLACK_ENV_FILE=/nonexistent
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "unit: a oneshot running the real, executable wrapper; daily timer; OnFailure paging registered; no secret" {
  [ "$(_values "$SVC" Service.Type)" = "oneshot" ]
  [ "$(_values "$SVC" Service.ExecStart)" = "/bin/bash $HYDRA_REPO/scripts/$NAME.sh" ]
  [ -x "$DAILY" ]
  [ -f "$HYDRA_REPO/scripts/$NAME.py" ]
  [ "$(_values "$TMR" Timer.OnCalendar)" = "*-*-* 06:30:00 UTC" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  [ "$(_values "$TMR" Timer.Persistent)" = "true" ]
  awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)/' "$INSTALLER" | grep -qx "  $NAME.service"
  run grep -E 'xoxb-|TOKEN=' "$SVC" "$TMR"
  [ "$status" -eq 1 ]
}

@test "the installer refuses to run without the wrapper and the measurement" {
  grep -q "scripts/$NAME.sh\" ]] \\\\" "$INSTALLER"
  grep -q "scripts/$NAME.py\" ]] \\\\" "$INSTALLER"
  grep -q "install -d -m 700 /var/lib/hydra/support-resolution" "$INSTALLER"
}

@test "a measured day posts the line as it stands, pings nobody, exits 0" {
  run bash "$DAILY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved 63 of 417 (15.1%)"* ]]
  grep -q "resolved 63 of 417 (15.1%)" "$TEST_TMPDIR/slack.log"
  run grep -q "<@" "$TEST_TMPDIR/slack.log"
  [ "$status" -eq 1 ]
  grep -q "scripts/$NAME.py" "$TEST_TMPDIR/py.argv"
}

@test "arguments reach the measurement, and --no-post posts nothing" {
  run bash "$DAILY" --no-post --hours 48 --no-record
  [ "$status" -eq 0 ]
  grep -q -- "--hours 48 --no-record" "$TEST_TMPDIR/py.argv"
  run grep -q -- "--no-post" "$TEST_TMPDIR/py.argv"
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/slack.log" ]
}

@test "CAN FAIL: an unmeasured day says so, prints no rate, and fails the unit with 3" {
  FAKE_RC=3 FAKE_OUT="Caroline resolution daily: UNMEASURED (search failed: URLError). No rate is reported for this run." run bash "$DAILY"
  [ "$status" -eq 3 ]
  grep -q "UNMEASURED" "$TEST_TMPDIR/slack.log"
  run grep -q "%" "$TEST_TMPDIR/slack.log"
  [ "$status" -eq 1 ]
}

@test "CAN FAIL: a crashed run says FAILED with no number and exits with the crash's code" {
  FAKE_RC=1 FAKE_OUT="Traceback (most recent call last):" FAKE_ERR="KeyError: 'parts'" run bash "$DAILY"
  [ "$status" -eq 1 ]
  grep -q "the run FAILED (rc=1), so there is no number for this day" "$TEST_TMPDIR/slack.log"
  run grep -q "resolved" "$TEST_TMPDIR/slack.log"
  [ "$status" -eq 1 ]
}
