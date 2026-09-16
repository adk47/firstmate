#!/usr/bin/env bats
# scripts/notify-unit-failed.sh — the OnFailure= target for hydra oneshot units
# (hydra-unit-failed@.service). journalctl, systemctl and the muso Slack CLI are
# stubbed on PATH; delivery runs through the REAL lib/deploy-notify.sh so the
# status-returning contract is what is under test. Nothing here can reach a
# real unit or Slack.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/notify-unit-failed.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"
  export NOTIFY_UNIT_FAILED_MARKER_DIR="$TEST_TMPDIR/markers"
  export HYDRA_SELF_PAGED_DIR="$TEST_TMPDIR/self-paged"
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/bin/bash
if [[ "\$*" == *"slack send"* ]]; then echo "\$*" >> "$PAGE_LOG"; fi
exit "\${STUB_MUSO_RC:-0}"
STUB
  # $STUB_JOURNAL_RECOVERED makes a `--since` query report a successful
  # completion, which is how the episode-scoped cooldown sees a recovery.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/bin/bash
# A --since query is the recovery probe. It MUST carry _PID=1, or it is
# reading the service's own stdout as well as systemd's lifecycle lines.
# Without the field match this stub emits exactly the kind of service output
# that a bare "Finished " match would wrongly accept.
_since=; _pid1=
for a in "$@"; do
  case "$a" in
    --since*) _since=1 ;;
    _PID=1)   _pid1=1 ;;
  esac
done
if [ -n "$_since" ]; then
  if [ -z "$_pid1" ]; then
    echo "worker[main]: Finished processing batch 7"      # service stdout, NOT systemd
    exit 0
  fi
  # $STUB_JOURNAL_DESC_TRAP emits a systemd FAILURE line whose unit
  # DESCRIPTION contains the word "Finished" -- it passes _PID=1 because
  # systemd wrote it, and only the ^ anchor keeps it from reading as success.
  if [ -n "${STUB_JOURNAL_DESC_TRAP:-}" ]; then
    echo "some-unit.service: Failed to start Finished nightly report."
    exit 0
  fi
  # The mirror trap for the OTHER alternative: a unit whose DESCRIPTION contains
  # "Deactivated successfully", failing to start. systemd wrote it, so _PID=1
  # cannot help; only the ": …\.$" anchor rejects it.
  if [ -n "${STUB_JOURNAL_DEACT_TRAP:-}" ]; then
    echo "some-unit.service: Failed to start Deactivated successfully report."
    exit 0
  fi
  [ -n "${STUB_JOURNAL_RECOVERED:-}" ] && echo "Finished some-unit.service - Some Unit."
  exit 0
fi
printf 'line one for %s\nfatal: node not found\n' "$2"
STUB
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/bash
echo "exit-code"
STUB
  chmod +x "$TEST_TMPDIR/bin/"*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  # Hermeticity: CI runs on a credentialed host where the bot token is already
  # EXPORTED, and slack_load_env honours that before reading the env file — so
  # the missing-token test only covers its path if the inherited var is gone.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/slack.env"
  printf 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test\n' > "$MUSO_SLACK_ENV_FILE"
  # The per-unit cooldown defaults to /var/lib/hydra/unit-failed-cooldown, and
  # CI runs these as ROOT — so without this pin the suite would stamp the REAL
  # production cooldown and, worse, the first test would suppress every later
  # one that pages the same unit.
  export NOTIFY_UNIT_FAILED_COOLDOWN_DIR="$TEST_TMPDIR/cooldown"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "pages CRITICAL (real mentions) with the unit name, Result and journal tail; exits 0; no marker" {
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"<@U"* ]]
  [[ "$page" == *"systemd unit FAILED"* ]]
  [[ "$page" == *"codex-edge-mirror.service"* ]]
  [[ "$page" == *"Result=exit-code"* ]]
  [[ "$page" == *"fatal: node not found"* ]]
  [ ! -d "$NOTIFY_UNIT_FAILED_MARKER_DIR" ]
}

