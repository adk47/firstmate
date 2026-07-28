#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-reauth.sh — device-code re-auth for a codex (ChatGPT OAuth) account.
#
# WHY THIS EXISTS: when an OAuth session is revoked upstream (2026-07-27:
# `token_invalidated` on aaron@muso.ai — a sign-in elsewhere ends the session),
# the refresh chain dies with it, so codex-oauth-refresh.sh answers
# `refresh_token_invalidated` and there is NO browser-free recovery. A human
# must complete a login. The obvious command does NOT work here:
#
#   openclaw models auth login --provider openai-codex --device-code
#     → "No provider plugins found"
#
# because the bundled `openai` plugin owns the device-code flow and hydra keeps
# it DISABLED and off `plugins.allow` to dodge #90925 (enabling it reroutes the
# fleet primary onto the api-key endpoint → fleet-wide `invalid_api_key`).
# Enabling it transiently is a live minefield: main self-restarts on memory
# pressure every ~40-60min, and a restart inside that window is a worse outage
# than the one being fixed.
#
# So we drive the NATIVE codex CLI instead — it is vendored inside the pinned
# @openclaw/codex plugin, owns its own OAuth, works headless, and needs no
# openclaw plugin state changed at all. (A hand-rolled curl to the device
# endpoint is NOT an option: auth.openai.com/oauth/device/code sits behind a
# Cloudflare challenge and answers 403 to a plain POST.)
#
# The credential is minted into a THROWAWAY CODEX_HOME, merged into the
# canonical store in the shape codex-auth-sync.sh expects, and the scratch copy
# is shredded — see SAFETY below.
#
# SAFETY:
#   - canonical is backed up before any write; atomic temp+rename at 0600;
#   - the scratch CODEX_HOME holds a REAL refresh token, so it is shredded on
#     EVERY exit path (trap). Leaving it would create a second holder of a
#     single-use rotating chain — the exact topology behind the 2026-05-29 and
#     2026-06-08 fleet-death incidents (see codex-auth-sync.sh "single-refresher
#     invariant"). The real refresh token must live in canonical and nowhere else.
#   - the profile is written ONLY on a fully-valid credential; a partial or
#     garbled login leaves canonical UNTOUCHED.
#
# The minted token IS rotatable by our refresher: the vendored codex binary
# embeds the same OAuth client id (app_EMoamEEZ73f0CkXaXp7hrann) that
# codex-oauth-refresh.sh posts with, so the twice-weekly timer keeps it fresh.
# --verify-chain re-checks that assumption after the merge rather than trusting it.
#
# Usage:
#   codex-reauth.sh                 # login, merge, sync, restart, verify
#   codex-reauth.sh --no-restart    # stop after sync (gateways keep old token)
#   codex-reauth.sh --dry-run       # show what would happen, mint nothing
#   codex-reauth.sh --verify-chain  # after merge, prove codex-oauth-refresh.sh
#                                   # can rotate the new token (spends one rotation)
# ──────────────────────────────────────────────────────────────
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="${CODEX_AUTH_STORE:-/root/.openclaw-main/agents/main/agent/auth-profiles.json}"
BACKUP_DIR="${CODEX_AUTH_BACKUP_DIR:-/root/codex-auth-backups}"
SCRATCH="${CODEX_REAUTH_SCRATCH:-/root/codex-reauth-scratch}"
# This script runs as ROOT and rm -rf's $SCRATCH on every exit path, so an
# env typo (CODEX_REAUTH_SCRATCH=/root) or a swapped symlink would delete or
# shred operator state. Refuse anything that is not a narrow, non-symlink path
# whose basename we own. The basename marker is the load-bearing guard: we only
# ever destroy a directory WE named, so no plausible typo can reach a real one.
_assert_safe_scratch() {
  case "$SCRATCH" in
    /*) : ;;
    *)  log "FATAL: CODEX_REAUTH_SCRATCH must be an absolute path (got '$SCRATCH')"; exit 2 ;;
  esac
  case "$(basename "$SCRATCH")" in
    codex-reauth*) : ;;
    *) log "FATAL: refusing to use '$SCRATCH' as scratch — basename must start with 'codex-reauth' (this path is rm -rf'd as root)"; exit 2 ;;
  esac
  # Depth guard: a 1-segment path (/foo) is never a legitimate scratch dir.
  case "${SCRATCH#/}" in
    */*) : ;;
    *) log "FATAL: refusing top-level scratch path '$SCRATCH'"; exit 2 ;;
  esac
  if [ -L "$SCRATCH" ]; then
    log "FATAL: '$SCRATCH' is a symlink — refusing (cleanup would shred the target, not the scratch)"
    exit 2
  fi
}
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-/root/.openclaw-main/npm/projects}"
LOGIN_TIMEOUT="${CODEX_REAUTH_TIMEOUT:-900}"   # device codes expire in 15min

