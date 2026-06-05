#!/usr/bin/env bash
set -euo pipefail

# HYDRA Deploy Script
# ===================
# CD entrypoint: validate config, sync to Node 8, restart gateway, smoke test.
# Supports targeted deployment: --target main|edge|all
#
# Run from node-8 itself (preferred — CI does this) or via SSH from a
# laptop. Laptop deploys go through the rsync-over-SSH branches but the
# POSTSYNC heredoc, Steps 4c/4d, and the profile config sync run on
# the local box, so a laptop deploy is only viable when the local box
# IS node-8 or a similar Linux host with /root/.openclaw/ access.
# In practice: SSH into node-8 first, then run deploy.sh from there.
#     ssh -i ~/.ssh/nick_ovh root@40.160.32.80
#     cd /opt/hydra && ./scripts/deploy.sh [--target main|edge|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

# Pinned openclaw runtime version. Updated together with this file so the
# version change appears in git history alongside any deploy-script tweaks
# the upgrade requires. Bump in lockstep with docs/REPO-MANAGEMENT.md.
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.5.27}"

# Pinned @openclaw/slack version. 2026.5.12 externalized Slack into this
# npm package; the bundled `channels.slack` plugin no longer ships. Kept
# in lockstep with OPENCLAW_VERSION by default — the SDK pluginApi compat
# range tracks the core release.
OPENCLAW_SLACK_VERSION="${OPENCLAW_SLACK_VERSION:-${OPENCLAW_VERSION}}"

# Pinned @openclaw/codex version. The Codex agent harness ships as this
# separate npm package; its supports()/ABI tracks the core runtime.
# openclaw 2026.5.20 made the runtime validate a forced harness's
# supports() BEFORE pinning it, so a Codex plugin older than the runtime
# silently rejects `openai/*` models and every Codex-pinned agent falls
# back to its secondary model. Incident 2026-05-29: the runtime bumped
# 5.19 -> 5.27 but the 5.19 Codex plugin stayed (deploy only pinned
# Slack), so ceo/cto/qa/operations/devops/design rejected openai/gpt-5.5
# and ran on Sonnet. Keep in lockstep with OPENCLAW_VERSION.
OPENCLAW_CODEX_VERSION="${OPENCLAW_CODEX_VERSION:-${OPENCLAW_VERSION}}"

# Detect if we're running on Node 8 (the HYDRA host)
if hostname | grep -q 'node-8\|ovh-node-8' || [ -d "/opt/hydra/workspaces" ]; then
  HYDRA_LOCAL=true
else
  HYDRA_LOCAL=false
fi

# ─── SSH connection: which key, which IP, why? ────────────────────
#
# There are TWO valid configurations for reaching node-8 and they don't
# share defaults. The script auto-picks one and lets you override either
# half via env var.
#
#   ┌────────────────┬────────────────────┬──────────────────────┐
#   │ Where you are  │ SSH key            │ NODE8_IP             │
#   ├────────────────┼────────────────────┼──────────────────────┤
#   │ CI / vrack     │ ~/.ssh/ovh_muso    │ 10.0.0.8  (vrack)    │
#   │ Laptop / WAN   │ ~/.ssh/nick_ovh    │ 40.160.32.80 (public)│
#   └────────────────┴────────────────────┴──────────────────────┘
#
# SSH_KEY: auto-detected. We probe `~/.ssh/ovh_muso` first (CI's key,
# also present on most operator machines that have ever deployed) and
# fall back to `~/.ssh/nick_ovh` (laptop-only). Override with:
#     export SSH_KEY=~/.ssh/your-key
#
# NODE8_IP: NOT auto-detected. The vrack IP (10.0.0.8) is the default
# because that's what CI uses, and probing both addresses at every
# deploy would add 5-10s of latency. Laptop users add this to their
# shell rc:
#     export NODE8_IP=40.160.32.80
#
# Why no shared defaults file? Because there's no central place to put
# it that's both checked into git AND machine-specific. Env vars are
# the lowest-friction config surface that handles "different defaults
# for different humans". sync-from-server.sh mirrors this exact logic.
# ──────────────────────────────────────────────────────────────────
if [[ -z "${SSH_KEY:-}" ]]; then
  for candidate in "$HOME/.ssh/ovh_muso" "$HOME/.ssh/nick_ovh"; do
    if [[ -f "$candidate" ]]; then
      SSH_KEY="$candidate"
      break
    fi
  done
fi
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"  # final fallback if no candidate exists

NODE8_IP="${NODE8_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
NAMESPACE="${NAMESPACE:-hydra}"
# SLACK_WEBHOOK: prefer the env var the GH Actions workflow exports
# (deploy.yml line 9 maps secrets.HYDRA_SLACK_WEBHOOK → SLACK_WEBHOOK).
# Fall back to HYDRA_SLACK_WEBHOOK for laptop operators who set the
# repo-specific name in their shell rc. Without this fallback, every
# deploy.sh notify_slack call from CI silently dropped because deploy.sh
# was reading the wrong env var name (caught in PR #68 review).
SLACK_WEBHOOK="${SLACK_WEBHOOK:-${HYDRA_SLACK_WEBHOOK:-}}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# SSH options used by every ssh/rsync invocation in this script.
# - StrictHostKeyChecking=no: server is in our control, key churn is normal
# - ConnectTimeout=10:        fail fast instead of hanging on a slow host
# - BatchMode=yes:            never prompt for password — fail loudly if key auth doesn't work
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
SSH_OPTS_STR="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# Use C locale for sort/comm consistency. Drift detection compares two
# sorted file lists with `comm`, which silently mis-classifies if the
# producer's locale collation differs from the consumer's.
export LC_ALL=C

# Parse --target flag
TARGET="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ -z "${2:-}" ]] && { echo "Error: --target requires a value (main|edge|all)"; exit 1; }
      TARGET="$2"; shift 2 ;;
    main|edge|all) TARGET="$1"; shift ;;
    *) echo "Usage: deploy.sh [--target main|edge|all]"; exit 1 ;;
  esac
done

# Validate target value (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|all"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; notify_slack ":x: HYDRA deploy FAILED ($TARGET): $*"; exit 1; }
needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }

notify_slack() {
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

# -------------------------------------------------------------------
# Plugin helpers (extracted to scripts/lib/plugin-env.sh in 2026-05-12
# so .github/workflows/pr-validate.yml can shift-left the same env-var
# check Step 4d runs. Single source of truth; both call sites stay
# behaviorally identical.
# -------------------------------------------------------------------
# shellcheck source=lib/plugin-env.sh
. "${SCRIPT_DIR}/lib/plugin-env.sh"

# install_openclaw — pins the global openclaw CLI to OPENCLAW_VERSION.
# Idempotent: skips the npm install when the live binary already reports
# the target version.
#
# Runs on whichever host this script is executing on. Like Steps 4c/4d
# below, it assumes deploy.sh is being run on node-8 (CD path) or that
# the caller is otherwise on the host where the gateway lives. SSH from
# a laptop deploys are out of scope; the deploy header at the top of
# this file already documents that constraint.
#
# History: openclaw < 2026.5.5 needed a follow-on patch (scripts/patch-
# openclaw-opus-4-7-thinking.sh) to add opus-4-7 to the adaptive-thinking
# allowlist — without it, every first-turn request to Opus 4.7 returned
# 400 "thinking.type.enabled is not supported … use thinking.type.adaptive".
# 2026.5.5 ships opus-4-7 natively in the allowlist (verified in
# dist/extensions/anthropic-vertex/stream-runtime.js + pi-ai's anthropic.js)
# and also restructured the bundled adapter into a facade pattern that
# broke the patch's anchor strings. The patch was retired together with
# this version pin; if we ever roll back to < 2026.5.5 we'll need to
# resurrect it from git history.
#
# Returns non-zero on npm-install failure. The single caller (Step 4c.5)
# treats that as fatal — npm's default leaves the previous global binary
# in place on a failed install, so aborting the deploy avoids continuing
# on a half-updated runtime.
install_external_plugin() {
  # Pins ONE externalized @openclaw/* plugin per-profile under
  # ~/.openclaw-<profile>/npm/. Args: <pkg> <version> (e.g.
  # "@openclaw/slack" "2026.5.27"). Idempotent: skips when the live
  # package.json already reports the target version.
  #
  # --force is REQUIRED for the upgrade path: `openclaw plugins install`
  # refuses to overwrite an already-installed plugin ("plugin already
  # exists ... delete it first"), so the FIRST real version bump (e.g.
  # 5.19 -> 5.27) aborts without it — every prior deploy only passed
  # because the installed version already equalled the target and this
  # function skipped. --force overwrites in place and is a harmless
  # no-op on a fresh install. It only overwrites an existing plugin; it
  # does NOT bypass the dangerous-code guard (that is the separate
  # --dangerously-force-unsafe-install flag). --pin records the tracked
  # spec as the exact resolved version so a stray `plugins update --all`
  # can never float it off the pinned build.
  local pkg="$1" version="$2"
  local profile pkg_json installed
  for profile in main edge; do
    if ! needs_target "$profile"; then continue; fi
    pkg_json="/root/.openclaw-${profile}/npm/node_modules/${pkg}/package.json"
    if [[ -f "$pkg_json" ]]; then
      installed=$(jq -r '.version // empty' "$pkg_json" 2>/dev/null || echo "")
    else
      installed=""
    fi
    if [[ "$installed" == "$version" ]]; then
      log "    ${pkg} already $version on $profile — skipping"
      continue
    fi
    log "    Installing ${pkg}@$version on $profile (was: ${installed:-not installed})"
    local install_out install_rc=0
    install_out=$(openclaw --profile "$profile" plugins install "${pkg}@${version}" --force --pin 2>&1) || install_rc=$?
    if (( install_rc != 0 )); then
      log "    ✗ openclaw plugins install ${pkg}@${version} ($profile) failed (rc=$install_rc):"
      echo "$install_out" | sed 's/^/        /'
      return 1
    fi
    # Trust the manifest, not the exit code: a 0 rc that left the old
    # version on disk would silently ship a mismatched plugin.
    # Re-read package.json and fail loud if the pin did not take.
    installed=$(jq -r '.version // empty' "$pkg_json" 2>/dev/null || echo "")
    if [[ "$installed" != "$version" ]]; then
      log "    ✗ ${pkg} on $profile is '${installed:-missing}' after install, expected '$version'"
      return 1
    fi
  done
  return 0
}

install_openclaw() {
  local installed
  installed=$(openclaw --version 2>/dev/null | awk 'NR==1 {print $2}' || true)
  if [[ -z "$installed" ]]; then
    log "    install_openclaw: openclaw CLI not found in PATH; running fresh install of $OPENCLAW_VERSION"
  elif [[ "$installed" == "$OPENCLAW_VERSION" ]]; then
    log "    openclaw already at $OPENCLAW_VERSION — skipping global install"
    return 0
  else
    log "    Upgrading openclaw $installed → $OPENCLAW_VERSION"
  fi

  local npm_out
  local npm_rc=0
  npm_out=$(npm install -g "openclaw@${OPENCLAW_VERSION}" 2>&1) || npm_rc=$?
  if (( npm_rc != 0 )); then
    log "    ✗ npm install -g openclaw@${OPENCLAW_VERSION} failed (rc=$npm_rc):"
    echo "$npm_out" | sed 's/^/        /'
    return 1
  fi
  return 0
}

# install_plugin — installs a single plugin into its target profile's
# openclaw extension directory. Single-arg: derives the profile
# internally via plugin_profile. Idempotent: re-running reinstalls.
#
# Fails with a structured error on dependency-install failure. The caller
# (Step 4d main loop) decides whether to fail-fast or collect failures
# based on HYDRA_CONTINUE_ON_PLUGIN_FAIL.
install_plugin() {
  local plugin_dir="$1"
  local plugin_name
  plugin_name=$(basename "$plugin_dir")
  # plugin_profile may emit multiple profiles (space-separated) for
  # plugins that are referenced by more than one profile's openclaw-*.json
  # (e.g. intercom is used by both main and edge).
  local profiles
  profiles=$(plugin_profile "$plugin_name")

  # Skip only if NO targeted profile needs this plugin. For a multi-profile
  # plugin deployed with --target=main, we still want to install to main
  # and silently skip edge.
  local profile any_needed=0
  for profile in $profiles; do
    if needs_target "$profile"; then any_needed=1; break; fi
  done
  if (( any_needed == 0 )); then
    log "    Skipping plugin $plugin_name (target=$TARGET, profiles=$profiles)"
    return 0
  fi

  log "    Installing plugin $plugin_name (profiles=$profiles)..."

  # Install deps with pnpm + the committed lockfile — the SAME path CI uses
  # (.github/workflows/pr-validate.yml: `pnpm install --frozen-lockfile`). Do
  # NOT use bare `npm install` here: it ignores pnpm-lock.yaml and free-resolves
  # version ranges, so "CI green" stopped implying "deploy installs cleanly".
  # On 2026-06-01 that gap aborted Deploy HYDRA #217: bare npm install resolved
  # vitest@^3.2.0 → 3.2.5, which pins the transitive vite-node@3.2.5 EXACTLY —
  # a version vitest published without publishing vite-node@3.2.5 (registry tops
  # out at 3.2.4) → ETARGET → whole deploy rolled back. --frozen-lockfile pins to
  # the exact versions CI validated. node_modules is rsync-excluded below, so
  # this is build-time only; the runtime resolves openclaw/* from the global
  # install regardless of which package manager laid down node_modules here.
  # Check the directory exists first so a missing plugin_dir reports "not found".
  local install_out
  local install_rc=0
  if [[ ! -d "$plugin_dir" ]]; then
    log "    ✗ plugin_dir not found: $plugin_dir"
    return 1
  fi
  if ! command -v pnpm >/dev/null 2>&1; then
    log "    ✗ pnpm required for plugin install (mirrors CI's --frozen-lockfile path) but not on PATH"
    return 1
  fi
  if [[ ! -f "$plugin_dir/pnpm-lock.yaml" ]]; then
    log "    ✗ $plugin_name has no pnpm-lock.yaml — every in-tree plugin must ship one (CI enforces it). Refusing un-pinned npm fallback."
    return 1
  fi
  install_out=$(cd "$plugin_dir" && pnpm install --frozen-lockfile 2>&1) || install_rc=$?
  if (( install_rc != 0 )); then
    log "    ✗ pnpm install --frozen-lockfile failed for $plugin_name (rc=$install_rc):"
    echo "$install_out" | sed 's/^/        /'
    log "      (if the lockfile drifted — e.g. after an OpenClaw version bump — regenerate it: cd $plugin_dir && pnpm install --lockfile-only, then commit pnpm-lock.yaml)"
    return 1
  fi

  # Build the plugin if it declares a build script. Required for every
  # installed plugin since openclaw 2026.5.19: the runtime now rejects
  # ./src/*.ts entries without compiled dist/index.js, with no kind=channel
  # exception (the legacy fallback that let intercom load src-only is gone).
  # See PR #303 for the incident that surfaced this — same gate is also
  # enforced at PR time by .github/workflows/pr-validate.yml plugin-tests.
  if ! command -v jq >/dev/null 2>&1; then
    log "    ✗ jq is required to detect plugin build scripts but is not installed"
    return 1
  fi
  local build_script
  build_script=$(jq -r '.scripts.build // empty' "$plugin_dir/package.json")
  if [[ -n "$build_script" ]]; then
    local build_rc=0
    local build_out
    build_out=$(cd "$plugin_dir" && pnpm run build 2>&1) || build_rc=$?
    if (( build_rc != 0 )); then
      log "    ✗ pnpm run build failed for $plugin_name (rc=$build_rc):"
      echo "$build_out" | sed 's/^/        /'
      return 1
    fi
    # Module-load self-check: confirm dist/index.js doesn't throw at import time.
    # This catches syntax errors / missing imports / circular dep issues that
    # tsc would not flag but Node will at require()-time. If this fails we're
    # better off failing the deploy here than after rsync, when the openclaw
    # gateway will crash-loop instead.
    if [[ -f "$plugin_dir/dist/index.js" ]]; then
      local load_rc=0
      local load_out
      load_out=$(cd "$plugin_dir" && node --input-type=module -e "import('./dist/index.js').then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); })" 2>&1) || load_rc=$?
      if (( load_rc != 0 )); then
        log "    ✗ dist/index.js failed to load for $plugin_name (rc=$load_rc):"
        echo "$load_out" | sed 's/^/        /'
        return 1
      fi
    fi
  fi

  # Pre-rsync: verify the target profile(s) have access to every env var
  # referenced by this plugin's config. The openclaw runtime will warn on
  # missing config keys but tools will fail silently at call time. Better
  # to fail the deploy here than chase 401s on a "successful" deploy.
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for profile in $profiles; do
    if ! needs_target "$profile"; then continue; fi
    if ! verify_plugin_env_for_profile "$plugin_name" "$profile" "$repo_root"; then
      return 1
    fi
  done

  # Determine the target extension paths per profile.
  #
  # Historically install_plugin only wrote to the legacy unified path
  # (/root/.openclaw/extensions/). That path pre-dates the multi-profile
  # migration (PR #43) and the running gateway services now read from
  # PROFILE-specific dirs:
  #
  #   openclaw-gateway-main.service  → /root/.openclaw-main/extensions/
  #   openclaw-gateway-edge.service  → /root/.openclaw-edge/extensions/
  #
  # The -main gateway does fall back to scanning the legacy path for auto-
  # discovered plugins, which masked the bug for a long time. The zombie
  # `openclaw-gateway.service` (stopped 2026-04-21, memory
  # reference_legacy_openclaw_service_zombie.md) was also loading from the
  # legacy path, so plugin changes reached production through that service.
  # When the zombie died, the -main gateway became sole authority and any
  # plugin NOT pinned in openclaw-main.json `plugins.installs` started
  # loading a stale copy from the profile dir (the muso-credit-verification-
  # enforcer slipped its Tier 1 block hook as a consequence — issue #152).
  #
  # Fix: dual-write to BOTH the profile-specific path (the authoritative
  # location the gateway loads from) AND the legacy path (preserves the
  # existing installPath pinning in openclaw-main.json for intercom).
  # Once all `installs` entries are moved to profile-specific paths, the
  # legacy write can go.
  local ext_paths=()
  for profile in $profiles; do
    if ! needs_target "$profile"; then continue; fi
    case "$profile" in
      main|edge)
        ext_paths+=( "/root/.openclaw-${profile}/extensions/$plugin_name" )
        ;;
      *)
        log "    ✗ unknown profile '$profile' for plugin $plugin_name"
        return 1
        ;;
    esac
  done
  # Belt-and-braces: mirror to the legacy path /root/.openclaw/extensions/<name>
  # ONLY when main is in the profile list. Rationale:
  #
  # 1. Only openclaw-main.json has `plugins.installs` entries pinned at the
  #    legacy path today (intercom — main-scoped).
  #    openclaw-edge.json does not pin anything at the legacy path, so
  #    mirroring from that profile is dead weight.
  #
  # 2. Without this gate, `deploy.sh --target edge` would overwrite
  #    /root/.openclaw/extensions/<plugin> with the EDGE build. Today every
  #    profile ships identical plugin code, so it is a no-op — but if edge
  #    ever diverges (feature flags, alternate entrypoints, vendored deps),
  #    a last-writer-wins race silently breaks main's pinned plugins.
  #
  # Once all main pins are migrated to profile-specific paths, the legacy
  # mirror can be removed entirely. See PR #154 for the path-drift context.
  if [[ " $profiles " == *" main "* ]] && needs_target "main"; then
    ext_paths+=( "/root/.openclaw/extensions/$plugin_name" )
  fi

  # Copy (first install) or rsync incrementally (update) to each target.
  #
  # Note: the rsync update path consumes "${RSYNC_EXCLUDES[@]}" — a
  # global array defined further down this file. This is required by
  # .githooks/pre-commit Check 2, which enforces that EVERY rsync call
  # in deploy.sh references the shared array (so a future "I'll just
  # call rsync directly" can't accidentally bypass the workspace
  # excludes). For a plugin-dir source, none of the workspace/audit
  # patterns in RSYNC_EXCLUDES would match anything, so they're no-ops
  # here. The coupling is intentional and is the trade-off accepted for
  # the pre-commit invariant. If RSYNC_EXCLUDES ever gains a pattern
  # that matches inside a plugin tree (e.g. "node_modules" without a
  # path prefix), this rsync's behavior could change silently — keep
  # that constraint in mind when extending the array.
  local ext_path
  for ext_path in "${ext_paths[@]}"; do
    if [[ ! -d "$ext_path" ]]; then
      mkdir -p "$(dirname "$ext_path")" || { log "    ✗ mkdir failed for $ext_path"; return 1; }
      cp -r "$plugin_dir" "$ext_path" || { log "    ✗ cp failed for $plugin_name → $ext_path"; return 1; }
    else
      rsync -az --exclude=node_modules "${RSYNC_EXCLUDES[@]}" "$plugin_dir/" "$ext_path/" \
        || { log "    ✗ rsync update failed for $plugin_name → $ext_path"; return 1; }
    fi
    log "    ✓ $plugin_name installed to $ext_path"
  done

  return 0
}