@test "a REJECTED Slack delivery is surfaced: exit non-zero, journal line, marker file naming the unit" {
  STUB_MUSO_RC=1 run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -ne 0 ]
  [[ "$output" == *"PAGE NOT DELIVERED for codex-edge-mirror.service"* ]]
  [[ "$output" == *"UNALERTED"* ]]
  marker="$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror.service.*.unpaged | head -1)"
  [ -s "$marker" ]
  [[ "$(basename "$marker")" =~ ^codex-edge-mirror\.service\.[0-9]+\.[0-9]+\.unpaged$ ]]   # one record per spool file, renamed into place
  [ "$(grep -c . "$marker")" -eq 1 ]
  [[ "$(cat "$marker")" == *"codex-edge-mirror.service"*"deploy-notify.sh exited 1"* ]]
  run ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"
  [[ "$output" != *".tmp"* ]]
}

@test "a MISSING token is a failed delivery too (deploy-notify returns non-zero), not a silent 0" {
  rm -f "$MUSO_SLACK_ENV_FILE"
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -ne 0 ]
  [ -n "$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror.service.*.unpaged 2>/dev/null)" ]
  [ ! -f "$PAGE_LOG" ]
}

@test "a missing deploy-notify.sh leaves the trace and exits non-zero" {
  DEPLOY_NOTIFY_BIN="$TEST_TMPDIR/nope.sh" run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -ne 0 ]
  [ -n "$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror.service.*.unpaged 2>/dev/null)" ]
}

@test "no unit argument is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# ── one pager per failure (OnFailure= handler vs the script's own page) ──────

@test "self-paged: a FRESH stamp from the unit's own script → the handler skips (no second page, exit 0)" {
  mkdir -p "$HYDRA_SELF_PAGED_DIR"; date -u +%s > "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service"
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"paged for its own failure"*"not paging it a second time"* ]]
  [ ! -f "$PAGE_LOG" ]
}

@test "self-paged: a STALE stamp (older than the window) does not suppress the handler" {
  mkdir -p "$HYDRA_SELF_PAGED_DIR"; printf '%s' "$(( $(date -u +%s) - 600 ))" > "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service"
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [[ "$(cat "$PAGE_LOG")" == *"systemd unit FAILED"* ]]
}

