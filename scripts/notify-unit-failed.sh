#!/usr/bin/env bash
# notify-unit-failed.sh <unit> — OnFailure= target for hydra oneshot units
# (hydra-unit-failed@.service, installed by install-aux-units.sh).
#
# A failed timer-driven oneshot is otherwise only a red unit in `systemctl
# list-units --failed` that nobody watches. Units that can page for themselves
# do (codex-edge-mirror.sh --restart pages on every structural exit); this
# covers what never reaches the script: ExecStart missing or not executable,
# the interpreter absent, or systemd killing the run at TimeoutStartSec.
#
# Delivery goes through lib/deploy-notify.sh, which RETURNS the real Slack
# status. slack_notify/slack_notify_critical deliberately swallow the send's
# exit code (docs/lessons: "slack_notify discards both streams and returns 0"),
# so a rejected post (invalid_auth, bot removed from the channel, CLI failure)
# would have exited 0 here with no page and no trace — the original failed
# timer silently unalerted (QA finding on #935, round 5). On a failed delivery
# this script exits NON-ZERO and leaves two observable traces: a journal line
# and a marker file under NOTIFY_UNIT_FAILED_MARKER_DIR (default
# /var/lib/hydra/unit-failed-unpaged/) named after the unit. systemd ignores an
# OnFailure unit's exit code, which is exactly why the marker exists.
#
# A PER-UNIT COOLDOWN is what makes this safe to wire fleet-wide. Without it,
# OnFailure= on a frequently-scheduled unit is an alert storm rather than an
# alert: hydra-release-watch.timer fires every 5 minutes, so a standing failure
# there would page #clio_devops ~288 times a day (it has been failing since
# 2026-09-07). The repo has been here before — a standing finding re-paged on
# every trigger produced 17 alerts in one day and trained everyone to ignore
# the channel, which is strictly worse than not paging.
#
# The window bounds one EPISODE: a successful run since the last page clears
# the stamp, so a unit that recovers and then breaks again pages immediately.
#
# 24h, not the 6h the cron watchdog uses, deliberately: this handler fires on
# EVERY failing unit, so the steady-state volume is (failing units x pages/day).
# One page per failing unit per day stays actionable with five standing
# failures; 6h would be twenty. A unit that starts failing still pages within
# seconds — the cooldown only bounds REPEATS of the same unit.
#
# Env: NOTIFY_UNIT_FAILED_LINES (journal tail, default 12),
#      NOTIFY_UNIT_FAILED_MARKER_DIR, DEPLOY_NOTIFY_BIN (tests),
#      NOTIFY_UNIT_FAILED_COOLDOWN_MIN (default 1440; 0 disables),
#      NOTIFY_UNIT_FAILED_COOLDOWN_DIR.
set -uo pipefail
umask 077

