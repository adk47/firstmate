#!/bin/bash
# ──────────────────────────────────────────────────────────────
# codex-oauth-refresh.sh — out-of-band ChatGPT-OAuth refresh for codex.
#
# WHY THIS EXISTS: hydra keeps the bundled `openai` provider plugin DISABLED to
# dodge #90925 (enabling it routes openai/gpt-5.5 to the api-key endpoint → fleet
# death). But that plugin also owns BOTH the device-code login AND the
# refresh-on-use machinery — so with it disabled, NOTHING on the box ever
# refreshes the codex OAuth token, and it lapses ~every 10 days
# (`authentication token is expired`, RUNBOOK §"Codex Token Lapse"). The native
# `openclaw models auth login --provider openai-codex` also fails ("No provider
# plugins found") for the same reason.
#
# This helper does the refresh OURSELVES — a direct `grant_type=refresh_token`
# POST to auth.openai.com/oauth/token (the exact flow the disabled `openai`
# plugin would run, and what was done manually on 2026-06-19) — writing the
# rotated token straight into the canonical auth store. Because nothing else
# refreshes codex, this process is the SOLE refresher → no single-use-token race.
#
# Used two ways: (1) standalone recovery when the token has already lapsed;
# (2) the durable auto-prevention: called by the twice-weekly codex-token-refresh
#     timer (scripts/codex-token-refresh.sh) BEFORE expiry. (codex-keepalive.sh
#     does NOT call this — it is only the safety-net pager.)
#
# SAFETY (single-use rotating refresh token — a spent-but-lost token = broken
# chain = forced browser re-auth):
#   - backs up the whole store before touching it;
#   - dumps the RAW token response to disk BEFORE any store write, so a rotated
#     token is always recoverable even if the merge/rename fails;
#   - writes a profile ONLY on a fully-valid response (access+refresh+expires_in);
#     a failed/garbled POST leaves that profile UNTOUCHED (old token unspent);
#   - atomic write (temp + rename, mode 0600); per-profile independent;
#   - fail-loud: non-zero exit + Slack page if any profile fails.
#
# After a successful refresh the gateways must RESTART to load the new token
# (they don't re-read the store on their own):
#   systemctl restart openclaw-gateway-main openclaw-gateway-edge
#
# CAVEAT: the live OAuth response shape cannot be unit-tested without spending a
# real token; `--dry-run` shows what it would do. The defenses above mean a
# wrong response shape fails safe (store untouched) rather than corrupting it.
# ──────────────────────────────────────────────────────────────
set -euo pipefail
# Create all token-bearing files (backup, raw dump, temp store) tight from birth
# — closes the create-at-default-umask-then-chmod-600 TOCTOU window.
umask 077

OAUTH_TOKEN_URL="${CODEX_OAUTH_TOKEN_URL:-https://auth.openai.com/oauth/token}"
OAUTH_CLIENT_ID="${CODEX_OAUTH_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
OAUTH_SCOPE="${CODEX_OAUTH_SCOPE:-openid profile email offline_access}"
STORE="${CODEX_AUTH_STORE:-/root/.openclaw-main/agents/main/agent/auth-profiles.json}"
BACKUP_DIR="${CODEX_AUTH_BACKUP_DIR:-/root/codex-auth-backups}"
CURL_BIN="${CURL_BIN:-curl}"

LOGPREFIX="[codex-oauth-refresh $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $1"; }

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Optional Slack page on failure (best-effort; absent in the bats sandbox).
_REFRESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$_REFRESH_DIR/slack-notify.sh" ]; then
  # shellcheck source=slack-notify.sh
  source "$_REFRESH_DIR/slack-notify.sh"
fi
_page() { declare -F slack_notify >/dev/null && slack_notify "$1" || true; }

