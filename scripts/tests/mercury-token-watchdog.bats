#!/usr/bin/env bats
# Tests for scripts/mercury-token-watchdog.sh — the pager around
# scripts/lib/ensure-mercury-token.sh (whose own verdicts are covered by
# ensure-mercury-token.bats). This suite owns the host guard, the alert
# cooldown, and the Slack post.
#
# The detector is STUBBED here (MERCURY_TOKEN_CHECK), so no test touches a real
# credential or api.mercury.com. CI runs bats as ROOT and ON ovh-node-8, so any
# test asserting on the host guard must control `hostname` rather than inherit
# the runner's.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/mercury-token-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export MERCURY_ALERT_STATE="$TEST_TMPDIR/last-alert"
  export MERCURY_UNKNOWN_STATE="$TEST_TMPDIR/unknown-streak"
  export MERCURY_UNKNOWN_ALERT_STATE="$TEST_TMPDIR/unknown-last-alert"
  export MERCURY_TOKEN_CHECK="$TEST_TMPDIR/bin/detector"
  export MERCURY_SKIP_HOST_GUARD=1
  mkdir -p "$TEST_TMPDIR/bin"
  # Prefixed so stub_hostname can shadow the real `hostname`. Fresh per test —
  # teardown drops the whole dir, so no stub leaks between cases.
  export PATH="$TEST_TMPDIR/bin:$PATH"
  stub_detector 1 "token REJECTED by Mercury (HTTP 401)"
  stub_muso 0
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# stub_detector <exit_code> <message>
stub_detector() {
  cat > "$MERCURY_TOKEN_CHECK" <<EOF
#!/usr/bin/env bash
echo "$2" >&2
exit $1
EOF
  chmod +x "$MERCURY_TOKEN_CHECK"
}

# stub_muso <exit_code> — one log line per invocation, newlines inside args
# collapsed so \`sends | wc -l\` counts SENDS and not message lines (the page
# body is multi-line). Same shape as the stub in ads-inquiry-watchdog.bats.
stub_muso() {
  cat > "$TEST_TMPDIR/bin/muso" <<EOF
#!/usr/bin/env bash
all="\$*"
printf '%s\n' "\${all//\$'\n'/ }" >> "$TEST_TMPDIR/slack-sends"
exit $1
EOF
  chmod +x "$TEST_TMPDIR/bin/muso"
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test"
  export MUSO_SLACK_ENV_FILE="/dev/null"
}

# stub_hostname <name> — the host guard reads `hostname`, and CI bats run ON
# ovh-node-8, so a guard assertion must control the name.
stub_hostname() {
  cat > "$TEST_TMPDIR/bin/hostname" <<EOF
#!/usr/bin/env bash
echo "$1"
EOF
  chmod +x "$TEST_TMPDIR/bin/hostname"
  hash -r
}

sends() { cat "$TEST_TMPDIR/slack-sends" 2>/dev/null || true; }
send_count() { sends | grep -c 'Mercury API token is dead' || true; }

# ── detector verdict → action ─────────────────────────────────────────────────

@test "violation with no prior state → pages and records the timestamp" {
  run "$WD"
  [ "$status" -eq 0 ]                 # never fails the cron tick
  [ "$(send_count)" -eq 1 ]
  [ -s "$MERCURY_ALERT_STATE" ]
}

@test "a working token pages nothing and writes no state" {
  stub_detector 0 "clean: token works"
  run "$WD"
  [ "$status" -eq 0 ]
  [ -z "$(sends)" ]
  [ ! -e "$MERCURY_ALERT_STATE" ]
}

# rc=2 is "could not evaluate" — transient by construction. Paging on it would
# turn every Mercury blip into a 3am ping.
@test "detector rc=2 does NOT page and does not stamp" {
  stub_detector 2 "cannot evaluate: unexpected HTTP 000"
  run "$WD"
  [ "$status" -eq 0 ]
  [ -z "$(sends)" ]
  [[ "$output" == *"WARN"* ]]
  [ ! -e "$MERCURY_ALERT_STATE" ]
}

# A run of "can't tell" is silence, and silence for weeks is the original
# failure. One blip must stay quiet; a streak must not.
@test "rc=2 below the threshold stays quiet but counts" {
  stub_detector 2 "cannot evaluate: unexpected HTTP 000"
  run "$WD"
  [ -z "$(sends)" ]
  [ "$(cat "$MERCURY_UNKNOWN_STATE")" = "1" ]
  run "$WD"
  [ -z "$(sends)" ]
  [ "$(cat "$MERCURY_UNKNOWN_STATE")" = "2" ]
}

@test "rc=2 at the threshold escalates with UNKNOWN wording, not 'token is dead'" {
  stub_detector 2 "cannot evaluate: unexpected HTTP 000"
  run "$WD"; run "$WD"; run "$WD"
  [[ "$(sends)" == *"health UNKNOWN"* ]]
  [[ "$(sends)" != *"Mercury API token is dead"* ]]
  [[ "$(sends)" == *"<@U0AL36NADEY>"* ]]
}

