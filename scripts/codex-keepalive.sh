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

# ── usage-cap auto-rotation seams (2026-07-21 incident class) ────────────────
# When the ACTIVE subscription hits its Codex usage cap, every codex model
# dies at once (sol+luna share one subscription) and the fleet degrades to the
# paid OpenRouter rung — while the standby subscription idles fresh. The
# original "never restart from a 15-min cron" doctrine above was written for
# TOKEN-EXPIRY, where a surprise restart is worse than a page. A cap is
# different: the fleet is ALREADY degraded, so a drain-restart that restores
# codex (via codex-account-rotate.sh) is strictly better than staying on the
# paid fallback. The rotate script owns cooldown + paging; this keepalive only
# detects the cap signature and pulls the trigger.
CODEX_KEEPALIVE_JOURNAL_BIN="${CODEX_KEEPALIVE_JOURNAL_BIN:-journalctl}"
CODEX_KEEPALIVE_CAP_WINDOW_MIN="${CODEX_KEEPALIVE_CAP_WINDOW_MIN:-20}"
CODEX_KEEPALIVE_CAP_SIG="${CODEX_KEEPALIVE_CAP_SIG:-reached your Codex subscription usage limit}"
CODEX_ROTATE_STAMP="${CODEX_ROTATE_STAMP:-/var/lib/hydra/codex-account-rotate.last}"
# Separate page cooldown for the "revoked AND no standby" case so it cannot be
# masked by the usage-cap cooldown — they are different outages needing
# different human actions.
CODEX_KEEPALIVE_REVOKED_STAMP="${CODEX_KEEPALIVE_REVOKED_STAMP:-${KEEPALIVE_STATE_DIR:-/var/lib/hydra}/codex-keepalive-revoked-cooldown}"
# Proactive rotation: switch accounts BEFORE the cap error ever fires, off a
# fresh rate_limits snapshot (any window >= ROTATE_AT% used with its reset
# still far away). Window-agnostic by design: OpenAI dropped the 5h window in
# Jul 2026 ("temporarily" — it may return), so thresholds apply to whatever
# windows the snapshot carries. The rotate actuator's own cooldown + target-
# viability gate (rc 7) make this safe to fire speculatively.
CODEX_KEEPALIVE_ROTATE_AT="${CODEX_KEEPALIVE_ROTATE_AT:-95}"
CODEX_KEEPALIVE_MIN_RESET_MIN="${CODEX_KEEPALIVE_MIN_RESET_MIN:-60}"
CODEX_KEEPALIVE_PROACTIVE_FRESH_MIN="${CODEX_KEEPALIVE_PROACTIVE_FRESH_MIN:-90}"
CODEX_USAGE_ARCHIVE_DIR="${CODEX_USAGE_ARCHIVE_DIR:-/var/lib/hydra/codex-usage}"
# Max age of a measurement that is allowed to VETO a rotation ("the cap
# signature is not our account"). Tighter than CQ_MEASURE_MAX_AGE_MIN because
# vetoing on stale evidence suppresses a real cap — see _check_usage_cap. One
# collector cycle (20min) plus slack.
CODEX_KEEPALIVE_NOISE_MAX_AGE_MIN="${CODEX_KEEPALIVE_NOISE_MAX_AGE_MIN:-25}"