LOGPREFIX="[codex-reauth $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $1"; }

if [ -r "$SCRIPT_DIR/slack-notify.sh" ]; then
  # shellcheck source=slack-notify.sh
  source "$SCRIPT_DIR/slack-notify.sh"
fi
# codex_count_session_invalidated is used by the post-restart verification below.
if [ -r "$SCRIPT_DIR/codex-health.sh" ]; then
  # shellcheck source=codex-health.sh
  source "$SCRIPT_DIR/codex-health.sh"
fi
_page() { declare -F slack_notify >/dev/null && slack_notify "[codex-reauth] $1" || true; }
# Fleet-down pages MUST use slack_notify_critical — it prepends the real <@UID>
# mentions. A plain notify pings nobody, and these fire during an outage where
# by definition nobody is already watching the channel. Mirrors
# codex-account-rotate.sh's _page_critical.
_page_critical() { declare -F slack_notify_critical >/dev/null && slack_notify_critical "[codex-reauth] $1" || _page "$1"; }

DRY_RUN=0; NO_RESTART=0; VERIFY_CHAIN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --no-restart)   NO_RESTART=1 ;;
    --verify-chain) VERIFY_CHAIN=1 ;;
    -h|--help)      sed -n '/^# Usage:/,/^# ─\{5,\}/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log "FATAL: unknown argument: $arg"; exit 2 ;;
  esac
done

command -v jq   >/dev/null 2>&1 || { log "FATAL: jq not found";      exit 2; }
command -v python3 >/dev/null 2>&1 || { log "FATAL: python3 not found"; exit 2; }
[ -r "$CANON" ] || { log "FATAL: canonical auth store not readable: $CANON"; exit 2; }
# Guard the root-run rm -rf target before anything can touch it.
_assert_safe_scratch
# Checked HERE, not at step 4: discovering the fan-out is missing only after a
# human has burned a device code is a needless second outage window.
[ -x "$SCRIPT_DIR/codex-auth-sync.sh" ] || { log "FATAL: codex-auth-sync.sh missing/not executable — a merged credential could never reach the runtime stores"; exit 2; }
# Only required when we will actually restart: --no-restart is a legitimate mode
# (converge the stores now, let the next restart load them), and failing it for a
# missing restart helper would refuse a recovery it does not need.
if [ "$NO_RESTART" -eq 0 ]; then
  [ -r "$SCRIPT_DIR/gateway-restart.sh" ] || { log "FATAL: gateway-restart.sh missing — cannot drain-restart safely (use --no-restart to converge stores only)"; exit 2; }
  # The post-restart verifier calls codex_count_* from codex-health.sh, which is
  # sourced best-effort above. Assert it HERE rather than dying with
  # "command not found" after the merge, the restart and a human's device code
  # have all been spent — a preflight failure is cheap, a mid-rescue crash is not.
  declare -F codex_count_openrouter_serving >/dev/null || {
    log "FATAL: codex-health.sh did not provide codex_count_openrouter_serving — post-restart verification would crash mid-rescue (use --no-restart to converge stores only)"; exit 2; }
fi

