#!/usr/bin/env bash
# deploy-send-tick-hold.sh — refuse to start a hydra deploy inside a credit send tick's window.
#
# ── The collision this closes (firstmate 768 (3), measured 2026-11-04) ──────
# The credit outbound tick is 2-hourly (scripts/credit-verify-outbound.sh, holding
# /var/lib/hydra/credit-verify-outbound/tick.lock). A deploy dispatched at 04:00Z
# ran INTO the 04:03Z round: node-8 was mid-rsync while a tick was building its
# audiences and reading the ledger the deploy was replacing underneath it. The
# deploy's own apply lock (QA #1604) protects an apply that has ALREADY started —
# it cannot protect a tick that starts INSIDE the deploy, and it says nothing
# about a tick that begins 3 minutes after the rsync does.
#
# #1756 gives the outbound script deploy-lock awareness. Until that lands the
# deploy side holds the line: a deploy may not START within HOLD_MIN minutes of a
# tick boundary, and may not start while a tick's flock is held. It waits (bounded)
# for the window to pass, and fails closed if the budget runs out — the same
# posture as the apply lock: refuse, change nothing, let a human re-dispatch.
#
# ── Contract ───────────────────────────────────────────────────────────────
#   deploy-send-tick-hold.sh [--now <epoch>] [--cadence <s>] [--hold-min <n>]
#                            [--lock <path>] [--poll <s>]
#     exit 0  GO      — outside the window, no tick in flight (prints nothing)
#     exit 3  WAIT    — prints "<seconds> <reason>": the caller sleeps and retries
#                       reasons: next-tick-in-Ns (the window has not opened yet),
#                       tick-in-flight (a tick holds the flock), and
#                       tick-not-yet-started-for-this-boundary (the boundary just
#                       passed and the delayed tick has left no trace yet)
#     exit 2  error   — unreadable argument (never a silent GO)
#
# `--poll <s>` changes ONE number and no verdict: a tick in flight is still a WAIT,
# but it is reported as "<s> tick-in-flight" (look again in <s> seconds) instead of a
# full cadence. It is for the caller that waits with NO lock held
# (deploy-send-tick-wait.sh). Without it the answer stays the cadence, so the gate
# deploy.sh runs under its locks still refuses at once rather than sit on the apply
# lock while a tick is trying to send.
#
# The window is measured to the NEXT boundary (a deploy that starts 9 minutes
# before a tick would still be syncing when the tick fires) and to the one just
# passed is irrelevant: a tick that already fired is caught by the lock check.
#
# `--now` exists so the arithmetic is testable without sleeping (bats arms in
# scripts/tests/deploy-send-tick-hold.bats). The caller (scripts/deploy.sh) uses
# the real clock, sleeps the returned seconds, and re-checks until its budget.
set -uo pipefail

NOW=""; CADENCE=7200; HOLD_MIN=10; POLL=""
LOCK="/var/lib/hydra/credit-verify-outbound/tick.lock"

while [ $# -gt 0 ]; do
  case "$1" in
    --now) NOW="${2:-}"; shift 2 || { echo "deploy-send-tick-hold: --now needs a value" >&2; exit 2; } ;;
    --cadence) CADENCE="${2:-}"; shift 2 || { echo "deploy-send-tick-hold: --cadence needs a value" >&2; exit 2; } ;;
    --hold-min) HOLD_MIN="${2:-}"; shift 2 || { echo "deploy-send-tick-hold: --hold-min needs a value" >&2; exit 2; } ;;
    --lock) LOCK="${2:-}"; shift 2 || { echo "deploy-send-tick-hold: --lock needs a value" >&2; exit 2; } ;;
    --poll) POLL="${2:-}"; shift 2 || { echo "deploy-send-tick-hold: --poll needs a value" >&2; exit 2; }
            # Given but empty or zero is an error, not "no poll": a caller that asked to poll and
            # got the cadence back would refuse at once and never learn why.
            case "$POLL" in ''|*[!0-9]*|0) echo "deploy-send-tick-hold: --poll must be a whole number > 0" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "deploy-send-tick-hold: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -n "$NOW" ] || NOW="$(date -u +%s)"
for v in "$NOW" "$CADENCE" "$HOLD_MIN"; do
  case "$v" in ''|*[!0-9]*) echo "deploy-send-tick-hold: $v is not a whole number" >&2; exit 2 ;; esac
done
[ "$CADENCE" -gt 0 ] || { echo "deploy-send-tick-hold: cadence must be > 0" >&2; exit 2; }

# A tick's flock is held for as long as the tick runs (possibly mid-apply). A held
# flock is a LIVE tick — the deploy waits for it, it never takes it over.
lock_held() { [ -e "$LOCK" ] && ! flock -n -x "$LOCK" true 2>/dev/null; }

if lock_held; then
  # Unknown duration: report the cadence as the worst case so the caller's budget
  # (not this number) decides. A tick that overruns its cadence is a human's call.
  # A caller holding no lock may ask to look again sooner (--poll); the verdict is
  # the same WAIT either way.
  echo "${POLL:-$CADENCE} tick-in-flight"
  exit 3
fi

INTO=$(( NOW % CADENCE ))
# 0 at the boundary itself: the tick is firing NOW, so it is the worst moment to start syncing - the
# modulus keeps that case a WAIT instead of wrapping to a full cadence of GO.
TO_NEXT=$(( (CADENCE - INTO) % CADENCE ))
WINDOW=$(( HOLD_MIN * 60 ))
if [ "$TO_NEXT" -le "$WINDOW" ]; then
  # Sleep past the boundary, plus a minute: the tick must have STARTED and its lock
  # be visible before the deploy touches node-8, and the caller's re-check settles it.
  echo "$(( TO_NEXT + 60 )) next-tick-in-${TO_NEXT}s"
  exit 3
fi

# ── The DELAYED tick (QA #1783 finding 1) ───────────────────────────────────
# A boundary 9 minutes in the past is NOT proof that its tick ran. Cron can start
# it minutes late (the 04:00Z round once began at 04:03Z): at 04:01 the next
# boundary is almost two hours away, no flock is held yet, and the old code said
# GO — so the rsync would be in flight when that tick began reading the ledger and
# building its audiences. The only evidence a delayed tick leaves is its flock
# FILE's mtime, which is written when the tick opens it: if this boundary's tick
# has not started yet, wait out the window and re-check. Past the window we cannot
# tell a quiet cron from a slow one, and a deploy that never runs is also a
# failure — the caller's budget decides, exactly as it does for a long tick.
if [ "$INTO" -le "$WINDOW" ]; then
  LAST=$(( NOW - INTO ))
  STARTED=0
  if [ -e "$LOCK" ]; then
    MTIME="$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)"
    case "$MTIME" in ''|*[!0-9]*) MTIME=0 ;; esac
    [ "$MTIME" -ge "$LAST" ] && STARTED=1
  fi
  if [ "$STARTED" = 0 ]; then
    echo "$(( WINDOW - INTO + 60 )) tick-not-yet-started-for-this-boundary"
    exit 3
  fi
fi

exit 0