# wait_for_agents_bound — polls `openclaw agents list --bindings` until
# the BOUND count matches the expected count for the given profile,
# or the timeout elapses. Called between Step 6 (gateway restart)
# and Step 7 (smoke test) to close the warm-up race.
#
# Expected count is derived from the config file, NOT hardcoded —
# this prevents the magic-number failure class where adding or
# disabling an agent silently breaks the smoke test.
#
# Returns 0 on success, 1 on timeout. Does not fail() — the caller
# decides what to do with a timeout (currently: log a warning and
# continue; the smoke test will report the actual count and fail
# explicitly if still wrong).
wait_for_agents_bound() {
  local profile="$1"
  local timeout_sec="${2:-30}"

  # Derive expected enabled-agent count from the config.
  # profile and DEPLOY_PATH are passed as argv — not shell-interpolated
  # into the Python source — to avoid any code-injection risk from
  # unsanitised values.
  local expected
  expected=$(python3 - "$profile" "$DEPLOY_PATH" <<'PYEOF'
import json, sys
profile = sys.argv[1]
deploy_path = sys.argv[2]
try:
    with open(f'{deploy_path}/openclaw-{profile}.json') as f:
        c = json.load(f)
    agents = c.get('agents', {}).get('list', [])
    enabled = [a for a in agents if a.get('enabled', True)]
    print(len(enabled))
except Exception:
    print(0)
    sys.exit(1)
PYEOF
  ) || {
    log "    wait_for_agents_bound: could not read ${DEPLOY_PATH}/openclaw-${profile}.json — skipping poll"
    return 1
  }

  if (( expected == 0 )); then
    log "    wait_for_agents_bound: 0 enabled agents in $profile — nothing to wait for"
    return 0
  fi

  log "    Waiting for $expected agents to bind on profile=$profile (timeout ${timeout_sec}s)..."

  local elapsed=0
  local bound=0
  while (( elapsed < timeout_sec )); do
    # Count agent entries in the CLI output. openclaw lists each bound
    # agent as a line starting with "- <name>" — this is the stable
    # structural signal, not the word BOUND (which appears nowhere in
    # recent CLI versions; verified 2026-04-08 on live main gateway).
    bound=$(openclaw --profile "$profile" agents list --bindings 2>/dev/null | grep -c '^- ' || true)
    if (( bound == expected )); then
      log "    ✓ All $bound/$expected agents bound on $profile after ${elapsed}s"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log "    ⚠ wait_for_agents_bound timeout on $profile: $bound/$expected bound after ${timeout_sec}s — continuing anyway"
  return 1
}

log "Deploy target: $TARGET"