# ── Resolve the vendored codex binary ────────────────────────────────────────
# The plugin dir name carries a content hash and CHANGES on every codex bump, so
# this must glob, never hardcode. A bump LEAVES THE OLD TREE in place, so more
# than one vendored binary is normal and filesystem traversal order is arbitrary
# — picking the first match could hand a rescue an arbitrarily old CLI whose
# device-auth flow or OAuth client id has since changed. Pick the NEWEST by mtime
# instead, and prove the choice actually supports the flow we need before a human
# is asked to stand at a browser.
CODEX_BIN="${CODEX_BIN:-}"
if [ -z "$CODEX_BIN" ]; then
  CODEX_BIN="$(find "$PLUGIN_ROOT" -type f -perm -u+x \
      -path '*@openai/codex-linux-x64/vendor/*/bin/codex' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n1 | cut -d' ' -f2- || true)"
fi
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
  log "FATAL: vendored codex binary not found under $PLUGIN_ROOT"
  _page_critical ":rotating_light: *Codex re-auth BROKEN* on node-8 — the vendored \`codex\` binary was not found under \`$PLUGIN_ROOT\`, so device-code re-auth cannot run. A revoked codex session now has NO recovery path. Check the @openclaw/codex plugin install."
  exit 2
fi
log "codex binary: $CODEX_BIN ($("$CODEX_BIN" --version 2>/dev/null || echo '?'))"
if ! "$CODEX_BIN" login --help 2>&1 | grep -q -- '--device-auth'; then
  log "FATAL: $CODEX_BIN does not support 'login --device-auth' — this codex CLI is too old or the flag was renamed"
  _page_critical ":rotating_light: *Codex re-auth BROKEN* on node-8 — the newest vendored \`codex\` binary (\`$CODEX_BIN\`) has no \`login --device-auth\`, so a revoked session has NO recovery path. The flag may have been renamed by a codex bump — check \`codex login --help\` and update scripts/lib/codex-reauth.sh."
  exit 2
fi

