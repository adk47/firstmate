#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-quota-refresh.sh — measure every codex account's real quota and
# persist it. MEASURES ONLY; it can never rotate an account.
#
# That split is deliberate and load-bearing. codex-keepalive.sh remains the
# SOLE caller of codex-account-rotate.sh — two cron actuators racing the same
# drain-restart pair would be a new outage class. This collector's entire job
# is to replace inference with evidence and leave the acting to one owner.
#
# Writes one row per account to $CODEX_USAGE_ARCHIVE_DIR/<key>.measure.tsv
# (see codex-quota.sh for the row format). Deliberately a different filename
# from codex-usage.sh's `.snapshot.tsv` archive so the measured layer and the
# legacy inferred layer can coexist during the bake, and so reverting the code
# leaves no ambiguous file behind.
#
# It also runs ONE cheap invariant check that nothing else can run, because
# nothing else knows measured quota:
#
#   auth.order.openai[0] must not be a MEASURED-CAPPED account.
#
# WHY that check exists (incident 2026-08-06): openclaw's embedded agent path
# does its own per-run profile rotation over auth.order.openai, independently
# of hydra's state-file rotation (which only governs codex-home/auth.json for
# the codex agentRuntime). Its per-profile cooldown after a rate_limit is only
# 30s → 60s → 300s capped, and clearExpiredCooldowns then returns the profile
# to the front of the order — so a permanently exhausted auth.order[0] is
# retried roughly every 75 seconds forever. With aaron@muso.ai at 100% that
# produced 143 wasted round-trips in three hours, and the resulting journal
# signature is what made codex-keepalive.sh page ":no_entry: Codex usage cap —
# no rotation target left" while two Pro subscriptions sat at 4% and 0%.
#
# DETECT-AND-PAGE ONLY, on purpose. Rewriting auth.order at runtime would mean
# an out-of-band write to openclaw-*.json (which requires announce-legit-write.sh,
# is reverted by the next rsync deploy, and trips the write-audit watcher).
# Re-ordering is a human decision made in a PR — same posture as
# ensure-session-budget-headroom.sh.
#
# Env overrides (tests / non-default layouts):
#   CODEX_USAGE_ARCHIVE_DIR   default /var/lib/hydra/codex-usage
#   CODEX_QUOTA_CONFIGS       space-separated openclaw config paths to check
#   CODEX_QUOTA_COOLDOWN_MIN  default 360 (page dedupe, per signal)
#   CODEX_QUOTA_STATE_DIR     default /var/lib/hydra
#
# Exit: 0 measured at least one account · 1 measured nothing · 2 misuse
# ──────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/codex-quota.sh
. "$HERE/lib/codex-quota.sh"
# shellcheck source=scripts/lib/codex-quota-probe.sh
. "$HERE/lib/codex-quota-probe.sh"
if [ -r "$HERE/lib/slack-notify.sh" ]; then
  # shellcheck source=scripts/lib/slack-notify.sh
  . "$HERE/lib/slack-notify.sh"
fi

CODEX_USAGE_ARCHIVE_DIR="${CODEX_USAGE_ARCHIVE_DIR:-/var/lib/hydra/codex-usage}"
CODEX_QUOTA_STATE_DIR="${CODEX_QUOTA_STATE_DIR:-/var/lib/hydra}"
CODEX_QUOTA_COOLDOWN_MIN="${CODEX_QUOTA_COOLDOWN_MIN:-360}"
CODEX_QUOTA_CONFIGS="${CODEX_QUOTA_CONFIGS:-/opt/hydra/openclaw-main.json /opt/hydra/openclaw-edge.json}"

LOGPREFIX="[codex-quota-refresh $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*"; }
_page() { declare -F slack_notify >/dev/null && slack_notify "$1" || log "PAGE (slack unavailable): $1"; }

_cooldown_ok() {
  local stamp="$1" mins="$2" now last
  now=$(date +%s)
  [ -r "$stamp" ] || return 0
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  # A stamp in the FUTURE (clock rollback, a bad manual write) must not be read
  # as an active cooldown: `now - last` would stay negative and silently
  # suppress every page on this stamp until wall time caught up. Paging twice is
  # recoverable; a swallowed page during an outage is not.
  [ "$last" -le "$now" ] || last=0
  [ "$(( now - last ))" -ge "$(( mins * 60 ))" ]
}

