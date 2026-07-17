#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# websearch-probe.sh — pure/injectable helpers for scripts/smoke-test.sh's
# post-restart web_search probe (see #695/#701 incident: PR #695 set
# tools.web.search.provider:"codex" on main, which on openclaw 7.1 disables
# NATIVE codex search and left the managed worker unable to authenticate —
# web_search failed fleet-wide for ~15min, silently, because nothing probed
# it post-restart).
#
# Sourced by smoke-test.sh; unit-tested by scripts/tests/websearch-probe.bats.
# Split out of smoke-test.sh itself (which runs unconditional host-wide
# checks — pgrep, systemctl, curl — the instant it's invoked, so it can't be
# sourced by bats without a live gateway) so these functions can be tested
# in isolation, same pattern as scripts/lib/codex-health.sh being a
# sourceable library for scripts/openclaw-watchdog.sh.
#
# Why NOT trust `openclaw agent --json` output or the gateway journal as
# PASS evidence (verified live on node-8, 2026-07-16 — QA finding on PR
# #704, node-8 signal facts folded in here):
#   - `--json` carries NO tool-call transcript at all: the only
#     "web_search" token anywhere in a 30KB response is the skill/prompt
#     listing. A model reply of "SEARCH_STATUS: ok" is NOT proof a tool call
#     happened — the model can answer from training data (MusicBrainz is a
#     very well-known site) without ever invoking web_search.
#   - the gateway journal logs web_search FAILURES only
#     (`[tools] web_search failed: Reconnecting`) — it never logs successes,
#     so "nothing broken in the journal" is not proof something ran either.
# The one authoritative signal that a REAL web_search call executed is a
# `web_search_end` event in the scout agent's codex-home session rollout:
# verified live, a successful probe produced 12 web_search_end / 0
# Reconnecting in the newest rollout; the broken (managed-provider
# misconfigured) state produced Reconnecting / 0 web_search_end.
# ──────────────────────────────────────────────────────────────

# _websearch_rollout_glob <profile> — glob for the scout agent's codex-home
# session rollout files. Env-overridable (WEBSEARCH_PROBE_ROLLOUT_GLOB) so
# bats can point this at a throwaway fixture dir instead of the real
# /root/.openclaw-<profile> store on node-8.
_websearch_rollout_glob() {
  local profile="$1"
  echo "${WEBSEARCH_PROBE_ROLLOUT_GLOB:-/root/.openclaw-${profile}/agents/scout/agent/codex-home/sessions/*/*/*/rollout-*.jsonl}"
}

# _websearch_newest_rollout <glob> — path of the most-recently-modified file
# matching glob, or empty if none match. `ls -t` (not GNU-only `find
# -newer`) so this stays portable across the bats host (macOS) and node-8.
_websearch_newest_rollout() {
  local glob="$1"
  # No-match MUST return success with empty output: `ls -t` on an unmatched
  # glob exits non-zero, and under the caller's `set -euo pipefail` a non-zero
  # command substitution (baseline_path=$(...)) would abort the whole smoke
  # test before the probe reaches its retry-then-warn path. The trailing
  # `|| true` (with `2>/dev/null` swallowing the ls error) makes the empty
  # case a clean, empty success — no prior rollout is a valid state (fresh
  # host, or a scout that has never searched).
  # shellcheck disable=SC2086  # intentional glob expansion, not quoting
  ls -t $glob 2>/dev/null | head -n1 || true
}

# _websearch_rollout_hits <path> — count of `web_search_end` events in the
# given rollout file. Echoes 0 (not an error) for an empty/missing path — a
# profile with no rollout history yet has made "0 real calls so far".
_websearch_rollout_hits() {
  local path="$1" n
  [ -n "$path" ] && [ -r "$path" ] || { echo 0; return; }
  n=$(grep -c 'web_search_end' "$path" 2>/dev/null) || true
  echo "${n:-0}"
}