UNIT="${1:-}"
[ -n "$UNIT" ] || { echo "usage: $0 <unit>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_BIN="${DEPLOY_NOTIFY_BIN:-$SCRIPT_DIR/lib/deploy-notify.sh}"
MARKER_DIR="${NOTIFY_UNIT_FAILED_MARKER_DIR:-/var/lib/hydra/unit-failed-unpaged}"
SELF_PAGED_DIR="${HYDRA_SELF_PAGED_DIR:-/var/lib/hydra/self-paged}"
SELF_PAGED_MAX_AGE="${NOTIFY_UNIT_FAILED_SELF_PAGED_MAX_AGE:-120}"
COOLDOWN_MIN="${NOTIFY_UNIT_FAILED_COOLDOWN_MIN:-1440}"
COOLDOWN_DIR="${NOTIFY_UNIT_FAILED_COOLDOWN_DIR:-/var/lib/hydra/unit-failed-cooldown}"
LOGPREFIX="[notify-unit-failed $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# Normalize COOLDOWN_MIN to canonical decimal before any arithmetic sees it.
# Placed after log() on purpose: a rejected value must SAY so. Bash arithmetic
# evaluates the VALUE, so a leading zero is read as OCTAL — `08` passes a
# digit-only test and then makes `$((08 * 60))` a fatal arithmetic error
# ("value too great for base"). QA finding on this PR. Measured on bash 5.2.21
# the error abandons the enclosing compound command in a way that is not
# cleanly characterisable from outside, so the safe move is to keep a
# non-canonical value away from `$(( ))` entirely rather than reason about what
# bash does when one arrives.
#
# Anything not canonical decimal, or past a sane ceiling, collapses to 0 = NO
# cooldown — the fail-open direction every branch here takes, because a missed
# page is an outage and an extra page is noise. 525600 is one year in minutes:
# far past any dedupe window anyone means, and safely inside integer range. The
# alternative, honouring it, would mute a unit for ~190 years on a typo.
_cooldown_raw="$COOLDOWN_MIN"
case "$COOLDOWN_MIN" in
  ''|*[!0-9]*) COOLDOWN_MIN=0 ;;
  *)
    # Bound by DIGIT COUNT before any arithmetic. `$((10#…))` coerces into
    # signed 64-bit, so a numeric ceiling checked afterwards can be bypassed by
    # wraparound: QA finding on this PR showed
    # NOTIFY_UNIT_FAILED_COOLDOWN_MIN=18446744073710077216 (2^64 + 525600)
    # normalizing to exactly 525600, passing `-le 525600`, and suppressing
    # repeat pages for a full year — the opposite of fail-open.
    #
    # Leading zeros are stripped first so "0000042" is 2 digits, not 7. Six
    # digits caps the value at 999999, far inside int64, and the numeric ceiling
    # below then narrows it to the real 525600 limit.
    _cd_digits="${COOLDOWN_MIN#"${COOLDOWN_MIN%%[!0]*}"}"
    [ -n "$_cd_digits" ] || _cd_digits=0
    if [ "${#_cd_digits}" -gt 6 ]; then
      COOLDOWN_MIN=0
    else
      # No `10#` needed: the leading-zero strip above guarantees _cd_digits
      # never begins with 0 (except the literal "0"), so there is no octal
      # coercion left to defend against. Keeping it would be a guard no test
      # can falsify — mutating it away changed nothing observable.
      COOLDOWN_MIN=$((_cd_digits))
      [ "$COOLDOWN_MIN" -le 525600 ] || COOLDOWN_MIN=0
    fi
    ;;
esac
if [ "$COOLDOWN_MIN" = "0" ] && [ "$_cooldown_raw" != "0" ]; then
  log "ignoring NOTIFY_UNIT_FAILED_COOLDOWN_MIN='$_cooldown_raw' (not canonical decimal, or above the ${_cooldown_ceiling:-525600}-minute ceiling) — running with NO cooldown, so every failure of this unit will page"
fi

# leave_trace <reason> — journal line + ONE spool file per record (temp name,
# then rename into place): the watchdog claims whole files by rename, and no
# producer ever holds an fd on a file it can claim — there is no shared append
# surface to race on. Never fails the caller.
leave_trace() {
  local now spool tmp
  log "PAGE NOT DELIVERED for $UNIT: $1 — the failed unit is UNALERTED"
  mkdir -p "$MARKER_DIR" 2>/dev/null || true
  now="$(date -u +%s)"; spool="$MARKER_DIR/${UNIT}.${now}.$$.unpaged"; tmp="$spool.tmp"
  if printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$UNIT" "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$spool" 2>/dev/null; then
    log "durable marker $spool left for cron-health-watchdog"
  else
    rm -f "$tmp" 2>/dev/null
    log "could not write marker under $MARKER_DIR"
  fi
}