# The inverted-ladder regression: "we don't know" paging must not silence the
# "we now know, it is revoked" page that follows it.
@test "an UNKNOWN page does not suppress the REVOKED page that follows" {
  stub_detector 2 "cannot evaluate"
  run "$WD"; run "$WD"; run "$WD"          # escalates to the UNKNOWN page
  [[ "$(sends)" == *"health UNKNOWN"* ]]
  stub_detector 1 "token REJECTED by Mercury (HTTP 401)"
  run "$WD"                                 # the answer arrives, same window
  [[ "$output" != *"page suppressed"* ]]
  [ "$(send_count)" -eq 1 ]                 # the definitive page DID go out
}

# A persistently broken checker is "nobody knows if the bank token works" —
# the same silence rc=2 streaks exist to end, so it must escalate too.
@test "a missing detector escalates after the threshold instead of staying silent" {
  rm -f "$MERCURY_TOKEN_CHECK"
  run "$WD"; run "$WD"
  [ -z "$(sends)" ]                         # quiet below the threshold
  run "$WD"
  [[ "$(sends)" == *"health UNKNOWN"* ]]
  [[ "$(sends)" == *"detector missing"* ]]
  [[ "$(sends)" != *"Mercury API token is dead"* ]]
}

@test "an unexpected detector rc escalates after the threshold too" {
  stub_detector 127 ""
  run "$WD"; run "$WD"; run "$WD"
  [[ "$(sends)" == *"health UNKNOWN"* ]]
  [[ "$(sends)" == *"unexpected rc=127"* ]]
}

# If the streak cannot persist, the counter is a no-op: every tick re-reads 0,
# records 1, and never reaches the threshold. Counting toward a number you can
# never reach is indistinguishable from not watching at all.
@test "an unpersistable streak path escalates immediately instead of counting forever" {
  : > "$TEST_TMPDIR/blocked"                       # a FILE, so mkdir -p under it fails even as root
  export MERCURY_UNKNOWN_STATE="$TEST_TMPDIR/blocked/streak"
  stub_detector 2 "cannot evaluate: unexpected HTTP 000"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot persist"* ]]
  [[ "$(sends)" == *"health UNKNOWN"* ]]           # paged on the FIRST tick
  [[ "$(sends)" == *"persistence FAILED"* ]]       # and says why
}

# The pair: when the path IS writable, one blip must still stay quiet.
@test "a persistable streak still waits for the threshold" {
  stub_detector 2 "cannot evaluate: unexpected HTTP 000"
  run "$WD"
  [ -z "$(sends)" ]
  [ "$(cat "$MERCURY_UNKNOWN_STATE")" = "1" ]
}

@test "a real verdict resets the unknown streak" {
  stub_detector 2 "cannot evaluate"
  run "$WD"; run "$WD"
  [ "$(cat "$MERCURY_UNKNOWN_STATE")" = "2" ]
  stub_detector 1 "token REJECTED by Mercury (HTTP 401)"
  run "$WD"
  [ ! -e "$MERCURY_UNKNOWN_STATE" ]
  stub_detector 0 "clean"
  run "$WD"
  [ ! -e "$MERCURY_UNKNOWN_STATE" ]
}

@test "--dry-run does not advance the unknown streak either" {
  stub_detector 2 "cannot evaluate"
  run "$WD" --dry-run
  [ ! -e "$MERCURY_UNKNOWN_STATE" ]
  [ -z "$(sends)" ]
}

# A broken detector is not a statement about the credential. Paging "the bank
# token is dead" because the checker has a bad shebang sends Nick and Aaron to
# the Mercury dashboard for nothing, with an empty diagnostic.
@test "an unexpected detector rc (127) warns and does NOT page" {
  stub_detector 127 ""
  run "$WD"
  [ "$status" -eq 0 ]
  [ -z "$(sends)" ]
  [[ "$output" == *"unexpected rc=127"* ]]
  [ ! -e "$MERCURY_ALERT_STATE" ]
}

@test "detector rc=126 (not executable) also warns rather than paging" {
  stub_detector 126 ""
  run "$WD"
  [ -z "$(sends)" ]
  [[ "$output" == *"unexpected rc=126"* ]]
}

# Without this, a break -> fix -> re-revoke cycle inside the cooldown window is
# silently suppressed — the exact class of miss this watchdog exists to end.
@test "recovery clears the cooldown so a later re-revocation pages at once" {
  run "$WD"                                   # page #1, stamp written
  [ -s "$MERCURY_ALERT_STATE" ]
  stub_detector 0 "clean: token works"
  run "$WD"                                   # recovered
  [ ! -e "$MERCURY_ALERT_STATE" ]             # stamp cleared
  stub_detector 1 "token REJECTED by Mercury (HTTP 401)"
  run "$WD"                                   # revoked again, same day
  [[ "$output" != *"page suppressed"* ]]
  [ "$(send_count)" -eq 2 ]
}

