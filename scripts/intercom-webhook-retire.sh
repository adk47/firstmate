#!/usr/bin/env bash
# intercom-webhook-retire.sh — prove the loopback receiver is dead traffic, then
# retire it (plan step 6), instead of cleaning it forever.
#
# WHY THIS EXISTS (T13, node8-to-pods plan 2026-10-27)
#
# `intercom-webhook.service` listens on 127.0.0.1:18792 and NOTHING routes to it:
# the live customer path is Ingress hydra.muso.ai/intercom/webhook → the edge
# gateway (:18810). Infra-monitor-m2 measured 3.7 s of CPU in six days. The plan
# says retire it "after 7 days of 0 hits confirmed" — so the retirement needs a
# PROOF, not a recollection. This script is that proof and the only supported
# retirement path:
#
#   intercom-webhook-retire.sh [--check]        # read-only proof (default)
#   intercom-webhook-retire.sh --retire         # retire, ONLY if the proof holds
#   intercom-webhook-retire.sh --check --days 3  # short READ-ONLY diagnostic
#
# --days is the measurement window. RETIRE requires at least 7 (the plan's
# "after 7 days of 0 hits confirmed"); a shorter window is a DIAGNOSTIC, so it is
# accepted only for --check and never reaches the retirement path. 0 is rejected
# outright in both modes — a zero-day window measures nothing and would make
# "READY" mean "we looked at no time at all".
#
# The deploy drives it (scripts/install-aux-units.sh): with the switch
# /etc/hydra/intercom-webhook-retire present, every deploy re-proves 0 hits and
# retires when the proof holds; without the switch nothing is retired. That keeps
# "infra changes come from a deploy, never from a hand-typed command" true while
# making retirement a reviewable, reversible one-file switch.
#
# THREE STATES, never two: hits>0 (NOT READY), hits==0 (READY), and CANNOT
# MEASURE (journald has no window to look at — vacuumed, unit never ran, journal
# unreadable). "We could not measure it" is NOT "0 hits" and must never retire a
# live endpoint on that basis.
#
# Retire is idempotent and reversible:
#   - unit disabled + stopped, unit file and drop-in dir removed
#   - /etc/hydra/intercom-webhook.env moved (0600) to /var/lib/hydra/intercom-webhook/retired/
#   - a durable marker /var/lib/hydra/intercom-webhook/RETIRED-<ts>.json records
#     the proof; while ANY RETIRED-* marker exists, install-aux-units.sh will not
#     reinstall the unit (a deploy must not resurrect a retired endpoint).
#   - revert: restore the unit + drop-in from git and the env file from retired/
#     (RUNBOOK § intercom-webhook secrets), or delete the marker.
#
# Exit: 0 READY / retired · 1 NOT READY (hits in the window) · 2 CANNOT MEASURE
# or usage/read error (also the refuse-to-retire code).
set -euo pipefail

UNIT_NAME="intercom-webhook.service"
UNIT_DIR="${INTERCOM_WEBHOOK_UNIT_DIR:-/etc/systemd/system}"
UNIT_PATH="${INTERCOM_WEBHOOK_UNIT_PATH:-$UNIT_DIR/$UNIT_NAME}"
DROPIN_DIR="${INTERCOM_WEBHOOK_DROPIN_DIR:-$UNIT_DIR/$UNIT_NAME.d}"
ENV_FILE="${INTERCOM_WEBHOOK_ENV_FILE:-/etc/hydra/intercom-webhook.env}"
STATE_DIR="${INTERCOM_WEBHOOK_RETIRE_DIR:-/var/lib/hydra/intercom-webhook}"
DAYS="${INTERCOM_WEBHOOK_RETIRE_DAYS:-7}"
NO_SYSTEMCTL="${INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL:-0}"
# Same knob pattern as the renderer's KUBECTL: a caller (and the tests) can point
# at a different systemctl, or at one that does not exist, without a real
# systemd on the host. Production never sets it.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
MODE=check

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  MODE=check ;;
    --retire) MODE=retire ;;
    --days)   [ -n "${2:-}" ] || usage; DAYS="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
