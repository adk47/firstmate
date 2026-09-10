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
#       [--state-archive <cold-backup.tgz>] [--no-restart]
#
#   --no-restart  downgrade the binary + lockstep plugins only; leave the
#                 gateways STOPPED and skip the smoke test. The caller owns the
#                 state restore and the restart (the 2026.8.x runbook's Rollback
#                 block restores the pre-8.1 archive FIRST, then starts).
#                 On an auto-selected 2026.8+ -> 2026.7.1 rollback, one of
#                 --state-archive or --no-restart is REQUIRED.
#
# Companion: take the snapshots this script restores during the cutover —
#   - config:  cp /root/.openclaw-<p>/openclaw.json  <dir>/openclaw-<p>.json
#   - state:   (gateways stopped) tar -czf <cold-backup.tgz> -C / <verified state paths>
# ──────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/version-compare.sh
source "$SCRIPT_DIR/lib/version-compare.sh"

# ── Defaults / args ────────────────────────────────────────────────────────
TO_VERSION="2026.5.27"
TO_VERSION_SET=false
TARGET="all"
CONFIG_BACKUP=""
STATE_ARCHIVE=""
CONFIRMED=false
NO_RESTART=false
# Test seams (never set on a real run): the node-8 sanity dir and the root the
# cold archive extracts into.
SANITY_DIR="${DOWNGRADE_SANITY_DIR:-/opt/hydra/workspaces}"
# The profile state dirs live under /root (/root/.openclaw-main, /root/.openclaw-edge),
# and the runbook's cold archive is built with `tar -C /root ... .openclaw-main
# .openclaw-edge`, so its entries are `.openclaw-<profile>/...` RELATIVE TO /root.
# (The pre-2.0 version of this script extracted at `/`, which would have landed
# the restore at /.openclaw-main — never where the gateways read.)
RESTORE_ROOT="${DOWNGRADE_RESTORE_ROOT:-/root}"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)            TO_VERSION="${2:?--to needs a version}"; TO_VERSION_SET=true; shift 2 ;;
    --target)        TARGET="${2:?--target needs main|edge|all}"; shift 2 ;;
    --config-backup) CONFIG_BACKUP="${2:?--config-backup needs a dir}"; shift 2 ;;
    --state-archive) STATE_ARCHIVE="${2:?--state-archive needs a file}"; shift 2 ;;
    --yes)           CONFIRMED=true; shift ;;
    --no-restart)    NO_RESTART=true; shift ;;
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
if [[ ! -d "$SANITY_DIR" ]]; then
  die "node-8 sanity check failed: $SANITY_DIR is missing — refusing (not a hydra deploy host)."
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

# Auto-select the rollback target when --to wasn't given explicitly: an
# installed >=2026.8 runtime rolls back to 2026.7.1 (the last pre-2.0
# validated rung, per docs/runbooks/UPGRADE-2026.8.1.md) instead of the
# historical 2026.5.27 6.1-core-safe default (see codex-version.sh for the
# same ladder on the forward-pin side).
# The 2.0 -> pre-2.0 hazard is a property of SOURCE >= 2026.8 and DESTINATION
# < 2026.8, NOT of how the destination was chosen: an explicit
# `--to 2026.7.1` (or 2026.5.27) from a 2026.8.x install is exactly as unsafe as
# the auto-selected rollback. Determine the installed version independently of
# auto-selection and derive the flag from the (source, destination) pair.
# The installed SOURCE version must be POSITIVELY parsed before anything is
# chosen or guarded: an empty/unparseable `openclaw --version` is not a 7.x
# runtime, and treating it as one would skip the 2.0 -> pre-2.0 guard and
# restart a downgraded binary against one-way-migrated 8.x state.
ROLLBACK_FROM_81=false
installed_ver="$(cur_ver)"
[[ "$installed_ver" =~ ^[0-9]{4}(\.[0-9]+)+$ ]] \
  || die "cannot determine the installed openclaw version (\`openclaw --version\` returned '${installed_ver:-<empty>}') — refusing to choose a target or evaluate the 2.0 rollback guard on an unidentified runtime; fix the CLI first"
