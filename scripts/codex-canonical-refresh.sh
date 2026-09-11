#!/usr/bin/env bash
# codex-canonical-refresh.sh — the scheduled codex OAuth refresher on 2.0.
#
# ── Why this exists ─────────────────────────────────────────────────────────
# NOTHING on this box refreshed the codex chain between the 2026-09-10 cutover
# and this script. codex-token-refresh.timer was retired during the upgrade on
# the premise that openclaw 2.0's native in-process auto-refresh takes over.
# That premise is FALSE here: the bundled `openai` plugin owns the
# refresh-on-use machinery and hydra keeps it DISABLED to dodge #90925, and a
# disabled plugin still OWNS provider `openai`, so the refresh path resolves to
# `configured-unavailable` and throws before any builtin fallback. Measured on
# 2026-09-11: no ENABLED plugin owns provider openai, codex declares
# providers=[], and no codex timer was armed. Earliest access-token expiry was
# 2026-09-20T12:56:09Z — a dated fleet-wide outage.
#
# This restores the retired timer's contract (refresh + restart, Sun+Wed 04:00
# UTC) against 2.0's SQLite auth cell instead of the pre-8.1 JSON store.
#
# ── What it does ────────────────────────────────────────────────────────────
#   1. codex-mint-idtoken.sh --all-profiles: one `grant_type=refresh_token`
#      POST per real profile, under ONE flock, writing access/refresh/idToken
#      back into the same cell. Sentinel-bearing (derived) profiles are skipped.
#   2. Restart the gateways — ONLY if something actually rotated.
#
# ── Why the restart is conditional ──────────────────────────────────────────
# The gateway loads auth at STARTUP; an out-of-band cell write is not reliably
# hot-reloaded (the runtime serves an in-process auth snapshot), so a rotation
# without a restart leaves the fresh token unloaded. But a no-op sweep must NOT
# restart the fleet: that would interrupt Caroline mid-conversation for nothing.
# Gate: exit 0 AND SWEEP_ROTATED >= 1.
#
# ── Why the drain-aware path ────────────────────────────────────────────────
# Reuses drain_restart_gateway() from lib/gateway-restart.sh, the same helper
# deploy.sh and codex-account-rotate.sh use, so the bounded-drain timeouts are
# defined ONCE. A restart is not free: on 2026-09-11 the drain forced
# qa-autoreview-pr-3126 to status=error inside its 335s wait. This logs the
# drain's own summary so that cost is visible in the journal rather than
# discovered later.
#
# Env overrides: CODEX_REFRESH_STATE_DIR, CODEX_REFRESH_SERVICES,
#                CODEX_REFRESH_RESTART (0 = converge only), MINT_BIN
set -uo pipefail

_CR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGPREFIX="[codex-canonical-refresh $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

STATE_DIR="${CODEX_REFRESH_STATE_DIR:-/root/.openclaw-main}"
# main FIRST, then edge: main owns the canonical cell, and a failure there is
# the one worth aborting on before disturbing the customer-facing profile.
SERVICES="${CODEX_REFRESH_SERVICES:-openclaw-gateway-main.service openclaw-gateway-edge.service}"
RESTART="${CODEX_REFRESH_RESTART:-1}"
MINT_BIN="${MINT_BIN:-$_CR_DIR/lib/codex-mint-idtoken.sh}"

# shellcheck source=lib/slack-notify.sh
[ -r "$_CR_DIR/lib/slack-notify.sh" ] && source "$_CR_DIR/lib/slack-notify.sh"
_page() { command -v slack_notify >/dev/null 2>&1 && slack_notify "$1" || log "PAGE(unsent): $1"; }
_page_critical() { command -v slack_notify_critical >/dev/null 2>&1 && slack_notify_critical "$1" || _page "$1"; }

[ -x "$MINT_BIN" ] || { log "ERROR: $MINT_BIN missing or not executable"; exit 2; }

# Stand down during a planned maintenance window. A window is exactly when a
# human (or a deploy run by one) is deliberately restarting gateways, and this
# unit would add a SECOND drain-restart on top — same reasoning as
# codex-keepalive.sh. Fail-safe: an absent/expired/malformed flag reads as "not
# in maintenance", so a missing flag can never suppress a refresh.
#
# KNOWN GAP, stated rather than papered over: this does NOT make the refresh
# mutually exclusive with an UNANNOUNCED deploy. Neither deploy.sh nor
# lib/gateway-restart.sh takes a lock around the restart, so a lock taken only
# here would be honoured by one side and buy nothing. Closing it properly means
# a shared lock in gateway-restart.sh that deploy.sh also takes — out of scope
# here and tracked separately. The residual risk is a redundant drain-restart if
# a deploy runs at Sun/Wed 04:00 UTC without a window open; systemd serialises
# `systemctl restart` per unit, so the cost is a wasted drain, not corruption.
if [ -r "$_CR_DIR/lib/maintenance-flag.sh" ]; then
  # shellcheck source=lib/maintenance-flag.sh
  source "$_CR_DIR/lib/maintenance-flag.sh"
  if maintenance_active 2>/dev/null; then
    log "maintenance window open ($(maintenance_reason 2>/dev/null || echo 'unknown')) — standing down; the token has days of life and the next tick refreshes"
    exit 0
  fi
fi

# ── 1. the sweep ────────────────────────────────────────────────────────────
sweep_out=""
sweep_rc=0
sweep_out="$("$MINT_BIN" --state-dir "$STATE_DIR" --all-profiles 2>&1)" || sweep_rc=$?
printf '%s\n' "$sweep_out" >&2