# _websearch_real_call_ran <profile> <baseline_path> <baseline_hits> —
# echoes 1 iff the newest scout rollout gained a web_search_end event since
# the pre-probe baseline (a brand-new rollout file counts as "gained" if it
# carries >=1 hit); echoes 0 otherwise, including "nothing changed" — the
# "model replied without actually calling the tool" case FINDING 2 (PR #704
# QA review) exists to catch.
_websearch_real_call_ran() {
  local profile="$1" baseline_path="$2" baseline_hits="$3"
  local glob after_path after_hits
  glob="$(_websearch_rollout_glob "$profile")"
  after_path="$(_websearch_newest_rollout "$glob")"
  after_hits="$(_websearch_rollout_hits "$after_path")"
  if [ "$after_path" != "$baseline_path" ]; then
    if [ "${after_hits:-0}" -gt 0 ]; then
      echo 1
    else
      echo 0
    fi
    return
  fi
  if [ "${after_hits:-0}" -gt "${baseline_hits:-0}" ]; then
    echo 1
  else
    echo 0
  fi
}

# _websearch_probe_verdict <response_text> <real_call_ran:0|1> — pure
# classification, no I/O.
#
# FINDING 1 fix (PR #704 QA): a BROKEN signature in the response text wins
# REGARDLESS of real_call_ran and regardless of the agent process's exit
# code — this function is handed the captured text directly, so a break can
# never be lost to a `response=$(...) || response="TIMEOUT"` clobber
# upstream (the original bug: a Reconnecting failure that also made the
# agent process exit non-zero discarded the real output before it could be
# matched against the break regex).
# FINDING 2 fix (PR #704 QA): PASS requires real_call_ran=1 (positive
# rollout evidence of an actual tool call); model text alone (e.g. a
# hallucinated "SEARCH_STATUS: ok") is never sufficient on its own.
# Anything else is "inconclusive" — callers retry once, then warn; this
# function never returns fail on an inconclusive read.
_websearch_probe_verdict() {
  local response="$1" real_call_ran="$2"
  if echo "$response" | grep -qiE 'Reconnecting|disabled or no provider is available|provider reconnection failed'; then
    echo fail
    return
  fi
  if [ "${real_call_ran:-0}" -eq 1 ]; then
    echo pass
    return
  fi
  echo inconclusive
}

# websearch_probe_attempt <profile> <prompt> — runs ONE real probe attempt
# and echoes exactly two lines: `VERDICT=<fail|pass|inconclusive>` and
# `DETAIL=<diagnostic text>` (the matched break signature on fail, a short
# rollout-evidence note on pass, or the raw exit code + reason on
# inconclusive). Snapshots the newest scout rollout + its web_search_end
# count BEFORE invoking openclaw (the baseline), invokes the agent turn
# WITHOUT clobbering the captured output on a nonzero exit (FINDING 1), then
# classifies via _websearch_probe_verdict.
websearch_probe_attempt() {
  local profile="$1" prompt="$2"
  local glob baseline_path baseline_hits response rc real_ran verdict detail
  glob="$(_websearch_rollout_glob "$profile")"
  baseline_path="$(_websearch_newest_rollout "$glob")"
  baseline_hits="$(_websearch_rollout_hits "$baseline_path")"

  if response=$(timeout 150 openclaw --profile "$profile" agent --agent scout --json --message "$prompt" 2>&1); then
    rc=0
  else
    rc=$?
  fi

  real_ran="$(_websearch_real_call_ran "$profile" "$baseline_path" "$baseline_hits")"
  verdict="$(_websearch_probe_verdict "$response" "$real_ran")"

  case "$verdict" in
    fail)
      detail="$(echo "$response" | grep -ioE 'Reconnecting[^"]*|disabled or no provider is available|provider reconnection failed' | head -1)"
      ;;
    pass)
      detail="confirmed via scout rollout web_search_end event"
      ;;
    *)
      detail="rc=${rc}, no confirmed tool call (agent may not have searched, or timed out)"
      ;;
  esac

  echo "VERDICT=${verdict}"
  echo "DETAIL=${detail}"
}
