#!/usr/bin/env bats
# Tests for scripts/intercom-webhook-retire.sh.
#
# Plan step 6 retires the loopback receiver "after 7 days of 0 hits confirmed" —
# so the retirement must rest on a MEASURED window, not a recollection. The
# script's whole job is that measurement plus a reversible removal.
#
# Three outcomes are load-bearing here and each has a test:
#   hits > 0        → NOT READY (never retire a receiver still taking traffic)
#   hits == 0       → READY (retire allowed)
#   nothing at all  → CANNOT MEASURE, which is NOT "0 hits" and must refuse.
#
# Everything runs in a throwaway tree. `journalctl`, `systemctl` and `id` are
# stubbed on PATH: `id` returns 0 so the root guard is satisfied WITHOUT giving
# the test any real privilege (the removals are all inside the temp dir), and
# `systemctl` records what was asked so we can assert the unit was actually
# stopped and disabled.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../intercom-webhook-retire.sh"
    [[ -f "$SCRIPT" ]] || { echo "retire script not found: $SCRIPT" >&2; return 1; }

    export INTERCOM_WEBHOOK_UNIT_DIR="$TEST_ROOT/systemd"
    export INTERCOM_WEBHOOK_UNIT_PATH="$TEST_ROOT/systemd/intercom-webhook.service"
    export INTERCOM_WEBHOOK_DROPIN_DIR="$TEST_ROOT/systemd/intercom-webhook.service.d"
    export INTERCOM_WEBHOOK_ENV_FILE="$TEST_ROOT/etc/intercom-webhook.env"
    export INTERCOM_WEBHOOK_RETIRE_DIR="$TEST_ROOT/var/intercom-webhook"
    unset INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL

    mkdir -p "$INTERCOM_WEBHOOK_UNIT_DIR/intercom-webhook.service.d" \
             "$TEST_ROOT/etc" "$TEST_ROOT/bin" "$INTERCOM_WEBHOOK_RETIRE_DIR"
    printf '[Service]\nEnvironmentFile=-%s\n' "$INTERCOM_WEBHOOK_ENV_FILE" > "$INTERCOM_WEBHOOK_UNIT_PATH"
    printf 'INTERCOM_TOKEN=fixture-token\n' > "$INTERCOM_WEBHOOK_ENV_FILE"
    printf '[Service]\nEnvironment=INTERCOM_TOKEN=fixture-token\n' > "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf"

    cat > "$TEST_ROOT/bin/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in -u) echo 0 ;; *) /usr/bin/id "$@" ;; esac
EOF
    # systemctl stub: state comes from $TEST_ROOT/active_state (default
    # "inactive"); `stop` clears it unless $TEST_ROOT/stop_fails exists. The
    # retire path now REQUIRES a successful stop and an inactive unit before it
    # touches a single file, so the stub has to model both.
    printf 'inactive' > "$TEST_ROOT/active_state"
    cat > "$TEST_ROOT/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TEST_ROOT/systemctl.log"
case "\$1" in
  is-active) [ -f "$TEST_ROOT/is_active_silent" ] && exit 0; cat "$TEST_ROOT/active_state" ; echo ;;
  is-enabled) if [ -f "$TEST_ROOT/enabled" ]; then echo enabled; exit 0; fi
              if [ -f "$TEST_ROOT/is_enabled_silent" ]; then exit 1; fi
              echo disabled; exit 1 ;;
  stop) [ -f "$TEST_ROOT/stop_fails" ] && exit 1
        [ -f "$TEST_ROOT/stop_noop" ] || printf 'inactive' > "$TEST_ROOT/active_state"; exit 0 ;;
  disable) [ -f "$TEST_ROOT/disable_fails" ] && exit 1; rm -f "$TEST_ROOT/enabled"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_ROOT/bin/id" "$TEST_ROOT/bin/systemctl"

    # journalctl prints whatever the test staged in journal.out.
    : > "$TEST_ROOT/journal.out"
    cat > "$TEST_ROOT/bin/journalctl" <<EOF
#!/usr/bin/env bash
echo "journalctl \$*" >> "$TEST_ROOT/journalctl.log"
case "\$*" in
  # retention probe: newest entry BEFORE the window. A file with contents means
  # the journal reaches back past the window start.
  *--until*) [ -f "$TEST_ROOT/retains_history" ] && cat "$TEST_ROOT/retains_history" ;;
  *"-o json"*) [ -f "$TEST_ROOT/unit_first.json" ] && cat "$TEST_ROOT/unit_first.json" ;;
  *) cat "$TEST_ROOT/journal.out" ;;