# Source the shared Slack helper (same #clio_devops devops-bot path the
# watchdog uses). Locate via this script's own dir so it works from a worktree
# (laptop test) or the /opt/hydra deploy mirror.
_KEEPALIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_KEEPALIVE_ROTATE_BIN="${CODEX_KEEPALIVE_ROTATE_BIN:-$_KEEPALIVE_DIR/lib/codex-account-rotate.sh}"
# shellcheck source=lib/slack-notify.sh
source "$_KEEPALIVE_DIR/lib/slack-notify.sh"
# Pure snapshot/quota helpers (cu_collect_rollouts, cu_latest_rate_limits,
# cu_archive_read, cu_row_capped_until, cu_human_resets_in) — no side effects.
# shellcheck source=lib/codex-usage.sh
source "$_KEEPALIVE_DIR/lib/codex-usage.sh"
# Pure MEASURED-quota helpers (cq_measure_read, cq_row_state, cq_row_load,
# cq_format_evidence). These are what let this script tell "our active account
# is actually spent" apart from "the journal is full of openclaw's own
# auth.order retry noise" — the distinction it got wrong on 2026-08-05.
# shellcheck source=lib/codex-quota.sh
source "$_KEEPALIVE_DIR/lib/codex-quota.sh"
# shellcheck source=lib/codex-active-account.sh
source "$_KEEPALIVE_DIR/lib/codex-active-account.sh"
# Derive from STORE_ROOT like every other path in this script (line 159 builds
# the same location that way). Hardcoding /root here made the measured-quota
# guard unreachable under test — the suite overrides CODEX_KEEPALIVE_STORE_ROOT,
# so _active_measured_row resolved against the real box, always came back empty,
# and every test silently exercised the fall-through instead of the guard.
CODEX_KEEPALIVE_CANON="${CODEX_KEEPALIVE_CANON:-$CODEX_KEEPALIVE_STORE_ROOT/.openclaw-main/agents/main/agent/auth-profiles.json}"

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh):
# a window is exactly when a human is deliberately touching codex/gateways, so
# this proactive pager is noise. The token life is days and the twice-weekly
# refresh timer resumes after; a bounded blind window is acceptable here. Fail-
# safe: an absent/expired/malformed flag reads as "not in maintenance".
# shellcheck source=lib/maintenance-flag.sh
source "$_KEEPALIVE_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

log() { echo "$LOGPREFIX $1"; }

