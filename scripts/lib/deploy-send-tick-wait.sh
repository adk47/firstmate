#!/usr/bin/env bash
# deploy-send-tick-wait.sh — wait for a credit send tick to finish BEFORE the deploy takes a lock.
#
# ── Why this exists (measured 2026-11-12, runs 42956794649 / 42753441441 / 42445264723 / 42336790465) ──
# Four of the five scheduled deploys from 11-07 to 11-11 died in the same second they
# started, on the same line: "deploy refused: a credit send tick window is open (7200
# tick-in-flight) and waiting it out would exceed 900s". Nothing was waited. The guard
# (deploy-send-tick-hold.sh) reports a held flock as a full cadence because it cannot
# know how long the tick will run, and the caller compares that worst case to its
# budget before sleeping once — so "wait, bounded" was in practice "refuse at once".
# Every PR merged after 2026-11-09 22:49Z stayed off node-8 while its PR page said
# merged.
#
# The wait cannot simply be made real where it stands. That loop runs AFTER deploy.sh
# takes the credit-message apply lock, and a tick that finds the apply lock held defers
# its sends (credit-verify-outbound.sh, spec-deploy-lock-deferral-m1). A deploy that
# sat on the apply lock for fifteen minutes waiting for a tick would be the reason the
# tick sent nothing. So the waiting happens HERE, with no lock held, and the gate under
# the locks stays exactly what it was: one look, and a refusal if a tick is there.
#
# ── Contract ───────────────────────────────────────────────────────────────
#   deploy-send-tick-wait.sh --max <s> [--poll <s>] [--now <epoch>]
#                            [--cadence <s>] [--hold-min <n>] [--lock <path>]
#     exit 0  clear    — the guard says GO; the caller may take its locks
#     exit 1  refused  — the budget ran out with the window still open (says why)
#     exit 2  error    — unreadable argument, or the guard could not decide
#   It takes no lock, creates no file and never touches the tick's flock: it only asks
#   the guard, sleeps, and asks again. A budget that runs out is a refusal, never a GO.
#
# `--now` is the test clock: the arithmetic advances by the seconds slept, so a bats
# case can hold a real flock for two seconds and watch the wait end (the sleeps are
# real; keep --poll small there).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/deploy-send-tick-hold.sh"
MAX=""; POLL=60; NOW=""; PASS=()

need() { [ $# -ge 2 ] || { echo "deploy-send-tick-wait: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --max) need "$@"; MAX="$2"; shift 2 ;;
    --poll) need "$@"; POLL="$2"; shift 2 ;;
    --now) need "$@"; NOW="$2"; shift 2 ;;
    --cadence|--hold-min|--lock) need "$@"; PASS+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "deploy-send-tick-wait: unknown argument $1" >&2; exit 2 ;;
  esac
done

for v in "$MAX" "$POLL" ${NOW:+"$NOW"}; do
  case "$v" in ''|*[!0-9]*) echo "deploy-send-tick-wait: '$v' is not a whole number (--max is required)" >&2; exit 2 ;; esac
done
# A zero poll would spin without spending budget, so the loop could never end in a refusal.
[ "$POLL" -gt 0 ] || { echo "deploy-send-tick-wait: --poll must be > 0" >&2; exit 2; }
[ -r "$GUARD" ] || { echo "deploy-send-tick-wait: the guard $GUARD is missing; refusing to call that a clear window" >&2; exit 2; }

say() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]   send-tick wait: $*"; }

spent=0
while :; do
  clock=()
  [ -z "$NOW" ] || clock=(--now "$(( NOW + spent ))")
  rc=0
  out="$(bash "$GUARD" ${PASS[@]+"${PASS[@]}"} ${clock[@]+"${clock[@]}"} --poll "$POLL" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then
    [ "$spent" = 0 ] || say "clear after ${spent}s"
    exit 0
  fi
  if [ "$rc" != 3 ]; then
    echo "deploy-send-tick-wait: the send-tick guard cannot decide (rc=$rc: $out)" >&2
    exit 2
  fi
  secs="${out%% *}"
  # The guard's WAIT line always leads with whole seconds. Anything else is a guard we
  # do not understand, and guessing a sleep for it would be deciding without it.
  case "$secs" in ''|*[!0-9]*|0) echo "deploy-send-tick-wait: unreadable WAIT from the guard ($out)" >&2; exit 2 ;; esac
  if [ "$(( spent + secs ))" -gt "$MAX" ]; then
    echo "send tick still in the way after ${spent}s (${out}); waiting ${secs}s more would exceed the ${MAX}s budget"
    exit 1
  fi
  say "${out}; sleeping ${secs}s (${spent}s of ${MAX}s spent, no lock held)"
  sleep "$secs"
  spent=$(( spent + secs ))
done
