#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# restart-recovery.sh — pure/injectable helpers for scripts/smoke-test.sh's
# post-restart LLM probes (ping_agent, the Clio -> CTO mesh probe).
#
# Sourced by smoke-test.sh; unit-tested by scripts/tests/restart-recovery.bats.
# Split out for the same reason as lib/mesh-probe.sh: smoke-test.sh runs
# host-wide checks the instant it is sourced, so bats cannot source it.
#
# WHAT THIS GUARDS (2026-09-11, openclaw 2026.8.2): after a FORCED gateway
# restart (SIGUSR1 with the drain skipped — 14 runs aborted mid-flight), the
# gateway boots into main-session restart recovery and REPLAYS each interrupted
# main session. While a replay holds `agent:<id>:main`, every direct turn on
# that key is rejected at claim time with
#   Session "agent:<id>:main" changed while starting work. Retry.
# (dist/agent-command-*.js:349 — claimMainSessionRecoveryOwner in
# dist/main-session-recovery-store-*.js returns "invalidated" because the
# foreground claim is a no_change while entry.mainRestartRecovery is held).
# Observed: agent:clio:main replayed 14:44:18Z → 15:00:54Z (16.5 min); 6 turns
# rejected inside that window, the first success 3 min after the terminal
# line; the pattern repeated verbatim on the next restart at 15:09:17Z. Slack
# thread keys are separate sessions and are not held by a main replay.
#
# The journal pair is the authoritative signal:
#   [main-session-restart-recovery] started interrupted main session: <key>
#   [main-session-restart-recovery] main-session restart recovery terminal: session=<key> run=… status=… reason=…
# A replay is PENDING between them and CLEAR after the terminal (whatever its
# status — a retry logs a fresh `started`). Only lines for the exact key count.
# ──────────────────────────────────────────────────────────────

# restart_recovery_state <session-key> <journal-text> — pure, no I/O.
# Echoes exactly one of: pending | clear. Walks the journal IN ORDER so a
# terminal followed by a later started is pending, not clear.
restart_recovery_state() {
  local key="$1" journal="$2" state=clear line
  while IFS= read -r line; do
    case "$line" in
      *"[main-session-restart-recovery] started interrupted main session: ${key}")
        state=pending ;;
      *"[main-session-restart-recovery] main-session restart recovery terminal: session=${key} run="*)
        state=clear ;;
    esac
  done <<< "$journal"
  echo "$state"
}

# restart_recovery_error <response> — true when an agent turn's output carries
# the runtime's recovery-claim rejection, so a caller can name the cause
# instead of reporting a generic timeout.
restart_recovery_error() {
  case "$1" in
    *"changed while starting work"*) return 0 ;;
    *) return 1 ;;
  esac
}

# restart_recovery_ping_verdict <rc> <response> — pure classification of a
# PONG probe. Echoes exactly one of: pass | recovery | timeout | fail.
# The recovery text wins first: `openclaw agent` exits NON-ZERO on a claim
# rejection, so a caller must capture the output without replacing it on a
# bad exit (`if response=$(…); then rc=0; else rc=$?; fi`, never
# `|| response="TIMEOUT"`) or this classifier never sees the error and the
# probe degrades to the generic timeout this lib exists to name. PASS requires
# BOTH a clean rc and the token, never the token alone: preserving stderr on a
# bad exit means an error that echoes the prompt ("request \"respond with
# PONG\" failed: …", rc 1) now reaches the matcher, and a keyword-only match
# would call that success (the same trap mesh_probe_verdict closed in PR #791;
# QA reproduced it against c2e5fc7f). rc 124 is timeout(1)'s own deadline
# signal.
restart_recovery_ping_verdict() {
  local rc="$1" response="$2"
  if restart_recovery_error "$response"; then
    echo recovery
    return
  fi
  if [ "${rc:-1}" -eq 0 ] &&
     printf '%s' "$response" | grep -qi 'pong'; then
    echo pass
    return
  fi
  if [ "${rc:-1}" -eq 124 ]; then
    echo timeout
    return
  fi
  echo fail
}

# restart_recovery_journal <profile> — the gateway journal since the unit's
# current activation (only THIS process's recovery lines can be pending).
# Seam: RESTART_RECOVERY_JOURNAL_FILE replaces the live read under bats.
# Exit 2 when the journal cannot be read.
restart_recovery_journal() {
  local profile="$1" since
  if [ -n "${RESTART_RECOVERY_JOURNAL_FILE:-}" ]; then
    cat "$RESTART_RECOVERY_JOURNAL_FILE" 2>/dev/null || return 2
    return 0
  fi
  since="$(systemctl show "openclaw-gateway-${profile}" -p ActiveEnterTimestamp --value 2>/dev/null)" || return 2
  [ -n "$since" ] || return 2
  journalctl -u "openclaw-gateway-${profile}.service" --since "$since" -o short-iso --utc --no-pager 2>/dev/null || return 2
}

# restart_recovery_pending_key <keys-csv> <journal-text> — pure. Echoes the
# FIRST key of a comma-separated list whose replay is pending; echoes nothing
# when every key is clear. A probe that spans two sessions (the mesh probe is
# a turn on agent:clio:main that nests a sessions_send into agent:cto:main)
# must be clear on ALL of them — a replay on the downstream key rejects the
# nested turn just the same.
restart_recovery_pending_key() {
  local keys="$1" journal="$2" key
  local -a list=()
  IFS=, read -r -a list <<< "$keys"
  for key in "${list[@]}"; do
    [ -n "$key" ] || continue
    if [ "$(restart_recovery_state "$key" "$journal")" = pending ]; then
      printf '%s\n' "$key"
      return 0
    fi
  done
  return 0
}

# restart_recovery_wait <profile> <keys-csv> <deadline-secs> [poll-secs]
# Polls until every key's replay is clear. Returns:
#   0 clear | 1 still pending at the deadline | 2 journal unreadable
#   3 deadline/poll is not a non-negative integer (validated BEFORE the loop:
#     `[ … -ge abc ]` prints "integer expression expected", evaluates false
#     on every iteration, and the "bounded" wait never ends — QA reproduced
#     it with SMOKE_RECOVERY_WAIT_SECS=abc, rc 124 under timeout)
# On 1, RESTART_RECOVERY_PENDING_KEY names the key that is still replaying
# (empty otherwise) so a caller can memo and report the exact session.
# shellcheck disable=SC2034  # consumed by the sourcing script (smoke-test.sh)
RESTART_RECOVERY_PENDING_KEY=""
# shellcheck disable=SC2034  # RESTART_RECOVERY_PENDING_KEY is read by smoke-test.sh
restart_recovery_wait() {
  local profile="$1" keys="$2" deadline="${3:-120}" poll="${4:-5}"
  local start now journal pending
  RESTART_RECOVERY_PENDING_KEY=""
  case "$deadline" in ''|*[!0-9]*) return 3 ;; esac
  case "$poll" in ''|*[!0-9]*) return 3 ;; esac
  start="$(date +%s)"
  while :; do
    if ! journal="$(restart_recovery_journal "$profile")"; then
      return 2
    fi
    pending="$(restart_recovery_pending_key "$keys" "$journal")"
    [ -z "$pending" ] && return 0
    now="$(date +%s)"
    if [ $((now - start)) -ge "$deadline" ]; then
      RESTART_RECOVERY_PENDING_KEY="$pending"
      return 1
    fi
    sleep "$poll"
  done
}
