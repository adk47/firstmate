#!/usr/bin/env bats
# The GDPR erasure pipeline tick unit (scripts/install-aux-units.sh, the
# `gdpr-pipeline-tick.service` heredoc).
#
# WHY THIS FILE EXISTS. On 2026-11-06 every deploy refused at Step 5c with
#   /opt/hydra/scripts/install-aux-units.sh: line 912: GDPR_SENDER_SEAT: unbound variable
# The unit is written through an UNQUOTED heredoc, so the shell expands every
# `$VAR` at write time. `$HYDRA_ROOT` is set and must expand; `$GDPR_SENDER_SEAT`
# is NOT set in the installer's own shell - it is meant to be expanded by
# systemd from the `Environment=GDPR_SENDER_SEAT=...` line - so under
# `set -euo pipefail` the write aborted and took the deploy with it.
#
# There was no test for this unit at all, which is why CI was green. The two
# assertions that matter are opposite in direction and both are load-bearing:
#   * the rendered ExecStart must still contain the LITERAL `$GDPR_SENDER_SEAT`
#     (systemd expands it; a baked-in id would silently ignore a rotated seat), and
#   * the rendered ExecStart must contain the EXPANDED HYDRA_ROOT (a literal
#     `$HYDRA_ROOT` in a unit is not expanded by systemd and the tick would
#     never start).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="gdpr-pipeline-tick"

# _render <dest-dir>: run the installer's own heredoc for this unit with the
# target rewritten into <dest-dir>, under the installer's real shell options.
# `set -u` is the whole point: without it the bug this file pins cannot happen.
_render() {
  local dest="$1/" snippet="$TEST_TMPDIR/render.sh"
  awk -v dir="/etc/systemd/system/" -v name="$NAME." -v dest="$dest" '
    !on && index($0, "cat > " dir name) == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1
      print "cat > " dest substr($0, length("cat > " dir) + 1); next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  [ -s "$snippet" ]
  { echo 'set -euo pipefail'; cat "$snippet"; } > "$snippet.run"
  HYDRA_ROOT="$HYDRA_REPO" bash "$snippet.run"
}

_kv() {
  awk '/^\[[^]]+\]$/ { sec = substr($0, 2, length($0) - 2); next }
       /^[A-Za-z][A-Za-z0-9]*=/ { i = index($0, "="); print sec "." substr($0, 1, i - 1) "=" substr($0, i + 1) }' "$1"
}

_values() { _kv "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'; }

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  UNITS="$TEST_TMPDIR/units"; mkdir -p "$UNITS"
  SVC="$UNITS/$NAME.service"; TMR="$UNITS/$NAME.timer"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the installer renders the tick unit under set -u (the 2026-11-06 deploy break)" {
  run _render "$UNITS"
  [ "$status" -eq 0 ]
  [ -s "$SVC" ]
  [ -s "$TMR" ]
}

@test "the seat survives to the unit as a literal for systemd to expand" {
  _render "$UNITS"
  run _values "$SVC" Service.ExecStart
  [ "$status" -eq 0 ]
  [[ "$output" == *'--approved-by $GDPR_SENDER_SEAT'* ]]
  # and the value it will expand to is declared in the same unit
  [ "$(_values "$SVC" Service.Environment)" = "HOME=/root
GDPR_SENDER_SEAT=U0AN41ZBTRU" ]
}

@test "HYDRA_ROOT is expanded at write time, not left for systemd" {
  _render "$UNITS"
  run _values "$SVC" Service.ExecStart
  [[ "$output" == *"$HYDRA_REPO/scripts/gdpr-pipeline.py"* ]]
  [[ "$output" != *'$HYDRA_ROOT'* ]]
}

@test "the tick sends under the standing grant, with the first-wave brake" {
  _render "$UNITS"
  run _values "$SVC" Service.ExecStart
  [[ "$output" == *" tick --page --send --limit 25 "* ]]
}

@test "the tick runs the DSAR ladder, capped, and with no approver of its own" {
  _render "$UNITS"
  run _values "$SVC" Service.ExecStart
  [[ "$output" == *" --ladder --ladder-limit 25" ]]
  # what authorises a ladder message is a reviewer verdict on its hash, never a seat: exactly one --approved-by
  [ "$(grep -o -- '--approved-by' <<<"$output" | wc -l)" -eq 1 ]
}

@test "the timer is hourly and starts this service" {
  _render "$UNITS"
  [ "$(_values "$TMR" Timer.OnUnitActiveSec)" = "60min" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  [ "$(_values "$TMR" Install.WantedBy)" = "timers.target" ]
}

@test "SECURITY: no secret literal appears in the rendered units" {
  _render "$UNITS"
  run grep -E 'MUSOAI_INTERCOM_TOKEN=|xoxb-|SLACK_BOT_TOKEN|GOG_KEYRING_PASSWORD=' "$SVC" "$TMR"
  [ "$status" -eq 1 ]
}