@test "end-to-end single page: the REAL mirror fails under --restart (pages + stamps), then the OnFailure handler runs → exactly ONE page" {
  # the real mirror, real deploy-notify, muso stubbed: a structural failure (edge store absent)
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"; mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$CODEX_AUTH_ROOT/.openclaw-edge/state"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "OpenClaw 2026.8.2 (test)"; exit 0; }; exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export CODEX_MIRROR_STATE_DIR="$TEST_TMPDIR/mirror-state" HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-window"
  printf '#!/bin/bash\ndrain_restart_gateway() { return 0; }\n' > "$TEST_TMPDIR/restart-stub.sh"; export CODEX_MIRROR_RESTART_LIB="$TEST_TMPDIR/restart-stub.sh"
  run "$HYDRA_REPO/scripts/lib/codex-edge-mirror.sh" --restart
  [ "$status" -eq 2 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
  [ -s "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  # systemd now runs OnFailure=hydra-unit-failed@codex-edge-mirror.service
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
}

@test "end-to-end fallback: the REAL mirror fails under --restart with delivery AND spool both failing → no stamp → the OnFailure handler DOES page" {
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"; mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$CODEX_AUTH_ROOT/.openclaw-edge/state"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "OpenClaw 2026.8.2 (test)"; exit 0; }; exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export CODEX_MIRROR_STATE_DIR="$TEST_TMPDIR/mirror-state" HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-window"
  printf '#!/bin/bash\ndrain_restart_gateway() { return 0; }\n' > "$TEST_TMPDIR/restart-stub.sh"; export CODEX_MIRROR_RESTART_LIB="$TEST_TMPDIR/restart-stub.sh"
  : > "$NOTIFY_UNIT_FAILED_MARKER_DIR"          # spool unwritable (a file in its place)
  STUB_MUSO_RC=1 run "$HYDRA_REPO/scripts/lib/codex-edge-mirror.sh" --restart   # delivery fails too
  [ "$status" -eq 2 ]
  [ ! -e "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  rm -f "$PAGE_LOG"; rm -f "$NOTIFY_UNIT_FAILED_MARKER_DIR"
  # systemd now runs OnFailure=hydra-unit-failed@codex-edge-mirror.service, and Slack is back
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [[ "$(cat "$PAGE_LOG")" == *"systemd unit FAILED"*"codex-edge-mirror.service"* ]]
}

# ── per-unit cooldown ───────────────────────────────────────────────────────
# What makes this handler safe to wire to every timer-driven oneshot.
# hydra-release-watch.timer fires every 5 minutes and has been failing since
# 2026-09-07, so an uncooled OnFailure= would page ~288 times a day. The repo
# has already learned this once: a standing finding re-paged on every trigger
# produced 17 alerts in one day and trained everyone to ignore the channel.
@test "cooldown: a second failure of the SAME unit inside the window does not re-page" {
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"within the"*"cooldown"* ]]
  # still exactly one page delivered
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "cooldown: a DIFFERENT unit is never suppressed by another unit's stamp" {
  run "$SCRIPT" unit-a.service
  [ "$status" -eq 0 ]
  run "$SCRIPT" unit-b.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "cooldown: an EXPIRED stamp pages again (a standing failure is not forgotten)" {
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  # backdate the stamp past the window
  echo "$(( $(date -u +%s) - 1441 * 60 ))" > "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service"
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "cooldown: 0 disables it entirely" {
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=0 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=0 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "cooldown FAILS OPEN: a non-numeric COOLDOWN_MIN pages rather than suppressing" {
  # This is what the `[ "$COOLDOWN_MIN" -gt 0 ]` guard actually protects. A
  # literal 0 needs no guard (the age comparison can never be true), so a test
  # using 0 leaves the guard unfalsifiable -- measured: removing it changes
  # nothing for 0, but turns "abc" from two pages into one silently suppressed
  # page, because $((abc * 60)) is an arithmetic error and the script runs
  # under `set -uo pipefail` without -e.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=abc run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=abc run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  # Assert the SUPPRESSION line is absent, not the word "cooldown": the
  # rejected-value notice legitimately contains that word now, and a test that
  # keys on the substring would fail for the wrong reason.
  [[ "$output" != *"within the"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "cooldown FAILS OPEN: an unparseable stamp pages rather than suppressing" {
  # A missed page is an outage; the storm this bounds is only noise. So every
  # unreadable/garbage/clock-skewed stamp must resolve to "page".
  mkdir -p "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR"
  printf 'not-a-timestamp\n' > "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service"
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "cooldown FAILS OPEN: a future-dated stamp (clock skew) pages" {
  mkdir -p "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR"
  echo "$(( $(date -u +%s) + 9999 ))" > "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service"
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
  # one delivered page == one "systemd unit FAILED" header; the stub logs
  # the whole multi-line message, so counting LINES over-counts.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "cooldown: a REJECTED delivery does NOT start a cooldown (the retry must survive)" {
  # A failed delivery leaves a spool marker for cron-health-watchdog to chase.
  # Stamping a cooldown here would suppress exactly the retry that marker is
  # for, so the failure would be both unpaged AND unrepeatable.
  STUB_MUSO_RC=1 run "$SCRIPT" some-unit.service
  [ "$status" -ne 0 ]
  [ ! -e "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service" ]
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
}

@test "cooldown is EPISODE-scoped: fail -> success -> fail pages the second incident" {
  # QA finding on this PR. Keyed on time alone, a unit that fails, recovers,
  # then breaks again from an unrelated regression has that SECOND incident
  # suppressed for the rest of the window. A recovery ends the episode.
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
  [ -e "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service" ]

  # ...the unit succeeds in between, then fails again INSIDE the 24h window.
  STUB_JOURNAL_RECOVERED=1 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered since the last page"*"NEW incident"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "a CONTINUOUS failure episode is still suppressed (no recovery in the journal)" {
  # The discriminator for the test above: same window, no success line, so this
  # is the same incident and must stay quiet.
  run "$SCRIPT" some-unit.service
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"within the"*"cooldown"* ]]
  [[ "$output" != *"recovered since"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "a recovery CLEARS the stamp, so the next episode starts a fresh window" {
  run "$SCRIPT" some-unit.service
  STUB_JOURNAL_RECOVERED=1 run "$SCRIPT" some-unit.service
  # the recovery page re-stamped; a further failure with no new recovery is a
  # repeat of THAT episode and must be quiet again.
  run "$SCRIPT" some-unit.service
  [[ "$output" == *"within the"*"cooldown"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "recovery detection FAILS OPEN: an unreadable journal pages" {
  # journalctl failing must not be the reason a real failure goes unreported.
  run "$SCRIPT" some-unit.service
  rm -f "$TEST_TMPDIR/bin/journalctl"
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/journalctl"
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "a recovery clears the stamp even when the page DELIVERY fails" {
  # Why the rm matters at all: on the success path the stamp is rewritten a
  # moment later, so clearing it there is invisible. On the DELIVERY-FAILURE
  # path nothing re-stamps -- so without the rm, the stale stamp from the
  # PREVIOUS episode would suppress the next failure even though the unit had
  # recovered in between, and the new incident would be lost with no page and
  # no cooldown line to explain it.
  run "$SCRIPT" some-unit.service                      # episode 1 pages + stamps
  [ -e "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service" ]

  # recovered, then failed again -- and Slack rejects the page
  STUB_JOURNAL_RECOVERED=1 STUB_MUSO_RC=1 run "$SCRIPT" some-unit.service
  [ "$status" -ne 0 ]
  [ ! -e "$NOTIFY_UNIT_FAILED_COOLDOWN_DIR/some-unit.service" ]
  # ...so the retry is not suppressed: a spool marker exists AND the next
  # attempt pages rather than reporting a cooldown.
  [ -n "$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/some-unit.service.*.unpaged 2>/dev/null)" ]
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"cooldown"* ]]
  # THREE, not two: the muso stub appends the message before exiting with
  # STUB_MUSO_RC, so $PAGE_LOG counts page ATTEMPTS (episode 1, the rejected
  # one, and this delivered one) rather than successful deliveries.
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 3 ]
}

@test "recovery detection ignores the SERVICE's own stdout (only systemd counts)" {
  # QA finding on this PR. `-o cat` prints message text with no metadata, and a
  # unit's journal interleaves systemd's lifecycle lines with the service's own
  # output -- so a bare `Finished ` match accepts "worker[main]: Finished
  # processing batch 7" as proof systemd completed the unit. That invents a
  # recovery, un-suppresses the cooldown, and turns one continuous outage into a
  # stream of "new" incidents. The journalctl stub emits exactly that line when
  # the probe forgets _PID=1, so dropping the field match fails here.
  run "$SCRIPT" some-unit.service                  # episode 1: pages + stamps
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
  # no systemd success in the journal, only service chatter -> same episode
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"within the"*"cooldown"* ]]
  [[ "$output" != *"recovered since"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "a systemd FAILURE line whose description contains \"Finished\" is not a recovery" {
  # The ^ anchor's job. _PID=1 cannot help here: systemd itself wrote the line,
  # so it is in scope -- but "some-unit.service: Failed to start Finished
  # nightly report." is a FAILURE, and matching "Finished" anywhere in it would
  # read a failed start as proof of success and reset the episode.
  run "$SCRIPT" some-unit.service
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
  STUB_JOURNAL_DESC_TRAP=1 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"within the"*"cooldown"* ]]
  [[ "$output" != *"recovered since"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "a leading-zero cooldown (08) is decimal 8, not an octal arithmetic error" {
  # QA finding on this PR. Bash arithmetic evaluates the VALUE, so "08" passes a
  # digit-only test and then makes $((08 * 60)) a fatal arithmetic error
  # ("value too great for base"). Measured on bash 5.2.21 the error abandons the
  # enclosing compound command in a way that is not cleanly characterisable, so
  # the value is normalized with 10# at the boundary and never reaches $(( )).
  # 08 must behave as EIGHT MINUTES: first failure pages, an immediate repeat is
  # suppressed, and no arithmetic error appears anywhere.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=08 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"value too great for base"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]

  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=08 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"value too great for base"* ]]
  [[ "$output" == *"within the 8m cooldown"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "an absurd cooldown collapses to 0 (no cooldown), never a silent forever-mute" {
  # A value past any sane dedupe window is a misconfiguration, and the fail-open
  # direction is to page. Muting a unit for 190 years because someone typed too
  # many digits is the one outcome this pager must never produce.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=99999999 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=99999999 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"within the"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "a rejected cooldown value SAYS so instead of being silently ignored" {
  # Without this the boundary collapse is invisible: the in-function `-gt 0`
  # guard already rejects a non-numeric value, so dropping the collapse changed
  # no observable behaviour and the branch was untestable dead weight. A
  # misconfigured dedupe window should be visible in the journal, not inferred
  # from the absence of cooldown lines.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=abc run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN='abc'"* ]]
  [[ "$output" == *"NO cooldown"* ]]

  # and a VALID value says nothing
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=30 run "$SCRIPT" other-unit.service
  [[ "$output" != *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN"* ]]
  # ...as does an explicit, deliberate 0
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=0 run "$SCRIPT" third-unit.service
  [[ "$output" != *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN"* ]]
}

@test "an OVERFLOWING cooldown cannot wrap past the ceiling" {
  # QA finding on this PR. $((10#…)) coerces into signed 64-bit, so a numeric
  # ceiling checked AFTER the coercion is bypassable: 2^64 + 525600 normalizes
  # to exactly 525600, passes `-le 525600`, and would suppress repeat pages for
  # a full year — the opposite of fail-open. The bound is now on DIGIT COUNT,
  # before any arithmetic.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=18446744073710077216 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN='18446744073710077216'"* ]]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=18446744073710077216 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"within the"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "leading zeros do not inflate the digit bound (0000042 is 42 minutes)" {
  # The digit bound strips leading zeros first, or "0000042" would read as 7
  # digits and be rejected as absurd.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=0000042 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN"* ]]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=0000042 run "$SCRIPT" some-unit.service
  [[ "$output" == *"within the 42m cooldown"* ]]
}

@test "recovery detection survives a journal larger than a pipe buffer" {
  # QA finding on this PR, and a trap already in docs/lessons: under pipefail,
  # `printf … | grep -q` returns 141 once grep exits at its first match and
  # printf takes SIGPIPE — which happens past ~64 KiB. The pipeline then fails
  # BECAUSE the success line was found, recovery reads false, and the stale
  # stamp suppresses a genuinely new incident. A here-string has no upstream
  # process to signal.
  run "$SCRIPT" some-unit.service                      # episode 1 pages + stamps
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
  # journalctl now emits the success line followed by >64 KiB of PID-1 chatter
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/bin/bash
_since=; _pid1=
for a in "$@"; do
  case "$a" in --since*) _since=1 ;; _PID=1) _pid1=1 ;; esac
done
if [ -n "$_since" ] && [ -n "$_pid1" ]; then
  echo "Finished some-unit.service - Some Unit."
  for i in $(seq 1 3000); do echo "some-unit.service: Consumed 1.234s CPU time. padding padding padding"; done
  exit 0
fi
echo "line one"
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered since the last page"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "a 6-digit value above the ceiling is rejected by the NUMERIC check" {
  # Discriminates the numeric ceiling from the digit bound: 999999 is only 6
  # digits so it passes the pre-arithmetic length test, and only `-le 525600`
  # can reject it. Without this the ceiling is unfalsifiable — the earlier
  # "absurd" case used 8 digits, which the digit bound catches first.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=999999 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN='999999'"* ]]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=999999 run "$SCRIPT" some-unit.service
  [[ "$output" != *"within the"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}

@test "the largest ACCEPTED cooldown (525600) still suppresses" {
  # The boundary from the other side, so the ceiling cannot be made stricter
  # without a test noticing.
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=525600 run "$SCRIPT" some-unit.service
  [[ "$output" != *"ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN"* ]]
  NOTIFY_UNIT_FAILED_COOLDOWN_MIN=525600 run "$SCRIPT" some-unit.service
  [[ "$output" == *"within the 525600m cooldown"* ]]
}

@test "a failure line whose description contains \"Deactivated successfully\" is not a recovery" {
  # QA finding on this PR: the second alternative was unanchored, so any PID-1
  # line CONTAINING the phrase counted as success. A unit described
  # "Deactivated successfully report" that fails to start logs
  # "Failed to start Deactivated successfully report." — which would clear the
  # episode stamp and un-suppress the pager on the next failure.
  #
  # The mirror of the ^Finished case. I anchored that one and left this one
  # open, reasoning a ^ could not work here — true, but ": …\.$" does.
  run "$SCRIPT" some-unit.service
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
  STUB_JOURNAL_DEACT_TRAP=1 run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"within the"*"cooldown"* ]]
  [[ "$output" != *"recovered since"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "the GENUINE Deactivated-successfully line is still a recovery" {
  # The discriminator: anchoring must not break the real signal. Format taken
  # verbatim from the live journal — "<unit>: Deactivated successfully."
  run "$SCRIPT" some-unit.service
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/bin/bash
_s=; _p=
for a in "$@"; do case "$a" in --since*) _s=1 ;; _PID=1) _p=1 ;; esac; done
if [ -n "$_s" ] && [ -n "$_p" ]; then echo "some-unit.service: Deactivated successfully."; exit 0; fi
echo "line one"
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$SCRIPT" some-unit.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered since the last page"* ]]
  [ "$(grep -c "systemd unit FAILED" "$PAGE_LOG" 2>/dev/null || echo 0)" -eq 2 ]
}
