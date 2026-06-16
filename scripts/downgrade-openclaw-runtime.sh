#!/usr/bin/env bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────────
# downgrade-openclaw-runtime.sh — MANUAL-ONLY OpenClaw runtime downgrade
# ──────────────────────────────────────────────────────────────────────────
# Downgrades the GLOBAL `openclaw` npm binary AND the per-profile
# @openclaw/slack + @openclaw/codex plugins, optionally restoring config and
# SQLite state, then restarts gateways and smoke-tests. This is the runtime
# rollback that a version bump (e.g. 2026.6.1 -> 2026.5.27) needs.
#
# ── THIS IS NOT rollback.sh ────────────────────────────────────────────────
# rollback.sh reverts ONLY committed config (git checkout HEAD~1 of
# openclaw-*.json) and restarts gateways — it does NOT touch the npm binary,
# the @openclaw/* plugins, or migrated SQLite state. .github/workflows/
# deploy.yml AUTO-FIRES rollback.sh on `if: failure()`. This script is
# DELIBERATELY NOT wired into CI or the watchdog: auto-downgrading the binary
# on a transient deploy failure would fight an intended upgrade and re-arm the
# "new binary on disk + old gateway in memory" hazard. Run it BY HAND, on
# node-8, with intent — never from automation.
#
# ── One-way state caveat ───────────────────────────────────────────────────
# OpenClaw 2026.6.1 forward-migrates SQLite-backed state (cron run-logs,
# plugin install ledgers, session metadata, channel bindings) on first boot.
# That migration is likely one-way: an older binary may not read the newer
# schema. The ONLY clean state-downgrade path is to restore a COLD backup
# taken with both gateways stopped BEFORE the first 6.1 restart (cutover
# Phase 3). Pass that archive via --state-archive. Without it, channel
# bindings can come up empty (smoke-test "0 agents bound") and recent state
# is lost.
#
# Usage:
#   downgrade-openclaw-runtime.sh --to 2026.5.27 --yes \
#       [--target main|edge|all] \
#       [--config-backup <dir-with-openclaw-{main,edge}.json>] \
#       [--state-archive <cold-backup.tgz>]
#
# Companion: take the snapshots this script restores during the cutover —
#   - config:  cp /root/.openclaw-<p>/openclaw.json  <dir>/openclaw-<p>.json
#   - state:   (gateways stopped) tar -czf <cold-backup.tgz> -C / <verified state paths>
# ──────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults / args ────────────────────────────────────────────────────────
TO_VERSION="2026.5.27"
TARGET="all"
CONFIG_BACKUP=""
STATE_ARCHIVE=""
CONFIRMED=false

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)            TO_VERSION="${2:?--to needs a version}"; shift 2 ;;
    --target)        TARGET="${2:?--target needs main|edge|all}"; shift 2 ;;
    --config-backup) CONFIG_BACKUP="${2:?--config-backup needs a dir}"; shift 2 ;;
    --state-archive) STATE_ARCHIVE="${2:?--state-archive needs a file}"; shift 2 ;;
    --yes)           CONFIRMED=true; shift ;;
    -h|--help)       sed -n '2,52p' "$0"; exit 0 ;;
    *)               die "unknown arg: $1 (see --help)" ;;
  esac
done

[[ "$TO_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || die "--to '$TO_VERSION' is not a valid openclaw version (e.g. 2026.5.27)"
case "$TARGET" in main|edge|all) ;; *) die "--target must be main|edge|all" ;; esac
needs() { [[ "$TARGET" == "all" || "$TARGET" == "$1" ]]; }
profiles() { needs main && echo -n "main "; needs edge && echo -n "edge "; }

# ── Guards: node-8 only, never from automation, explicit consent ───────────
if [[ -n "${CI:-}${GITHUB_ACTIONS:-}${HYDRA_AUTO_ROLLBACK:-}" ]]; then
  die "refusing to run from automation (CI/GITHUB_ACTIONS/HYDRA_AUTO_ROLLBACK set). This is a manual-only tool — never wire it into CI or the watchdog."
