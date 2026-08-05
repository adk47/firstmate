#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# mesh-probe.sh — pure/injectable helpers for scripts/smoke-test.sh's
# cross-agent mesh behavioral probe (Clio -> CTO via sessions_send).
#
# Sourced by smoke-test.sh; unit-tested by scripts/tests/mesh-probe.bats.
# Split out for the same reason as scripts/lib/websearch-probe.sh: smoke-test.sh
# runs unconditional host-wide checks (pgrep, systemctl, curl) the instant it is
# sourced, so bats cannot source it without a live gateway.
#
# WHY A DEDICATED TOKEN AND NOT A KEYWORD MATCH (QA finding on PR #791):
# the probe previously passed on `grep -qi 'cto\|responded\|pong\|acknowledged'`.
# That matches the FAILURE sentence "I couldn't reach CTO" just as happily as a
# success, and the agent turn exits 0 while reporting that failure — so the
# probe could report PASS precisely when cross-agent messaging was broken. The
# keyword set was harmless only while the probe was incapable of reaching rc=0
# at all (it called a nonexistent `agent send` subcommand); repairing the
# invocation is what made the weak pattern load-bearing.
#
# So the prompt now asks CTO for an exact token and asks Clio to self-report an
# explicit failure marker, and this classifier requires the positive token.
#
# HONEST LIMIT — this is NOT proof a real sessions_send happened. Clio is handed
# MESH_OK in its own prompt and could echo it without ever reaching CTO. The
# sibling web_search probe avoids that by reading positive rollout evidence
# (a `web_search_end` event), and the same trick does not currently work here:
# `sessions_send` is a METHOD of the global `.tools.sessions` tool rather than a
# named tool (see the hard gate in smoke-test.sh above this probe), and no
# `function_call` for it appears in Clio's codex-home rollouts even for a
# round-trip verified successful by hand on node-8 (2026-08-04). Claiming
# rollout evidence we cannot actually read would be worse than not claiming it.
# What this DOES buy: a failure report can no longer be mistaken for a success,
# which is the defect QA flagged. The structural `.tools.sessions.visibility`
# check remains the hard gate; this stays a soft warn.
# ──────────────────────────────────────────────────────────────

# The exact tokens the probe prompt asks for. Kept here (not inlined in the
# prompt string) so the prompt and the classifier can never drift apart.
MESH_OK_TOKEN="${MESH_OK_TOKEN:-MESH_OK}"
MESH_FAIL_TOKEN="${MESH_FAIL_TOKEN:-MESH_FAIL}"

# mesh_probe_prompt — the message sent to Clio. Instructs BOTH halves: emit
# MESH_OK only on a real reply from CTO, and MESH_FAIL (not prose) on any
# failure, so an unreachable-CTO turn is self-identifying rather than something
# we have to recognise from free text.
mesh_probe_prompt() {
  printf '%s' "Use sessions_send to ask the cto agent to reply with the exact token ${MESH_OK_TOKEN}. Then report back: if CTO replied, output the token CTO sent verbatim. If you could NOT reach CTO for any reason, output exactly ${MESH_FAIL_TOKEN} and the reason. Output nothing else."
}

# mesh_probe_verdict <rc> <response> — pure classification, no I/O.
# Echoes exactly one of: pass | fail | inconclusive.
#
# Precedence mirrors _websearch_probe_verdict: an explicit failure marker in the
# TEXT wins regardless of the exit code, because the text is the only place a
# self-reported failure can appear and we must never lose it to the rc. PASS
# requires BOTH a clean rc and the positive token — never the absence of a
# failure marker, which is what let the old keyword match report false success.
# Everything else is inconclusive: the caller retries, then degrades to a warn.
# This function never returns pass on an ambiguous read.
mesh_probe_verdict() {
  local rc="$1" response="$2"
  # Word-boundaried so a token embedded in a larger identifier does not match.
  if printf '%s' "$response" | grep -qE "(^|[^A-Za-z0-9_])${MESH_FAIL_TOKEN}([^A-Za-z0-9_]|$)"; then
    echo fail
    return
  fi
  if [ "${rc:-1}" -eq 0 ] &&
     printf '%s' "$response" | grep -qE "(^|[^A-Za-z0-9_])${MESH_OK_TOKEN}([^A-Za-z0-9_]|$)"; then
    echo pass
    return
  fi
  echo inconclusive
}

# mesh_probe_detail <rc> <verdict> <response> — one-line diagnostic for the log
# / warn message. Distinguishes the failure modes that the old
# `|| MESH_RESPONSE="TIMEOUT"` collapsed into the single word "TIMEOUT":
# rc 124 is timeout(1)'s own deadline signal, any other non-zero rc is the
# command itself failing (surface its stderr verbatim — that is what would have
# revealed the nonexistent `agent send` subcommand in ~0s instead of hiding it
# for four months), and rc 0 without the token means the turn ran but did not
# confirm.
mesh_probe_detail() {
  local rc="$1" verdict="$2" response="$3" head
  head="$(printf '%s' "$response" | tr '\n' ' ' | cut -c1-200)"
  case "$verdict" in
    fail)
      echo "Clio reported ${MESH_FAIL_TOKEN}: $head"
      ;;
    *)
      if [ "${rc:-1}" -eq 124 ]; then
        echo "timed out after 60s"
      elif [ "${rc:-1}" -ne 0 ]; then
        echo "exited rc=$rc: $head"
      else
        echo "ran ok but no ${MESH_OK_TOKEN} token in reply: $head"
      fi
      ;;
  esac
}