esac
EOF
    chmod +x "$TEST_ROOT/bin/journalctl"
    # default: the journal reaches back past the window (the honest, common case)
    printf '{"__REALTIME_TIMESTAMP":"1700000000000000"}\n' > "$TEST_ROOT/retains_history"

    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

stage_journal_startup_only() {
    cat > "$TEST_ROOT/journal.out" <<'EOF'
[intercom-webhook] listening on 127.0.0.1:18792
[intercom-webhook] OpenClaw: http://localhost:18789 | bot: configured | workspace: configured
EOF
}

stage_journal_with_traffic() {
    cat > "$TEST_ROOT/journal.out" <<'EOF'
[intercom-webhook] listening on 127.0.0.1:18792
[intercom-webhook] OpenClaw: http://localhost:18789 | bot: configured | workspace: configured
[intercom-webhook] conversation.user.replied conv=abc123 event=evt_1
EOF
}

@test "READY on a window with 0 inbound events (startup lines do not count)" {
    stage_journal_startup_only
    run bash "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"READY: 0 inbound events"* ]]
}

@test "NOT READY when the receiver handled an event in the window" {
    stage_journal_with_traffic
    run bash "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT READY: 1 inbound event"* ]]
}

@test "CANNOT MEASURE (rc 2) when journald has no window to look at" {
    : > "$TEST_ROOT/journal.out"
    run bash "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT MEASURE"* ]]
}

@test "CANNOT MEASURE (rc 2) when journald is unavailable" {
    rm -f "$TEST_ROOT/bin/journalctl"
    cat > "$TEST_ROOT/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_ROOT/bin/journalctl"
    run bash "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT MEASURE"* ]]
}