# -------------------------------------------------------------------
# Mutual exclusion: only one deploy at a time per source tree.
# -------------------------------------------------------------------
# Two concurrent deploys would race the .deployed-sha baseline (last
# writer wins) and could each pass Step 0 against the same baseline,
# missing the other's changes. Portable mkdir-based locking — mkdir is
# atomic on every POSIX FS, and unlike flock it works on macOS without
# extra packages.
#
# SCOPE: this lock is per-host. Two operators deploying from two
# different machines each acquire their own local lock. The actual
# cross-host serialization happens server-side via the .deployed-sha
# baseline + Step 0 drift check — one of the two will fail drift and
# refuse. The mkdir lock just prevents one operator's machine from
# racing itself.
#
# Stale-lock recovery: a SIGKILL'd or crashed deploy leaves $LOCK_DIR
# behind. The next run inspects $LOCK_DIR/pid: if the recorded PID is
# dead, we clear and retake. The pid file is written AFTER mkdir (one
# bash line later), so a SIGKILL in that microsecond window leaves an
# empty $LOCK_DIR with no pid file — that case is handled below as
# "PID: unknown" and reported clearly so the operator knows to clean up.
LOCK_DIR="${TMPDIR:-/tmp}/hydra-deploy.lock.d"
mkdir_err=$(mkdir "$LOCK_DIR" 2>&1)
mkdir_rc=$?
if (( mkdir_rc != 0 )); then
  # Distinguish "lock dir already exists" (EEXIST → check for stale)
  # from other failures (permission denied, ENOSPC, EROFS, etc.).
  # Without this distinction, all of those fall into the "another
  # deploy running" branch with a misleading error.
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail "could not create deploy lock dir at $LOCK_DIR: $mkdir_err"
  fi
  # Lock dir exists. Try stale-PID recovery.
  if [[ -f "$LOCK_DIR/pid" ]]; then
    holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    # Validate the pid is a positive integer before passing to kill -0,
    # so a corrupted/empty pid file doesn't get misinterpreted.
    if [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
      fail "another deploy is already running (lock: $LOCK_DIR, holder PID: $holder_pid)"
    fi
    log "  stale deploy lock found (holder PID '$holder_pid' is dead or invalid) — clearing"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || fail "failed to re-acquire deploy lock after clearing stale: $LOCK_DIR"
  else
    # Lock dir exists but pid file does not. Either another deploy is
    # mid-acquisition (microsecond race window between mkdir and
    # echo $$ > pid) or a previous deploy was SIGKILL'd in that window.
    # Refuse rather than guess — manual `rm -rf $LOCK_DIR` is the fix.
    fail "deploy lock at $LOCK_DIR exists but has no pid file (another deploy mid-acquisition, or a prior deploy was killed before writing pid). If you're sure no deploy is running, remove it manually: rm -rf $LOCK_DIR"
  fi
fi
echo $$ > "$LOCK_DIR/pid"
# Arm the cleanup trap ONLY after we successfully claim the lock.
# If we'd armed it earlier and then fail()'d during the EEXIST check,
# the trap would wipe the OTHER deploy's lock dir on our exit.
trap 'rm -rf "$LOCK_DIR"' EXIT

# -------------------------------------------------------------------
# Ensure git hooks are activated for this checkout.
# -------------------------------------------------------------------
# setup-hooks.sh is idempotent: it just sets core.hooksPath and chmods.
# Running it from deploy.sh guarantees that anyone who deploys from a
# fresh clone gets the pre-commit guard active without a manual step.
#
# We don't `fail` on hook setup failure (idempotent activation
# shouldn't block a deploy) — but we DO surface a visible warning
# instead of swallowing the error with `|| true`. The whole point of
# setting hooks up here is "guarantee they're active"; silently
# failing would break that guarantee while pretending it succeeded.
if [[ -x "$SCRIPT_DIR/setup-hooks.sh" ]] && [[ -d "$HYDRA_ROOT/.git" ]]; then
  if ! hook_setup_out=$("$SCRIPT_DIR/setup-hooks.sh" 2>&1); then
    log "  WARNING: setup-hooks.sh failed — pre-commit guard may not be active."
    log "  Run manually to investigate: scripts/setup-hooks.sh"
    echo "$hook_setup_out" | sed 's/^/    /'
  fi
fi

# -------------------------------------------------------------------
# RSYNC_EXCLUDES — shared by every rsync invocation in this script:
#   - Step 0 drift check (dry-run, local + remote variants)
#   - Step 4a pre-flight (dry-run, local + remote variants)
#   - Step 4b push (real sync, local + remote variants)
#   - Step 4c skills sync (single local rsync)
#   - install_plugin() rsync update path (called from Step 4d)
# The pre-commit hook Check 2 enforces that every rsync call references
# this array, so adding a new rsync without it will fail at commit time.
#
# RUNTIME MUTATION: preflight_drift_check() (Step 4a) APPENDS auto-
# detected `workspaces/<ws>/<subdir>/` patterns to this array for any
# subdir that rsync --delete would remove AND git has never tracked.
# See scripts/lib/classify-deletions.sh. Entries in the static list
# below act as a fast path for known cases and survive as documentation
# of the historical whack-a-mole; new agent-runtime dirs do not need to
# be added here manually.
# -------------------------------------------------------------------
# Each path here is server-owned state that --delete would otherwise
# silently wipe on every deploy. Confirmed by running pre-flight against
# the live server (2026-04-07).
RSYNC_EXCLUDES=(
  # Repo hygiene
  --exclude='.git'
  --exclude='hydra docs/'
  --exclude='tests/'
  --exclude='secrets/'
  # Drift baseline file (server-managed, not part of the repo)
  --exclude='.deployed-sha'
  # Decommissioned CLIProxyAPI sidecar (PR #224). Files no longer in the
  # repo but may still exist on /opt/hydra/ until ops cleanup. Excluded
  # so rsync --delete doesn't trip the deploy pre-flight gate; safe to
  # remove from node-8 manually anytime.
  --exclude='cliproxyapi.conf'
  --exclude='cliproxyapi.yaml'
  # Workspace runtime data (real, accumulating data)
  --exclude='workspaces/*/memory/'
  --exclude='workspaces/*/api-logs/'
  # Agent long-term memory (written by agents at runtime, should survive
  # deploys — see docs/WORKSPACE-FILE-OWNERSHIP.md). MEMORY.md IS tracked
  # in git as a seed, but agents modify it post-deploy and we must not
  # overwrite those modifications with the seed on subsequent deploys.
  --exclude='workspaces/*/MEMORY.md'
  # Agent-created backups directory — never in repo, never overwritten.
  --exclude='workspaces/*/backups/'
  # Generated reports (CSVs, PDFs, JSON dumps from agent runs).
  # Convention: agents that produce reports for human consumption
  # write them to workspaces/<agent>/reports/<filename>. They're
  # server-owned (often contain customer PII like emails or invoice
  # data) and must never propagate into git. Established 2026-04-07
  # after the finance agent's q1_2026_sales_tax_report.csv triggered
  # a pre-flight block during deploy testing.
  --exclude='workspaces/*/reports/'
  # Agent-created queue/inbox directories (support agent's urgent-escalations
  # and pending-tickets). Server-owned, populated at runtime, not seeded
  # from repo. Tripped the deploy pre-flight on 2026-04-14 (PR #95).
  --exclude='workspaces/*/urgent-escalations/'
  --exclude='workspaces/*/pending-tickets/'
  # Per-skill runtime state (e.g. cmo-eod's send-ledger.jsonl and
  # cron-runs.jsonl, written every time the cron fires). Server-owned,
  # never seeded from repo. Tripped pre-flight on 2026-04-24.
  --exclude='workspaces/*/skills/*/state/'
  # Per-agent write-activity.log — runtime audit journal of GitHub
  # merges and other agent-observed events (currently coordinator only,
  # but pattern is forward-compatible). Server-owned, never seeded.
  # Tripped pre-flight on 2026-04-29 right after PR #224's merge deploy.
  --exclude='workspaces/*/write-activity.log'
  # Python bytecode cache. Created at runtime when any python3 process
  # imports from /opt/hydra/scripts/lib/. Server-owned, rebuilt on each
  # import, never in the repo. Tripped the deploy pre-flight on
  # 2026-04-14 (PR #102) after running worker sanity checks on node-8.
  --exclude='__pycache__/'
  --exclude='*.pyc'
  # Hot-patch timestamped backups (convention: <orig>.bak.YYYYMMDDTHHMMSSZ
  # OR <orig>.bak-YYYYMMDDTHHMMSSZ-<tag>). Created on the live server when
  # an operator hot-patches a script or SKILL.md and copies the original
  # aside before editing — see feedback_hot_patch_pattern memory note.
  # The .bak files are operator safety nets, not durable repo content.
  # Server-owned, never seeded from repo, would trip pre-flight if not
  # excluded. Both dot and hyphen separators are conventional in-tree.
  --exclude='*.bak.*'
  --exclude='*.bak-*'
  # Agent-generated audio binaries (cmo-onboarding-guide currently emits
  # ~14MB of .mp3 narration via upload_onboarding.py). Server-owned —
  # the *.py generator IS in the repo, the rendered output is not, same
  # pattern as a build artifact. Tripped pre-flight on 2026-04-28 when
  # the rendered MP3s landed under workspaces/cmo/skills/cmo-onboarding-guide/audio/.
  --exclude='*.mp3'
  # Cloudflare Workers build cache. Created when `wrangler` runs inside a
  # workspace (currently operations/ — tripped pre-flight on 2026-04-17
  # as `workspaces/operations/.wrangler/cache/wrangler-account.json`).
  # Build-tool cache, regenerated on each wrangler invocation, never seeded
  # from the repo. Same category as __pycache__.
  --exclude='workspaces/*/.wrangler/'
  # Workspace runtime state (regenerated by openclaw at boot, but the
  # data on disk is more current than the repo seeds, so we leave it.)
  --exclude='workspaces/*/.openclaw/'
  --exclude='workspaces/*/IDENTITY.md'
  --exclude='workspaces/*/HEARTBEAT.md'
  # TOOLS.md follows the same seed-but-runtime-owned pattern as
  # MEMORY.md/IDENTITY.md/HEARTBEAT.md. The repo carries an initial
  # seed but agents append/edit at runtime (e.g. when an operator
  # adds a new MCP-tool entry to a workspace's TOOLS.md from inside
  # Slack). Tripped pre-flight 2026-04-26 against workspaces/cmo/
  # and workspaces/finance/. Server-owned post-deploy.
  --exclude='workspaces/*/TOOLS.md'
  # Auto-generated TOOLS.md.bak-<ts> files. deploy.sh creates these
  # right before overwriting TOOLS.md (legacy code path), so they
  # accumulate on the server. They are recoverable from the live
  # TOOLS.md, never need to enter version control. Pattern matches
  # any timestamp-suffixed backup. Tripped pre-flight 2026-04-26.
  --exclude='workspaces/*/TOOLS.md.bak-*'
  --exclude='workspaces/*/*.md.bak-*'
  # Agent-generated images (jpeg/png/webp) — e.g. CMO marketing
  # mock-ups, Design wireframes. These are output artifacts, not
  # source-controlled. Already excluded *.png in pre-commit but the
  # full set of image extensions wasn't covered. Tripped pre-flight
  # 2026-04-26 against workspaces/cmo/producer-studio-flux2.jpeg.
  --exclude='workspaces/*/*.jpeg'
  --exclude='workspaces/*/*.jpg'
  --exclude='workspaces/*/*.webp'
  --exclude='workspaces/*/*.gif'
  # `gog` — Google search/scrape skill installed at runtime via the
  # openclaw plugin loader; node-8 owns the SKILL.md content per
  # workspace. Operator-installed, not source-controlled. Tripped
  # pre-flight 2026-04-26 against workspaces/{ceo,cmo,finance}/skills/gog/.
  --exclude='workspaces/*/skills/gog/'
  # Agent-curated knowledge bases — large markdown collections that
  # agents build incrementally (e.g. CMO outreach team building up
  # muso-ads-knowledge-base.md from research). Server-owned because
  # editing them via PR adds friction the agents shouldn't have.
  # Convention: any file matching *-knowledge-base.md under a skill
  # references/ dir. Tripped 2026-04-26.
  --exclude='workspaces/*/skills/*/references/*-knowledge-base.md'
  # Audit logs (per-workspace memory snapshots, conversation logs)
  --exclude='audit/'
  # Manual audit backup (pre-existing on node-8 at /opt/hydra/audit-local-backup/,
  # 8.6MB of 2026-04-07 memory snapshots created during the audit/ migration).
  # Treated like audit/ — server-owned, not synced from repo.
  --exclude='audit-local-backup/'
  # Dead CD shadow mirror at /opt/hydra/config/ (~16MB). The GitHub
  # Actions deploy workflow USED TO write here via a "Sync config to
  # Node 8" step that mirrored the entire repo, then seeded individual
  # workspaces from there. That step was deleted in the 2026-04-08 CD
  # consolidation (this PR). The directory still exists on the server
  # until the manual `rm -rf /opt/hydra/config/` cleanup is done — the
  # smoke-test warn_check fires a reminder on every deploy until then.
  # This exclude prevents deploy.sh from wiping the residual content
  # (which historically included real Sentinel skills like clawsec,
  # audit-scanner, quarantine, trust-scorer that existed NOWHERE else)
  # before the cleanup happens.
  --exclude='config/'
  # Plugin install artifacts (server runs pnpm install --frozen-lockfile in-place)
  --exclude='plugins/*/node_modules/'
  --exclude='plugins/*/package-lock.json'
  # Plugin build outputs. gitignored (`plugins/*/dist/`) so the repo never
  # carries them; the deploy build step regenerates dist/ on the server
  # post-rsync. Excluded so rsync --delete doesn't blow away the freshly-
  # built artifacts every preflight pass — same logic as node_modules/.
  # Tripped pre-flight 2026-05-11 after PR #270 (support-tools/Caroline)
  # deployed and left plugins/support-tools/dist/ on /opt/hydra/.
  --exclude='plugins/*/dist/'
  # CTO scratch / draft HTML authored directly on node-8 (workspaces/cto/),
  # not tracked in repo and not intended to be. Excluded so rsync --delete
  # doesn't wipe Aaron's working copy. Tripped pre-flight 2026-05-08 on
  # PR #263. If a future cto/ HTML drops in via the same path it can be
  # added alongside this entry.
  --exclude='workspaces/cto/project_renaissance_v20.html'
  # CMO agent scratchpad. The canonical parent-companies doc lives under
  # workspaces/cmo/skills/muso-outreach-engine/references/parent-companies.md
  # (referenced by every outreach skill), but the cmo agent sometimes
  # writes a parallel copy at the workspace root — partially redundant,
  # partially confabulated (e.g. it placed audio-technica.com under
  # HARMAN, which is wrong; Audio-Technica is independent). Excluded so
  # the agent's scratchpad doesn't block the deploy pre-flight gate.
  # Tripped pre-flight 2026-05-25 right after PR #314 merge.
  # TODO(follow-up): teach the cmo agent to only edit the canonical
  # engine-reference path, then remove this exclude and clean the
  # orphan file off node-8.
  --exclude='workspaces/cmo/parent-companies.md'
  # Server-only operational tooling. Aaron wrote scripts/hydra-heal.sh
  # directly on node-8 during a 2026-04-07 incident as a manual
  # health-check + self-healing script (gateway restart, secrets
  # restore from Vault, watchdog repair, etc). It contains a hardcoded
  # Vault token that needs to be rotated before the file can safely
  # enter version control. Until that rotation happens, deploys must
  # NOT wipe the server-local copy.
  # TODO(follow-up): rotate the Vault token, replace the hardcoded
  # value with an env-var lookup, remove this exclude, and commit
  # hydra-heal.sh to the repo like other operational scripts.
  --exclude='scripts/hydra-heal.sh'
  # Runtime auth token caches. `muso-admin-api.sh` (in muso-ops-admin)
  # and `muso-ads-api.sh` (in muso-ads-manager) cache JWTs on disk for
  # ~23h next to the script. These files are server-owned runtime state
  # and contain real tokens — they must never be shipped via the repo.
  # A stale copy of `.admin-token-cache` was accidentally committed in
  # ed558ce ("Sync live Node 8 state"), which caused the drift check to
  # block every deploy on main after the server refreshed the token.
  # Some workspace copies of muso-ops-admin/scripts/ carry a local
  # .gitignore for .admin-token-cache; the root .gitignore and this rsync
  # exclude are the canonical guards for all copies and for .ads-token-cache.
  --exclude='.admin-token-cache'
  --exclude='.ads-token-cache'
  # CMO's ad-hoc CSV outputs (b2b target research iterations, agent
  # research scratchpads). CMO currently writes these to the workspace
  # root; they're ephemeral-ish and may contain PII from b2b
  # prospecting.
  # TODO(follow-up): update workspaces/cmo/SOUL.md to tell CMO to
  # write ephemeral research outputs to workspaces/cmo/reports/
  # instead (already excluded via workspaces/*/reports/). Once CMO
  # follows the new convention, this broader workspace-root exclude
  # can be removed. Tracked in project_skills_architecture_followup.md.
  --exclude='workspaces/*/*.csv'
  # Workspace .env files contain API keys (e.g., FREEPIK_API_KEY in
  # workspaces/cmo/.env). Server-owned secrets, must never enter git.
  --exclude='workspaces/*/.env'
  # Support agent pending-ticket queue. Contains customer PII (emails,
  # profile IDs). Runtime state created by the support agent.
  --exclude='workspaces/*/pending-tickets/'
  # Large media artifacts generated at runtime (test renders, exports).
  # Example: workspaces/cmo/freepik-test-studio.png (5MB).
  --exclude='workspaces/*/*.png'
  # Customer attachment documents (PDFs) the support agent fetches/receives.
  # Customer PII (invoices, IDs, contracts). Runtime-owned, never in repo.
  # Same category as *.png. Tripped pre-flight 2026-05-28 with 4 top-level
  # support PDFs (jacob_davila.pdf + UUID copies).
  --exclude='workspaces/*/*.pdf'
  # Per-conversation inbound attachment store written by the Intercom plugin
  # (workspaces/support/intercom/<conversationId>/<messageId>/). Holds customer
  # images + PDFs + rasterized PDF pages — PII, runtime-owned, never seeded
  # from repo. Lives under the agent workspaceDir so the vision media-path
  # allowlist accepts it; excluded so rsync --delete never wipes it.
  --exclude='workspaces/*/intercom/'
  # Agent-generated media (Freepik renders, hero images, etc.)
  --exclude='workspaces/*/media/'
  --exclude='workspaces/*/generated/'
  # Agent-generated presentation decks (iterative HTML renders, binary
  # .pptx files) and exported long-form reports. Same category as
  # media/ and generated/ — work product the agents iterate on, not
  # canonical repo state. Example: workspaces/cmo/presentations/
  # contained project-midway-v2.html, -v3.html, -v3-final.html,
  # -v2-backup.html, project-renaissance.html, project-renaissance-v20.pptx
  # on 2026-04-20 — tripped pre-flight on PR #126.
  --exclude='workspaces/*/presentations/'
  --exclude='workspaces/*/exports/'
  # Agent research scratchpads (may contain proprietary data)
  --exclude='workspaces/*/research/'
  # Agent-created wiki pages (company knowledge bases, specs, etc.)
  --exclude='workspaces/*/wiki/'
  # Runtime text dumps (e.g., workspaces/operations/pending-credits-*.txt)
  --exclude='workspaces/*/*.txt'
  # Agent ad-hoc scratch python at the workspace top level (NOT skills/scripts,
  # which are tracked). Iterative throwaway investigations — hardcoded test
  # filenames, demo API keys, near-duplicate files. Same category as the
  # scratch *.csv/*.txt above; legit code lives under skills/ or scripts/.
  # Tripped the deletion rail on 2026-05-28 with 6 support-agent OCR/PDF
  # experiments (free_ocr*.py, read_pdf.py, test_ocr.py, ...).
  --exclude='workspaces/*/*.py'
  # Skill daily batch outputs (runtime data generated by CMO outreach engine)
  --exclude='workspaces/*/skills/*/references/daily-batches/'
  # Operator-created skill archives (e.g. cmo/skills/_archive/outreach-deprecated-2026-05-27/,
  # a Fede-authorized snapshot of retired outreach skills kept for "resurrect if needed").
  # Server-owned, never seeded from repo. Inert to the resolver — workspace skill discovery
  # is one-level deep (skills/*/SKILL.md), so depth-2 SKILL.md files under _archive/ are
  # never loaded. Tripped the Step 4a pre-flight on 2026-05-28 (deploy for #361 merge 2af7a65).
  --exclude='workspaces/*/skills/_archive/'
  # Workspace tmp directories (agent scratch space — scripts, CSVs, etc.)
  --exclude='workspaces/*/tmp/'
  # Workspace state directories (send ledgers, cron run logs — runtime data)
  --exclude='workspaces/*/state/'
  # Agent ad-hoc analysis scripts. Same category as tmp/ — iterative
  # throwaway work the agents generate during investigations (e.g.
  # finance wrote 10 Python scripts on 2026-04-13 for a tax jurisdiction
  # dive: enrich-tax-v1/v2/v3.py, find-no-tax-subs-v1/v2/v3.py, etc).
  # Never canonical, never tracked in repo. If a script graduates into
  # something worth keeping, promote it to a proper skill under
  # workspaces/<agent>/skills/<skill-name>/ instead.
  --exclude='workspaces/*/scripts/'
)

# -------------------------------------------------------------------
# Step 0: Drift check (deploy-equivalent of `git pull` before `git push`)
# -------------------------------------------------------------------
# git push refuses when remote has commits the local doesn't. We mirror
# that here using a tiny baseline file on the server: /opt/hydra/.deployed-sha
# (written after every successful deploy, AFTER smoke test passes).
# It records the git SHA the server was last synced from.
#
# Drift logic:
#   intended_changes = files this repo touched since LAST_SHA
#                      (committed + staged + unstaged, in one git diff)
#   would_update     = files rsync says have different content vs server
#   drift            = would_update − intended_changes
#
# If drift is non-empty, the server has files we don't account for —
# someone edited /opt/hydra/ directly. Refuse and tell the user to pull
# with scripts/sync-from-server.sh.
#
# Bypass:
#   HYDRA_FORCE=1            skip both this check AND Step 4a pre-flight
#   HYDRA_SKIP_DRIFT_CHECK=1 skip only Step 0; Step 4a pre-flight still runs
#                            (use when SSH baseline read is genuinely broken)
log "Step 0/9: Drift check (server vs last-deployed SHA)..."
drift_check_against_baseline() {
  if [[ "${HYDRA_FORCE:-0}" == "1" ]]; then
    log "  Skipped (HYDRA_FORCE=1 set)"
    return 0
  fi
  if [[ "${HYDRA_SKIP_DRIFT_CHECK:-0}" == "1" ]]; then
    log "  Skipped (HYDRA_SKIP_DRIFT_CHECK=1 set; Step 4a pre-flight will still run)"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    log "  git not found — skipping drift check"
    return 0
  fi
  if ! git -C "$HYDRA_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "  not a git checkout — skipping drift check"
    return 0
  fi

  # 1. Read baseline SHA from server.
  # Distinguish three cases via a single SSH round-trip:
  #   - file exists & readable    → its content
  #   - file absent (first deploy) → sentinel "__ABSENT__"
  #   - ssh failed                 → ssh non-zero exit → fail closed
  # Single-call form saves a round-trip vs probe-then-cat AND closes
  # a tiny race where the file could be deleted between the two calls.
  local last_sha=""
  if $HYDRA_LOCAL; then
    if [[ -f "$DEPLOY_PATH/.deployed-sha" ]]; then
      last_sha=$(cat "$DEPLOY_PATH/.deployed-sha")
    fi
  else
    local read_rc=0 read_out=""
    read_out=$(ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "if [ -f '$DEPLOY_PATH/.deployed-sha' ]; then cat '$DEPLOY_PATH/.deployed-sha'; else echo __ABSENT__; fi" \
      2>&1) || read_rc=$?
    if (( read_rc != 0 )); then
      log "  ssh failed reading drift baseline (rc=$read_rc):"
      echo "$read_out" | sed 's/^/    /'
      fail "could not reach node-8 to read drift baseline. Fix SSH or set HYDRA_SKIP_DRIFT_CHECK=1 explicitly."
    fi
    if [[ "$read_out" == "__ABSENT__" ]]; then
      last_sha=""
    else
      last_sha="$read_out"
    fi
  fi
  last_sha=$(echo "$last_sha" | tr -d '[:space:]')

  if [[ -z "$last_sha" ]]; then
    log "  No .deployed-sha on server (first deploy with this guard)"
    log "  → drift check skipped, will be enabled after this deploy succeeds"
    return 0
  fi

  # Validate format. A garbled value (rare — would mean someone edited the
  # baseline file by hand) should not silently degrade to "skip check".
  if ! [[ "$last_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "baseline .deployed-sha on server is not a valid 40-char hex SHA: '$last_sha'. Inspect /opt/hydra/.deployed-sha and remove it if corrupted."
  fi

  if ! git -C "$HYDRA_ROOT" cat-file -e "$last_sha^{commit}" 2>/dev/null; then
    log "  Server reports last_sha=$last_sha but it's not in this repo's git history"
    log "  → can't compute drift baseline. Run: git fetch && retry."
    log "  Skipping drift check this run; pre-flight (Step 4a) will still catch deletions."
    return 0
  fi

  log "  Baseline: $last_sha (server's last successful deploy)"

  # 2. Files we intentionally changed since baseline.
  # `git diff --name-only <commit>` (single arg) covers committed +
  # staged + unstaged in one shot. Simpler than the prior two-diff
  # version that unioned `diff $last_sha HEAD` with `diff HEAD` —
  # both compute the same set, but one call is less to read and one
  # less subshell to spawn.
  #
  # NOTE: this also includes files DELETED locally since baseline,
  # which is what we want — a local delete that the deploy will
  # propagate to the server is "intended", not drift.
  local intended
  intended=$(git -C "$HYDRA_ROOT" diff --name-only "$last_sha" | sort -u | sed '/^$/d')

  # 3. Files rsync would push (content differs between repo and server).
  # Capture rsync exit code separately — `|| true` would let an SSH
  # failure look identical to "clean", which is the exact silent-failure
  # this whole step exists to prevent.
  #
  # NOTE: we use -rcn (recursive + checksum + dry-run) NOT -an (archive
  # + dry-run). The -a flag implies -t (sync times), -p (perms), -g, -o,
  # which causes rsync to flag files where ONLY metadata (mtime) differs.
  # In dry-run mode, rsync may skip the full checksum and fall back to
  # mtime+size, producing false positives on files with identical content
  # but different timestamps (e.g., agent-edited skills on node-8).
  # Using -rc gives a pure content-only comparison.
  local dry_out dry_rc=0
  if $HYDRA_LOCAL; then
    dry_out=$(rsync -rcn --itemize-changes \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  else
    dry_out=$(rsync -rczn --itemize-changes \
      -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  fi
  if (( dry_rc != 0 )); then
    log "  rsync dry-run failed (rc=$dry_rc):"
    echo "$dry_out" | sed 's/^/    /'
    fail "drift check rsync failed — refusing to proceed without a clean baseline (override: HYDRA_SKIP_DRIFT_CHECK=1)"
  fi

  # Parse rsync itemize lines. Format is `<flags> <filename>` where flags
  # are 11 chars: YXcstpoguax. We want lines where:
  #   - col 2 (X) = 'f'   → it's a file, not a dir
  #   - col 3 (c) = 'c'   → checksum differs (existing file modified) OR
  #   - col 4 (s) = 's'   → size differs
  #
  # SCOPE NOTE: This catches CONTENT DRIFT on files that exist on both
  # sides. It does NOT catch:
  #   - new files server-only (caught by Step 4a's `*deleting` path
  #     when --delete dry-run sees server-only files)
  #   - new files local-only (those are just "new content to push" —
  #     not drift, not blocked, and including them would false-positive
  #     on every untracked local file: .DS_Store, .worktrees/, etc.)
  #
  # Filename can contain spaces, so strip the first whitespace-delimited
  # token (the flags) and print the rest verbatim.
  local would_update
  would_update=$(echo "$dry_out" \
    | awk '{
        if (substr($0,2,1)=="f" && (substr($0,3,1)=="c" || substr($0,4,1)=="s")) {
          sub(/^[^[:space:]]+[[:space:]]+/, "")
          print
        }
      }' \
    | sort -u | sed '/^$/d')

  # 4. drift = would_update − intended (set difference; both sides sorted under LC_ALL=C)
  local drift
  drift=$(comm -23 <(echo "$would_update") <(echo "$intended"))

  if [[ -z "$drift" ]]; then
    log "  Clean — every file rsync would update is accounted for in local commits/edits"
    return 0
  fi

  cat <<DRIFT_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — server has edits this repo doesn't account for
================================================================================

WHAT THIS MEANS:
  Like \`git push\` refusing when the remote has moved ahead, deploy.sh
  just compared the server (/opt/hydra/, last synced from commit
  $last_sha) against your local repo. The files below differ in
  content, but they are NOT in the diff between the baseline and HEAD —
  meaning you didn't edit them locally. Someone edited them DIRECTLY
  on node-8.

  Pushing now would silently overwrite their work. There is no backup.

DRIFTED FILES (server has edits not in any local commit):
$(echo "$drift" | sed 's/^/  /')

WHAT TO DO (the only safe path, mirrors \`git pull --rebase\`):
  1. Pull the server-side edits into your local repo:
       scripts/sync-from-server.sh skills --apply       # if drift is in skills-all/
       scripts/sync-from-server.sh workspaces --apply   # if drift is in workspaces/
       scripts/sync-from-server.sh audit --apply        # if drift is in audit/
       # or pull a single file directly (uses same defaults as deploy.sh):
       scp -i "\$SSH_KEY" "\$NODE8_USER@\$NODE8_IP:$DEPLOY_PATH/<path>" ./<path>
  2. Review what came down:
       git status
       git diff -- <path>
  3. Commit the pulled changes (this advances your HEAD past the
     server's edits, so the next drift check sees them as accounted for):
       git add -A
       git commit -m "chore: pull <description> from node-8"
  4. Re-run deploy. Step 0 should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  Almost never. This is the equivalent of \`git push --force\` over a
  teammate's commits. Only do it if:
    - You have explicit confirmation from whoever made the edits that
      they want them discarded, AND
    - You have inspected each drifted file and verified it's safe.

  If you can't satisfy both, don't HYDRA_FORCE=1.

  Skip just the drift check but keep pre-flight + post-deploy guards:
    HYDRA_SKIP_DRIFT_CHECK=1 ./scripts/deploy.sh
  (Use only when SSH to node-8 is broken in a way that breaks the
  baseline read, not as a way to ignore drift.)
================================================================================
DRIFT_BRIEFING
  fail "drift detected against baseline $last_sha (override: HYDRA_FORCE=1)"
}
drift_check_against_baseline

# -------------------------------------------------------------------
# Step 1: Validate config files
# -------------------------------------------------------------------
log "Step 1/9: Validating config files..."

if needs_target "main"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-main.json" >/dev/null 2>&1 || fail "openclaw-main.json is not valid JSON"
  log "  openclaw-main.json is valid JSON."
fi
if needs_target "edge"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-edge.json" >/dev/null 2>&1 || fail "openclaw-edge.json is not valid JSON"
  log "  openclaw-edge.json is valid JSON."
fi
# cron-jobs.json is loaded later by Step 5a's POSTSYNC (when targeting
# main). Pre-validate the JSON here so a malformed cron file fails the
# deploy at Step 1 with a clear message instead of inside the heredoc
# with a generic "cron sync failed" error 30 seconds into the deploy.
if needs_target "main" && [ -f "$HYDRA_ROOT/cron-jobs.json" ]; then
  python3 -m json.tool "$HYDRA_ROOT/cron-jobs.json" >/dev/null 2>&1 || fail "cron-jobs.json is not valid JSON"
  log "  cron-jobs.json is valid JSON."
fi

# Reject committed MCP servers that use the `npx mcp-remote` stdio
# bridge — those leak subprocesses that share the gateway's pgid, so
# any reap-by-pgid takes the whole gateway down (Clio outage
# 2026-04-24). Native `transport: "streamable-http"` has zero
# subprocesses and is supported by bundle-mcp + sdk v1.10+. The
# live file is re-linted after the Step 5a merge-preserve, but
# catching it here means a bad commit fails before we touch Node 8.
LINT_OPENCLAW_CFG="$SCRIPT_DIR/lint-openclaw-config.sh"
if [ -x "$LINT_OPENCLAW_CFG" ]; then
  lint_targets=()
  needs_target "main" && lint_targets+=("$HYDRA_ROOT/openclaw-main.json")
  needs_target "edge" && lint_targets+=("$HYDRA_ROOT/openclaw-edge.json")
  if (( ${#lint_targets[@]} > 0 )); then
    "$LINT_OPENCLAW_CFG" "${lint_targets[@]}" || fail "openclaw config lint: repo contains mcp-remote stdio entries"
    log "  openclaw configs free of mcp-remote stdio entries."
  fi
fi

# Run drift check when deploying all or multiple profiles
if [[ "$TARGET" == "all" ]] || [[ "$TARGET" == *","* ]]; then
  "$SCRIPT_DIR/validate-shared-config.sh" || fail "Shared config drift detected"
fi

# -------------------------------------------------------------------
# Step 2: Validate SOUL.md files
# -------------------------------------------------------------------
log "Step 2/9: Validating SOUL.md files..."
validate_souls() {
  local config="$1"
  local label="$2"
  local agents
  agents=$(python3 -c "
import json, os
with open('$config') as f:
    c = json.load(f)
defaults_ws = c.get('agents', {}).get('defaults', {}).get('workspace', '')
for a in c.get('agents', {}).get('list', []):
    ws = a.get('workspace', defaults_ws)
    print(a['id'] + ':' + os.path.basename(ws))
")
  local missing=()
  for entry in $agents; do
    local agent_id="${entry%%:*}"
    local ws_dir="${entry##*:}"
    [[ -z "$ws_dir" ]] && ws_dir="$agent_id"
    if [[ ! -f "$HYDRA_ROOT/workspaces/$ws_dir/SOUL.md" ]]; then
      missing+=("$agent_id")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing SOUL.md for $label agents: ${missing[*]}"
  fi
}

if needs_target "main"; then validate_souls "$HYDRA_ROOT/openclaw-main.json" "main"; fi
if needs_target "edge"; then validate_souls "$HYDRA_ROOT/openclaw-edge.json" "edge"; fi
log "  All SOUL.md files present."

# -------------------------------------------------------------------
# Step 3: Validate tool-deny-lists.yaml
# -------------------------------------------------------------------
log "Step 3/9: Validating tool-deny-lists.yaml (deny lists can only grow)..."
DENY_LIST="$HYDRA_ROOT/policies/tool-deny-lists.yaml"

if [[ ! -f "$DENY_LIST" ]]; then
  fail "policies/tool-deny-lists.yaml not found"
fi

if git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" >/dev/null 2>&1; then
  PREV_TOOLS=$(git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" | grep -E '^\s+- ' | sed 's/^[[:space:]]*- //' | sort -u)
  CURR_TOOLS=$(grep -E '^\s+- ' "$DENY_LIST" | sed 's/^[[:space:]]*- //' | sort -u)
  REMOVED=$(comm -23 <(echo "$PREV_TOOLS") <(echo "$CURR_TOOLS"))
  if [[ -n "$REMOVED" ]]; then
    fail "Deny list SHRUNK. Removed tools: $REMOVED"
  fi
fi
log "  Deny lists validated (only growth detected)."

# -------------------------------------------------------------------
# Step 4: rsync repo to Node 8
# -------------------------------------------------------------------
# RSYNC_EXCLUDES is defined near the top of the file (hoisted because
# Step 0 also uses it for the drift check baseline computation).

# -------------------------------------------------------------------
# Step 4a: Pre-flight drift check
# -------------------------------------------------------------------
# Abort if the server has content in skills-all/ that the repo doesn't —
# that means someone edited skills directly on the server and a deploy
# would silently wipe their work. Also surface any suspicious deletions
# inside workspaces/ or skills-all/.
# Bypass: HYDRA_FORCE=1 ./deploy.sh ...
log "Step 4a/9: Pre-flight drift check..."
preflight_drift_check() {
  # Same -rcn rationale as Step 0: pure content comparison, no metadata
  # false positives. --delete is still needed here to detect server-only
  # files that would be wiped.
  local dry_out dry_rc=0
  if $HYDRA_LOCAL; then
    dry_out=$(rsync -rcn --delete --itemize-changes \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  else
    dry_out=$(rsync -rczn --delete --itemize-changes \
      -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/" 2>&1) || dry_rc=$?
  fi
  if (( dry_rc != 0 )); then
    log "  rsync dry-run failed (rc=$dry_rc):"
    echo "$dry_out" | sed 's/^/    /'
    fail "pre-flight rsync failed — refusing to proceed without a clean dry-run (no override; fix SSH first)"
  fi

  # Skills-all/ drift to block on, decided by scripts/lib/drift-check.sh.
  # When we have node-8-local access AND a last-deployed baseline, this is
  # baseline-aware: the PR's own intended skill edits (REPO-AHEAD) are allowed
  # through and only genuine server edits (SERVER-AHEAD) and true CONFLICTs
  # block. That is the fix for the #366 false-block, where Step 4a's old blunt
  # "any content difference" check killed a deploy whose change Step 0 had
  # already cleared as intended. Without a baseline (first deploy / unreachable
  # / remote deploy) it falls back to the previous blunt content-drift parse,
  # so the gate never silently weakens. The blunt fallback still uses the same
  # itemize columns (YXcstpoguax: col 2 'f', col 3 'c' or col 4 's').
  local last_sha=""
  if $HYDRA_LOCAL && [[ -f "$DEPLOY_PATH/.deployed-sha" ]]; then
    last_sha=$(tr -d '[:space:]' < "$DEPLOY_PATH/.deployed-sha" 2>/dev/null || true)
  fi
  # shellcheck source=lib/drift-check.sh
  source "$SCRIPT_DIR/lib/drift-check.sh"
  local skills_drift block_rc=0
  skills_drift=$(compute_skill_block_lines \
    "$dry_out" "$last_sha" "$HYDRA_ROOT" "$DEPLOY_PATH" "$HYDRA_LOCAL") || block_rc=$?
  if (( block_rc != 0 )); then
    fail "skill drift classifier failed (rc=$block_rc) — refusing to deploy. Fix the checkout (e.g. git fetch), or set HYDRA_FORCE=1 after manual review."
  fi

  # Hot-patch acknowledgement: remove lines from $skills_drift (the
  # in-memory rsync-itemize string, not the announce log) whose
  # server-side sha256 was pre-announced by an operator on node-8
  # within the ack window (default 1h). rsync still overwrites
  # server bytes with repo HEAD bytes in Step 4b — this only
  # suppresses the halt for files the operator explicitly
  # pre-authorised. See scripts/lib/announce-skill-hot-patch.sh
  # for the writer side and the 2026-05-26 deploy-26443889421
  # incident for context.
  # shellcheck source=lib/acknowledge-hot-patch-drift.sh
  source "$SCRIPT_DIR/lib/acknowledge-hot-patch-drift.sh"
  if [[ -n "$skills_drift" ]]; then
    skills_drift=$(acknowledge_announced_hotpatches "$skills_drift")
  fi

  # Deletions that --delete would perform on the server
  local deletions
  deletions=$(echo "$dry_out" | grep '^\*deleting' || true)

  # -----------------------------------------------------------------
  # Auto-exclude NEVER-TRACKED workspace subdirectories
  # -----------------------------------------------------------------
  # Stops the whack-a-mole pattern where every new agent-output dir
  # (workspaces/*/clients/, .../output/, .../reports/, ...) trips a
  # deploy and requires a manual RSYNC_EXCLUDES PR.
  #
  # The classifier is in a shared library so the PR-time CI gate
  # (.github/workflows/pr-validate.yml) applies the same rule. Fail-
  # closed semantics are enforced in the helper: git unavailability or
  # an empty-ever-tracked-but-workspaces-populated mismatch aborts the
  # deploy rather than silently auto-excluding everything.
  # shellcheck source=lib/classify-deletions.sh
  source "$SCRIPT_DIR/lib/classify-deletions.sh"

  if [[ -n "$deletions" ]]; then
    local classified
    local classify_rc=0
    classified=$(classify_workspace_deletions "$deletions" "$HYDRA_ROOT") || classify_rc=$?
    if (( classify_rc != 0 )); then
      fail "auto-exclude classifier refused to run (rc=$classify_rc) — see stderr above. Refusing to deploy blindly."
    fi

    local -a auto_excluded_subdirs=()
    local remaining_deletions=""
    local s
    while IFS= read -r s; do
      case "$s" in
        "AUTO: "*)    auto_excluded_subdirs+=("${s#AUTO: }") ;;
        "REMAIN: "*)  remaining_deletions+="${s#REMAIN: }"$'\n' ;;
      esac
    done <<< "$classified"

    if (( ${#auto_excluded_subdirs[@]} > 0 )); then
      for s in "${auto_excluded_subdirs[@]}"; do
        RSYNC_EXCLUDES+=(--exclude="$s")
      done
      log "  Auto-excluding ${#auto_excluded_subdirs[@]} never-tracked workspace subdirectory/ies (agent runtime state):"
      for s in "${auto_excluded_subdirs[@]}"; do
        log "    + $s"
      done
      # Feed only the remaining suspicious deletions to the briefing.
      deletions="${remaining_deletions%$'\n'}"
    fi
  fi

  if [[ -n "$skills_drift" ]]; then
    cat <<DRIFT_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — skills-all/ drift between node-8 and the repo
================================================================================

WHAT THIS MEANS:
  These skill files differ between /opt/hydra/skills-all/ on node-8 and this
  commit in a way the repo does NOT account for. Lines tagged SERVER-AHEAD were
  edited directly on node-8 (often by Fede or an agent) and are not in the
  repo; lines tagged CONFLICT were edited on BOTH sides. Your own intended
  skill edits (REPO-AHEAD) are allowed through and are NOT listed here. If you
  push past this check, rsync --delete OVERWRITES the server bytes with this
  commit's bytes and there is NO backup — losing server-side work agents rely on.
  (Lines shown as raw rsync flags mean no baseline was available, so this fell
  back to a blunt "any difference" check — treat every line as SERVER-AHEAD.)

DRIFTED FILES:
$(echo "$skills_drift" | sed 's/^/  /')

THE SAFE FIX — capture per file. Do NOT bulk-pull: a full
scripts/sync-from-server.sh skills --apply would clobber your OTHER skill edits
in this branch.
  SERVER-AHEAD — pull just that file and commit it:
       scripts/sync-from-server.sh skills --apply --only <path>
       git add <path> && git commit -m "chore: capture skill edit from node-8"
  CONFLICT — 3-way merge by hand (both sides changed); the baseline is the
  commit in /opt/hydra/.deployed-sha:
       git show "\$(cat /opt/hydra/.deployed-sha)":<path>   # baseline version
       # reconcile that, the node-8 copy, and your branch; commit the result
  Then re-run deploy — pre-flight should report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  - You have explicit confirmation the server-side edits can be discarded, AND
  - You have verified each file above is safe to overwrite, AND
  - You understand this destroys that work permanently.

  If ANY of those is not true, STOP and capture first.
================================================================================
DRIFT_BRIEFING
    if [[ "${HYDRA_FORCE:-0}" != "1" ]]; then
      fail "skills-all drift — refusing to deploy (override: HYDRA_FORCE=1)"
    fi
    log "  HYDRA_FORCE=1 set — proceeding despite drift (will overwrite server)"
  fi

  if [[ -n "$deletions" ]]; then
    local del_count sus_count
    del_count=$(printf '%s\n' "$deletions" | grep -c .)

    # Deletions inside workspaces/ or skills-all/ are likely real data
    # (IDENTITY.md, workspace-state.json, custom skills) — these get a
    # full briefing. Other deletions just get a heads-up.
    local suspicious
    suspicious=$(echo "$deletions" | grep -E 'workspaces/|skills-all/' || true)
    sus_count=$(printf '%s\n' "$suspicious" | grep -c . || true)

    if [[ -n "$suspicious" ]]; then
      local sus_overflow=""
      if (( sus_count > 30 )); then
        sus_overflow="  ... ($((sus_count - 30)) more)"
      fi
      cat <<DEL_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — sync would delete server state
================================================================================

WHAT THIS MEANS:
  rsync --delete is about to remove files from /opt/hydra/ that exist
  on the server but NOT in the repo. The files below sit under
  workspaces/ or skills-all/, which means they're likely either:
    - real accumulated data (dispute trackers, audit logs, scan results)
    - runtime state generated by openclaw on the server
    - skills someone added directly on node-8 without committing

  Wiping any of these silently breaks production. There is no backup.

FILES THAT WOULD BE DELETED ($del_count total, suspicious shown):
$(echo "$suspicious" | head -30 | sed 's/^/  /')
$sus_overflow

THE ONLY SAFE FIX (do this, in order):
  1. For each path above, decide:
     (a) Is it real data? → Pull it into the repo:
           scripts/sync-from-server.sh workspaces --apply   # for workspaces/*
           scripts/sync-from-server.sh skills --apply       # for skills-all/*
           scripts/sync-from-server.sh audit --apply        # for audit/*
         Then commit.
     (b) Is it runtime state we want server-owned? → Add an --exclude
         line to RSYNC_EXCLUDES at the top of scripts/deploy.sh (it's
         hoisted there because Step 0 also reads it) so rsync stops
         trying to manage it. Then re-run pre-commit:
           bash .githooks/pre-commit
         The Check 2 list (required_excludes) in .githooks/pre-commit
         must also be updated so future deploys keep enforcing it.
  2. Re-run deploy. Pre-flight should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  - You've individually verified every file in the list is regenerable
    or genuinely garbage, AND
  - You're certain no human or agent will need it again.

  If you're not sure, STOP. Pull first.
================================================================================
DEL_BRIEFING
      if [[ "${HYDRA_FORCE:-0}" != "1" ]]; then
        fail "refusing to delete server state (override: HYDRA_FORCE=1)"
      fi
      log "  HYDRA_FORCE=1 set — proceeding despite suspicious deletions"
    else
      # Non-suspicious deletions: just log them and continue
      log "  ⚠ sync will delete $del_count file(s) on server (none under workspaces/ or skills-all/):"
      echo "$deletions" | head -10 | sed 's/^/      /'
      (( del_count > 10 )) && log "      ... ($((del_count - 10)) more)"
    fi
  fi

  log "  Pre-flight clean."
}
preflight_drift_check

# -------------------------------------------------------------------
# Step 4b: rsync repo to Node 8
# -------------------------------------------------------------------
if $HYDRA_LOCAL; then
  log "Step 4b/9: Local sync (running on Node 8)..."
  rsync -a --delete \
    "${RSYNC_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$DEPLOY_PATH/"
  log "  Config synced locally to $DEPLOY_PATH/"
else
  log "Step 4b/9: Remote sync to Node 8 ($NODE8_IP)..."
  rsync -azP --delete \
    -e "ssh -i $SSH_KEY $SSH_OPTS_STR" \
    "${RSYNC_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
  log "  Config synced to $NODE8_IP:$DEPLOY_PATH/"
fi

# -------------------------------------------------------------------
# Step 4c: Sync global skills to openclaw managed-skills dirs (per profile)
# -------------------------------------------------------------------
# skills-all/ is the canonical source of truth for shared skills used
# across ALL profiles — muso-intercom by edge's support, muso-devops by
# main's devops, etc.
#
# Path discovery (2026-05-26, hydra #336): openclaw 2026.5.19's resolver
# loads "managed" skills at tier 4 from `<CONFIG_DIR>/skills/`, where
# CONFIG_DIR = dirname(OPENCLAW_CONFIG_PATH) when --profile is used. So
# the gateway started with `--profile main` resolves CONFIG_DIR to
# `/root/.openclaw-main/`, and reads managed skills from
# `/root/.openclaw-main/skills/<skill>/SKILL.md`.
#
# Pre-#336 this step rsynced to `/root/.openclaw/skills/skills/` — both
# wrong dir (no `-main`/`-edge` profile suffix) AND wrong nesting (extra
# `skills/`). The result: managed tier was silently empty, and every
# agent loaded skills exclusively from its workspace rank-1 dir
# (`/opt/hydra/workspaces/<agent>/skills/`). That's why 11 agents froze
# on stale workspace doctrine — they had no canonical fallback at all.
#
# Fix: rsync to each profile's managed-skills dir. Runs unconditionally
# when skills-all/ exists, regardless of --target.
log "Step 4c/9: Syncing global skills to per-profile managed-skills dirs..."
if [[ -d "$HYDRA_ROOT/skills-all" ]]; then
  skills_rc=0
  for profile in main edge dev; do
    profile_config="/root/.openclaw-${profile}/openclaw.json"
    # Only sync for profiles that actually exist on this server.
    [[ -f "$profile_config" ]] || continue
    profile_skills_dir="/root/.openclaw-${profile}/skills"
    mkdir -p "$profile_skills_dir"
    # RSYNC_EXCLUDES is passed to satisfy .githooks/pre-commit Check 2,
    # which enforces that every rsync call references the shared array.
    # None of the workspace/audit/plugin patterns in RSYNC_EXCLUDES match
    # anything inside skills-all/, so they're no-ops here — same rationale
    # as the install_plugin rsync. See the comment there for more detail.
    rsync -az --delete "${RSYNC_EXCLUDES[@]}" "$HYDRA_ROOT/skills-all/" "$profile_skills_dir/" || {
      skills_rc=$?
      fail "skills-all/ → $profile_skills_dir/ sync failed (rsync rc=$skills_rc)"
    }
    skill_count=$(find "$profile_skills_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    log "  ✓ profile=$profile: synced $skill_count skills to $profile_skills_dir/"
  done
else
  log "  skills-all/ not found in repo — skipping"
fi

# -------------------------------------------------------------------
# Step 4c.5: Pin openclaw runtime version
# -------------------------------------------------------------------
# Sits between skills sync (4c) and plugin install (4d) so that any
# plugin scripts which shell out to the openclaw CLI during their own
# install hooks see the pinned version. Idempotent — same-version
# deploys skip the npm install. See OPENCLAW_VERSION near the top of
# the file and install_openclaw() up by install_plugin().
log "Step 4c.5/9: Pinning openclaw runtime to ${OPENCLAW_VERSION}..."
if ! install_openclaw; then
  fail "openclaw runtime pin failed (target ${OPENCLAW_VERSION})"
fi

# -------------------------------------------------------------------
# Step 4d: Install plugins
# -------------------------------------------------------------------
# Moved from deploy.yml's "Install plugins" step on 2026-04-08 (CD
# consolidation). Uses the plugin_profile() and install_plugin()
# helpers defined near the top of this file.
#
# Behavior on plugin failure:
#   HYDRA_CONTINUE_ON_PLUGIN_FAIL unset or "0": fail on first error
#     (default; retry is idempotent, partial state is recoverable)
#   HYDRA_CONTINUE_ON_PLUGIN_FAIL="1": collect all failures and report
#     at the end; useful for seeing full breakage picture at once
log "Step 4d/9: Installing plugins..."
if [[ -d "$HYDRA_ROOT/plugins" ]]; then
  plugin_failures=()
  for plugin_dir in "$HYDRA_ROOT"/plugins/*/; do
    [[ -d "$plugin_dir" ]] || continue
    if [[ ! -f "${plugin_dir}package.json" ]]; then
      log "    Skipping $(basename "$plugin_dir") — no package.json"
      continue
    fi
    if ! install_plugin "$plugin_dir"; then
      plugin_name=$(basename "$plugin_dir")
      plugin_failures+=("$plugin_name")
      if [[ "${HYDRA_CONTINUE_ON_PLUGIN_FAIL:-0}" != "1" ]]; then
        fail "plugin install failed: $plugin_name (set HYDRA_CONTINUE_ON_PLUGIN_FAIL=1 to collect all failures before failing)"
      fi
    fi
  done
  if (( ${#plugin_failures[@]} > 0 )); then
    fail "plugin install: ${#plugin_failures[@]} plugin(s) failed: ${plugin_failures[*]}"
  fi
  log "  ✓ All plugins installed"
else
  log "  plugins/ not found in repo — skipping"
fi

# Fix script permissions (rsync doesn't preserve +x from git)
chmod +x "$DEPLOY_PATH"/scripts/*.sh "$DEPLOY_PATH"/scripts/*.py 2>/dev/null || true
log "  Script permissions fixed"

# -------------------------------------------------------------------
# Step 4d.5: Install externalized plugins (Slack + Codex)
# -------------------------------------------------------------------
# Several harness/channel plugins ship as separate @openclaw/* npm
# packages whose ABI tracks the core runtime, so a runtime bump must
# re-pin them IN LOCKSTEP or they silently mis-behave:
#   - @openclaw/slack: externalized from 2026.5.12; without it the
#     gateway emits "plugins.entries.slack: plugin not installed" and
#     #muso-hydra goes silent (incident PR #302).
#   - @openclaw/codex: a stale plugin under a newer runtime rejects
#     `openai/*` models so Codex-pinned agents fall back to Sonnet
#     (incident 2026-05-29 — runtime went 5.19->5.27 but the deploy
#     only pinned Slack, leaving the 5.19 Codex plugin behind).
log "Step 4d.5/9: Pinning externalized plugins (slack=${OPENCLAW_SLACK_VERSION}, codex=${OPENCLAW_CODEX_VERSION})..."
if ! install_external_plugin "@openclaw/slack" "$OPENCLAW_SLACK_VERSION"; then
  fail "@openclaw/slack pin failed (target ${OPENCLAW_SLACK_VERSION})"
fi
if ! install_external_plugin "@openclaw/codex" "$OPENCLAW_CODEX_VERSION"; then
  fail "@openclaw/codex pin failed (target ${OPENCLAW_CODEX_VERSION})"
fi

# Surface (warn, don't fail) any OTHER externalized @openclaw/* plugin
# that has drifted from the runtime, so a silent skew like the
# 2026-05-29 Codex incident can't hide again. These are deliberately NOT
# auto-pinned because their version policy is independent of the core
# runtime (e.g. @openclaw/lobster tracks its own validated build) — bump
# them on purpose, not implicitly.
for _profile in main edge; do
  needs_target "$_profile" || continue
  for _pj in /root/.openclaw-${_profile}/npm/node_modules/@openclaw/*/package.json; do
    [[ -f "$_pj" ]] || continue
    _name=$(jq -r '.name // empty' "$_pj" 2>/dev/null || echo "")
    case "$_name" in
      @openclaw/slack|@openclaw/codex|"") continue ;;
    esac
    _ver=$(jq -r '.version // empty' "$_pj" 2>/dev/null || echo "")
    if [[ "$_ver" != "$OPENCLAW_VERSION" ]]; then
      log "    ⚠ ${_name} is ${_ver:-unknown} on ${_profile} (runtime ${OPENCLAW_VERSION}) — drift; not auto-pinned, bump deliberately"
    fi
  done
done

# NOTE: drift baseline (.deployed-sha) is updated AFTER Step 7 (smoke test
# passes), not here. Writing it now would advance the baseline before we
# know the deploy actually works — a half-failed deploy would leave a
# stale baseline that masks real drift on the next run.

# Sync per-profile configs to profile state dirs.
# Preserves `.mcp.servers` from the live file across deploys so
# server-side `openclaw mcp set` registrations (e.g. NocoDB, which
# carries an auth token we don't want to commit) survive. The repo
# copy wins for every other field. Mirrors the cron-state preservation
# pattern used in Step 5a (below) for the same reason: deploys must
# not silently wipe server-registered runtime state.
sync_profile_config() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    return
  fi
  SRC="$src" DST="$dst" ANNOUNCE_HELPER="$SCRIPT_DIR/lib/announce-legit-write.sh" \
    python3 - <<'PYEOF' || fail "profile config sync failed for $dst"
import hashlib, json, os, subprocess, sys, tempfile, time
src_path = os.environ['SRC']
dst_path = os.environ['DST']
announce_helper = os.environ.get('ANNOUNCE_HELPER', '')

def warn(msg):
    # Match the deploy.sh log() format so aggregators see a consistent shape.
    sys.stderr.write(f"  WARNING: {msg}\n")

with open(src_path) as f:
    repo_cfg = json.load(f)

live_cfg = None
try:
    with open(dst_path) as f:
        live_cfg = json.load(f)
except json.JSONDecodeError as e:
    # Live file is unparseable. Back it up before we overwrite — it may hold
    # auth tokens or server definitions that can be recovered by hand. The
    # alternative (silently treating as empty) permanently destroys that state
    # and is the exact class of silent failure this PR is meant to eliminate.
    ts = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    quarantine = f"{dst_path}.corrupted.{ts}"
    try:
        os.rename(dst_path, quarantine)
        warn(f"live config {dst_path} is not valid JSON ({e.msg}); "
             f"moved to {quarantine} before overwrite")
    except OSError as move_err:
        warn(f"live config {dst_path} is not valid JSON and could not be "
             f"quarantined ({move_err}); proceeding with repo copy")
    live_cfg = {}

preserved = {}
if isinstance(live_cfg, dict):
    mcp = live_cfg.get('mcp')
    if isinstance(mcp, dict):
        servers = mcp.get('servers')
        if isinstance(servers, dict):
            preserved = servers
        elif servers is not None:
            warn(f"live {dst_path} has non-dict .mcp.servers "
                 f"({type(servers).__name__}); ignoring, not preserving")
    elif mcp is not None:
        warn(f"live {dst_path} has non-dict .mcp "
             f"({type(mcp).__name__}); ignoring, not preserving")
else:
    warn(f"live {dst_path} parsed but root is not a JSON object; ignoring")

if preserved:
    repo_cfg.setdefault('mcp', {})['servers'] = preserved

# Atomic write to avoid torn-read by a concurrently-starting gateway.
tmp = tempfile.NamedTemporaryFile('w', dir=os.path.dirname(dst_path), delete=False)
try:
    json.dump(repo_cfg, tmp, indent=2)
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp.close()
    # Announce the legitimate write before renaming so
    # openclaw-config-write-audit.sh's inotify-triggered alert can
    # match on path+sha256 and suppress the "out-of-band write" Slack
    # page. See scripts/lib/announce-legit-write.sh.
    if announce_helper and os.path.isfile(announce_helper):
        with open(tmp.name, 'rb') as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
        subprocess.run(
            [announce_helper, 'deploy.sh', dst_path],
            check=False,
            env={**os.environ, 'ANNOUNCE_SHA': sha},
        )
    os.replace(tmp.name, dst_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
sys.stderr.write(f"  preserved {len(preserved)} live MCP server(s) in {dst_path}\n")
PYEOF
}

log "  Syncing profile configs..."
if needs_target "main"; then
  sync_profile_config "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw-main/openclaw.json
  # Mirror to legacy default path as defense-in-depth (see cron sync below
  # for the same rationale) — preserve its `.mcp.servers` the same way as
  # the profile-specific path, so if the pre-multi-profile gateway ever
  # reanimates (smoke-test.sh hard-fails the deploy if it does) it will
  # still have the server list rather than being silently stripped.
  sync_profile_config "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw/openclaw.json
  log "  Synced main profile config (+ default openclaw.json)"
fi
if needs_target "edge"; then
  sync_profile_config "$DEPLOY_PATH/openclaw-edge.json" /root/.openclaw-edge/openclaw.json
  log "  Synced edge profile config"
fi
# Schema validate the post-merge result for every profile we just touched.
# sync_profile_config preserves only `.mcp.servers` from live, so a clean
# repo config should produce a clean merge — but the openclaw schema gets
# stricter across versions (2026-04-30: `plugins.config` removed,
# `subagents` rejected, `streaming` shape changed) and a deploy that
# leaves an invalid config on disk turns into a crash-loop the moment the
# next gateway restart fires. Catch it now while we still hold control,
# instead of finding out via the smoke test (which only sees the
# downstream "0 agents bound" symptom and can't tell us what's wrong).
for _profile in main edge; do
  needs_target "$_profile" || continue
  _validate_out=$(openclaw --profile "$_profile" config validate 2>&1 || true)
  if ! echo "$_validate_out" | grep -q "Config valid"; then
    fail "post-sync openclaw schema validation failed on profile=${_profile}: ${_validate_out}"
  fi
done
log "  Post-sync openclaw schema validation passed."

# Re-lint the live configs after the merge: a live-only (never-
# committed) `npx mcp-remote` entry — e.g. one added long ago via
# the openclaw CLI's default stdio shape — would slip past Step 1's
# repo-only lint, survive the merge-preserve, and silently bring
# the leak back. Catch it here while the gateway hasn't reloaded yet.
# Only lint the profiles this deploy targets — otherwise a partial
# deploy (e.g. `deploy.sh --target edge`) would be blocked by a
# stale mcp-remote entry on an unrelated profile the operator never
# touched.
if [ -x "$LINT_OPENCLAW_CFG" ]; then
  live_lint_targets=()
  if needs_target "main" && [ -f /root/.openclaw-main/openclaw.json ]; then
    live_lint_targets+=(/root/.openclaw-main/openclaw.json)
  fi
  if needs_target "edge" && [ -f /root/.openclaw-edge/openclaw.json ]; then
    live_lint_targets+=(/root/.openclaw-edge/openclaw.json)
  fi
  if (( ${#live_lint_targets[@]} > 0 )); then
    "$LINT_OPENCLAW_CFG" "${live_lint_targets[@]}" \
      || fail "openclaw config lint failed on live config — see preceding stderr for the profile + server name; rewrite with \`openclaw --profile <p> mcp set\` to transport: \"streamable-http\""
    log "  Live openclaw configs free of mcp-remote stdio entries."
  fi
fi

# -------------------------------------------------------------------
# Step 5a: Post-sync setup on Node 8
# -------------------------------------------------------------------
# Renamed from Step 5 → Step 5a on 2026-04-08 to make room for
# Step 5b (k8s manifest apply). If you're grepping deploy logs for
# "Step 5:" you'll need to update filters to "Step 5[ab]:".
log "Step 5a/9: Running post-sync setup..."

run_on_node8() {
  if $HYDRA_LOCAL; then
    bash -c "$1"
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" "$1"
  fi
}

# Post-sync inline (runs locally on node-8).
#
# IMPORTANT: `bash << 'POSTSYNC'` starts a CHILD bash process. The child
# does NOT inherit unexported parent shell variables (like HYDRA_ROOT)
# or unexported parent shell functions (like fail/log/needs_target).
# Any code added inside this heredoc that references parent symbols MUST
# be preceded by an explicit `export` (or `export -f` for functions).
#
# These exports were added 2026-04-07 after PR #64's first version
# referenced $HYDRA_ROOT and fail() inside the heredoc and would have
# crashed on the very first deploy with "HYDRA_ROOT: unbound variable"
# (set -u) plus "fail: command not found" — wrong error message AND
# silently bypassed notify_slack(). Caught by silent-failure-hunter
# during the second-round PR review.
export HYDRA_ROOT TARGET DEPLOY_PATH HYDRA_LOCAL
export -f fail log notify_slack needs_target

bash << 'POSTSYNC'
set -euo pipefail

# AWS credentials (from K8s secret or pre-configured)
if [ ! -f ~/.aws/credentials ]; then
  echo "  Setting up AWS credentials..."
  mkdir -p ~/.aws
  AWS_KEY=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d)
  AWS_SECRET=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d)
  AWS_ROLE=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_ROLE_ARN}' 2>/dev/null | base64 -d)
  if [ -n "$AWS_KEY" ]; then
    cat > ~/.aws/credentials << CEOF
[plaque]
aws_access_key_id = ${AWS_KEY}
aws_secret_access_key = ${AWS_SECRET}
CEOF
    cat > ~/.aws/config << CEOF
[default]
region = us-west-2
role_arn = ${AWS_ROLE}
source_profile = plaque

[profile plaque]
region = us-west-2
CEOF
    chmod 600 ~/.aws/credentials
    echo "  AWS credentials configured."
  else
    echo "  WARNING: aws-hydra-readonly secret not found — skipping AWS setup."
  fi
fi

# Ensure GOG_KEYRING_PASSWORD is set for gog CLI
if ! grep -q "GOG_KEYRING_PASSWORD" /root/.bashrc 2>/dev/null; then
  GOG_PW=$(kubectl get secret -n hydra hydra-service-tokens -o jsonpath='{.data.GOG_KEYRING_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -n "$GOG_PW" ]; then
    echo "export GOG_KEYRING_PASSWORD='${GOG_PW}'" >> /root/.bashrc
    echo "  GOG keyring password set in .bashrc"
  fi
fi

# Guard: ensure muso-ops-admin credentials are present in the main profile
# env file. The ops agent (on the main profile) needs MUSO_ADMIN_EMAIL and
# MUSO_ADMIN_PASSWORD to auth against the Muso admin API; without them all
# admin API operations fail — the ops agent surfaces this as "admin API
# credentials are not configured" (first observed on credit-verification
# requests). These vars live in /etc/openclaw/main.env (loaded as systemd
# EnvironmentFile by openclaw-gateway-main.service) and are NOT in ~/.zshrc
# — the daemon does not source an interactive shell. Warn loudly on drift so
# a future main.env regeneration can't silently break the ops agent again.
# Note: warn-only (not fail-fast) because creds are manually provisioned;
# failing here would block deploys on new hosts where main.env doesn't exist
# yet.
if needs_target "main"; then
  MAIN_ENV="/etc/openclaw/main.env"
  if [ -f "$MAIN_ENV" ]; then
    missing_vars=()
    grep -qE "^MUSO_ADMIN_EMAIL=.+"    "$MAIN_ENV" || missing_vars+=(MUSO_ADMIN_EMAIL)
    grep -qE "^MUSO_ADMIN_PASSWORD=.+" "$MAIN_ENV" || missing_vars+=(MUSO_ADMIN_PASSWORD)
    if (( ${#missing_vars[@]} > 0 )); then
      log "WARN: $MAIN_ENV is missing: ${missing_vars[*]}"
      log "WARN: ops agent admin API operations will fail until these are added."
      log "WARN: fix with:  sudo vim $MAIN_ENV  &&  systemctl restart openclaw-gateway-main"
    fi
  else
    log "WARN: $MAIN_ENV does not exist — ops agent will start with no admin credentials."
    log "WARN: create it, add MUSO_ADMIN_EMAIL= (e.g. retool@muso.ai) and MUSO_ADMIN_PASSWORD=, then:"
    log "WARN:   systemctl restart openclaw-gateway-main"
  fi
fi

# Note: mention gate patch (patch-openclaw-mention-gate.sh) removed — no longer needed on OpenClaw 2026.4.2+

# Sync cron jobs from repo to the main profile data dir (preserve live state).
# Under `--profile main`, openclaw reads/writes cron state at
# /root/.openclaw-main/cron/jobs.json — this is the authoritative storePath
# (verified 2026-04-21 via `openclaw --profile main cron status --json`
# once the legacy zombie service was masked; see the zombie guard in
# smoke-test.sh for the full incident context).
#
# We ALSO mirror to /root/.openclaw/cron/jobs.json (the pre-migration
# legacy path) as defense-in-depth. If the pre-multi-profile
# `openclaw-gateway.service` unit ever reanimates (smoke-test hard-fails
# the deploy if it does), at least both paths will carry the same job set
# so the drift window is zero rather than 2 weeks. In steady state nothing
# reads the mirror; cost is ~1 extra install -m 600 per deploy.
if [ -f "$HYDRA_ROOT/cron-jobs.json" ] && needs_target "main"; then
  LIVE_CRON="/root/.openclaw-main/cron/jobs.json"
  LEGACY_CRON="/root/.openclaw/cron/jobs.json"
  # NOTE: the parent profile dir /root/.openclaw-main/ is guaranteed to
  # exist by the profile-config-sync block that runs between Step 4d
  # and Step 5a in this same deploy (the "mkdir -p /root/.openclaw-main;
  # cp openclaw-main.json ..." block above), so we don't need to assert
  # it here. Earlier versions had an "if [ ! -d $PROFILE_DIR ]; then
  # fail" check that could never fire — removed as dead code.
  mkdir -p "$(dirname "$LIVE_CRON")" || fail "failed to create cron dir at $(dirname "$LIVE_CRON")"
  if [ -f "$LIVE_CRON" ]; then
    LIVE_CRON="$LIVE_CRON" REPO_CRON="$HYDRA_ROOT/cron-jobs.json" python3 - <<'PYEOF' || fail "cron sync failed for $LIVE_CRON"
import json, os, sys, tempfile
live_path = os.environ['LIVE_CRON']
repo_path = os.environ['REPO_CRON']
with open(repo_path) as f:
    repo = json.load(f)
with open(live_path) as f:
    live = json.load(f)

# Schema guard: every job MUST have a stable id (we key live state on it).
# A hand-edited cron-jobs.json missing an id would otherwise crash with
# a bare KeyError mid-loop and the operator gets a generic "cron sync
# failed" message. Surface the actual problem with a clear error.
for j in repo.get('jobs', []):
    if 'id' not in j:
        sys.exit(f"cron-jobs.json job missing required 'id': {j.get('name', '<unnamed>')}")
for j in live.get('jobs', []):
    if 'id' not in j:
        sys.exit(f"live cron file has job missing required 'id': {j.get('name', '<unnamed>')} — manual fix required")

# Key live state by job id (not name) so renames preserve runtime state
# instead of silently dropping it. The id is a stable UUID; the name is a
# human label that may change (e.g. b2b-reply-scanner-15m -> -1h cadence
# rename).
live_states = {j['id']: j.get('state', {}) for j in live.get('jobs', [])}
# Ephemeral one-shot jobs (deleteAfterRun + a one-time `at` schedule) are
# created at runtime by agents and self-delete after firing — never a
# committable/protected orphan. Used by the orphan filter below.
live_ephemeral = {j['id'] for j in live.get('jobs', [])
                  if j.get('deleteAfterRun') is True and j.get('schedule', {}).get('kind') == 'at'}
repo_ids = {j['id'] for j in repo.get('jobs', [])}
preserved = 0
for j in repo.get('jobs', []):
    if j['id'] in live_states:
        j['state'] = live_states[j['id']]
        preserved += 1

# Orphaned ids = jobs that exist in live but no longer exist in repo.
# Their runtime state will be permanently dropped on the next write.
# That's a real data-loss event (lastRunMs/nextRunMs gone forever) and
# should fail the deploy unless explicitly allowed via env var. The
# common cases that legitimately produce orphans are: deliberate job
# removal (set HYDRA_ALLOW_ORPHAN_CRON=1) or a refactor that changed
# UUIDs (write a migration instead of bypassing the guard).
orphaned = set(live_states) - repo_ids
# Ephemeral one-shot crons (deleteAfterRun + a one-time `at` schedule) are
# created at runtime by agents and never committed to the repo: the QA
# auto-review bot's qa-autoreview-pr-<N> review jobs (PR #391), the CMO
# agent's b2b-*-send-report reminders, etc. They are disposable and
# self-delete after firing — not protected orphan state. Drop them from the
# live file on sync without blocking the deploy (otherwise any deploy that
# races a pending one-shot would halt). Matched by PROPERTY, not name, so
# every agent's one-shots are covered — not just the QA bot's.
orphaned = {i for i in orphaned if i not in live_ephemeral}
if orphaned:
    if os.environ.get('HYDRA_ALLOW_ORPHAN_CRON') == '1':
        print(f'  HYDRA_ALLOW_ORPHAN_CRON=1: dropping live state for {len(orphaned)} job ids no longer in repo: {sorted(orphaned)}', file=sys.stderr)
    else:
        sys.exit(f"refusing to drop live state for {len(orphaned)} orphaned job id(s): {sorted(orphaned)}. Set HYDRA_ALLOW_ORPHAN_CRON=1 if this is intentional (e.g. you removed jobs from cron-jobs.json on purpose).")

# Heal-from-empty: live file existed but had 0 jobs. This is the exact
# state the 2026-04-07 outage left the system in. Repo file will
# repopulate it. Print to stderr so deploy log aggregators catch it.
if not live.get('jobs'):
    print('  WARNING: live cron file was empty — repo file will repopulate (this is the post-outage heal path; safe on first run after a truncation, suspicious otherwise)', file=sys.stderr)

# Write atomically: tmpfile + os.replace so a mid-write crash never leaves
# the live file truncated (which would silently re-trigger the cron outage
# this PR is fixing).
fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(live_path), prefix='.jobs-', suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(repo, f, indent=2)
    os.replace(tmp_path, live_path)
except Exception:
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
    raise
print(f'  Synced {len(repo.get("jobs", []))} cron jobs to {live_path} '
      f'({preserved} states preserved)')
PYEOF
  else
    # Use install -m 600 instead of cp+chmod to set perms atomically on
    # creation (no brief 0644 window). cron-jobs.json contains agent
    # prompts with sensitive references (sheet IDs, account names).
    install -m 600 "$HYDRA_ROOT/cron-jobs.json" "$LIVE_CRON" || fail "failed to install cron-jobs.json to $LIVE_CRON"
    echo "  Deployed cron jobs to $LIVE_CRON (fresh install)"
  fi
  chmod 600 "$LIVE_CRON" || fail "failed to chmod $LIVE_CRON"

  # Mirror to the legacy path as defense-in-depth against zombie
  # reanimation (see block comment above). install -m 600 sets perms
  # atomically on creation (no 0644 window). Symlink guard: if either
  # path resolves to the same inode (e.g. someone symlinked
  # /root/.openclaw/cron/jobs.json → the profile file as a manual
  # convergence fix), skip the install — it would be a self-copy and
  # the "mirrored" log line would be misleading.
  mkdir -p "$(dirname "$LEGACY_CRON")" || fail "failed to create cron dir at $(dirname "$LEGACY_CRON")"
  if [ -e "$LEGACY_CRON" ] && [ "$(readlink -f "$LIVE_CRON")" = "$(readlink -f "$LEGACY_CRON")" ]; then
    log "  Skipped legacy mirror: $LEGACY_CRON resolves to same inode as $LIVE_CRON"
  else
    install -m 600 "$LIVE_CRON" "$LEGACY_CRON" || fail "failed to mirror cron-jobs.json to $LEGACY_CRON"
    log "  Mirrored cron-jobs.json to $LEGACY_CRON (defense-in-depth vs zombie legacy service)"
  fi
fi
POSTSYNC

log "  Post-sync setup complete."

# -------------------------------------------------------------------
# Step 5b: Apply k8s manifests
# -------------------------------------------------------------------
# Moved from deploy.yml's "Apply K8s manifests" step on 2026-04-08
# (CD consolidation). Captures current state to /tmp for the
# rollback.sh kubectl-apply path, then kubectl apply the manifests.
#
# Convention: k8s/prod/<namespace>/*.yaml — directory name is the target
# namespace. Each subdir is applied with --namespace=<dir-name>.
# HYDRA_NAMESPACE env (legacy override for test/staging) only redirects
# the k8s/prod/hydra/ subdir, not other namespaces' manifests, because
# kubectl 1.34+ rejects --namespace mismatches when the yaml declares one.
# Skips silently if no k8s/prod/<ns>/ dirs exist.
log "Step 5b/9: Applying k8s manifests..."
shopt -s nullglob
k8s_ns_dirs=("$HYDRA_ROOT"/k8s/prod/*/)
shopt -u nullglob
if (( ${#k8s_ns_dirs[@]} == 0 )); then
  log "  no k8s/prod/<ns>/ dirs found — skipping k8s apply"
else
  for ns_dir in "${k8s_ns_dirs[@]}"; do
    dir_ns=$(basename "$ns_dir")
    if [[ "$dir_ns" == "hydra" ]]; then
      apply_ns="${HYDRA_NAMESPACE:-hydra}"
    else
      apply_ns="$dir_ns"
    fi

    # Capture per-namespace rollback snapshot. The 2>/dev/null || true
    # tolerates "namespace not found" / "kubectl not configured" so the
    # snapshot is best-effort, but we explicitly check the resulting
    # files are non-empty before referencing them in the failure message.
    rollback_dep="/tmp/hydra-rollback-deployments-${apply_ns}.yaml"
    rollback_cm="/tmp/hydra-rollback-configmaps-${apply_ns}.yaml"
    kubectl get deployments -n "$apply_ns" -o yaml > "$rollback_dep" 2>/dev/null || true
    kubectl get configmaps -n "$apply_ns" -o yaml > "$rollback_cm" 2>/dev/null || true

    apply_rc=0
    kubectl apply -f "$ns_dir" --namespace="$apply_ns" || apply_rc=$?
    if (( apply_rc != 0 )); then
      rollback_hint="rollback yaml at $rollback_dep / $rollback_cm"
      if [[ ! -s "$rollback_dep" ]]; then
        rollback_hint="WARNING: $rollback_dep is empty (kubectl get deployments returned nothing — namespace missing or kubectl not configured?). No automatic recovery available; manual investigation required."
      fi
      fail "kubectl apply to namespace=$apply_ns failed (rc=$apply_rc) — $rollback_hint. To revert manually if the snapshot is non-empty: kubectl apply -f $rollback_dep -n $apply_ns"
    fi
    log "  ✓ K8s manifests applied to namespace=$apply_ns (from $ns_dir)"
  done
fi

# -------------------------------------------------------------------
# Step 5c: Install/refresh aux units (drop-ins, audit, watchdog cron)
# -------------------------------------------------------------------
# Reconciles the systemd drop-ins that wire ExecStartPre self-heal
# and a restart ceiling onto the three gateway services, plus the
# openclaw-config-write-audit@<profile>.path watchers and the 2-min watchdog
# cron file. Idempotent — safe to run on every deploy. Must come
# BEFORE Step 6's gateway restart so the next start picks up the
# drop-in's ExecStartPre.
if $HYDRA_LOCAL; then
  log "Step 5c/9: Installing/refreshing aux systemd units..."
  if [ -x "$DEPLOY_PATH/scripts/install-aux-units.sh" ]; then
    "$DEPLOY_PATH/scripts/install-aux-units.sh" "$DEPLOY_PATH" \
      || fail "install-aux-units.sh failed — see preceding output"
    log "  Aux units installed/refreshed."
  else
    log "  install-aux-units.sh missing or not executable — skipping (laptop deploy?)"
  fi
else
  log "Step 5c/9: skipping aux-units install (not running on node-8)"
fi

# -------------------------------------------------------------------
# Step 6: Restart targeted gateway(s)
# -------------------------------------------------------------------
log "Step 6/9: Restarting OpenClaw Gateway ($TARGET)..."
restart_gateway() {
  local service="$1"
  local cmd="systemctl restart $service"
  if $HYDRA_LOCAL; then
    eval "$cmd"
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" "$cmd"
  fi
  # Gateway takes ~12s to start (loads all agents + plugins). Poll up to 30s.
  for i in $(seq 1 15); do
    sleep 2
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log "  $service restarted successfully (${i}x2s)."
      return 0
    fi
  done
  fail "Failed to restart $service (timed out after 30s)"
}

if needs_target "main"; then restart_gateway "openclaw-gateway-main"; fi
if needs_target "edge"; then restart_gateway "openclaw-gateway-edge"; fi

# -------------------------------------------------------------------
# WARMUP: wait for agents to bind before smoke test
# -------------------------------------------------------------------
# Agents need time to load after a systemctl restart — about 12-20s
# in practice. The smoke test was previously running immediately
# after restart, which caused the cross-agent mesh test to fail on
# timing even when the gateway was actually healthy.
#
# We poll openclaw's BOUND count per profile and wait up to 30s
# before proceeding. Timeout is non-fatal — the smoke test will
# catch any real issue with a clearer error.
log "  Waiting for agents to bind before smoke test..."
if needs_target "main"; then
  wait_for_agents_bound "main" 30 || true
fi
if needs_target "edge"; then
  wait_for_agents_bound "edge" 30 || true
fi

# -------------------------------------------------------------------
# Step 7: Run smoke test
# -------------------------------------------------------------------
log "Step 7/9: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh" "$TARGET"; then
  fail "Smoke test failed after deploy"
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Update drift baseline (only after smoke test passed).
# -------------------------------------------------------------------
# Step 0 of the next deploy reads this file to know what "baseline" to
# compare against when detecting server-side edits. Writing here (not
# after Step 4b) means a half-failed deploy never advances the baseline
# past a SHA the server isn't actually running — the equivalent of
# `git push` only updating remote refs after the push succeeds.
if command -v git >/dev/null 2>&1 \
   && git -C "$HYDRA_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  DEPLOYED_SHA=$(git -C "$HYDRA_ROOT" rev-parse HEAD)
  # Validate format before sending — defense against weird git output.
  if ! [[ "$DEPLOYED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    fail "git rev-parse HEAD returned unexpected format: '$DEPLOYED_SHA' (refusing to write baseline)"
  fi
  # Write via stdin pipe rather than embedding the value in a remote
  # shell command — sidesteps quoting/injection issues entirely.
  if $HYDRA_LOCAL; then
    printf '%s\n' "$DEPLOYED_SHA" > "$DEPLOY_PATH/.deployed-sha"
  else
    printf '%s\n' "$DEPLOYED_SHA" \
      | ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
        "cat > '$DEPLOY_PATH/.deployed-sha'" \
      || fail "failed to write drift baseline to server (ssh/cat error)"
    # Read it back to verify it landed. Capture rc and stderr separately
    # so a transient SSH failure on the readback produces an actionable
    # error instead of "server has '', expected 'abc...'".
    readback_rc=0
    readback_out=$(ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "cat '$DEPLOY_PATH/.deployed-sha'" 2>&1) || readback_rc=$?
    if (( readback_rc != 0 )); then
      log "  baseline readback ssh failed (rc=$readback_rc):"
      echo "$readback_out" | sed 's/^/    /'
      fail "drift baseline readback failed — wrote SHA but couldn't verify it landed"
    fi
    readback_clean=$(echo "$readback_out" | tr -d '[:space:]')
    if [[ "$readback_clean" != "$DEPLOYED_SHA" ]]; then
      fail "drift baseline write verification failed: server has '$readback_clean', expected '$DEPLOYED_SHA'"
    fi
  fi
  log "  Drift baseline updated: .deployed-sha → $DEPLOYED_SHA"
fi

# -------------------------------------------------------------------
# Step 8: Verify AWS access (main only)
# -------------------------------------------------------------------
# NOTE: Hydra is hosted on OVH (node-8), not AWS. This step verifies
# the *data plane* — Muso has two AWS accounts (Flagship 068358774785
# and Plaque 686505752817) holding the data lake (S3, Athena, Glue)
# and audit trail (CloudTrail). Several agents query them at runtime:
#   - devops: daily-aws-change-report cron (CloudTrail scan)
#   - data-expert / query-writer: Athena queries
#   - clio: data-platform queries
# Step 5a wrote ~/.aws/credentials on node-8 from the k3s secret
# `aws-hydra-readonly` (role: plaque, region: us-west-2). This step
# runs `aws sts get-caller-identity` to confirm the credentials
# propagated and the role is assumable. Non-fatal — a failure here
# only affects AWS-reading agents on the next cron run.
if needs_target "main"; then
  log "Step 8/9: Verifying AWS data-plane access (Athena/S3/CloudTrail)..."
  if $HYDRA_LOCAL; then
    aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1 \
      && log "  AWS access verified." \
      || log "  WARNING: AWS access check failed (non-fatal)."
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1" \
      && log "  AWS access verified." \
      || log "  WARNING: AWS access check failed (non-fatal)."
  fi
else
  log "Step 8/9: Skipping AWS check (not targeting main)."
fi

# -------------------------------------------------------------------
# Post-flight: Caroline RAG smoke test (non-fatal)
# -------------------------------------------------------------------
# Runs only when targeting edge (the only profile with memorySearch
# enabled on the support agent). Surfaces stale index / broken
# embedding-provider auth via Slack rather than blocking the deploy.
if needs_target "edge" && [ -x "$SCRIPT_DIR/validate-caroline-rag.sh" ]; then
  log "Post-flight: Caroline RAG check (edge/support)..."
  rag_rc=0
  PROFILE=edge AGENT=support "$SCRIPT_DIR/validate-caroline-rag.sh" || rag_rc=$?
  if [ "$rag_rc" -eq 0 ]; then
    log "  Caroline RAG check passed."
  else
    log "  Caroline RAG check FAILED (rc=$rag_rc). Continuing deploy."
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
      curl -s -X POST -H "Content-type: application/json" \
        --data "{\"text\":\":warning: Caroline RAG post-deploy check failed (rc=$rag_rc). Run: ssh hydra PROFILE=edge AGENT=support ${DEPLOY_PATH}/scripts/validate-caroline-rag.sh\"}" \
        "$SLACK_WEBHOOK" >/dev/null || true
    fi
  fi
fi

# -------------------------------------------------------------------
# Step 9: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
# `git describe` prints either the current tag (`v2026.5.26`) or the most
# recent tag plus distance + sha (`v2026.5.26-3-gabc1234`). Bare commit-sha
# fallback for the pre-first-release window where no tags exist yet.
RELEASE_REF=$(git -C "$HYDRA_ROOT" describe --tags --always 2>/dev/null || echo "$COMMIT_SHA")
log "Step 9/9: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully (target: $TARGET). Release: $RELEASE_REF (sha: $COMMIT_SHA)"
log "Deploy complete. Target: $TARGET. Commit: $COMMIT_SHA"