case "$DAYS" in ''|*[!0-9]*) echo "--days must be a positive integer, got '$DAYS'" >&2; exit 2 ;; esac
# Normalise before any arithmetic or use: `10#` keeps bash from reading "010" as
# octal 8 (a silent off-by-two-days window is exactly the class of bug this
# script exists to refuse), and it makes "007" mean the seven days it says.
DAYS=$((10#$DAYS))
if [ "$DAYS" -lt 1 ]; then
  echo "--days must be at least 1, got '$DAYS'" >&2; exit 2
fi

# THE SEVEN-DAY PROOF IS NOT NEGOTIABLE IN RETIRE MODE (QA Important, 2026-11-04).
# --days/INTERCOM_WEBHOOK_RETIRE_DAYS used to accept any digit string, so
# `--retire --days 1` retired a receiver that had handled an event two days ago
# (0 hits yesterday, 1 the day before) and wrote a durable RETIRED marker that
# every later deploy honours. A retirement proof you can shorten at the call site
# is not a proof. Shortening stays available where it cannot cause harm: --check
# is read-only and exits 0/1/2 without touching the unit.
RETIRE_MIN_DAYS=7
if [ "$MODE" = "retire" ] && [ "$DAYS" -lt "$RETIRE_MIN_DAYS" ]; then
  echo "REFUSING to retire on a ${DAYS}-day window: the retirement proof is at least ${RETIRE_MIN_DAYS} days of 0 inbound events (plan step 6). Shorter windows are read-only diagnostics — use --check --days ${DAYS}." >&2
  exit 2
fi

# Diagnostics go to STDERR: the hit count is this script's only stdout, and a
# log line captured into it would read as traffic.
log() { echo "[intercom-webhook-retire] $*" >&2; }

# ── already retired? ────────────────────────────────────────────────────────
marker() { find "$STATE_DIR" -maxdepth 1 -name 'RETIRED-*.json' -type f 2>/dev/null | LC_ALL=C sort | tail -1; }
if [ -n "$(marker)" ]; then
  log "already retired — proof on file: $(marker)"
  exit 0
fi

# ── measure ─────────────────────────────────────────────────────────────────
# Count INBOUND work, not lines: the receiver writes one `[intercom-webhook] …`
# line per event it handles (topic/conv, invalid signature, malformed, duplicate,
# escalated, blocked, replied). The three startup lines are excluded, and so is
# any FATAL (that is a config failure, not traffic).
measure_hits() {
  local since="${DAYS} days ago" out rc=0
  [ "$NO_SYSTEMCTL" != "1" ] || { log "CANNOT MEASURE: systemctl/journald disabled by INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL"; return 2; }
  command -v journalctl >/dev/null 2>&1 || { log "CANNOT MEASURE: no journalctl on this host"; return 2; }

  # COVERAGE FIRST (Fable r5 / QA Important a): a non-empty journal proves
  # *some* history, not that the whole --days window survived. A journal that was
  # vacuumed or rotated 20 h ago returns a healthy-looking stream for a 7-day
  # window while 6 of those days were never observed — and "0 hits" over the
  # days we CAN see is exactly the claim that would retire a live endpoint.
  #
  # The ONLY acceptable proof is a journal that reaches back past the window
  # start. Ask for the newest entry BEFORE the window (`--until <window start>`);
  # empty means the journal's history begins inside the window.
  #
  # A first version also accepted "the unit's own first retained entry is inside
  # the window" as coverage. QA rejected it and was right: that entry is only
  # proof of what the JOURNAL still holds, not of when the unit started. A
  # journal vacuumed one day ago leaves the receiver's first retained line one
  # day old while six days of the window were never observed — the fixture that
  # reproduced READY/rc 0 for six unobserved days. Fail closed instead: no
  # complete window, no measurement.
  local until_count
  until_count="$(journalctl --until "$since" --no-pager -o cat -n 1 2>/dev/null | wc -l | tr -d ' ')" || until_count=0
  if [ "${until_count:-0}" -eq 0 ]; then
    log "CANNOT MEASURE: the journal holds no entry before $since, so the last $DAYS day(s) were not all observed — refusing to call unobserved time zero"
    return 2
  fi

  out="$(journalctl -u "$UNIT_NAME" --since "$since" --no-pager -o cat 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    # No journal in the window is NOT zero traffic: a vacuumed or rotated
    # journal looks identical to an idle unit from here.
    log "CANNOT MEASURE: journald returned nothing for $UNIT_NAME over the last $DAYS day(s) (rc=$rc)"
    return 2
  fi
  # An all-filtered-out stream is ZERO, not an error: with `pipefail` a middle
  # grep returning 1 (no matching lines) would fail the pipeline, and the caller
  # would read that as "cannot measure" — the exact confusion this script exists
  # to prevent, in the opposite direction.
  local count
  set +o pipefail
  # shellcheck disable=SC2126  # grep -c cannot subtract the three startup lines
  count="$(printf '%s\n' "$out" \
    | grep -F '[intercom-webhook]' \
    | grep -vF 'listening on ' \
    | grep -vF 'OpenClaw: ' \
    | grep -vF 'FATAL: ' \
    | wc -l | tr -d ' ')"
  set -o pipefail
  printf '%s' "${count:-0}"
}

HITS="$(measure_hits)" || { log "refusing to treat 'could not measure' as '0 hits'"; exit 2; }
[ -n "$HITS" ] || { log "CANNOT MEASURE: hit count empty"; exit 2; }

if [ "$HITS" -gt 0 ]; then
  log "NOT READY: $HITS inbound event(s) handled in the last $DAYS day(s); nothing routes to :18792 — investigate before retiring"
  exit 1
fi

log "READY: 0 inbound events in the last $DAYS day(s) (journald window) for $UNIT_NAME"

if [ "$MODE" = "check" ]; then
  exit 0
fi

# ── retire ──────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { log "retirement needs root (systemd unit removal)"; exit 2; }
install -d -m 700 "$STATE_DIR" "$STATE_DIR/retired"
ts="$(date -u +%Y%m%dT%H%M%SZ)"

# STOP BEFORE TOUCHING ANYTHING (Fable r5 / QA Important b). A failed
# `disable --now` used to be logged and ignored, so the files could be moved and
# a RETIRED marker written while the receiver was still running — and every later
# deploy honours that marker, so nothing would ever notice. A retirement script
# must never report done while the process runs.
if [ "$NO_SYSTEMCTL" = "1" ] || ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
  log "REFUSING to retire: systemctl is unavailable, so the receiver cannot be stopped — leaving the unit in place"
  exit 2
fi
stop_rc=0
"$SYSTEMCTL" stop "$UNIT_NAME" >/dev/null 2>&1 || stop_rc=$?
disable_rc=0
"$SYSTEMCTL" disable "$UNIT_NAME" >/dev/null 2>&1 || disable_rc=$?
state_after="$("$SYSTEMCTL" is-active "$UNIT_NAME" 2>/dev/null || true)"
# A CONFIRMED state is required (Fable r5 QA Important b, carried): an empty or
# `unknown` answer is not "stopped". A systemd that cannot answer — bus down, a
# typo'd unit name, a wrapper that printed nothing — used to satisfy neither
# refusal branch, so the files were removed and a RETIRED marker written without
# ever confirming the receiver stopped. Accept only inactive/failed.
case "$state_after" in
  inactive|failed) ;;
  "")
    log "REFUSING to retire: systemctl is-active returned NOTHING for $UNIT_NAME after stop (stop rc=$stop_rc, disable rc=$disable_rc) — cannot confirm the receiver stopped; nothing removed, no marker written"
    exit 2 ;;
  *)
    log "REFUSING to retire: $UNIT_NAME is '$state_after' after stop (stop rc=$stop_rc, disable rc=$disable_rc) — cannot confirm the receiver stopped; nothing removed, no marker written"
    exit 2 ;;