# _cooldown_ok <stampfile> <minutes> — true if last alert older than N min.
_cooldown_ok() {
  local stamp="$1" mins="$2" now last
  now=$(date +%s)
  [ -r "$stamp" ] || return 0
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  # A truncated or garbled stamp (an interrupted write, a hand-edit) would make
  # the arithmetic below a syntax error and abort the tick — i.e. a corrupt
  # cooldown file would silence the pager rather than reset it. Treat anything
  # non-numeric as "no cooldown recorded". Same guard as the one in
  # scripts/codex-quota-refresh.sh; keep the two in step.
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  # A stamp in the FUTURE (clock rollback, a bad manual write) must not be read
  # as an active cooldown: `now - last` would stay negative and silently
  # suppress every page on this stamp until wall time caught up. Paging twice is
  # recoverable; a swallowed page during an outage is not.
  [ "$last" -le "$now" ] || last=0
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

# ── usage-cap detection → account rotation ───────────────────────────────────

# _cap_hits — count usage-cap fallback lines in the recent journal window.
# Always echoes a number; a missing journal binary (macOS bats host, container)
# logs and echoes 0 — the reactive watchdog still owns the degraded-fleet page,
# so this is a bounded blind spot, not a silent one.
_cap_hits() {
  local out
  if ! command -v "$CODEX_KEEPALIVE_JOURNAL_BIN" >/dev/null 2>&1; then
    log "cap-check: $CODEX_KEEPALIVE_JOURNAL_BIN not found — skipping usage-cap detection"
    echo 0; return 0
  fi
  out="$("$CODEX_KEEPALIVE_JOURNAL_BIN" -u openclaw-gateway-main -u openclaw-gateway-edge \
          --since "-${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min" --no-pager 2>/dev/null \
        | grep -c "$CODEX_KEEPALIVE_CAP_SIG")" || out=0
  echo "${out:-0}"
}

# _rotated_recently — true if the rotate stamp is younger than the cap window.
# Right after a rotation the OLD signature lines are still inside the journal
# window; re-triggering on them would burn the rotate cooldown and false-page
# "no rotation target left".
_rotated_recently() {
  local last now
  [ -r "$CODEX_ROTATE_STAMP" ] || return 1
  last="$(cat "$CODEX_ROTATE_STAMP" 2>/dev/null || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  # Future-dated stamp: (now - last) goes negative and satisfies the -lt below,
  # so this would report "we just rotated" forever and skip cap AND revocation
  # handling entirely. Same clock-rollback class as _cooldown_ok.
  [ "$last" -le "$now" ] || return 1
  [ "$(( now - last ))" -lt "$(( CODEX_KEEPALIVE_CAP_WINDOW_MIN * 60 ))" ]
}

# _active_snapshot — freshest fleet-wide rate_limits TSV row (the active
# account's, since the fleet runs one account at a time). Echoes nothing when
# no rollout in the lookback window carries one.
_active_snapshot() {
  local -a rollouts=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && rollouts+=("$f")
  done < <(cu_collect_rollouts "$CODEX_KEEPALIVE_STORE_ROOT" 48)
  [ "${#rollouts[@]}" -gt 0 ] || return 0
  cu_latest_rate_limits "${rollouts[@]}"
}

# _earliest_reset_note — best-effort "self-heals <in Xd Yh>" phrase from the
# accounts' known capped windows (live snapshot + rotation archives).
_earliest_reset_note() {
  local earliest="" row until f
  row="$(_active_snapshot)"
  if [ -n "$row" ] && until="$(cu_row_capped_until "$row" "$CODEX_KEEPALIVE_ROTATE_AT")"; then
    earliest="$until"
  fi
  for f in "$CODEX_USAGE_ARCHIVE_DIR"/*.snapshot.tsv; do
    [ -r "$f" ] || continue
    row="$(head -n1 "$f")"
    if until="$(cu_row_capped_until "$row" "$CODEX_KEEPALIVE_ROTATE_AT")"; then
      if [ -z "$earliest" ] || [ "$until" -lt "$earliest" ]; then earliest="$until"; fi
    fi
  done
  [ -n "$earliest" ] || return 0
  printf 'Earliest known quota reset: %s.' "$(cu_human_resets_in "$earliest")"
}

# _measured_earliest_reset_note — earliest recovery time across MEASURED rows.
#
# The rc 7 page is framed entirely as measured evidence, so it must not end
# with a number from _earliest_reset_note(), which derives its ETA from the
# fleet-wide rollout snapshot and the legacy *.snapshot.tsv archives — the very
# misattribution this change retires. On 2026-08-06 every one of those archives
# carried aaron@muso.ai's reset epoch, so the old note would hand an operator a
# confident wrong time inside an otherwise-honest message. Emits nothing when
# nothing was measured, rather than falling back to the inferred number.
_measured_earliest_reset_note() {
  local key row at earliest="" now
  now="$(date +%s)"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    row="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$key" 2>/dev/null || true)"
    [ -n "$row" ] || continue
    at="$(cq_row_reset_at "$row" "$now")" || continue
    if [ -z "$earliest" ] || [ "$at" -lt "$earliest" ]; then earliest="$at"; fi
  done < <(jq -r '.profiles | keys[] | select(startswith("openai-codex:"))' \
             "$CODEX_KEEPALIVE_CANON" 2>/dev/null)
  [ -n "$earliest" ] || return 0
  printf 'Earliest MEASURED quota reset: %s.' "$(cq_human_in "$earliest" "$now")"
}

# _measured_account_lines — one evidence line per configured codex account,
# rendered exclusively through cq_format_evidence so a page can never carry a
# bare percentage with no age or provenance, and an unmeasured account renders
# as "quota UNKNOWN" rather than being silently omitted (an omitted account
# reads as "not a problem", which is how two idle subscriptions went unnoticed
# through the 2026-08-05 incident).
_measured_account_lines() {
  local key row out="" active now
  # One clock for the whole page: cq_format_evidence forks `date +%s` when no
  # `now` is passed, so an unthreaded loop also renders each account's age
  # against a slightly different instant.
  now="$(date +%s)"
  active="$(caa_active_key "$CODEX_KEEPALIVE_CANON" 2>/dev/null)" || active=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    row="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$key" 2>/dev/null || true)"
    out="$out"$'\n'"• $(cq_format_evidence "${key#openai-codex:}" "$row" "$now")"
    [ "$key" = "$active" ] && out="$out (active)"
  done < <(jq -r '.profiles | keys[] | select(startswith("openai-codex:"))' \
             "$CODEX_KEEPALIVE_CANON" 2>/dev/null)
  [ -n "$out" ] || return 0
  printf 'Measured quota:%s' "$out"
}

# Set to 1 when the reactive path invoked a rotation this tick, so the
# proactive check does not double-fire.
CAP_ACTED=0

# ── Session revocation → rotate, don't just page (2026-07-27) ────────────────
# A revoked OAuth session leaves the ACTIVE account permanently unusable until a
# human completes a browser login — exactly the usage-cap shape ("this account
# cannot serve, another one can"), and exactly what the standby pool exists for.
# On 2026-07-27 the fleet sat on the paid OpenRouter rung for ~2h with two other
# credentialed accounts idle, because nothing connected "active account is dead"
# to the rotation lever that already existed. Detection alone would not have
# shortened that; this does.
#
# Rotation is the right REFLEX but not the cure — the revoked account still needs
# codex-reauth.sh. codex-account-rotate.sh pages the outcome either way, so the
# human still learns about it; they just aren't the critical path to service.
_revoked_hits() {
  local out
  if ! command -v "$CODEX_KEEPALIVE_JOURNAL_BIN" >/dev/null 2>&1; then
    log "revoked-check: $CODEX_KEEPALIVE_JOURNAL_BIN not found — skipping session-revocation detection"
    echo 0; return 0
  fi
  # Same two signatures as codex_count_session_invalidated (gateway wording vs
  # API wording). Kept as a literal here rather than sourcing codex-health.sh so
  # keepalive stays dependency-light, but the strings MUST track that function.
  out="$("$CODEX_KEEPALIVE_JOURNAL_BIN" -u openclaw-gateway-main -u openclaw-gateway-edge \
          --since "-${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min" --no-pager 2>/dev/null \
        | grep -c -i -E -e "access token could not be refreshed" -e "token_invalidated")" || out=0
  echo "${out:-0}"
}

_check_session_revoked() {
  local hits rc
  [ "$CAP_ACTED" -eq 1 ] && return 0        # a rotation already fired this tick
  hits="$(_revoked_hits)"
  if ! [[ "$hits" =~ ^[0-9]+$ ]] || [ "$hits" -eq 0 ]; then
    return 0
  fi
  if _rotated_recently; then
    log "revoked: signature present (${hits}x) but a rotation ran <${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min ago — waiting for the journal window to clear"
    return 0
  fi
  log "revoked: session-invalidated signature ${hits}x in last ${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min — attempting account rotation"
  rc=0
  # Same rule as the cap path: only claim the tick on an actual rotation.
  # --allow-unmeasured is REQUIRED on this path. A revoked session means the
  # active account is DEAD, so any reachable standby beats the paid openrouter
  # rung — refusing because we could not measure the target would strand the
  # whole fleet on exactly the outage this reflex exists to end (2026-07-27,
  # ~2h). rc 8 must never be able to fire here: it protects an ELECTIVE choice,
  # and this is not one. The rotate script still pages honestly that the target
  # was unverified rather than implying it was measured healthy.
  "$CODEX_KEEPALIVE_ROTATE_BIN" --auto --allow-unmeasured \
    --reason "session revoked upstream (keepalive auto-rotate)" || rc=$?
  [ "$rc" -eq 0 ] && CAP_ACTED=1
  case "$rc" in
    0) log "revoked: auto-rotation kicked (the rotate script pages the outcome)" ;;
    *)
      # No healthy standby to rotate to — this is the genuinely human-blocked
      # case, so page with the ONE command that actually recovers it.
      if _cooldown_ok "$CODEX_KEEPALIVE_REVOKED_STAMP" "$COOLDOWN_MIN"; then
        slack_notify_critical ":rotating_light: *Codex session revoked and NO standby available* — the active account's OAuth session was ended upstream (${hits}x signature in ${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min) and auto-rotation could not find a healthy account (rc=$rc). The fleet is on the paid \`openrouter\` rung until a human re-auths: run \`/opt/hydra/scripts/lib/codex-reauth.sh\` on node-8 — it prints a device URL + code for the account owner, then merges, syncs and restarts."
        date +%s > "$CODEX_KEEPALIVE_REVOKED_STAMP"
        log "revoked: paged #clio_devops (no standby, rc=$rc)"
      fi
      ;;
  esac
}

# _active_measured_row — the MEASURED quota row for the account the state file
# says is active. Echoes nothing when there is no measurement (which reads as
# `unknown` downstream, never as healthy).
_active_measured_row() {
  local key
  key="$(caa_active_key "$CODEX_KEEPALIVE_CANON" 2>/dev/null)" || key=""
  [ -n "$key" ] || return 1
  cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$key" 2>/dev/null
}

_check_usage_cap() {
  local hits rc stamp row state
  hits="$(_cap_hits)"
  if ! [[ "$hits" =~ ^[0-9]+$ ]] || [ "$hits" -eq 0 ]; then
    return 0
  fi
  if _rotated_recently; then
    log "cap: signature present (${hits}x) but a rotation ran <${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min ago — waiting for the journal window to clear"
    return 0
  fi

  # ── The signature is NOT self-evidently about our active account. ──
  # openclaw's embedded path runs its OWN profile rotation over
  # auth.order.openai, independent of the state file this script actuates. Its
  # per-profile rate-limit cooldown caps at 5 minutes, after which the head
  # profile returns to the front of the order — so a permanently exhausted
  # auth.order[0] emits this exact signature roughly every 75 seconds forever,
  # no matter which account WE have made active.
  #
  # That is precisely what happened on 2026-08-05/06: aaron@muso.ai sat at 100%
  # as auth.order[0] and produced 143 cap lines in three hours. This script read
  # them as "the active account is spent", rotated the state file (a different
  # surface entirely, which changed nothing), exhausted the rotate cooldown, and
  # paged ":no_entry: no rotation target left — every alternate account is
  # known-capped" while gmail sat at 4% and me.com at 0%.
  #
  # So: if we have a FRESH measurement saying the active account is fine, the
  # signature is somebody else's problem and rotating cannot fix it. Say so and
  # point at the real lever. `unknown` deliberately falls through to the rotate
  # path — absence of measurement must not block a genuine cap response.
  #
  # FRESH here is deliberately STRICTER than the general CQ_MEASURE_MAX_AGE_MIN
  # (60min) this guard used to inherit. The collector runs every 20 min, and an
  # account at 85% when measured can be at 100% well inside an hour — so a
  # 59-minute-old "healthy" row was enough to veto rotation during a real cap
  # and page the exact opposite of the truth. Suppressing a genuine cap is the
  # worse error of the two: a false "not ours" strands the fleet on the paid
  # rung, whereas falling through merely reaches the rotate actuator, which has
  # its own measured gates (rc 7/8) and refuses on its own evidence. Anything
  # older than one collector cycle plus slack therefore does NOT get to veto.
  row="$(_active_measured_row)" || row=""
  state="$(cq_row_state "$row" "$CQ_CAP_PCT" "$CODEX_KEEPALIVE_NOISE_MAX_AGE_MIN")"
  if [ "$state" = healthy ]; then
    stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-authorder-noise-cooldown"
    if _cooldown_ok "$stamp" "$COOLDOWN_MIN"; then
      slack_notify ":mag: *Codex cap signature is NOT our active account* — the usage-limit line appeared ${hits}x in ${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min, but $(cq_format_evidence "the active account" "$row"). This is openclaw's own \`auth.order\` profile rotation retrying a spent profile (its cooldown caps at 5min, then the profile returns to the head of the order), not a cap on the account we run. Rotating the active account would change nothing. Check which account leads \`auth.order.openai\` — quotas: \`/opt/hydra/scripts/codex-usage-report.sh\`."
      date +%s > "$stamp"
      log "cap: signature ${hits}x but active account measures healthy — auth.order noise, not rotating (paged)"
    else
      log "cap: signature ${hits}x but active account measures healthy — auth.order noise, not rotating (within page cooldown)"
    fi
    return 0
  fi

  log "cap: usage-limit signature ${hits}x in last ${CODEX_KEEPALIVE_CAP_WINDOW_MIN}min, active account state=$state — attempting account rotation"

  # When we MEASURED our own account as capped, the active subscription is
  # spent and any reachable standby beats the paid rung — so an unmeasured
  # target is acceptable and the rotate script will say so on the page.
  # When the active account is merely `unknown`, we do NOT know the signature
  # is even ours, so we keep rc 8: burning a drain-restart pair on a guess is
  # the 2026-08-06 wasted-rotation failure, and a page naming the gap is the
  # honest response.
  local -a rotate_args=(--auto)
  [ "$state" = capped ] && rotate_args+=(--allow-unmeasured)
  rc=0
  "$CODEX_KEEPALIVE_ROTATE_BIN" "${rotate_args[@]}" --reason "usage cap (keepalive auto-rotate)" || rc=$?
  # Claim the tick ONLY if a rotation actually happened. CAP_ACTED exists to
  # stop two rotations in one tick; setting it before the call made a rotation
  # that changed NOTHING still block the later handlers. The concrete failure:
  # both signatures present with the active account's quota `unknown` → this
  # path calls rotate without --allow-unmeasured, gets rc 8, and
  # _check_session_revoked (which DOES pass --allow-unmeasured, because a
  # revoked account is provably dead) then returns immediately. Every tick
  # repeats it, so the fleet stays on the paid rung while the emergency reflex
  # that could rescue it never runs.
  [ "$rc" -eq 0 ] && CAP_ACTED=1
  case "$rc" in
    0) log "cap: auto-rotation kicked (the rotate script pages the outcome)" ;;
    3)
      # Cooldown — we rotated recently and the signature is still live. This is
      # NOT a statement about anyone's quota, and it must never be rendered as
      # one. Merging it with rc 7 under a single "every alternate account is
      # known-capped" headline is exactly how the false 2026-08-05 page was
      # produced.
      stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-rotatecooldown-cooldown"
      if _cooldown_ok "$stamp" "$COOLDOWN_MIN"; then
        slack_notify ":hourglass_flowing_sand: *Codex rotation deferred — cooldown* — the cap signature is live but a rotation already ran inside the ${CODEX_ROTATE_COOLDOWN_MIN:-120}min cooldown, so the actuator declined. No claim is being made about any account's quota. Quotas: \`/opt/hydra/scripts/codex-usage-report.sh\`; override: \`/opt/hydra/scripts/lib/codex-account-rotate.sh --to <email> --force\`."
        date +%s > "$stamp"
        log "cap: paged #clio_devops (rotation on cooldown, rc=3)"
      else
        log "cap: rotation on cooldown (rc=3), page within its own cooldown — not re-paging"
      fi ;;
    7)
      # Every alternate is MEASURED capped. This headline may only be used when
      # the claim is backed by a fresh measurement — cq_format_evidence cannot
      # render a percentage without its age and source, so an unmeasured
      # account renders as UNKNOWN here rather than silently as "capped".
      stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-bothcapped-cooldown"
      if _cooldown_ok "$stamp" "$COOLDOWN_MIN"; then
        slack_notify ":no_entry: *Codex — every alternate account is measured CAPPED* — the cap signature is live and rotation cannot help. Fleet rides the \`openrouter/openai/gpt-5.6-luna\` fallback rung (paid api-key route) until a window resets. $(_measured_account_lines) $(_measured_earliest_reset_note) Manual override: \`/opt/hydra/scripts/lib/codex-account-rotate.sh --to <email> --force\`."
        date +%s > "$stamp"
        log "cap: paged #clio_devops (all alternates measured capped, rc=7)"
      else
        log "cap: all alternates measured capped (rc=7) but page within its own cooldown — not re-paging"
      fi ;;
    8)
      # NEW: the actuator declined because it could not MEASURE a target, which
      # is a different fact from "the target is capped" and must never be
      # reported as one. Before the tri-state existed, an absent or stale
      # reading was read as healthy and the fleet was rotated onto an exhausted
      # account (2026-08-06, me.com: a 13-day-old row with a lapsed reset).
      stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-quotaunknown-cooldown"
      if _cooldown_ok "$stamp" "$COOLDOWN_MIN"; then
        slack_notify ":grey_question: *Codex — cannot measure alternate account quota* — the cap signature is live, but no alternate account has a fresh measurement, so auto-rotation declined rather than guess. *This is NOT a claim that those accounts are capped* — it means we do not know. $(_measured_account_lines) Check the collector (\`/var/log/codex-quota-refresh.log\`, kill switch \`/etc/hydra/codex-quota-probe.disabled\`), or rotate deliberately with \`/opt/hydra/scripts/lib/codex-account-rotate.sh --to <email> --allow-unmeasured\`."
        date +%s > "$stamp"
        log "cap: paged #clio_devops (alternate quota unknown, rc=8)"
      else
        log "cap: alternate quota unknown (rc=8) but page within its own cooldown — not re-paging"
      fi ;;
    4)
      stamp="$KEEPALIVE_STATE_DIR/codex-keepalive-nostandby-cooldown"
      if _cooldown_ok "$stamp" "$COOLDOWN_MIN"; then
        slack_notify ":no_entry_sign: *Codex — no standby account exists* — the cap signature is live and the canonical auth store holds no other usable codex profile (missing, no access token, or token expired). This is a STRUCTURAL fact about the credential store, not a quota claim. Fleet on the paid OpenRouter fallback rung until the window resets. Re-auth/refresh a second account (RUNBOOK §\"Codex Usage Cap / Account Rotation\")."
        date +%s > "$stamp"
        log "cap: paged #clio_devops (no viable standby account)"
      fi ;;
    *) log "cap: rotate failed rc=$rc (the rotate script pages critical failures itself)" ;;
  esac
}

# _check_proactive_rotate — rotate BEFORE the cap: a fresh snapshot showing a
# window >= ROTATE_AT% used with its reset still far away means the cap error
# is imminent; switching now skips the degraded window entirely. Failure modes
# are quiet by design — nothing is broken yet, and the reactive path (plus the
# rotate script's own paging) owns the alerts.
_check_proactive_rotate() {
  [ "$CAP_ACTED" -eq 0 ] || return 0
  if _rotated_recently; then
    return 0
  fi
  local row ts now f3 f4 f5 f6 f7 f8 w wm wp wr rc
  # MEASURED evidence, not the fleet-wide rollout snapshot. This path used to
  # read _active_snapshot — the account-blind inference this whole change
  # exists to retire — which meant the two halves of one tick could reach
  # opposite conclusions from different data: _check_usage_cap could measure
  # the active account healthy and decline to rotate, and then this function
  # could rotate anyway off an unattributed snapshot belonging to whichever
  # profile openclaw's own auth.order failover happened to be using. The result
  # was an unnecessary drain-restart of both gateways off a measured-healthy
  # account, plus a burnt 120-min cooldown that left the NEXT real cap able to
  # do nothing but page "rotation deferred".
  row="$(_active_measured_row)" || row=""
  [ -n "$row" ] || return 0
  now="$(date +%s)"
  IFS=$'\t' read -r ts _ f3 f4 f5 f6 f7 f8 _ _ <<<"$row"
  [[ "$ts" =~ ^[0-9]+$ ]] || return 0
  # Future-dated measurement: (now - ts) goes negative and passes the staleness
  # test, so a rolled-back clock would let this rotate the fleet off a reading
  # we have no reason to trust. Same guard as cq_row_state's.
  [ "$ts" -le "$(( now + CQ_MAX_CLOCK_SKEW_SEC ))" ] || return 0
  if [ "$(( now - ts ))" -gt "$(( CODEX_KEEPALIVE_PROACTIVE_FRESH_MIN * 60 ))" ]; then
    return 0   # measurement too old to act on
  fi
  for w in "$f3|$f4|$f5" "$f6|$f7|$f8"; do
    IFS='|' read -r wm wp wr <<<"$w"
    [[ "$wm" =~ ^[0-9]+$ ]] && [[ "$wr" =~ ^[0-9]+$ ]] || continue
    if awk -v p="$wp" -v m="$CODEX_KEEPALIVE_ROTATE_AT" 'BEGIN{exit !(p+0 >= m+0)}' \
       && [ "$(( wr - now ))" -gt "$(( CODEX_KEEPALIVE_MIN_RESET_MIN * 60 ))" ]; then
      log "proactive: $(cu_window_label "$wm") at ${wp}% used (>= ${CODEX_KEEPALIVE_ROTATE_AT}%) with reset $(cu_human_resets_in "$wr" "$now") — rotating before the cap hits"
      rc=0
      "$CODEX_KEEPALIVE_ROTATE_BIN" --auto \
        --reason "proactive: $(cu_window_label "$wm") at ${wp}% used" || rc=$?
      case "$rc" in
        0) log "proactive: rotation kicked (the rotate script pages the outcome)" ;;
        *) log "proactive: rotate declined rc=$rc — staying on the current account (reactive path owns any pages)" ;;
      esac
      return 0
    fi
  done
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

  # Usage-cap → account rotation (fleet-wide journal signal, checked once),
  # then the proactive pre-cap check (skipped if the reactive path just acted).
  _check_usage_cap
  _check_session_revoked
  _check_proactive_rotate
}

main "$@"
