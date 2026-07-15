#!/bin/bash
# ──────────────────────────────────────────────────────────────
# codex-keepalive.sh — PROACTIVE codex OAuth expiry SAFETY-NET pager.
#
# The recurring fleet outage (gpt-5.5 → openrouter/gpt-5.4-mini) is the
# ChatGPT-OAuth access token LAPSING: `authentication token is expired` on the
# OAuth route. Root cause: hydra keeps the bundled `openai` plugin DISABLED to
# dodge #90925, but that plugin owns the refresh machinery — so NOTHING on the
# box auto-refreshes codex (upstream openclaw#57399 is wontfix). None of the
# three structural guards (ensure-codex-{auth,refresh-lock-shared,version-pinned})
# can prevent it.
#
# The actual PREVENTION is the twice-weekly `codex-token-refresh` systemd timer
# (scripts/codex-token-refresh.sh → scripts/lib/codex-oauth-refresh.sh) which
# refreshes the token out-of-band and restarts the gateways to load it. THIS
# script is the SAFETY NET: every 15 min it reads the token's own expiry from
# the canonical auth store (auth-profiles.json — OUR source of truth, written
# solely by codex-oauth-refresh.sh) and pages #clio_devops if the token is
# unexpectedly close to expiry (the scheduled refresh failed, or the token life was
# shorter than expected) — BEFORE the cliff, so a human runs the refresh
# deliberately instead of after a surprise outage. openclaw-watchdog.sh only
# pages REACTIVELY (after the 401 storm).
#
# It deliberately does NOT refresh/restart itself: the gateway only loads a token
# on restart, and unscheduled restarts from a 15-min cron are worse than a page.
# The page points at the recovery runbook (`codex-oauth-refresh.sh`).
#
# NOTE: the CLI is NOT a usable data source. `openclaw models status --check`
# always exits 1 (it flags the deliberately-disabled `openai` provider as
# "missing"), and as of openclaw 2026.7.x `--json` carries NO expiry data at
# all (profiles surface as type:"token", status:"static" — no remainingMs
# anywhere; verified live 2026-07-14, when the pre-7.1 remainingMs parse went
# silently blind for hours during a fleet 401 storm). Reading the canonical
# store directly is also runtime-schema-proof.
#
# BLINDNESS PAGES: if the store is unreadable or holds no openai-codex
# profiles, that is itself the exact silent-window class this pager exists to
# close — page (cooldown-limited), never skip-and-log.
#
# Install on node-8: managed by scripts/install-aux-units.sh (writes
# /etc/cron.d/codex-keepalive). Do not hand-edit the cron file on node-8.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[codex-keepalive $(date -u +%Y-%m-%dT%H:%M:%SZ)]"

# Tunables (env-overridable; the bats suite overrides the store root + state dir).
# Canonical codex token lives on the main profile; every other store is derived
# from it, so checking main reflects the one shared token. Space-separated for
# future use.
CODEX_KEEPALIVE_PROFILES="${CODEX_KEEPALIVE_PROFILES:-main}"
# Root under which the profile state dirs live; the canonical store is
# <root>/.openclaw-<profile>/agents/main/agent/auth-profiles.json.
CODEX_KEEPALIVE_STORE_ROOT="${CODEX_KEEPALIVE_STORE_ROOT:-/root}"
# Page pre-emptively when the token has less than this many minutes left. Default
# 2 days (2880) — strictly BELOW the steady-state trough so it never false-pages
# in normal operation. The codex token life is ~10d (measured live: the
# auth.openai.com/oauth/token grant returns expires_in=864000s, and a fresh
# `models status` shows remainingMs ≈ 864000000), and codex-token-refresh runs
# TWICE weekly (~every 3.5d), so a healthy token never drops below ~6.5d; 2d
# fires only when refreshes have genuinely been failing for days — with 2d runway.
WARN_MIN="${CODEX_KEEPALIVE_WARN_MIN:-2880}"
# Re-alert at most once per this many minutes (token life is ~days; hourly ok).
COOLDOWN_MIN="${CODEX_KEEPALIVE_COOLDOWN_MIN:-60}"
# Overridable so the bats suite writes throwaway cooldown stamps instead of
# clobbering the production keepalive's real /tmp clocks.
KEEPALIVE_STATE_DIR="${KEEPALIVE_STATE_DIR:-/tmp}"

# Source the shared Slack helper (same #clio_devops devops-bot path the
# watchdog uses). Locate via this script's own dir so it works from a worktree
# (laptop test) or the /opt/hydra deploy mirror.
_KEEPALIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_KEEPALIVE_DIR/lib/slack-notify.sh"

log() { echo "$LOGPREFIX $1"; }

# _cooldown_ok <stampfile> <minutes> — true if last alert older than N min.
_cooldown_ok() {
  local stamp="$1" mins="$2" now last
  now=$(date +%s)
  [ -r "$stamp" ] || return 0
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  [ "$(( now - last ))" -ge "$(( mins * 60 ))" ]
}