if ! $TO_VERSION_SET && version_at_least "2026.8" "$installed_ver"; then
  TO_VERSION="2026.7.1"
fi
if version_at_least "2026.8" "$installed_ver" && ! version_at_least "2026.8" "$TO_VERSION"; then
  ROLLBACK_FROM_81=true
fi
unset installed_ver

if $ROLLBACK_FROM_81 && [[ -z "$STATE_ARCHIVE" ]] && ! $NO_RESTART; then
  # A 2026.8+ runtime migrated the state one-way (auth + sessions to SQLite).
  # Downgrading the binary and RESTARTING on that state would boot 2026.7.1
  # against stores it cannot read and then smoke-test the wreckage. Refuse
  # unless the operator either hands us the pre-8.1 cold archive to restore
  # BEFORE the restart, or takes the restart out of our hands (--no-restart:
  # the runbook restores first, then starts).
  die "rolling back from a 2026.8+ runtime requires --state-archive <pre-8.1 cold archive> (restored before any restart) or --no-restart (the caller restores state, then starts the gateways) — see docs/runbooks/UPGRADE-2026.8.1.md §Rollback"
fi
if $ROLLBACK_FROM_81; then
  log "REMINDER: rolling back from a 2026.8+ runtime. State is NOT forward-compatible:"
  log "  - restore state from the PRE-8.1 cold archive taken before the first 8.1"
  log "    restart (docs/runbooks/UPGRADE-2026.8.1.md Phase 2) via --state-archive;"
  log "    the shared-auth SQLite rows this runtime wrote will not survive a"
  log "    forward-then-back trip on a 7.1 core otherwise."
  log "  - re-enable codex-token-refresh.timer if it was disabled for the 2026.8.1"
  log "    window (docs/runbooks/UPGRADE-2026.8.1.md) — the 7.1 core relies on it"
  log "    for OAuth refresh and does not read the 2.0 auth-mint path."
fi

# --no-restart contract on a 2.0 -> pre-2.0 rollback: the caller has ALREADY
# restored the pre-8.1 state (the runbook's Rollback block does so before
# invoking us), because the plugins we pin below land inside the profile state
# dirs and a restore AFTER us would replace them with the archive's old trees.
# Verify it: a state dir that still carries the 2.0 shared-auth cell table is
# a live/migrated 8.x tree, not a restored one — refuse before any mutation.
state_dir_is_2_0_migrated() { # <profile-state-dir> -> 0 = 2.0 cell table present; 1 = readable DB WITHOUT it; 3 = no DB at all; 2 = unreadable
  local dbf="$1/state/openclaw.sqlite"
  # A restored pre-8.1 tree HAS state/openclaw.sqlite (7.1 keeps cron/plugin
  # state there); a missing DB is a damaged or never-restored tree, not proof.
  [[ -f "$dbf" ]] || return 3
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    try { const db=new DatabaseSync(process.argv[1],{readOnly:true});
      const r=db.prepare("select 1 from sqlite_master where type=? and name=?").get("table","config_machine_state");
      process.exit(r ? 0 : 1); } catch (e) { process.exit(2); }' "$dbf" 2>/dev/null
}
if $ROLLBACK_FROM_81 && $NO_RESTART; then
  for p in $(profiles); do
    mig_rc=0; state_dir_is_2_0_migrated "${RESTORE_ROOT%/}/.openclaw-$p" || mig_rc=$?
    case "$mig_rc" in
      1) ;;   # the ONLY passing result: the DB is readable and has no 2.0 cell table (or there is no DB yet)
      0) die "--no-restart requires the pre-8.1 state to be restored BEFORE this helper runs, but ${RESTORE_ROOT%/}/.openclaw-$p still carries the 2.0 shared-auth cell (a live/migrated 8.x tree). Restore the archive first (docs/runbooks/UPGRADE-2026.8.1.md §Rollback), then re-run — plugins pinned now would be wiped by that restore." ;;
      3) die "${RESTORE_ROOT%/}/.openclaw-$p has NO state/openclaw.sqlite — a restored pre-8.1 tree carries one; this is a damaged or never-restored tree, not proof of a restore. Refusing before any mutation." ;;
      *) die "cannot tell whether ${RESTORE_ROOT%/}/.openclaw-$p is a restored pre-8.1 tree: its state/openclaw.sqlite is unreadable/corrupt (probe rc=$mig_rc). An unverifiable tree is NOT a restored one — refusing before any mutation." ;;
    esac
  done