# Read the MACHINE channel FIRST, BEFORE branching on rc, and never the prose.
# A partial sweep — profile A rotated and COMMITTED, profile B then failed —
# exits non-zero while A's fresh credentials are already persisted and A's old
# single-use refresh token is SPENT. Gating the restart on rc==0 left those
# credentials persisted-but-unloaded: the running gateway kept serving a
# snapshot whose refresh chain had moved on. So a committed rotation is loaded
# REGARDLESS of the sweep's rc, and the failures are paged AFTER the restart
# rather than instead of it.
rotated="$(printf '%s\n' "$sweep_out" | sed -n 's/^SWEEP_ROTATED=\([0-9][0-9]*\)$/\1/p' | tail -1)"

if [ "$sweep_rc" -ne 0 ] && { [ -z "$rotated" ] || [ "$rotated" -lt 1 ]; }; then
  # Nothing was committed, so there is nothing to load: a restart would cost a
  # drain for no benefit.
  log "sweep FAILED (rc=$sweep_rc) with NO committed rotation — NOT restarting"
  _page_critical ":rotating_light: *codex canonical refresh FAILED* on node-8 (rc=${sweep_rc}) — the OAuth chain was NOT rotated and the fleet will drop to \`openrouter\` when the current access token expires. Check \`/var/log/codex-canonical-refresh.log\` and RUNBOOK §\"Codex Token Lapse\"."
  exit "$sweep_rc"
fi

if [ "$sweep_rc" -ne 0 ]; then
  log "sweep PARTIAL (rc=$sweep_rc, rotated=$rotated) — restarting anyway so the COMMITTED rotations load, then reporting the failures"
fi

if [ -z "$rotated" ] && [ "$sweep_rc" -eq 0 ]; then
  log "ERROR: sweep exited 0 but emitted no SWEEP_ROTATED marker — refusing to guess whether a restart is needed"
  _page_critical ":warning: *codex canonical refresh* on node-8 exited 0 without a \`SWEEP_ROTATED\` marker — cannot tell whether the chain rotated, so no restart was attempted. Inspect \`/var/log/codex-canonical-refresh.log\`."
  exit 2
fi
log "sweep OK — rotated=$rotated"

if [ "$rotated" -lt 1 ]; then
  log "nothing rotated — NOT restarting the fleet (a no-op sweep must not interrupt live work)"
  exit 0
fi

# ── 2. the restart ──────────────────────────────────────────────────────────
if [ "$RESTART" != "1" ]; then
  log "CODEX_REFRESH_RESTART=0 — cell converged, skipping restarts (the token loads on the next restart)"
  exit 0
fi

# Guard the helper explicitly. This script runs `set -uo pipefail` WITHOUT -e,
# so a failed `source` would NOT abort: drain_restart_gateway would simply be
# "command not found", land in the failure branch, and page "restart FAILED" —
# accidentally non-zero, but for the wrong reason and with a page that sends
# the reader to systemctl instead of to the missing file.
if [ ! -r "$_CR_DIR/lib/gateway-restart.sh" ]; then
  log "ERROR: lib/gateway-restart.sh missing or unreadable — the chain ROTATED but cannot be loaded"
  _page_critical ":rotating_light: *codex canonical refresh* rotated the chain on node-8 but \`lib/gateway-restart.sh\` is missing/unreadable, so no gateway was restarted. The new token is in \`authProfiles.store\` and NOT loaded on either profile. Restart both gateways by hand."
  exit 2
fi
# shellcheck source=lib/gateway-restart.sh
source "$_CR_DIR/lib/gateway-restart.sh"
GATEWAY_FALLBACK_NOTIFY_FN="${GATEWAY_FALLBACK_NOTIFY_FN:-_page}"
export GATEWAY_FALLBACK_NOTIFY_FN

restart_failed=0
failed_services=""
ok_services=""
for service in $SERVICES; do
  profile="${service##*-}"; profile="${profile%.service}"
  if drain_restart_gateway "$service" "$profile"; then
    ok_services="${ok_services:+$ok_services }$service"
    log "$service restarted (drain summary above — any forced work is the cost of this refresh)"
  else
    restart_failed=1
    failed_services="${failed_services:+$failed_services }$service"
    log "ERROR: $service restart FAILED — the rotated token is NOT loaded on this profile"
  fi
done

if [ "$restart_failed" -ne 0 ]; then
  # Name WHICH profile failed, and do not claim more than was measured. The
  # first version said "the fleet runs on the OLD access token" for ANY
  # failure — false on a partial one, where the restarted profile HAS loaded
  # the new token. Sending a reader after a fleet-wide fault that is really
  # edge-only is the same class of error as a page with no evidence in it.
  _page_critical ":rotating_light: *codex canonical refresh rotated the chain but a gateway restart FAILED* on node-8 — FAILED: \`${failed_services}\`${ok_services:+ (restarted OK: \`${ok_services}\`)}. The new token is in \`authProfiles.store\` but is NOT loaded on the failed profile(s), which keep serving the OLD access token until restarted. Run \`systemctl status ${failed_services}\` now."
  exit 6
fi

if [ "$sweep_rc" -ne 0 ]; then
  # The committed rotations ARE loaded now, but the sweep did not complete.
  # Exit non-zero so the timer goes red, and name what failed — reporting
  # success here would hide a chain that still needs attention.
  log "refresh PARTIAL — rotated=$rotated loaded, but the sweep failed (rc=$sweep_rc)"
  _page_critical ":warning: *codex canonical refresh was PARTIAL* on node-8 — ${rotated} profile(s) rotated AND loaded (gateways restarted), but the sweep exited ${sweep_rc}: at least one profile did NOT rotate. The loaded profiles are fine; the failed one(s) still hold their old refresh token and will lapse. See \`/var/log/codex-canonical-refresh.log\` for the per-profile lines."
  exit "$sweep_rc"
fi

log "refresh complete — rotated=$rotated, both gateways restarted"
exit 0