# ── Always destroy the scratch credential ────────────────────────────────────
_cleanup_scratch() {
  # Re-check at destroy time, not just at startup: the dir could have been
  # replaced by a symlink while the human was at the browser.
  [ -L "$SCRATCH" ] && { log "WARNING: '$SCRATCH' became a symlink — NOT deleting"; return 0; }
  [ -d "$SCRATCH" ] || return 0
  [ -f "$SCRATCH/auth.json" ] && shred -u "$SCRATCH/auth.json" 2>/dev/null || true
  rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup_scratch EXIT INT TERM

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would mint a device code via '$CODEX_BIN login --device-auth' (CODEX_HOME=$SCRATCH)"
  log "DRY-RUN: would merge the result into $CANON as openai-codex:<email>, then shred $SCRATCH"
  log "DRY-RUN: would run codex-auth-sync.sh$([ "$NO_RESTART" -eq 1 ] && echo '' || echo ' then restart both gateways')"
  exit 0
fi

# ── 1. Device-code login ─────────────────────────────────────────────────────
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
log "starting device-code login — the URL and code below go to whoever owns the account"
echo "────────────────────────────────────────────────────────────"
if ! CODEX_HOME="$SCRATCH" timeout "$LOGIN_TIMEOUT" "$CODEX_BIN" login --device-auth; then
  echo "────────────────────────────────────────────────────────────"
  log "FATAL: device login did not complete (timeout ${LOGIN_TIMEOUT}s, expired code, or user abort)"
  _page ":warning: *Codex re-auth did not complete* on node-8 — the device-code login timed out or was abandoned. The fleet is still on whatever credential it had. Re-run \`/opt/hydra/scripts/lib/codex-reauth.sh\` when the account owner is at a browser."
  exit 1
fi
echo "────────────────────────────────────────────────────────────"
[ -s "$SCRATCH/auth.json" ] || { log "FATAL: login reported success but $SCRATCH/auth.json is absent/empty"; exit 1; }

# ── 2. Merge into canonical ──────────────────────────────────────────────────
# Shape mapping (validated against real tokens 2026-07-27):
#   codex auth.json {auth_mode, tokens:{access_token,refresh_token,id_token,account_id}}
#   → canonical      {type,provider,email,access,refresh,accountId,chatgptPlanType,expires}
# `expires` is derived from the access token's own `exp` claim (ms epoch) — the
# value codex-keepalive.sh reads to pre-warn before a lapse.
# The id_token carries `email` in EITHER the profile namespace OR as a top-level
# claim depending on the login path (google-oauth2 logins use the latter) — both
# were observed on 2026-07-27, so both are read.
MERGE_OUT="$(python3 - "$SCRATCH/auth.json" "$CANON" "$BACKUP_DIR" <<'PYEOF'
import base64, json, os, shutil, sys, time

scratch, canon, backup_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def claims(tok):
    pl = tok.split(".")[1]
    pl += "=" * (-len(pl) % 4)
    return json.loads(base64.urlsafe_b64decode(pl))

src = json.load(open(scratch))
if src.get("auth_mode") != "chatgpt":
    sys.exit("scratch auth_mode=%r, expected 'chatgpt' (an apikey-mode file would 401 the fleet)" % src.get("auth_mode"))

t = src.get("tokens") or {}
access, refresh = t.get("access_token"), t.get("refresh_token")
account, idt = t.get("account_id"), t.get("id_token")
if not (access and refresh and account and idt):
    sys.exit("scratch auth.json missing one of access_token/refresh_token/account_id/id_token")

ic = claims(idt)
prof_ns = ic.get("https://api.openai.com/profile") or {}
auth_ns = ic.get("https://api.openai.com/auth") or {}
email = prof_ns.get("email") or ic.get("email")
if not email:
    sys.exit("could not read email from id_token claims: %s" % sorted(ic))
exp = claims(access).get("exp")
if not exp:
    sys.exit("access_token carries no exp claim")

key = "openai-codex:%s" % email
store = json.load(open(canon))
profiles = store.setdefault("profiles", {})
replaced = key in profiles
profiles[key] = {
    "type": "oauth",
    "provider": "openai-codex",
    "email": email,
    "access": access,
    "refresh": refresh,
    "accountId": account,
    "chatgptPlanType": auth_ns.get("chatgpt_plan_type"),
    "expires": exp * 1000,
}

os.makedirs(backup_dir, mode=0o700, exist_ok=True)
bak = os.path.join(backup_dir, "auth-profiles-prereauth-%s.json" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
shutil.copy2(canon, bak)

tmp = canon + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(store, fh, indent=2)
os.replace(tmp, canon)

print(json.dumps({
    "key": key, "email": email, "plan": auth_ns.get("chatgpt_plan_type"),
    "replaced": replaced, "backup": bak,
    "expires_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp)),
}))
PYEOF
)" || { log "FATAL: merge failed — canonical left UNTOUCHED"; exit 1; }

IFS=$'\t' read -r REAUTH_KEY REAUTH_EMAIL REAUTH_PLAN REAUTH_EXPIRES REAUTH_REPLACED REAUTH_BACKUP \
  <<<"$(printf '%s' "$MERGE_OUT" | jq -r '[.key,.email,.plan,.expires_utc,.replaced,.backup]|@tsv')"
log "merged $REAUTH_KEY (plan $REAUTH_PLAN, access expires $REAUTH_EXPIRES, replaced=$REAUTH_REPLACED)"
log "canonical backed up → $REAUTH_BACKUP"

_cleanup_scratch
log "scratch credential shredded (single-refresher invariant: the real refresh token now lives ONLY in canonical)"

# ── 3. Is this account the one the fleet will actually use? ──────────────────
# codex-auth-sync.sh writes ONE account's identity into every agent's
# codex-home/auth.json, chosen by codex-active-account.sh. Re-authing a
# NON-active account fixes nothing on its own — the fleet keeps riding the
# account the state file names. Fail loud rather than let the operator believe
# the outage is over.
ACTIVE_KEY=""
if [ -r "$SCRIPT_DIR/codex-active-account.sh" ]; then
  # shellcheck source=codex-active-account.sh
  source "$SCRIPT_DIR/codex-active-account.sh"
  ACTIVE_KEY="$(caa_active_key "$CANON" 2>/dev/null || true)"
fi
if [ -n "$ACTIVE_KEY" ] && [ "$ACTIVE_KEY" != "$REAUTH_KEY" ]; then
  log "WARNING: the ACTIVE account is '$ACTIVE_KEY', not the one just re-authed ('$REAUTH_KEY')"
  log "WARNING: the fleet will keep using '$ACTIVE_KEY'. To switch:"
  log "WARNING:   $SCRIPT_DIR/codex-account-rotate.sh --to $REAUTH_EMAIL"
  _page ":warning: *Codex re-auth landed on a NON-active account* — re-authed \`${REAUTH_KEY}\` but the fleet's active account is \`${ACTIVE_KEY}\`, so nothing changes for the fleet yet. Rotate with \`codex-account-rotate.sh --to $REAUTH_EMAIL\` if this credential is meant to serve."
fi

# ── 4. Fan out ───────────────────────────────────────────────────────────────
{
  "$SCRIPT_DIR/codex-auth-sync.sh" || {
    log "FATAL: codex-auth-sync.sh failed — derived stores are STALE, fleet still on the old token"
    _page_critical ":rotating_light: *Codex auth sync FAILED after re-auth* on node-8 — the new credential is in canonical but did NOT reach the runtime stores. Run \`/opt/hydra/scripts/lib/codex-auth-sync.sh\` manually, then restart both gateways."
    exit 1
  }
}

# ── 5. Optionally prove our refresher owns the new chain ─────────────────────
# The device login mints a token under codex's OWN client id. That id matches
# ours today, but a codex bump could change it — and the failure would surface
# as a silent lapse days later at the twice-weekly timer, not now. This spends
# one rotation to find out immediately.
if [ "$VERIFY_CHAIN" -eq 1 ] && [ -x "$SCRIPT_DIR/codex-oauth-refresh.sh" ]; then
  log "verifying the refresh chain (codex-oauth-refresh.sh must rotate the new token)..."
  if "$SCRIPT_DIR/codex-oauth-refresh.sh"; then
    log "refresh chain OK — the twice-weekly timer can keep this credential fresh"
  else
    log "WARNING: codex-oauth-refresh.sh reported a failure — see its output for WHICH profile"
    _page ":warning: *Codex refresh chain unverified after re-auth* — \`codex-oauth-refresh.sh\` did not cleanly rotate every profile. If the FRESHLY re-authed one failed, the OAuth client id may have drifted and this credential will lapse silently in ~10 days. Investigate before the next Sun/Wed timer fire."
  fi
fi

# ── 6. Restart + verify ──────────────────────────────────────────────────────
if [ "$NO_RESTART" -eq 1 ]; then
  log "done (--no-restart): gateways still hold the OLD token until restarted"
  exit 0
fi

# Drain-aware, NOT a bare `systemctl restart`: a SIGTERM mid-turn kills in-flight
# work (Caroline part-way through a customer reply — the case gateway-restart.sh
# was written for), and a bare restart has no post-restart `is-active` poll, so a
# unit landing in `failed` would be reported as success. Under `set -euo pipefail`
# a failing bare restart would also abort the script BEFORE the page below, so an
# operator waiting on a rescue would get silence. Same shape as
# codex-account-rotate.sh.
# shellcheck source=gateway-restart.sh
source "$SCRIPT_DIR/gateway-restart.sh"
GATEWAY_FALLBACK_NOTIFY_FN="${GATEWAY_FALLBACK_NOTIFY_FN:-_page}"
export GATEWAY_FALLBACK_NOTIFY_FN

# Boundary for post-restart log evaluation — captured BEFORE the restart so the
# window can never include the pre-restart failure lines.
RESTART_BOUNDARY="$(date -u '+%Y-%m-%d %H:%M:%S')"
log "drain-restarting gateways to load the new token (credentials load only at startup)"
RESTART_FAILED=0
for service in ${CODEX_REAUTH_SERVICES:-openclaw-gateway-main.service openclaw-gateway-edge.service}; do
  profile="${service##*-}"; profile="${profile%.service}"
  if drain_restart_gateway "$service" "$profile"; then
    log "$service restarted"
  else
    RESTART_FAILED=1
    log "ERROR: $service restart FAILED — the new credential is in the stores but NOT loaded"
  fi
done
if [ "$RESTART_FAILED" -eq 1 ]; then
  _page_critical ":rotating_light: *Codex re-auth: gateway restart FAILED* on node-8 — the re-authed credential reached every store but at least one gateway did not come back, so the fleet is NOT running on it. Check \`systemctl status openclaw-gateway-main openclaw-gateway-edge\`."
  exit 1
fi

# ── Post-restart verification ────────────────────────────────────────────────
# A rolling journal window is NOT a verification: it still contains the
# PRE-restart failure lines (so a successful recovery reads DEGRADED), and when
# the box is quiet it contains nothing at all (so an unusable credential reads
# HEALTHY). Both directions are wrong in the way that matters — this script's
# whole job is to answer "is codex serving again?".
#
# So: capture a boundary BEFORE the restart, drive a REAL turn after it, and
# judge only the logs after that boundary. DEGRADED and UNVERIFIABLE both exit
# non-zero, matching codex_health_gate's fail-closed contract — a rescue that
# cannot prove it worked must not report success.
VERIFY_AGENT="${CODEX_REAUTH_VERIFY_AGENT:-ceo}"
if [ "${CODEX_REAUTH_VERIFY:-1}" = "1" ] && command -v openclaw >/dev/null 2>&1; then
  log "driving a real turn through agent '$VERIFY_AGENT' to prove codex is serving..."
  TURN_OUT=""
  if TURN_OUT="$(OPENCLAW_STATE_DIR=/root/.openclaw-main timeout 150 \
        openclaw --profile main agent --agent "$VERIFY_AGENT" \
        --message 'Reply with exactly one word: pong' 2>&1)"; then
    log "verification turn returned: $(printf '%s' "$TURN_OUT" | tail -n1)"
  else
    # A turn that cannot complete is a FAILED verification, not a footnote —
    # without this the journal check below could still read "HEALTHY" off
    # unrelated post-restart lines and report a broken rescue as successful.
    log "verification turn FAILED to complete — treating recovery as unproven"
    REAUTH_DEGRADED=1
  fi
  # Only logs AFTER the restart boundary count.
  POST=$(journalctl -u openclaw-gateway-main -u openclaw-gateway-edge \
           --since "$RESTART_BOUNDARY" --no-pager 2>/dev/null || true)
  if [ -z "$POST" ]; then
    log "post-restart codex health: UNVERIFIABLE — no journal output since $RESTART_BOUNDARY"
    REAUTH_DEGRADED=1
  else
    POST_FALLBACK=$(printf '%s\n' "$POST" | codex_count_openrouter_serving)
    POST_REVOKED=$(printf '%s\n' "$POST" | codex_count_session_invalidated)
    POST_AUTHPERM=$(printf '%s\n' "$POST" | codex_count_auth_permanent)
    if [ "${POST_FALLBACK:-0}" -gt 0 ] || [ "${POST_REVOKED:-0}" -gt 0 ] || [ "${POST_AUTHPERM:-0}" -gt 0 ]; then
      log "post-restart codex health: DEGRADED (openrouter-served=${POST_FALLBACK}, session-revoked=${POST_REVOKED}, auth-permanent=${POST_AUTHPERM} since the restart boundary)"
      _page_critical ":rotating_light: *Codex still DEGRADED after re-auth* on node-8 — the credential was merged, synced and the gateways drain-restarted, but a real turn AFTER the restart still shows codex failing (openrouter-served=${POST_FALLBACK}, session-revoked=${POST_REVOKED}, auth-permanent=${POST_AUTHPERM}). The account may lack Codex entitlement, or a different failure class is now in play."
      REAUTH_DEGRADED=1
    else
      log "post-restart codex health: HEALTHY — a real turn ran with no fallback since the restart boundary"
    fi
  fi
else
  # Cannot prove it → fail closed. "Skipped" must never read as success: this is
  # the documented recovery for a fleet-down incident and a caller that sees 0
  # will stop escalating.
  log "post-restart verification SKIPPED (CODEX_REAUTH_VERIFY=0 or openclaw not on PATH) — codex is NOT proven to be serving"
  REAUTH_DEGRADED=1
fi

# Consume the verdict. This exit is the whole point of the verification above;
# an earlier revision set REAUTH_DEGRADED in every failure branch and then still
# returned 0, so a failed rescue reported success.
if [ "${REAUTH_DEGRADED:-0}" -eq 1 ]; then
  log "re-auth completed but codex is NOT proven healthy — exiting non-zero so callers keep escalating"
  exit 1
fi
log "re-auth complete and verified: codex served a real turn with no fallback since the restart."
exit 0