fi
log "Downgrade plan:"
log "  current openclaw binary : $(cur_ver)"
log "  target version          : $TO_VERSION"
log "  profiles                : $(profiles)"
log "  config-backup           : ${CONFIG_BACKUP:-<none — keeping live config>}"
log "  state-archive           : ${STATE_ARCHIVE:-<none — NOT restoring SQLite state>}"
log "  restart + smoke         : $($NO_RESTART && echo 'SKIPPED (--no-restart: caller restarts)' || echo yes)"
[[ -n "$CONFIG_BACKUP"  ]] && { [[ -d "$CONFIG_BACKUP" ]]  || die "config-backup dir not found: $CONFIG_BACKUP"; }
[[ -n "$STATE_ARCHIVE" ]] && { [[ -f "$STATE_ARCHIVE" ]] || die "state-archive not found: $STATE_ARCHIVE"; }

if ! $CONFIRMED; then
  read -r -p "Proceed with runtime DOWNGRADE to $TO_VERSION on [$(profiles)]? Type 'downgrade' to confirm: " ans
  [[ "$ans" == "downgrade" ]] || die "aborted by operator"
fi

# ── 0. PREFLIGHT the archive (no mutation yet) ─────────────────────────────
# Extract + structurally validate BEFORE any gateway is stopped or the global
# binary is replaced: a truncated archive or one missing a targeted profile
# must fail while the fleet is still running on the untouched runtime, not
# after both gateways are down and the binary is already downgraded.
restore_tmp=""
if [[ -n "$STATE_ARCHIVE" ]]; then
  log "Preflighting cold archive $STATE_ARCHIVE (extract + validate before any mutation) ..."
  restore_tmp="$(mktemp -d "$RESTORE_ROOT/pre81-restore.XXXXXX")" || die "cannot create a temp restore root under $RESTORE_ROOT"
  tar -C "$restore_tmp" -xzf "$STATE_ARCHIVE" || { rm -rf "$restore_tmp"; die "state archive does not extract (truncated/corrupt?) — nothing was stopped or downgraded"; }
  for p in $(profiles); do
    d=".openclaw-$p"
    [[ -s "$restore_tmp/$d/openclaw.json" ]] && { [[ -e "$restore_tmp/$d/state/openclaw.sqlite" ]] || [[ -e "$restore_tmp/$d/agents" ]]; } \
      || { rm -rf "$restore_tmp"; die "archive has no usable $d tree (openclaw.json + state/openclaw.sqlite or agents/) — refusing BEFORE any mutation; the fleet is untouched"; }
  done
  log "  archive OK: $(profiles)trees present and complete"
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