fi
# Fail-CLOSED node-8 gate: the hostname match is MANDATORY (node-8 reports
# `ovh-node-8`), with the deploy-path as an additional sanity check — BOTH must
# hold. A non-node-8 host that merely has /opt/hydra/workspaces must NOT be able
# to reach the destructive path (stop gateways, downgrade the global binary,
# reinstall plugins, restart). Was an OR-pass guard; tightened per PR #523 QA.
if ! { hostname | grep -q 'node-8'; }; then
  die "this must run on node-8 (downgrades the global openclaw binary + restarts live gateways). hostname='$(hostname)' is not node-8 — refusing."
fi
if [[ ! -d /opt/hydra/workspaces ]]; then
  die "node-8 sanity check failed: /opt/hydra/workspaces is missing — refusing (not a hydra deploy host)."
fi
command -v openclaw >/dev/null || die "openclaw CLI not on PATH"
command -v npm >/dev/null      || die "npm not on PATH"

cur_ver() { openclaw --version 2>/dev/null | awk 'NR==1 {print $2}'; }
# Resolve the installed plugin version from the runtime's OWN ledger
# (`plugins list --json`, keyed by unscoped plugin id) — NOT a guessed
# filesystem path. openclaw 2026.6.x isolates externalized installs under
# ~/.openclaw-<p>/npm/projects/openclaw-<pkg>-<hash>/node_modules/ (#88794),
# so the old npm/node_modules/<pkg> read returned "" after a 6.x install. The
# --json shape is identical on 5.27 and 6.x (verified v2026.5.27 tag), so this
# one read is correct for ANY downgrade target. Mirrors deploy.sh's
# plugin_runtime_version (PR #537).
plugin_ver() { # <profile> <pkg e.g. @openclaw/slack>
  local profile="$1" id="${2##*/}"
  # `|| true` is load-bearing: a ledger lookup failure must yield empty, NOT
  # abort. Under `set -euo pipefail` a non-zero pipeline (pipefail propagates an
  # openclaw failure) would exit the script at the plain assignment
  # `pv=$(plugin_ver ...)` BEFORE the contextual `die "<pkg> on <p> reports
  # 'missing'"` below could run — turning a diagnostic into a silent abort.
  openclaw --profile "$profile" plugins list --json 2>/dev/null \
    | jq -r --arg id "$id" '(.plugins // .)[]? | select(.id == $id) | .version // empty' 2>/dev/null \
    | head -1 || true
}

log "Downgrade plan:"
log "  current openclaw binary : $(cur_ver)"
log "  target version          : $TO_VERSION"
log "  profiles                : $(profiles)"
log "  config-backup           : ${CONFIG_BACKUP:-<none — keeping live config>}"
log "  state-archive           : ${STATE_ARCHIVE:-<none — NOT restoring SQLite state>}"
[[ -n "$CONFIG_BACKUP"  ]] && { [[ -d "$CONFIG_BACKUP" ]]  || die "config-backup dir not found: $CONFIG_BACKUP"; }
[[ -n "$STATE_ARCHIVE" ]] && { [[ -f "$STATE_ARCHIVE" ]] || die "state-archive not found: $STATE_ARCHIVE"; }

if ! $CONFIRMED; then
  read -r -p "Proceed with runtime DOWNGRADE to $TO_VERSION on [$(profiles)]? Type 'downgrade' to confirm: " ans
  [[ "$ans" == "downgrade" ]] || die "aborted by operator"
fi

# ── 1. Stop gateways (so SQLite is quiescent before restore) ───────────────
for p in $(profiles); do
  log "Stopping openclaw-gateway-$p ..."
  systemctl stop "openclaw-gateway-$p" || log "  WARN: stop returned non-zero (continuing)"