@test "missing detector is reported, not silently treated as clean" {
  rm -f "$MERCURY_TOKEN_CHECK"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"detector missing"* ]]
  [ -z "$(sends)" ]
}

# ── the page itself ───────────────────────────────────────────────────────────

@test "the page pings real UIDs, not literal @names" {
  run "$WD"
  [[ "$(sends)" == *"<@U0AL36NADEY>"* ]]   # Nick
  [[ "$(sends)" == *"<@U7RP6HKUZ>"* ]]     # Aaron
}

# A wrong channel id is a SILENT no-alarm loop in prod: muso exits non-zero,
# the cooldown never advances, and it retries daily forever without ever
# reaching anyone — indistinguishable from the outage it is watching.
@test "the page goes to #clio_devops specifically" {
  run "$WD"
  [[ "$(sends)" == *"--channel C0ADV2W76G4"* ]]
}

# $out is the only diagnostic the reader gets; dropping it leaves a page that
# says something is wrong without saying what.
@test "the detector diagnostic reaches the page body" {
  stub_detector 1 "SENTINEL-401-DIAGNOSTIC"
  run "$WD"
  [[ "$(sends)" == *"SENTINEL-401-DIAGNOSTIC"* ]]
}

@test "the page carries the remediation path and the credential location" {
  run "$WD"
  [[ "$(sends)" == *"/opt/hydra/secrets/mercury.env"* ]]
  [[ "$(sends)" == *"read-only"* ]]
}

# ── cooldown ──────────────────────────────────────────────────────────────────

@test "a second violation inside the interval is suppressed" {
  run "$WD"
  [ "$(send_count)" -eq 1 ]
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"page suppressed"* ]]
  [ "$(send_count)" -eq 1 ]            # still ONE send, not two
}

# The pair to the suppression test — dedupe must expire, or a real 8-week
# outage would page exactly once and then go quiet forever.
@test "a violation after the interval elapses pages again" {
  run "$WD"
  printf '0' > "$MERCURY_ALERT_STATE"   # last page at the epoch
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"page suppressed"* ]]
  [ "$(send_count)" -eq 2 ]
}

@test "a corrupt state file is treated as 'never paged', not as a fresh page" {
  printf 'garbage' > "$MERCURY_ALERT_STATE"
  run "$WD"
  [ "$status" -eq 0 ]
  [ "$(send_count)" -eq 1 ]
}

# The hazard slack-notify.sh documents the status-aware variant for: a failed
# post must not mark the incident "already paged" and go quiet for 20h.
@test "a FAILED Slack post does NOT advance the cooldown" {
  stub_muso 1
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack post FAILED"* ]]
  [ ! -e "$MERCURY_ALERT_STATE" ]
}

@test "after a failed post, the next tick retries instead of suppressing" {
  stub_muso 1
  run "$WD"
  [ ! -e "$MERCURY_ALERT_STATE" ]
  stub_muso 0
  run "$WD"
  [[ "$output" != *"page suppressed"* ]]
  [ -s "$MERCURY_ALERT_STATE" ]
}

# ── host guard ────────────────────────────────────────────────────────────────

@test "host guard blocks off node-8, BEFORE invoking the detector" {
  stub_hostname "ci-runner-not-node8"
  unset MERCURY_SKIP_HOST_GUARD
  # Detector that would prove it ran by leaving a marker.
  cat > "$MERCURY_TOKEN_CHECK" <<EOF
#!/usr/bin/env bash
touch "$TEST_TMPDIR/DETECTOR-RAN"
exit 1
EOF
  chmod +x "$MERCURY_TOKEN_CHECK"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to run"* ]]
  [ -z "$(sends)" ]
  [ ! -e "$TEST_TMPDIR/DETECTOR-RAN" ]   # no live bank call off node-8
}

# Asserting only the blocked direction would pass just as well if the guard were
# hard-wired to refuse everything.
@test "host guard lets the run through ON ovh-node-8" {
  stub_hostname "ovh-node-8"
  unset MERCURY_SKIP_HOST_GUARD
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing to run"* ]]
  [ "$(send_count)" -eq 1 ]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run reports the violation but posts nothing" {
  run "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"VIOLATION"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [ -z "$(sends)" ]
}

# Deliberately unlike stuck-lane/prod-log-alert, whose --dry-run advances their
# watermarks: advancing the cooldown here would let a rehearsal silence the next
# real page for 20h.
@test "--dry-run does NOT advance the cooldown (a rehearsal can't mute the alarm)" {
  run "$WD" --dry-run
  [ ! -e "$MERCURY_ALERT_STATE" ]
  run "$WD"
  [ "$(send_count)" -eq 1 ]            # the real page still goes out
}

@test "unknown argument → exit 2" {
  run "$WD" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
