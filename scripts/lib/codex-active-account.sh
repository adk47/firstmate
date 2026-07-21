#!/usr/bin/env bash
# codex-active-account.sh — sourceable resolver for WHICH codex (ChatGPT OAuth)
# subscription the fleet runs on.
#
# hydra runs ONE active codex account at a time (single-refresher invariant —
# see codex-auth-sync.sh) with the second account held as a hot standby, kept
# fresh by codex-oauth-refresh.sh (which refreshes ALL openai-codex:* profiles).
# Historically the active account was a baked-in default inside
# codex-auth-sync.sh, so when the active subscription hit its usage cap
# (2026-07-21: aaron@muso.ai capped at 100% while a fresh, paid standby idled)
# the whole codex surface died at once — sol/luna are model VARIANTS on one
# subscription, so the model-level fallback chain can never express "try the
# other account" — and the fleet rode the paid OpenRouter rung for hours.
# Worse, any live hot-switch died on the next deploy/heal: the rsync'd script
# restored the baked default.
#
# This lib makes the choice a durable, deploy-proof STATE FILE:
#   /var/lib/hydra/codex-active-account     (one line: openai-codex:<email>)
# outside the /opt/hydra rsync tree, written ONLY by codex-account-rotate.sh.
#
# Resolution order (applied by callers — codex-auth-sync.sh, codex-usage-report.sh):
#   1. $CODEX_AUTH_PRIMARY env      (explicit operator override, never persisted)
#   2. the state file               (iff its key exists in the canonical store)
#   3. the baked default            (aaron@muso.ai)
#
# Pure functions, no side effects at source time (edge-restart-gate.sh
# doctrine). Tested by scripts/tests/codex-account-rotate.bats.

CODEX_ACTIVE_ACCOUNT_FILE="${CODEX_ACTIVE_ACCOUNT_FILE:-/var/lib/hydra/codex-active-account}"
CODEX_ACTIVE_ACCOUNT_DEFAULT="${CODEX_ACTIVE_ACCOUNT_DEFAULT:-openai-codex:aaron@muso.ai}"

# caa_state_key <canonical-auth-profiles.json>
# Echo the state file's profile key iff the file is readable, non-empty AND the
# key exists in the canonical store. rc 1 (echoes nothing) otherwise. A
# present-but-unknown key WARNs on stderr — that is a mis-rotation or a
# canonical/state split-brain, not routine.
caa_state_key() {
  local canon="$1" key
  [ -r "$CODEX_ACTIVE_ACCOUNT_FILE" ] || return 1
  key="$(head -n1 "$CODEX_ACTIVE_ACCOUNT_FILE" 2>/dev/null | tr -d '[:space:]')" || key=""
  [ -n "$key" ] || return 1
  if ! jq -e --arg k "$key" '.profiles[$k] != null' "$canon" >/dev/null 2>&1; then
    echo "[codex-active-account] WARNING: $CODEX_ACTIVE_ACCOUNT_FILE names '$key' which is not a profile in $canon — ignoring the state file" >&2
    return 1
  fi
  printf '%s' "$key"
}

# caa_active_key <canonical-auth-profiles.json>
# The effective active account: state file if valid, else the baked default.
# (Env precedence is the CALLER's job via ${CODEX_AUTH_PRIMARY:-…} so an
# explicit operator override is visible at the call site.)
caa_active_key() {
  local canon="$1" key
  if key="$(caa_state_key "$canon")"; then
    printf '%s' "$key"
  else
    printf '%s' "$CODEX_ACTIVE_ACCOUNT_DEFAULT"
  fi
}

# caa_write_active <profile-key>
# Atomically persist the active account (0600, tmp+mv; mkdir -p the parent so
# a fresh box works). Callers validate the key against canonical BEFORE writing
# — a state file pointing at a nonexistent profile would only warn-and-default
# on read, but it still signals split-brain and pollutes every later log.
caa_write_active() {
  local key="$1" dir tmp
  dir="$(dirname "$CODEX_ACTIVE_ACCOUNT_FILE")"
  mkdir -p "$dir"
  tmp="$CODEX_ACTIVE_ACCOUNT_FILE.tmp.$$"
  printf '%s\n' "$key" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CODEX_ACTIVE_ACCOUNT_FILE"
}