# One pager per failure: a unit whose script paged for its own failure just
# now (it stamps $SELF_PAGED_DIR/<unit> under its systemd run — see
# codex-edge-mirror.sh page_failure) must not be paged again by this generic
# OnFailure= handler; that would also bypass the script's own cooldown.
_self_paged_age() {
  local f="$SELF_PAGED_DIR/$UNIT" ts now
  [ -r "$f" ] || return 1
  ts="$(cat "$f" 2>/dev/null)"; case "$ts" in (*[!0-9]*|"") return 1 ;; esac
  now="$(date -u +%s)"
  [ $((now - ts)) -ge 0 ] && [ $((now - ts)) -le "$SELF_PAGED_MAX_AGE" ] || return 1
  printf '%s' $((now - ts))
}
if age="$(_self_paged_age)"; then
  log "$UNIT paged for its own failure ${age}s ago (self-paged stamp) — not paging it a second time"
  exit 0
fi

# Per-unit cooldown. Checked AFTER the self-paged skip (that one is about a
# single failure being double-reported; this one is about the same unit failing
# again and again) and BEFORE any Slack call, so a suppressed tick costs
# nothing.
#
# Fails OPEN on purpose: if the stamp cannot be read or written we PAGE. An
# unreadable cooldown must never be the reason a real failure goes unreported —
# the storm this bounds is noise, a missed page is an outage.
_cooldown_stamp="$COOLDOWN_DIR/$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9@._-' '_')"

# _recovered_since <epoch> — did this unit COMPLETE SUCCESSFULLY since then?
#
# The cooldown must bound one continuous failure episode, not wall-clock time
# since the last page. QA finding on this PR: keyed on time alone,
# hydra-release-watch failing at 00:00 (pages), succeeding at 00:05, then
# failing again at 10:00 from an unrelated regression would have that SECOND
# incident silently suppressed for another 14 hours. A recovery ends the
# episode, so the next failure is new and must page.
#
# systemd logs a successful oneshot as "Finished <unit> - <desc>." and
# "<unit>: Deactivated successfully."; either ends the episode.
#
# `_PID=1` is REQUIRED, not decoration. QA finding on this PR: `-o cat` prints
# the message text with no record metadata, and a unit's journal interleaves
# systemd's lifecycle lines with the SERVICE'S OWN stdout/stderr. So a bare
# `Finished ` match accepts the service saying "Finished processing batch" as
# proof that systemd completed it — inventing a recovery that never happened,
# which un-suppresses the cooldown and reports a continuous outage as a string
# of new incidents. Measured on node-8 for hydra-peer-labels.service over 2h:
# 600 journal lines unfiltered, 96 with `_PID=1`, and every one of those 96 is
# `SYSLOG_IDENTIFIER=systemd`. The unfiltered set includes lines like
# "provision-peer-labels[main]: done: 0 patched, 10 skipped".
#
# BOTH alternatives are anchored, asymmetrically because systemd's two success
# messages have different shapes: "Finished <unit> - <desc>." begins the
# message, while "<unit>: Deactivated successfully." puts the unit name FIRST.
# So the first anchors at ^ and the second anchors on its ": " prefix plus the
# trailing period at $.
#
# An earlier version left the second alternative UNANCHORED, reasoning that a ^
# could never match it. True, but it does not follow that no anchor works — and
# unanchored it accepts any PID-1 line merely CONTAINING the phrase. QA finding
# on this PR: a unit described "Deactivated successfully report" that fails to
# start logs "Failed to start Deactivated successfully report.", which would
# have cleared the episode stamp and un-suppressed the pager. Verified against
# the live journal: "<unit>: Deactivated successfully." still matches, while
# "Failed to start Deactivated successfully report." and "some.service: Failed
# to start Deactivated successfully." are both rejected.
#
# Both remain success-only — a failed run logs "Failed to start" / "Failed with
# result" / "Main process exited, code=exited", never "Finished".
#
# Fails OPEN like every other branch here: an unreadable journal resolves to
# "recovered", which pages. Over-paging is noise; a missed page is an outage.
_recovered_since() {
  local ts="$1" out
  out="$(journalctl -u "$UNIT" --since "@$ts" _PID=1 --no-pager -o cat 2>/dev/null)" || return 0
  # HERE-STRING, not a pipe. QA finding on this PR: under `set -o pipefail`,
  # `printf … | grep -q` returns 141 when grep exits at its first match and
  # printf takes SIGPIPE — which happens once the journal exceeds a pipe buffer
  # (~64 KiB). The pipeline then reports failure precisely BECAUSE the success
  # line was found, `_recovered_since` reads false, and the stale stamp
  # suppresses a genuinely new incident. A here-string has no upstream process
  # to signal. (This trap is in docs/lessons under grep-pipe-under-pipefail; I
  # wrote it anyway.)
  grep -qE '^Finished |: Deactivated successfully\.$' <<<"$out"
}

