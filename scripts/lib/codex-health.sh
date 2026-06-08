#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-health.sh — sourceable helpers for detecting Codex
# (OpenAI agentRuntime) health problems on the EDGE gateway.
#
# Sourced by scripts/openclaw-watchdog.sh; unit-tested by
# scripts/tests/codex-health.bats. The log-scanning functions read
# journal text on STDIN and echo an integer, so they are testable
# with heredoc fixtures and never call journalctl/ssh themselves —
# the same pure-function pattern as scripts/lib/drift-check.sh.
#
# Why these specific signatures (verified live on hydra, openclaw
# 2026.5.27, against the 14-day edge journal during the #356 window):
# a Codex OAuth failure does NOT surface as `reason=auth` in the
# `[model-fallback/decision]` line — that field was only ever
# unknown / timeout / rate_limit on edge. It surfaces as the literal
# OAuth error string, and for the vision/image tool as the
# image/pdf "All image models failed" summary. So keying an alert on
# `reason=auth` would never fire here; we key on the substrings that
# actually appear.
# ──────────────────────────────────────────────────────────────

# codex_count_auth_invalidated — count Codex-OAuth-dead lines on stdin.
# Signature: "authentication token has been invalidated" (openclaw emits
# this from both the text turn and the image/pdf tool when the
# openai-codex credential is stale/rotated-away). Fired 35x / 14 days
# during the edge #356 window. After the auth symlink + restart this
# should read 0; any nonzero means edge's Codex token went stale and
# Caroline has silently degraded to the sonnet text fallback.
codex_count_auth_invalidated() {
  grep -c -i -e "authentication token has been invalidated" || true
}

# codex_count_refresh_reused — count Codex-OAuth REFRESH-RACE lines on stdin.
# This is a DIFFERENT failure signature from codex_count_auth_invalidated above
# and it is the one that went undetected for 3.5h on 2026-06-08: two gateway
# processes (main + edge) sharing the one canonical codex token both hit the
# 5-min pre-expiry refresh window at once, both POSTed a refresh, one rotated the
# single-use token and the loser got an HTTP 401 it surfaces as:
#   "OpenAI Codex token refresh failed (401): ... code=refresh_token_reused"
# and the model-fallback layer then logs `reason=auth_permanent` while it drops
# the whole codex fleet to openrouter/openai/gpt-5.4-mini. NONE of those strings
# matches codex_count_auth_invalidated (which keys on the May-29 "token has been
# invalidated" wording), so the old watchdog stayed silent. We key on the literal
# substrings that actually appear for THIS class. Any nonzero count = a codex
# refresh race / permanent-auth fallback is in progress on the scanned journal.
# The durable PREVENTION is scripts/lib/ensure-codex-refresh-lock-shared.sh
# (converge the two processes' refresh-lock dirs); this detector is the alarm.
codex_count_refresh_reused() {
  grep -c -i -E \
    -e "refresh_token_reused" \
    -e "OpenAI Codex token refresh failed" \
    -e "reason=auth_permanent" \
    -e "token refresh failed.*\(?401\)?" || true
}

# codex_count_vision_failures — count exhausted-vision lines on stdin.
# Signature: "All image models failed" (the image tool AND the pdf tool
# share this prefix). Caroline's image tool is agents.defaults.imageModel
# = codex/gpt-5.5 → openrouter gemini-3.5-flash → haiku-4.5, so this line
# only fires when ALL of codex AND both OpenRouter fallbacks failed — a
# real, customer-visible vision outage, not a transient codex-auth blip
# (a codex-only failure degrades to gemini and does NOT log this). NOTE:
# deliberately does NOT match the per-candidate "Model does not support
# images" line, which is benign noise emitted while iterating fallbacks.
codex_count_vision_failures() {
  grep -c -i -e "All image models failed" || true
}

# codex_edge_auth_symlink_status <auth-profiles-path>
# Filesystem health of edge/support's codex auth store. Echoes exactly
# one of: ok | not-symlink | dangling | missing
#   missing      — neither a file nor a symlink at the path
#   not-symlink  — a regular file (a deploy/rsync clobbered the symlink,
#                  or it was never provisioned by ensure-edge-codex-auth.sh)
#   dangling     — a symlink whose target no longer exists
#   ok           — a symlink whose target exists
# This checks STRUCTURE only — that edge's store is a live symlink to main's
# canonical codex token (the durability invariant a deploy/rsync can silently
# break, re-introducing #356). It deliberately does NOT inspect token
# `expires`: the codex access token is short-lived (~9h) and refresh-on-use.
# Verified live 2026-06-08 — the canonical auth-profiles.json had just rewritten
# itself (mtime 08:43:29Z, auth-state usageStats.lastUsed 08:43:28Z) to an
# `expires` only ~9h out, with 0 "authentication token has been invalidated"
# lines on edge. So `expires` is ALWAYS far inside any multi-hour window and
# carries no human-re-auth signal; the former 24h "stale" sub-check fired on
# essentially every cycle — a false alarm that re-auth would NOT have silenced
# (a fresh token is also <24h out). A genuinely dead/rotated-away token surfaces
# in the journal and is caught by codex_count_auth_invalidated above.
# Reads through the symlink, so it is portable across macOS (bats host) and
# Linux (node-8) without `readlink -f`.
codex_edge_auth_symlink_status() {
  local path="$1"
  if [ -L "$path" ]; then
    if [ ! -e "$path" ]; then echo dangling; return; fi
    echo ok; return
  fi
  if [ -e "$path" ]; then echo not-symlink; return; fi
  echo missing
}