esac
# Disabled must also be confirmed: an enabled unit with its file removed can come
# back on the next boot from a stale unit path.
# The ENABLED state must be an explicit terminal answer. An EMPTY answer is not
# "disabled" — a failed `disable` on a systemd that cannot answer used to fall
# through here (empty matched the accept branch), removing a unit that could come
# back on the next boot. Fail closed on anything that is not an explicit
# disabled/masked.
enabled_state="$("$SYSTEMCTL" is-enabled "$UNIT_NAME" 2>/dev/null || true)"
case "$enabled_state" in
  disabled|masked|masked-runtime) ;;
  "")
    log "REFUSING to retire: is-enabled returned NOTHING for $UNIT_NAME (disable rc=$disable_rc) — cannot confirm it is disabled; nothing removed, no marker written"
    exit 2 ;;
  *)
    log "REFUSING to retire: $UNIT_NAME reports '$enabled_state' after disable (rc=$disable_rc) — nothing removed, no marker written"
    exit 2 ;;
esac
# (The enabled-state decision was made above, from the confirmed value; do not
# re-ask here — a second, differently-failing probe would reintroduce exactly the
# "two answers, one of them silent" shape this guard exists to remove.)
log "stopped + disabled $UNIT_NAME (state=$state_after, stop rc=$stop_rc, disable rc=$disable_rc)"
# BACK UP EVERYTHING FIRST, then delete (QA new finding 3): a swallowed backup
# failure used to be followed by deleting the only revert copy — a full state
# filesystem would leave a RETIRED marker describing files that no longer exist.
# If any copy fails, nothing original is touched.
backup_unit() {
  [ -f "$UNIT_PATH" ] || return 0
  install -m 600 "$UNIT_PATH" "$STATE_DIR/retired/$UNIT_NAME.retired-$ts"
}
backup_dropins() {
  [ -d "$DROPIN_DIR" ] || return 0
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    install -m 600 "$f" "$STATE_DIR/retired/$(basename "$f").retired-$ts" || return 1
  done < <(find "$DROPIN_DIR" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.conf.*' \) | LC_ALL=C sort)
  return 0
}
if ! backup_unit; then
  log "REFUSING to retire: could not back up $UNIT_PATH to $STATE_DIR/retired/ (disk full?) — nothing removed, no marker written"
  exit 2
fi
if ! backup_dropins; then
  log "REFUSING to retire: could not back up every drop-in in $DROPIN_DIR — nothing removed, no marker written (the unit was stopped; re-enable it with: systemctl enable --now $UNIT_NAME)"
  exit 2
fi
if [ -f "$UNIT_PATH" ]; then rm -f "$UNIT_PATH"; fi
if [ -d "$DROPIN_DIR" ]; then rm -rf "$DROPIN_DIR"; fi
# The rendered secret file dies with the unit; move (not delete) it so a revert
# does not need a rotation.
if [ -f "$ENV_FILE" ]; then
  install -m 600 "$ENV_FILE" "$STATE_DIR/retired/intercom-webhook.env.retired-$ts"
  rm -f "$ENV_FILE"
fi
command -v "$SYSTEMCTL" >/dev/null 2>&1 && "$SYSTEMCTL" daemon-reload || true

# The durable marker is what stops the next deploy from reinstalling the unit.
printf '{"retired_at":"%s","unit":"%s","days_measured":%s,"inbound_events":%s,"measure":"journald -u %s --since %s days ago","coverage_verified_before_remove":true,"stopped_before_remove":true}\n' \
  "$ts" "$UNIT_NAME" "$DAYS" "$HITS" "$UNIT_NAME" "$DAYS" > "$STATE_DIR/RETIRED-$ts.json"
chmod 600 "$STATE_DIR/RETIRED-$ts.json"

log "RETIRED $UNIT_NAME — proof: 0 inbound events over $DAYS day(s) (marker $STATE_DIR/RETIRED-$ts.json)"
log "revert: restore $STATE_DIR/retired/$UNIT_NAME.retired-$ts to $UNIT_PATH, the env file from retired/, and delete the marker"
exit 0