_cooldown_active() {
  # COOLDOWN_MIN is already canonical decimal (normalized at assignment), so
  # this is the "disabled" gate rather than a parse guard: 0 means no cooldown,
  # and every rejected value — non-numeric, leading-zero/octal, absurdly large —
  # has been collapsed to 0 before reaching here.
  [ "$COOLDOWN_MIN" -gt 0 ] 2>/dev/null || return 1
  local ts now age
  [ -r "$_cooldown_stamp" ] || return 1
  ts="$(cat "$_cooldown_stamp" 2>/dev/null)"
  case "$ts" in (*[!0-9]*|"") return 1 ;; esac        # unparseable => page
  now="$(date -u +%s)"
  age=$((now - ts))
  [ "$age" -ge 0 ] || return 1                        # clock went backwards => page
  [ "$age" -lt $((COOLDOWN_MIN * 60)) ] || return 1
  # Inside the window, but a recovery since the last page ends that episode.
  if _recovered_since "$ts"; then
    log "$UNIT recovered since the last page — treating this as a NEW incident, not a repeat"
    rm -f "$_cooldown_stamp" 2>/dev/null || true
    return 1
  fi
  return 0
}
if _cooldown_active; then
  log "$UNIT failed again within the ${COOLDOWN_MIN}m cooldown — not re-paging (still failing; \`systemctl --failed\` and the journal remain the record)"
  exit 0
fi

tail_lines="$(journalctl -u "$UNIT" -n "${NOTIFY_UNIT_FAILED_LINES:-12}" --no-pager -o cat 2>/dev/null | tr '`' "'" | tail -c 1500)"
result="$(systemctl show -p Result --value "$UNIT" 2>/dev/null || true)"
msg="*systemd unit FAILED* on node-8: \`${UNIT}\` (Result=${result:-unknown}). The unit's own pager did not run, so treat this as unhandled. Last journal lines:
\`\`\`
${tail_lines:-<no journal output>}
\`\`\`
\`systemctl status ${UNIT}\` for the rest."

# deploy-notify.sh is invoked through bash (it is not +x in the repo; the deploy
# workflow calls it the same way).
if [ ! -r "$NOTIFY_BIN" ]; then
  leave_trace "$NOTIFY_BIN missing or unreadable"
  exit 1
fi
rc=0
bash "$NOTIFY_BIN" critical "$msg" || rc=$?
if [ "$rc" -ne 0 ]; then
  leave_trace "deploy-notify.sh exited $rc (Slack rejected or the CLI failed)"
  exit 1
fi
# Stamp only a DELIVERED page. A rejected delivery already left a spool marker
# for cron-health-watchdog to chase, and starting a cooldown on it would
# suppress the retry that is the whole point of that marker.
mkdir -p "$COOLDOWN_DIR" 2>/dev/null || true
date -u +%s > "$_cooldown_stamp" 2>/dev/null \
  || log "could not write the cooldown stamp $_cooldown_stamp — the next failure of $UNIT will page again"
log "paged #clio_devops for $UNIT"
exit 0