# Structural preconditions fail loud AND page — a broken refresher would
# otherwise surface only as a failed systemd unit with no alert.
command -v jq >/dev/null 2>&1 || { log "FATAL: jq not found"; _page ":rotating_light: *Codex OAuth refresh BROKEN* on node-8 — jq not found, cannot refresh the codex token. The fleet will lapse to gpt-5.4-mini at the next expiry."; exit 2; }
command -v "$CURL_BIN" >/dev/null 2>&1 || { log "FATAL: curl not found"; _page ":rotating_light: *Codex OAuth refresh BROKEN* on node-8 — curl not found, cannot refresh the codex token."; exit 2; }
[ -r "$STORE" ] || { log "FATAL: auth store not readable: $STORE"; _page ":rotating_light: *Codex OAuth refresh BROKEN* on node-8 — auth store not readable: \`$STORE\`."; exit 2; }

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR" 2>/dev/null || true
# Prune token-bearing backups/dumps older than 30d: old rotated refresh tokens
# are already spent, but old access tokens were live secrets — don't accumulate
# them on disk forever (the scheduled timer + recovery runs would otherwise grow
# /root unbounded). Logrotate covers /var/log only, not this dir.
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'auth-profiles-*.json' -o -name 'refresh-resp-*.json' \) -mtime +30 -delete 2>/dev/null || true
ts="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$DRY_RUN" -eq 0 ]; then
  cp -a "$STORE" "$BACKUP_DIR/auth-profiles-$ts.json"
  log "backed up store → $BACKUP_DIR/auth-profiles-$ts.json"
fi

_keys=()
while IFS= read -r _k; do [ -n "$_k" ] && _keys+=("$_k"); done \
  < <(jq -r '.profiles | keys[] | select(test("openai-codex"))' "$STORE" 2>/dev/null)
if [ "${#_keys[@]}" -eq 0 ]; then
  log "FATAL: no openai-codex profiles in $STORE"
  _page ":rotating_light: *Codex OAuth refresh BROKEN* on node-8 — no \`openai-codex:*\` profiles in the auth store; cannot refresh."
  exit 2
fi