done

# ── 2. Downgrade the global binary ─────────────────────────────────────────
log "Installing openclaw@$TO_VERSION globally ..."
npm install -g "openclaw@$TO_VERSION" || die "npm install -g openclaw@$TO_VERSION failed"
got="$(cur_ver)"
[[ "$got" == "$TO_VERSION" ]] || die "binary still reports '$got' after install of $TO_VERSION"
log "  global binary now: $got"

# ── 3. Downgrade per-profile @openclaw/slack + @openclaw/codex (lockstep) ──
for p in $(profiles); do
  for pkg in @openclaw/slack @openclaw/codex; do
    log "Pinning $pkg@$TO_VERSION on profile=$p ..."
    openclaw --profile "$p" plugins install "$pkg@$TO_VERSION" --force --pin \
      || die "plugins install $pkg@$TO_VERSION failed (profile=$p)"
    pv="$(plugin_ver "$p" "$pkg")"
    [[ "$pv" == "$TO_VERSION" ]] || die "$pkg on $p reports '${pv:-missing}' after install of $TO_VERSION"
    log "  $pkg@$p now: $pv"
  done
done

# ── 4. Restore config (out-of-band write → must announce first) ────────────
if [[ -n "$CONFIG_BACKUP" ]]; then
  for p in $(profiles); do
    src="$CONFIG_BACKUP/openclaw-$p.json"
    dst="/root/.openclaw-$p/openclaw.json"
    [[ -f "$src" ]] || { log "  WARN: $src missing — leaving live $p config in place"; continue; }
    sha="$(sha256sum "$src" | awk '{print $1}')"
    ANNOUNCE_SHA="$sha" "$SCRIPT_DIR/lib/announce-legit-write.sh" downgrade-openclaw-runtime.sh "$dst" \
      || log "  WARN: announce-legit-write failed (audit watcher may false-positive)"
    install -m 600 "$src" "$dst" || die "failed to restore config to $dst"
    log "  restored config: $dst (from $src)"
  done
fi

# ── 5. Restore cold SQLite state (gateways are stopped) ────────────────────
if [[ -n "$STATE_ARCHIVE" ]]; then
  log "Restoring SQLite state from cold archive $STATE_ARCHIVE ..."
  tar -xzf "$STATE_ARCHIVE" -C / || die "state restore (tar -xzf) failed"
  log "  state restored. NOTE: any state written after the backup is lost."
fi

# ── 6. Re-point codex auth symlinks (self-heal canonical store) ────────────
if [[ -x "$SCRIPT_DIR/lib/ensure-codex-auth.sh" ]]; then
  log "Re-running ensure-codex-auth.sh ..."
  "$SCRIPT_DIR/lib/ensure-codex-auth.sh" || log "  WARN: ensure-codex-auth returned non-zero"
fi

# ── 7. Start gateways ──────────────────────────────────────────────────────
for p in $(profiles); do
  log "Starting openclaw-gateway-$p ..."
  systemctl start "openclaw-gateway-$p" || die "failed to start openclaw-gateway-$p"
done

# ── 8. Smoke-test + verify ─────────────────────────────────────────────────
log "Smoke-testing target=$TARGET ..."
"$SCRIPT_DIR/smoke-test.sh" "$TARGET" || die "smoke-test FAILED after downgrade — investigate immediately"

if [[ -x "$SCRIPT_DIR/lib/ensure-codex-auth.sh" ]]; then
  log "Verifying codex auth symlinks ..."
  "$SCRIPT_DIR/lib/ensure-codex-auth.sh" --check \
    || log "  WARN: ensure-codex-auth --check flagged a non-symlink/dangling store — see codex-health watchdog"
fi

log "Downgrade complete. openclaw=$(cur_ver) on [$(profiles)]."
log "Next: confirm model selection is openai/* (not Sonnet fallback) and channel bindings are present."