@test "--retire REFUSES while traffic is present, and changes nothing" {
    stage_journal_with_traffic
    run bash "$SCRIPT" --retire
    [ "$status" -eq 1 ]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    [ -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l"
    [ "$output" -eq 0 ]
    run bash -c "grep -c 'disable' '$TEST_ROOT/systemctl.log' 2>/dev/null | head -1"
    [ "${output:-0}" = "0" ]
}

@test "--retire REFUSES when it cannot measure" {
    : > "$TEST_ROOT/journal.out"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
}

@test "--retire stops + disables the unit, removes it, and keeps everything for a revert" {
    stage_journal_startup_only
    run bash "$SCRIPT" --retire
    [ "$status" -eq 0 ]
    [[ "$output" == *"RETIRED"* ]]
    # stop and disable are now SEPARATE, ordered calls, and both must have run
    # BEFORE any file was touched (QA Important b).
    run grep 'stop intercom-webhook.service' "$TEST_ROOT/systemctl.log"
    [ "$status" -eq 0 ]
    run grep 'disable intercom-webhook.service' "$TEST_ROOT/systemctl.log"
    [ "$status" -eq 0 ]
    # unit + drop-in gone from the load path
    [ ! -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    [ ! -d "$INTERCOM_WEBHOOK_DROPIN_DIR" ]
    # ...and preserved for revert, 0600
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/retired/ | grep -c 'intercom-webhook.service.retired-'"
    [ "$output" = "1" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/retired/ | grep -c 'env.conf.retired-'"
    [ "$output" = "1" ]
    # the secret file dies with the unit (moved, not deleted)
    [ ! -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/retired/ | grep -c 'intercom-webhook.env.retired-'"
    [ "$output" = "1" ]
    # durable marker records the proof
    run bash -c "cat '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"inbound_events":0'* ]]
    [[ "$output" == *'"days_measured":7'* ]]
}

@test "a second --retire is a no-op: the marker short-circuits it" {
    stage_journal_startup_only
    run bash "$SCRIPT" --retire
    [ "$status" -eq 0 ]
    : > "$TEST_ROOT/systemctl.log"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 0 ]
    [[ "$output" == *"already retired"* ]]
    run bash -c "wc -l < '$TEST_ROOT/systemctl.log' | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--check reports 'already retired' and does not re-measure" {
    stage_journal_startup_only
    run bash "$SCRIPT" --retire
    [ "$status" -eq 0 ]
    : > "$TEST_ROOT/journalctl.log"
    run bash "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"already retired"* ]]
    run bash -c "wc -l < '$TEST_ROOT/journalctl.log' | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--days is passed to the measurement window and validated" {
    stage_journal_startup_only
    run bash "$SCRIPT" --check --days 3
    [ "$status" -eq 0 ]
    run grep -- '--since 3 days ago' "$TEST_ROOT/journalctl.log"
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" --check --days three
    [ "$status" -eq 2 ]
    [[ "$output" == *"--days must be a positive integer"* ]]
}

# ── the seven-day proof cannot be shortened at the retire call site (QA r6) ────
# `--retire --days 1` used to be honoured: a receiver that handled an event two
# days ago but none yesterday measured 0 hits over 1 day, printed READY, was
# stopped and removed, and left a durable RETIRED-*.json marker that every later
# deploy honours. The proof is the plan's seven days or it is not a proof — the
# window may only be shortened for the READ-ONLY --check diagnostic.

@test "--retire REFUSES a 1-day window and changes nothing at all" {
    stage_journal_startup_only
    run bash "$SCRIPT" --retire --days 1
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSING to retire on a 1-day window"* ]]
    [[ "$output" == *"at least 7 days"* ]]
    # it must refuse BEFORE measuring or touching anything: no unit removal,
    # no journald window, no systemctl call, no marker.
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    [ -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    [ ! -s "$TEST_ROOT/systemctl.log" ]
    [ ! -s "$TEST_ROOT/journalctl.log" ]
    run bash -c "find '$INTERCOM_WEBHOOK_RETIRE_DIR' -maxdepth 1 -name 'RETIRED-*.json' | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--retire REFUSES a 6-day window (one short of the proof)" {
    stage_journal_startup_only
    run bash "$SCRIPT" --retire --days 6
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSING to retire on a 6-day window"* ]]
    run bash -c "find '$INTERCOM_WEBHOOK_RETIRE_DIR' -maxdepth 1 -name 'RETIRED-*.json' | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "INTERCOM_WEBHOOK_RETIRE_DAYS cannot shorten the retire proof either" {
    stage_journal_startup_only
    INTERCOM_WEBHOOK_RETIRE_DAYS=2 run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSING to retire on a 2-day window"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    run bash -c "find '$INTERCOM_WEBHOOK_RETIRE_DIR' -maxdepth 1 -name 'RETIRED-*.json' | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--days 0 is rejected in both modes: a zero-day window measures nothing" {
    stage_journal_startup_only
    run bash "$SCRIPT" --check --days 0
    [ "$status" -eq 2 ]
    [[ "$output" == *"--days must be at least 1"* ]]
    run bash "$SCRIPT" --retire --days 0
    [ "$status" -eq 2 ]
    [[ "$output" == *"--days must be at least 1"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
}

@test "a zero-padded --days 007 means seven days, and the retire path accepts it" {
    # bash arithmetic reads 010 as octal 8 and 08 as an error, so a padded window
    # must be normalised with 10# before it is used or compared.
    stage_journal_startup_only
    run bash "$SCRIPT" --check --days 007
    [ "$status" -eq 0 ]
    run grep -- '--since 7 days ago' "$TEST_ROOT/journalctl.log"
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" --retire --days 007
    [ "$status" -eq 0 ]
}

@test "--check still accepts a short window (the diagnostic the refusal points at)" {
    stage_journal_startup_only
    run bash "$SCRIPT" --check --days 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"READY: 0 inbound events in the last 1 day(s)"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
}

# ── retire must never report done while the process runs (QA Important b) ─────

@test "--retire REFUSES when stop fails and the unit is still active; nothing is removed" {
    stage_journal_startup_only
    printf 'active' > "$TEST_ROOT/active_state"
    : > "$TEST_ROOT/stop_fails"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSING to retire"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    [ -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--retire REFUSES when stop 'succeeds' but the unit reports active anyway" {
    stage_journal_startup_only
    printf 'active' > "$TEST_ROOT/active_state"
    : > "$TEST_ROOT/stop_noop"   # stop returns 0 but the process survives
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"is 'active' after stop"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--retire REFUSES when disable fails and the unit stays enabled" {
    stage_journal_startup_only
    : > "$TEST_ROOT/enabled"
    : > "$TEST_ROOT/disable_fails"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"reports 'enabled'"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--retire REFUSES when systemctl is unavailable (cannot prove it stopped)" {
    # `rm`-ing the stub is not enough: node-8 has a real /usr/bin/systemctl later
    # on PATH, so this passed on a laptop and failed in CI. Point the script's
    # SYSTEMCTL knob at a path that does not exist instead.
    stage_journal_startup_only
    SYSTEMCTL="$TEST_ROOT/no-such-systemctl" run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot be stopped"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "CANNOT MEASURE when the journal does not reach back past the window" {
    stage_journal_startup_only
    rm -f "$TEST_ROOT/retains_history"          # nothing older than the window
    # ...and the unit itself has entries from BEFORE the window
    printf '{"__REALTIME_TIMESTAMP":"1600000000000000"}\n' > "$TEST_ROOT/unit_first.json"
    run bash "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"were not all observed"* ]]
}

@test "CANNOT MEASURE when only a recent retained line remains (the vacuumed-journal fixture)" {
    # QA's reproduction: journal vacuumed a day ago, so the receiver's first
    # RETAINED line is one day old. That is proof of what the journal holds, not
    # of when the unit started — six of seven days were never observed, so this
    # must never read as 0 hits (Fable r5 QA Important, carried).
    stage_journal_startup_only
    rm -f "$TEST_ROOT/retains_history"
    printf '{"__REALTIME_TIMESTAMP":"1793000000000000"}\n' > "$TEST_ROOT/unit_first.json"
    run bash "$SCRIPT" --check --days 7
    [ "$status" -eq 2 ]
    [[ "$output" == *"were not all observed"* ]]
}

@test "--retire REFUSES on a truncated journal window even with 0 hits" {
    stage_journal_startup_only
    rm -f "$TEST_ROOT/retains_history"
    printf '{"__REALTIME_TIMESTAMP":"1600000000000000"}\n' > "$TEST_ROOT/unit_first.json"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "the retired marker records that coverage AND the stop were verified" {
    stage_journal_startup_only
    run bash "$SCRIPT" --retire
    [ "$status" -eq 0 ]
    run bash -c "cat '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json"
    [[ "$output" == *'"coverage_verified_before_remove":true'* ]]
    [[ "$output" == *'"stopped_before_remove":true'* ]]
}

@test "--retire REFUSES when is-active answers NOTHING after stop (unknown is not stopped)" {
    stage_journal_startup_only
    : > "$TEST_ROOT/is_active_silent"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"returned NOTHING"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    [ -f "$INTERCOM_WEBHOOK_ENV_FILE" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--retire REFUSES when is-active reports the literal state 'unknown'" {
    stage_journal_startup_only
    printf 'unknown' > "$TEST_ROOT/active_state"
    : > "$TEST_ROOT/stop_noop"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"is 'unknown' after stop"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
}

@test "--retire REFUSES when is-enabled answers NOTHING (empty is not 'disabled')" {
    # QA new/carried finding: an empty is-enabled answer matched the accept
    # branch, so a failed disable could still remove the unit and write a marker.
    stage_journal_startup_only
    : > "$TEST_ROOT/is_enabled_silent"
    : > "$TEST_ROOT/enabled"          # it IS enabled, and the host cannot say so
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"is-enabled returned NOTHING"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]
    [ -f "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf" ]
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "--retire REFUSES and KEEPS every original when a drop-in backup cannot be written" {
    # QA new finding: a swallowed backup failure was followed by deleting the only
    # revert copy. Fail the BACKUP installs only (a PATH stub, so this behaves the
    # same as root in CI and as a normal user locally), and assert the originals
    # survive and no marker is written.
    stage_journal_startup_only
    local real_install
    real_install="$(command -v install)"
    cat > "$TEST_ROOT/bin/install" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in */retired/*) exit 1 ;; esac
done
exec "$real_install" "\$@"
STUB
    chmod +x "$TEST_ROOT/bin/install"
    run bash "$SCRIPT" --retire
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not back up"* ]]
    [ -f "$INTERCOM_WEBHOOK_UNIT_PATH" ]              # original kept
    [ -f "$INTERCOM_WEBHOOK_DROPIN_DIR/env.conf" ]    # original kept
    run bash -c "ls '$INTERCOM_WEBHOOK_RETIRE_DIR'/RETIRED-*.json 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}