failed=0 ok=0
for key in "${_keys[@]}"; do
  refresh_tok="$(jq -r --arg k "$key" '.profiles[$k].refresh // empty' "$STORE")"
  if [ -z "$refresh_tok" ]; then
    log "$key: no refresh token stored — needs device-code re-auth"; failed=$((failed+1)); continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "$key: DRY-RUN — would POST grant_type=refresh_token to $OAUTH_TOKEN_URL"; ok=$((ok+1)); continue
  fi

  resp="$("$CURL_BIN" -sS -m 30 -X POST "$OAUTH_TOKEN_URL" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=$OAUTH_CLIENT_ID" \
    --data-urlencode "refresh_token=$refresh_tok" \
    --data-urlencode "scope=$OAUTH_SCOPE" 2>/dev/null || true)"

  # Persist the raw response (may carry a freshly-rotated token) BEFORE any
  # store write, so a rotated token is never lost to a later failure.
  resp_dump="$BACKUP_DIR/refresh-resp-$(printf '%s' "$key" | tr '/:@' '___')-$ts.json"
  printf '%s' "$resp" > "$resp_dump"; chmod 600 "$resp_dump" 2>/dev/null || true

  # `|| true` is load-bearing: jq exits 5 on a NON-JSON body (e.g. an HTML 5xx
  # page from the OAuth CDN edge, or a `-m 30` truncated body). Without it,
  # `set -e` aborts here BEFORE the fail-loud page below — silently defeating the
  # alerting. With it, a garbled body yields empty fields → the recovery branch.
  access="$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null || true)"
  new_refresh="$(printf '%s' "$resp" | jq -r '.refresh_token // empty' 2>/dev/null || true)"
  expires_in="$(printf '%s' "$resp" | jq -r '.expires_in // empty' 2>/dev/null || true)"

  if [ -z "$access" ] || [ -z "$new_refresh" ] || ! [[ "$expires_in" =~ ^[0-9]+$ ]]; then
    local_err="$(printf '%s' "$resp" | jq -r '.error // .error_description // "unparseable response"' 2>/dev/null || true)"
    log "$key: refresh FAILED (${local_err:-unparseable response}) — store left UNTOUCHED (raw resp: $resp_dump)"
    failed=$((failed+1)); continue
  fi

  new_expires=$(( ( $(date +%s) + expires_in ) * 1000 ))
  tmp="$STORE.tmp.$$"
  # chmod+mv are INSIDE the guard: a chmod/mv failure (RO fs, perms) must route
  # to the else (recovery log + page), not abort the script via set -e.
  if jq --arg k "$key" --arg a "$access" --arg r "$new_refresh" --argjson e "$new_expires" \
       '.profiles[$k].access=$a | .profiles[$k].refresh=$r | .profiles[$k].expires=$e' \
       "$STORE" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && chmod 600 "$tmp" && mv "$tmp" "$STORE"; then
    log "$key: refreshed OK — new expiry $(date -u -d "@$(( new_expires / 1000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "+${expires_in}s")"
    ok=$((ok+1))
  else
    rm -f "$tmp"
    log "$key: store write FAILED after a successful POST — rotated token is in $resp_dump (RECOVER IT)"
    failed=$((failed+1))
  fi
done

log "done: $ok refreshed, $failed failed"

# openclaw >= 2026.7: the runtime reads codex auth from the main-agent sqlite
# row + each agent's codex-home/auth.json, NOT from the canonical JSON we just
# rotated — fan the new ACCESS token out (the refresh token stays ONLY here;
# codex-auth-sync.sh enforces that invariant and no-ops on pre-2026.7
# runtimes). A failed/missing sync means the fleet keeps running on the OLD
# access token until it expires — page AND exit non-zero, same severity as a
# failed refresh (a 0 exit here would show the timer/systemd unit green while
# the derived stores ride a stale token).
SYNC_BIN="${CODEX_AUTH_SYNC_BIN:-$_REFRESH_DIR/codex-auth-sync.sh}"
sync_failed=0
if [ "$ok" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -x "$SYNC_BIN" ]; then
    # CANON_DIR follows the store we just rotated, so a CODEX_AUTH_STORE
    # override (sandbox/manual recovery) fans out ITS tokens, not /root's.
    if ! CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}" \
         CANON_DIR="$(cd "$(dirname "$STORE")" && pwd)" \
         "$SYNC_BIN"; then
      log "WARNING: codex-auth-sync.sh failed after refresh — derived stores are STALE"
      _page ":rotating_light: *Codex auth sync FAILED* on node-8 after a successful token refresh — the rotated access token did NOT reach the runtime stores (sqlite row / codex-home). Run \`scripts/lib/codex-auth-sync.sh\` manually, then restart gateways."
      sync_failed=1
    fi
  else
    log "WARNING: codex-auth-sync.sh missing/not executable — derived stores NOT synced"
    _page ":rotating_light: *Codex auth sync MISSING* on node-8 — the token refreshed but scripts/lib/codex-auth-sync.sh is absent/not executable, so the runtime stores were NOT updated. Restore the script and run it, then restart gateways."
    sync_failed=1
  fi
fi

if [ "$failed" -gt 0 ]; then
  _page ":rotating_light: *Codex OAuth refresh FAILED* on node-8 — $failed/$(( ok + failed )) profile(s) did not refresh (likely a dead refresh token → needs device-code re-auth, see RUNBOOK §\"Codex Token Lapse\"). $ok succeeded."
  exit 1
fi
if [ "$sync_failed" -gt 0 ]; then
  log "refresh OK but derived-store sync FAILED — run scripts/lib/codex-auth-sync.sh, then restart gateways"
  exit 1
fi
log "restart gateways to load the new token: systemctl restart openclaw-gateway-main openclaw-gateway-edge"
exit 0