# _codex_remaining_ms <profile> — milliseconds until the SOONEST openai-codex
# expiry in the profile's canonical auth store (may be negative = already
# expired). Echoes nothing if the store has no openai-codex profiles. Returns 2
# if the store is missing/unreadable/not JSON.
_codex_remaining_ms() {
  local profile="$1" store now_ms rem
  store="$CODEX_KEEPALIVE_STORE_ROOT/.openclaw-$profile/agents/main/agent/auth-profiles.json"
  [ -r "$store" ] || return 2
  now_ms="$(( $(date +%s) * 1000 ))"
  # `.expires | numbers` drops absent/non-numeric expiries instead of letting a
  # malformed profile turn min() into a jq runtime error.
  rem=$(jq -r --argjson now "$now_ms" '
    [ .profiles // {} | to_entries[]
      | select(.key | startswith("openai-codex:"))
      | .value.expires | numbers ]
    | if length == 0 then empty else (min - $now) end' "$store" 2>/dev/null) || return 2
  printf '%s' "$rem"
}

_page_expiring() {
  local profile="$1" rem_min="$2"
  slack_notify ":hourglass_flowing_sand: *Codex OAuth token expiring* on node-8 (\`${profile}\`) — ~${rem_min}m left and the scheduled auto-refresh has not renewed it. Refresh NOW to avoid the fleet dropping to \`openrouter/openai/gpt-5.6-luna\`: \`/opt/hydra/scripts/lib/codex-oauth-refresh.sh && systemctl restart openclaw-gateway-main openclaw-gateway-edge\`. If it reports \`invalid_grant\` the refresh token is dead → device-code re-auth (RUNBOOK §\"Codex Token Lapse\"). (Proactive pre-empt — the reactive watchdog only fires AFTER the 401s start.)"
}

_page_blind() {
  local profile="$1" reason="$2"
  slack_notify ":rotating_light: *Codex keepalive BLIND* on node-8 (\`${profile}\`) — ${reason}. The pre-expiry safety net cannot see the codex token, so the next lapse would hit UNWARNED (exactly the 2026-07-14 silent window). Check \`${CODEX_KEEPALIVE_STORE_ROOT}/.openclaw-${profile}/agents/main/agent/auth-profiles.json\` and RUNBOOK §\"Codex Token Lapse\"."
}

main() {
  # Fail-loud self-check: the notify path and jq must be present, else this
  # keepalive would silently never page (the exact silent-window class it exists
  # to close).
  if ! declare -F slack_notify >/dev/null; then
    log "FATAL: slack_notify not defined (lib/slack-notify.sh missing?)" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "FATAL: jq not found" >&2
    exit 1
  fi

  local profile rem rem_min blind_reason blind_stamp
  read -ra _profiles <<< "$CODEX_KEEPALIVE_PROFILES"
  for profile in "${_profiles[@]}"; do
    # Blindness is a page, not a skip: a keepalive that can't read the token's
    # expiry is the silent-window failure it exists to prevent (post-7.1 it
    # logged "skipping" for hours while the fleet 401'd).
    blind_reason=""
    if ! rem=$(_codex_remaining_ms "$profile"); then
      blind_reason="the canonical auth store is missing/unreadable/not JSON"
    elif [ -z "$rem" ] || ! [[ "$rem" =~ ^-?[0-9]+$ ]]; then
      blind_reason="no openai-codex profile with a numeric expiry in the canonical auth store (rem='$rem')"
    fi
    if [ -n "$blind_reason" ]; then
      log "$profile: BLIND — $blind_reason"
      blind_stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-${profile}-blind-cooldown"
      if _cooldown_ok "$blind_stamp" "$COOLDOWN_MIN"; then
        _page_blind "$profile" "$blind_reason"
        date +%s > "$blind_stamp"
        log "$profile: paged #clio_devops (keepalive blind)"
      else
        log "$profile: blind but within cooldown — not re-paging"
      fi
      continue
    fi
    rem_min=$(( rem / 60000 ))

    if [ "$rem" -le 0 ]; then
      # Already lapsed — the reactive watchdog owns this page (it keys on the
      # journal 401 signature). Don't double-alert; just log.
      log "$profile: codex token ALREADY EXPIRED (${rem_min}m) — reactive watchdog owns the page"
      continue
    fi
    if [ "$rem" -gt "$(( WARN_MIN * 60000 ))" ]; then
      log "$profile: codex token healthy (${rem_min}m remaining)"
      continue
    fi

    log "$profile: codex token EXPIRING in ${rem_min}m (warn threshold ${WARN_MIN}m)"
    local stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-${profile}-cooldown"
    if _cooldown_ok "$stamp" "$COOLDOWN_MIN"; then
      _page_expiring "$profile" "$rem_min"
      date +%s > "$stamp"
      log "$profile: paged #clio_devops (pre-emptive)"
    else
      log "$profile: expiring but within cooldown — not re-paging"
    fi
  done
}

main "$@"