# _check_auth_order_head <measurements-dir>
# Page when auth.order.openai[0] resolves to an account we MEASURED as capped.
# Silent when the head account is healthy, or when we have no fresh measurement
# for it — an unknown is not evidence of a problem any more than it is evidence
# of health.
_check_auth_order_head() {
  local dir="$1" cfg head key row state now stamp msg
  now="$(date +%s)"
  for cfg in $CODEX_QUOTA_CONFIGS; do
    [ -r "$cfg" ] || continue
    head="$(jq -r '.auth.order.openai[0] // empty' "$cfg" 2>/dev/null)"
    [ -n "$head" ] || continue
    # auth.order uses the runtime "openai:<email>" namespace; the measurement
    # store is keyed by canonical "openai-codex:<email>". Translating here is
    # the whole reason this check can exist — see the three-namespace rule in
    # CLAUDE.md; an exact-key lookup across namespaces silently finds nothing.
    key="openai-codex:${head#openai:}"
    row="$(cq_measure_read "$dir" "$key" 2>/dev/null || true)"
    state="$(cq_row_state "$row" "$CQ_CAP_PCT" "$CQ_MEASURE_MAX_AGE_MIN" "$now")"
    [ "$state" = capped ] || continue

    stamp="$CODEX_QUOTA_STATE_DIR/codex-quota-authorder-$(basename "$cfg" .json).cooldown"
    if _cooldown_ok "$stamp" "$CODEX_QUOTA_COOLDOWN_MIN"; then
      msg=":warning: *Codex \`auth.order\` head is a capped account* — \`$(basename "$cfg")\` lists \`$head\` first, and $(cq_format_evidence "$head" "$row" "$now")."
      msg="$msg openclaw's embedded path retries the head profile roughly every 75s (its rate-limit cooldown caps at 5min, then the profile returns to the front of the order), so every run pays a wasted round-trip and the journal fills with a usage-cap signature that is NOT evidence the fleet is out of quota."
      msg="$msg Fix by reordering \`auth.order.openai\` in the repo config and deploying — do NOT edit it on the box (out-of-band writes to openclaw-*.json trip the audit watcher and are reverted by the next rsync)."
      _page "$msg"
      date +%s > "$stamp"
      log "paged: auth.order head $head is measured-capped in $(basename "$cfg")"
    else
      log "auth.order head $head is measured-capped in $(basename "$cfg") but within page cooldown"
    fi
  done
}

main() {
  local dir="$CODEX_USAGE_ARCHIVE_DIR"
  command -v jq >/dev/null 2>&1 || { log "FATAL: jq not found"; return 2; }

  if [ -e "$CODEX_PROBE_DISABLED_FLAG" ]; then
    log "kill switch present ($CODEX_PROBE_DISABLED_FLAG) — no measurements taken this tick"
    return 1
  fi

  local bin
  bin="$(cqp_resolve_binary)" || { log "FATAL: no vendored codex binary under $PLUGIN_ROOT"; return 2; }
  cqp_preflight "$bin" || {
    local stamp="$CODEX_QUOTA_STATE_DIR/codex-quota-probe-broken.cooldown"
    if _cooldown_ok "$stamp" "$CODEX_QUOTA_COOLDOWN_MIN"; then
      _page ":warning: *Codex quota probe unavailable* — \`codex app-server\` is missing or renamed on node-8, so per-account quota can no longer be measured. Every account degrades to \`quota UNKNOWN\` and elective balancing stays off. Re-verify \`account/rateLimits/read\` against the current codex version."
      date +%s > "$stamp"
    fi
    return 2
  }

  local key row rc measured=0 failed=0 listed
  listed="$(cqp_list_accounts)" || {
    log "FATAL: canonical auth store became unreadable while listing accounts"
    return 2
  }
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    row="$(cqp_probe_account "$key" "$bin")"; rc=$?
    if [ "$rc" -eq 9 ]; then
      # A safety violation is never "just a failed measurement" — and saying
      # "probing is being stopped" while leaving the */20 cron free to re-enter
      # the same path 20 minutes later would make the page a lie AND keep
      # re-running the thing that just breached the single-refresher invariant.
      # Write the kill switch here so the claim is true; a human clears it.
      mkdir -p "$(dirname "$CODEX_PROBE_DISABLED_FLAG")" 2>/dev/null || true
      if printf 'auto-disabled %s: SAFETY VIOLATION probing %s\n' \
           "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" > "$CODEX_PROBE_DISABLED_FLAG" 2>/dev/null; then
        log "wrote kill switch $CODEX_PROBE_DISABLED_FLAG"
      else
        log "WARN: could NOT write kill switch $CODEX_PROBE_DISABLED_FLAG — the cron will re-enter this path in 20min"
      fi
      _page ":rotating_light: *Codex quota probe SAFETY VIOLATION* on node-8 for \`$key\` — the scratch credential was rewritten or the canonical refresh token leaked into the probe sandbox. Probing has been AUTO-DISABLED via \`$CODEX_PROBE_DISABLED_FLAG\`; per-account quota will now read UNKNOWN until a human investigates and removes that file. This is the single-refresher invariant — do not clear it without understanding why the credential moved."
      log "FATAL: safety violation probing $key — aborting"
      return 2
    fi
    if [ "$rc" -eq 2 ]; then
      log "FATAL: canonical auth store became unreadable while probing $key"
      return 2
    fi
    if [ "$rc" -ne 0 ] || [ -z "$row" ]; then
      failed=$(( failed + 1 ))
      log "no measurement for $key"
      continue
    fi
    if cq_measure_write "$dir" "$key" "$row"; then
      measured=$(( measured + 1 ))
      log "measured $key: $(cq_format_evidence "$key" "$row")"
    else
      log "WARN: could not persist measurement for $key"
    fi
  done <<< "$listed"

  if [ "$measured" -eq 0 ]; then
    local stamp="$CODEX_QUOTA_STATE_DIR/codex-quota-allfailed.cooldown"
    if _cooldown_ok "$stamp" "$CODEX_QUOTA_COOLDOWN_MIN"; then
      _page ":warning: *Codex quota probe unavailable* — no account could be measured this tick ($failed attempted). Per-account quota is now \`UNKNOWN\`, which means rotation will not elect a target it cannot verify. Reactive cap handling is unaffected."
      date +%s > "$stamp"
    fi
    log "measured 0 accounts ($failed failures)"
    return 1
  fi

  _check_auth_order_head "$dir"
  log "measured $measured account(s), $failed failure(s)"
  return 0
}

main "$@"
