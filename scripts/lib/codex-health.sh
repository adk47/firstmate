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

# codex_edge_auth_symlink_status <auth-profiles-path> [min_hours_valid]
# Filesystem health of edge/support's codex auth store. Echoes exactly
# one of: ok | not-symlink | dangling | stale | missing
#   missing      — neither a file nor a symlink at the path
#   not-symlink  — a regular file (a deploy/rsync clobbered the symlink,
#                  or it was never provisioned by ensure-edge-codex-auth.sh)
#   dangling     — a symlink whose target no longer exists
#   stale        — symlink + target exists, but the freshest access-token
#                  `expires` (epoch ms) is < now + min_hours (default 24h):
#                  the shared main token is about to expire / has expired
#   ok           — symlink, target present, token fresh
# Reads the target THROUGH the symlink (jq follows it), so it is portable
# across macOS (bats host) and Linux (node-8) without `readlink -f`.
codex_edge_auth_symlink_status() {
  local path="$1" min_hours="${2:-24}"
  if [ -L "$path" ]; then
    if [ ! -e "$path" ]; then echo dangling; return; fi
    local max_exp
    max_exp=$(jq -r '[.profiles[]?.expires // 0] | max // 0' "$path" 2>/dev/null || echo 0)
    max_exp=${max_exp%.*}
    [[ "$max_exp" =~ ^[0-9]+$ ]] || max_exp=0
    local now_ms threshold_ms
    now_ms=$(( $(date +%s) * 1000 ))
    threshold_ms=$(( now_ms + min_hours * 3600 * 1000 ))
    if [ "$max_exp" -lt "$threshold_ms" ]; then echo stale; return; fi
    echo ok; return
  fi
  if [ -e "$path" ]; then echo not-symlink; return; fi
  echo missing
}