# ── 3. Restore cold state FIRST (gateways are stopped) ─────────────────────
# BEFORE plugins and config: the archive REPLACES each whole profile state dir,
# which is exactly where the per-profile plugins (<state-dir>/npm/) and the
# live openclaw.json live. Installing plugins or restoring a config backup
# before this swap would be silently undone by it (observed in QA review:
# a 5.27 core would have started with the archive's 7.1 plugin trees).
if [[ -n "$STATE_ARCHIVE" ]]; then
  # REPLACE, never overlay: extracting over the live tree keeps every file the
  # archive did not contain (a 2026.8 `state/openclaw.sqlite`, migrated agent
  # DBs, *.migrated-* sidecars) and boots the old runtime on a mixed-generation
  # tree. Extract into a temp root, validate each targeted profile tree, then
  # swap the live directories — the same contract as the runbook's rollback block.
  log "Restoring state from the preflighted archive (replace, not overlay) ..."
  [[ -n "$restore_tmp" && -d "$restore_tmp" ]] || die "internal: preflighted restore root missing"
  for p in $(profiles); do
    d=".openclaw-$p"
    # ${d:?} + the explicit pattern check: this rm can never expand to "/" or to
    # anything but a profile state dir, whatever the env seams hold.
    [[ "$d" =~ ^\.openclaw-(main|edge)$ ]] || die "refusing to remove '$d' — not a profile state dir"
    rm -rf "${RESTORE_ROOT%/}/${d:?}" || die "could not remove live $d before restore"
    mv "$restore_tmp/$d" "${RESTORE_ROOT%/}/$d" || die "could not move restored $d into place — live state is GONE; restore by hand from $STATE_ARCHIVE"
    log "  replaced ${RESTORE_ROOT%/}/$d from the archive"
  done
  rmdir "$restore_tmp" 2>/dev/null || rm -rf "$restore_tmp"
  log "  state restored. NOTE: any state written after the backup is lost."
fi

# ── 4. Restore config (out-of-band write → must announce first) ────────────
# After the state swap, so a config backup is not overwritten by the archive's openclaw.json.
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

# ── 5. Downgrade per-profile @openclaw/slack + @openclaw/codex (lockstep) ──
# LAST of the state-dir writers: the plugin trees must land in the RESTORED
# state dir and be verified there.
# 2026.8+ CLIs REFUSE a plugin install without --accept-capabilities (the
# non-interactive capability ack); 7.x CLIs reject the option as unknown. Gate
# it on the DESTINATION version — the same contract deploy.sh applies — so an
# 8.x -> 8.x move (e.g. --to 2026.8.1 from 2026.8.2) installs cleanly and a
# 2.0 -> 7.1 rollback never passes a flag the old CLI cannot parse.
plugin_flags=()
if version_at_least "2026.8" "$TO_VERSION"; then plugin_flags+=(--accept-capabilities); fi
for p in $(profiles); do
  for pkg in @openclaw/slack @openclaw/codex; do
    log "Pinning $pkg@$TO_VERSION on profile=$p ..."
    openclaw --profile "$p" plugins install "$pkg@$TO_VERSION" --force --pin "${plugin_flags[@]}" \
      || die "plugins install $pkg@$TO_VERSION failed (profile=$p)"
    pv="$(plugin_ver "$p" "$pkg")"
    [[ "$pv" == "$TO_VERSION" ]] || die "$pkg on $p reports '${pv:-missing}' after install of $TO_VERSION"
    log "  $pkg@$p now: $pv"
  done
done

# ── 6. Re-point codex auth symlinks (self-heal canonical store) ────────────
if [[ -x "$SCRIPT_DIR/lib/ensure-codex-auth.sh" ]]; then
  log "Re-running ensure-codex-auth.sh ..."
  "$SCRIPT_DIR/lib/ensure-codex-auth.sh" || log "  WARN: ensure-codex-auth returned non-zero"
fi

# ── 7. Start gateways ──────────────────────────────────────────────────────
if $NO_RESTART; then
  log "--no-restart: binary + plugins downgraded to $(cur_ver) into the (already restored) state dirs; gateways left STOPPED."
  log "Next (caller-owned): systemctl start openclaw-gateway-{$(profiles | tr ' ' ',' | sed 's/,$//')}, then smoke-test. Do NOT restore state after this point — it would replace the plugin trees just pinned."
  exit 0
fi
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
