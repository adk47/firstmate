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
# the upgrade requires. Bump in lockstep with docs/guides/REPO-MANAGEMENT.md.
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.7.1}"

# Minimum Node.js for the pinned runtime (openclaw 2026.7.1 raised the floor
# to >=22.22.3 — its bin refuses to start below it, so a deploy on an old Node
# would install a runtime that can never boot). Checked fail-loud in
# install_openclaw(); upgrading Node is a manual pre-step, see
# docs/runbooks/UPGRADE-2026.7.1.md.
OPENCLAW_NODE_FLOOR="${OPENCLAW_NODE_FLOOR:-22.22.3}"

# Pinned @openclaw/slack version. 2026.5.12 externalized Slack into this
# npm package; the bundled `channels.slack` plugin no longer ships. Kept
# in lockstep with OPENCLAW_VERSION by default — the SDK pluginApi compat
# range tracks the core release.
OPENCLAW_SLACK_VERSION="${OPENCLAW_SLACK_VERSION:-${OPENCLAW_VERSION}}"

# Pinned @openclaw/codex version. The value + full rationale (why codex is pinned
# BELOW the runtime to dodge the #90925 api-key-route regression) live in the
# SINGLE SOURCE OF TRUTH scripts/lib/codex-version.sh, also read by the
# ExecStartPre pin healer (ensure-codex-version-pinned.sh) and the watchdog so the
# three enforcers can never disagree. Honors an OPENCLAW_CODEX_VERSION env override.
# shellcheck source=lib/version-compare.sh
source "$SCRIPT_DIR/lib/version-compare.sh"

# shellcheck source=lib/codex-version.sh
source "$SCRIPT_DIR/lib/codex-version.sh"

# Per-host deploy lock + stale-PID recovery (unit-tested in
# scripts/tests/deploy-lock.bats). Extracted from an inline block whose
# `mkdir_err=$(mkdir …)` tripped `set -e` before recovery, wedging every deploy
# behind one orphaned lock (incident 2026-07-01).
# shellcheck source=lib/deploy-lock.sh
source "$SCRIPT_DIR/lib/deploy-lock.sh"

# Effective systemd EnvironmentFile validation for the muso CLI credentials
# used by the main gateway (unit-tested in scripts/tests/muso-env-preflight.bats).
# shellcheck source=lib/muso-env-preflight.sh
source "$SCRIPT_DIR/lib/muso-env-preflight.sh"

# Pinned muso CLI version (github.com/Muso-AI/muso-cli) — the admin-API /
# policy CLI for main-gateway agents (soak phase: opt-in via the
# skills-all/muso-cli skill). Independent release cadence from openclaw;
# bump deliberately. Installed from the repo's GitHub Release with
# checksum verification (install_muso below) — never a bare latest.
#
# 0.11.1 carries the `tracks sources` verb group (muso-cli#36), which
# skills-all/muso-ops-tracks now documents in place of hand-rolled
# analytics-source payloads. The pin and the skill must move together: with
# the pin behind, the skill documents verbs the installed CLI does not have.
# Prod credentials still resolve — v0.11 reads the scoped MUSO_PROD_ADMIN_*
# pair but keeps the generic MUSO_ADMIN_* as a production-only fallback
# (internal/auth/env.go), which is what node-8's main.env carries; only
# `--env dev` fails closed, and node-8 has no dev pair to begin with.
MUSO_CLI_VERSION="${MUSO_CLI_VERSION:-0.11.1}"

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

# Resolve the installed version of an externalized @openclaw/* plugin from the
# runtime's OWN ledger (`plugins list --json`, keyed by plugin id) rather than a
# guessed filesystem path. openclaw 2026.6.x isolates externalized installs
# under ~/.openclaw-<p>/npm/projects/openclaw-<pkg>-<hash>/node_modules/...
# (upstream #88794) instead of ~/.openclaw-<p>/npm/node_modules/<pkg>/, so the
# old fixed-path package.json read returned "missing" even after a SUCCESSFUL
# install and FATAL'd Step 4d.5 on every 6.x deploy (Deploy HYDRA, 2026-06-16:
# "@openclaw/slack on main is 'missing' after install" — slack@2026.6.1 was in
# fact installed, loaded, and serving). Plugin id is the unscoped package name
# (@openclaw/slack -> slack, @openclaw/codex -> codex). `plugins list` is a flat
# JSON array in current builds; tolerate a {plugins:[...]} wrapper defensively.
plugin_runtime_version() { # <profile> <pkg e.g. @openclaw/slack>
  local profile="$1" id="${2##*/}"
  openclaw --profile "$profile" plugins list --json 2>/dev/null \
    | jq -r --arg id "$id" '(.plugins // .)[]? | select(.id == $id) | .version // empty' 2>/dev/null \
    | head -1
}

install_external_plugin() {
  # Pins ONE externalized @openclaw/* plugin per-profile under
  # ~/.openclaw-<profile>/npm/. Args: <pkg> <version> (e.g.
  # "@openclaw/slack" "2026.5.27"). Idempotent: skips when the runtime
  # ledger (plugins list) already reports the target version.
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
  local profile installed
  for profile in main edge; do
    if ! needs_target "$profile"; then continue; fi
    installed=$(plugin_runtime_version "$profile" "$pkg")
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
    # Trust the runtime ledger, not the exit code: a 0 rc that left the old
    # version pinned would silently ship a mismatched plugin. Re-read the
    # installed version (path-independent) and fail loud if the pin missed.
    installed=$(plugin_runtime_version "$profile" "$pkg")
    if [[ "$installed" != "$version" ]]; then
      log "    ✗ ${pkg} on $profile is '${installed:-missing}' after install, expected '$version'"
      return 1
    fi
  done
  return 0
}

install_openclaw() {
  # Node floor gate: openclaw 2026.7.1+ refuses to start on Node below its
  # engine range. Fail BEFORE npm install so we never replace a working
  # runtime with one the host's Node cannot boot.
  local node_ver
  node_ver=$(node --version 2>/dev/null | sed 's/^v//' || true)
  if [[ -z "$node_ver" ]]; then
    log "    ✗ install_openclaw: node not found in PATH (need >= ${OPENCLAW_NODE_FLOOR})"
    return 1
  fi
  if ! version_at_least "$OPENCLAW_NODE_FLOOR" "$node_ver"; then
    log "    ✗ install_openclaw: Node $node_ver < required ${OPENCLAW_NODE_FLOOR} for openclaw ${OPENCLAW_VERSION}."
    log "      Upgrade Node first (manual pre-step): see docs/runbooks/UPGRADE-2026.7.1.md §Node."
    return 1
  fi

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

# install_muso — pins the muso CLI from the Muso-AI/muso-cli GitHub
# release. Same contract as install_openclaw(): skip when the live binary
# already reports the target version, otherwise install and FAIL LOUD.
# Two hardenings carried over from the plugin path:
#   - assets are sha256-verified against the release's checksums.txt
#     before install (pin-everything doctrine, PR #217 incident);
#   - the installed version is re-read after install — exit codes are
#     not trusted (install_external_plugin precedent).
# gh is already authenticated on node-8 (release tagging uses it).
install_muso() {
  local installed
  installed=$(timeout 10 muso version --json 2>/dev/null | jq -r '.version // empty' || true)
  if [[ -z "$installed" ]]; then
    log "    install_muso: muso not found in PATH; installing ${MUSO_CLI_VERSION}"
  elif [[ "$installed" == "$MUSO_CLI_VERSION" ]]; then
    log "    muso already at ${MUSO_CLI_VERSION} — skipping install"
    return 0
  else
    log "    Upgrading muso ${installed} → ${MUSO_CLI_VERSION}"
  fi

  local arch asset tmp dl_out
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) log "    ✗ install_muso: unsupported arch $(uname -m)"; return 1 ;;
  esac
  asset="muso_linux_${arch}.tar.gz"
  tmp=$(mktemp -d) || return 1

  local dl_rc=0
  dl_out=$(timeout 120 gh release download "v${MUSO_CLI_VERSION}" --repo Muso-AI/muso-cli \
    --pattern "$asset" --pattern checksums.txt --dir "$tmp" 2>&1) || dl_rc=$?
  if (( dl_rc != 0 )); then
    log "    ✗ install_muso: gh release download v${MUSO_CLI_VERSION} failed (rc=$dl_rc):"
    echo "$dl_out" | sed 's/^/        /'
    rm -rf "$tmp"
    return 1
  fi
  # Belt: assert checksums.txt actually lists the asset. On node-8
  # (coreutils >= 8.25) `-c --ignore-missing` already exits 1 with "no
  # file was verified" when nothing matches (verified live, coreutils
  # 9.4), so this guards older/other hosts and makes the intent explicit.
  if ! grep -q "[[:space:]]${asset}\$" "$tmp/checksums.txt"; then
    log "    ✗ install_muso: checksums.txt has no entry for ${asset} — refusing unverified install"
    rm -rf "$tmp"
    return 1
  fi
  if ! (cd "$tmp" && sha256sum -c checksums.txt --ignore-missing >/dev/null 2>&1); then
    log "    ✗ install_muso: checksum verification failed for ${asset}"
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "${tmp}/${asset}" -C "$tmp" muso; then
    log "    ✗ install_muso: ${asset} does not contain the muso binary"
    rm -rf "$tmp"
    return 1
  fi
  install -m 755 "${tmp}/muso" /usr/local/bin/muso
  rm -rf "$tmp"

  installed=$(timeout 10 muso version --json 2>/dev/null | jq -r '.version // empty' || true)
  if [[ "$installed" != "$MUSO_CLI_VERSION" ]]; then
    log "    ✗ muso is '${installed:-missing}' after install, expected '${MUSO_CLI_VERSION}'"
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
# acquire_deploy_lock recovers a stale (dead-holder) lock and refuses only when a
# LIVE deploy holds it (or the lock is in an unrecoverable/ambiguous state); it
# writes our PID to $LOCK_DIR/pid on success. See lib/deploy-lock.sh for the
# per-return-code semantics and the incident that motivated the extraction.
acquire_deploy_lock "$LOCK_DIR" || fail "could not acquire deploy lock at $LOCK_DIR (see the deploy-lock message above)"
# Arm the cleanup trap ONLY after we successfully claim the lock.
# If we'd armed it earlier and then fail()'d during acquisition, the trap
# would wipe the OTHER deploy's lock dir on our exit.
trap 'release_deploy_lock "$LOCK_DIR"' EXIT

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
  # CTO clone-hook guard files, GENERATED on the server by
  # scripts/lib/setup-cto-clone-hooks.sh (run at deploy time from
  # install-aux-units.sh). They live inside the rsync-managed tree but are
  # never tracked in the repo, so without these excludes every rsync --delete
  # would wipe them (they'd then regenerate) and — worse — the deploy
  # pre-flight gate flags them as deletions and fails every PR. Server-owned,
  # regenerated each deploy; exclude so --delete leaves them alone.
  --exclude='.cto-clone-hooks.gitconfig'
  --exclude='scripts/lib/cto-git-hooks/'
  # Workspace runtime data (real, accumulating data)
  --exclude='workspaces/*/memory/'
  --exclude='workspaces/*/api-logs/'
  # openclaw >= 2026.7 writes a workspace-setup marker into each agent
  # workspace at first boot (workspace_setup_state). Server-owned runtime
  # state — never tracked in the repo; without this exclude every rsync
  # --delete after the 7.1 upgrade would wipe the markers and the deploy
  # pre-flight gate would flag them on every PR.
  --exclude='workspaces/*/openclaw-workspace-state.json'
  # Agent scratch temp files: agents write transient scratch into their
  # workspace during runtime ops and sometimes ORPHAN it (unheld by any
  # process). Many naming shapes have all tripped the rsync --delete pre-flight
  # and blocked EVERY PR + merge-deploy until node-8 was manually cleaned:
  # devops kubectl scratch '.tmp-kubectl-catalog-*.sh' (2026-07-15, #690);
  # Scout's numbered AI-music candidate + final batches 'tmp_ai_music_*.json'
  # written at its workspace root during a research run (2026-07-17, #698);
  # QA/scout review scratch 'tmp_*'; and devops atomic-write leftovers '*.tmp'
  # (2026-07-17). Server-owned transient scratch, recreatable at runtime, never
  # in the repo. The single '*tmp*' glob subsumes every one of these shapes
  # (and any future variant) — it REPLACES the former per-shape excludes
  # ('.tmp-*' and the two 'workspaces/scout/tmp_ai_music_*'). Depth-1
  # workspace-scoped (rsync '*' never crosses '/'). Drift guard requires the
  # mirrored '*tmp*' KEEP glob in scripts/qa-clean-merge-scratch.sh.
  # Convention: agents name workspace scratch with a 'tmp' marker so it lands
  # here — see docs/lessons/deploy-ci-pr.md.
  --exclude='workspaces/*/*tmp*'
  # Scout's company-finder run scratch: the AGENT invents these names at
  # runtime ('final-prep-input.json', 'final-batch.json' — 2026-07-21, blocked
  # #719) and ignored the tmp-marker convention, so '*tmp*' misses them.
  # Server-owned per-run scratch, recreatable, never in the repo. Mirrored
  # KEEP glob in scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/final-*.json'
  # Same agent, same lesson, new names: the company-finder run now also writes
  # DOT-prefixed scratch ('.company-finder-raw-<date>.json',
  # '.company-finder-final.json', '.company-finder-final-<date>.json' — observed
  # on node-8 2026-07-30, blocked #772). The leading dot and the
  # 'company-finder-' prefix mean neither '*tmp*' nor 'final-*.json' matches, so
  # every PR whose pre-flight ran while they existed went red. Server-owned
  # per-run scratch, recreatable, never in the repo. Mirrored KEEP glob in
  # scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/.company-finder-*.json'
  # Same agent, same lesson, FOURTH naming shape: the outreach-discovery
  # pipeline writes dated per-stage intermediates at its workspace root
  # ('finder-input-<date>.json', 'prep-output-<date>.json', plus '-v2' reruns —
  # observed on node-8 2026-08-05 18:14Z, blocked #794's merge-deploy and every
  # deploy after it). No 'tmp' marker, no 'final-' prefix, no leading dot, so
  # none of the three globs above match. Server-owned per-run scratch (stage
  # inputs and survivor/reject sets), recreatable by re-running the pipeline,
  # never in the repo. Mirrored KEEP globs in scripts/qa-clean-merge-scratch.sh
  # (lockstep rule, asserted by scripts/tests/qa-clean-merge-scratch.bats).
  --exclude='workspaces/*/finder-input-*.json'
  --exclude='workspaces/*/prep-output-*.json'
  # QA credit-verification todo inventory — dated per-run working state the QA
  # agent writes on node-8 (e.g. credit-verification-todo-inventory-2026-07-21.json),
  # never in the repo. Server-owned scratch; mirrored KEEP glob in
  # scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/credit-verification-todo-inventory-*.json'
  # Agent long-term memory (written by agents at runtime, should survive
  # deploys — see docs/guides/WORKSPACE-FILE-OWNERSHIP.md). MEMORY.md IS tracked
  # in git as a seed, but agents modify it post-deploy and we must not
  # overwrite those modifications with the seed on subsequent deploys.
  --exclude='workspaces/*/MEMORY.md'
  # Agent-created backups directory — never in repo, never overwritten.
  --exclude='workspaces/*/backups/'
  # Per-PR QA review state (external-pr-review runs write
  # workspaces/qa/pr-review-<n>.json at runtime). Server-owned; first
  # flagged by pre-flight 2026-08-02 (pr-review-562.json).
  #
  # Broadened 2026-08-03 from 'pr-review-*.json' to 'pr-review*.json': the
  # muso-github-code-review skill writes the batched review body to
  # /tmp/pr-review.json, but the agent has also written it relative to its
  # workspace, landing an UNNUMBERED workspaces/qa/pr-review.json on node-8.
  # The old glob required the '-' and so missed it. Because this pre-flight is
  # a LIVE gate against the running server, that one stray file turned EVERY
  # open PR red the moment it appeared (first failing run 14:10Z, after a
  # 14:08Z green). Deliberately NOT mirrored into qa-clean-merge-scratch.sh's
  # KEEP_GLOBS: that drift guard only covers 'workspaces/*/' file excludes, and
  # the deploy must not delete this mid-review while the merge-scratch cleanup
  # should still reap it afterwards as the per-run scratch it is.
  --exclude='workspaces/qa/pr-review*.json'
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
  # Per-workspace gateway runtime state, written by openclaw as agents run.
  # Server-owned, never seeded from the repo. Tripped pre-flight on
  # 2026-07-14 (coordinator/finance/operations/scout/cmo all carried one).
  --exclude='workspaces/*/openclaw-workspace-state.json'
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
  #
  # GOTCHA: the pattern below is UNANCHORED, so it swallows every config/
  # dir at every depth — including skills-all/<skill>/config/, which is how
  # the prod-log-alert watchdog shipped without its deployments.txt on
  # 2026-06-10 (fail-closed every tick) and how muso-devops-set-env's gate
  # configs never reached the server. The per-skill includes below take
  # precedence (rsync: first matching pattern wins) and are deliberately
  # per-skill rather than a blanket skills-all/*/config/: muso-ops-admin's
  # CANONICAL config has known server-side divergence (drifted
  # tier2-approvers.txt + a godmode allowlist the repo intentionally omits
  # from canonical) that a blanket include would overwrite/delete. They are
  # also deliberately unanchored so they match in BOTH the repo-root sync
  # and the skills-all/ → per-profile skills sync (different transfer roots).
  --include='muso-devops-prod-logs/config/'
  --include='muso-devops-prod-logs/config/**'
  --include='muso-devops-set-env/config/'
  --include='muso-devops-set-env/config/**'
  --include='muso-ops-credit-sync/config/'
  --include='muso-ops-credit-sync/config/**'
  # muso-ops-admin is a SELECTIVE exception (NOT a blanket include). Its config
  # carries server-side divergence we must never clobber: tier2-godmode-allowlist.txt
  # exists ONLY on node-8 (deliberately absent from canonical). So we sync the
  # three version-controlled, repo-authoritative files explicitly, then exclude
  # the rest of the dir. The trailing muso-ops-admin/config/** protects the
  # SERVER-ONLY canonical tier2-godmode-allowlist.txt (absent from the repo) from
  # rsync --delete — VERIFIED on node-8's GNU rsync 3.2.7, the deploy target
  # (deploy uses plain --delete, not --delete-excluded). NB: the *workspace* copy
  # of that file is tracked in the repo and syncs normally to its own path; and
  # macOS openrsync handles this dir-include + ** + --delete corner differently,
  # so verify rsync-filter changes on node-8, never locally. Before 2026-06 the
  # whole dir was excluded, which silently froze tier2-endpoints.txt and shipped
  # #519's tier-2 gate-gap fix dead on arrival (matcher deployed, allowlist did
  # not). The guard below enforces that the ** protection stays and that the
  # godmode file is never named in an include.
  --include='muso-ops-admin/config/'
  --include='muso-ops-admin/config/tier2-endpoints.txt'
  --include='muso-ops-admin/config/tier2-approvers.txt'
  --include='muso-ops-admin/config/capability-approvers.txt'
  --include='muso-ops-admin/config/bulk-destructive-exclude.txt'
  --exclude='muso-ops-admin/config/**'
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
  # CTO clone push-audit guard, installed out-of-band at deploy time by
  # scripts/lib/setup-cto-clone-hooks.sh (PR #582). The generator IS tracked
  # (scripts/lib/cto-push-audit-guard.sh), but its rendered outputs are not:
  # the shared hooks dir scripts/lib/cto-git-hooks/ (holding a pre-push copy of
  # the guard) and the .cto-clone-hooks.gitconfig includeIf at the repo root.
  # Both are server-generated, reference absolute /opt/hydra/ paths, and are
  # never seeded from the repo — same "generator tracked, output server-owned"
  # pattern as plugins/*/dist/. #582 shipped the generator without these
  # excludes, so the pre-flight rsync --delete dry-run flagged them for
  # deletion on every PR after its deploy ran (tripped 2026-07-06 on PR #617).
  --exclude='scripts/lib/cto-git-hooks/'
  --exclude='.cto-clone-hooks.gitconfig'
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
  # an operator-authorized snapshot of retired outreach skills kept for "resurrect if needed").
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
  # Repos the agents clone for cross-repo work (muso-repos skill): core-backend,
  # H-DevOps, web-credits, plus per-branch worktrees — hundreds of thousands of
  # files, never tracked in hydra. `repos` sits directly under workspaces/ (not
  # per-agent), so this is workspaces/repos/, not workspaces/*/repos/. Left
  # unexcluded, the deploy would try to wipe them and the pre-flight gate's
  # deletion classifier chokes on the volume (~386K entries) and hangs the
  # single self-hosted CI runner for hours (2026-07-10).
  --exclude='workspaces/repos/'
)

# -------------------------------------------------------------------
# Guard: every skills-all/<skill>/config/ needs an explicit include pair
# -------------------------------------------------------------------
# The unanchored --exclude='config/' above swallows skills-all/*/config/
# unless a per-skill include pair precedes it. Forgetting the pair ships a
# skill without its config — a SILENT runtime failure, already hit twice
# (prod-log watchdog fail-closed every tick 2026-06-10; set-env gate
# configs never reached the server). Fail the deploy loudly at the source
# instead. muso-ops-admin is the named exception: its canonical config has
# deliberate server-side divergence (drifted tier2-approvers.txt + godmode
# allowlist) and must NOT be synced — see the rationale above the includes.
# rsync filter rules are first-match-wins, so an include AFTER the
# --exclude='config/' line is dead — check ordering, not mere presence.
cfg_exclude_idx=-1
cfg_idx=0
for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do
  [[ "$cfg_rule" == "--exclude=config/" ]] && cfg_exclude_idx="$cfg_idx" && break
  cfg_idx=$(( cfg_idx + 1 ))
done
[[ "$cfg_exclude_idx" -ge 0 ]] || fail "RSYNC_EXCLUDES no longer contains --exclude='config/' — the skills-all config guard needs updating"
for cfg_dir in "$HYDRA_ROOT"/skills-all/*/config; do
  [[ -d "$cfg_dir" ]] || continue
  cfg_skill="$(basename "$(dirname "$cfg_dir")")"
  cfg_include_idx=-1
  cfg_idx=0
  for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do
    [[ "$cfg_rule" == "--include=${cfg_skill}/config/" ]] && cfg_include_idx="$cfg_idx" && break
    cfg_idx=$(( cfg_idx + 1 ))
  done
  if (( cfg_include_idx < 0 || cfg_include_idx > cfg_exclude_idx )); then
    fail "skills-all/${cfg_skill}/config/ exists but RSYNC_EXCLUDES has no --include='${cfg_skill}/config/' pair BEFORE --exclude='config/' (rsync is first-match-wins) — the config would silently never reach the server (unanchored exclude gotcha, see PR #474). Add the include pair next to the existing ones."
  fi
done
# muso-ops-admin/config/ is a SELECTIVE include (the 3 repo-authoritative files
# above). The server-only tier2-godmode-allowlist.txt must stay protected from
# BOTH transfer and rsync --delete. Enforce that here so a future edit can't
# widen the include and ship/destroy the godmode allowlist:
#   - if the dir is included, '--exclude=muso-ops-admin/config/**' MUST be present
#     and ordered before '--exclude=config/' (rsync is first-match-wins), else the
#     server-only godmode file leaks into the sync;
#   - no rule may ever NAME tier2-godmode-allowlist.txt in an include.
if printf '%s\n' "${RSYNC_EXCLUDES[@]}" | grep -qFx -- "--include=muso-ops-admin/config/"; then
  oa_protect_idx=-1
  oa_idx=0
  for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do
    [[ "$cfg_rule" == "--exclude=muso-ops-admin/config/**" ]] && oa_protect_idx="$oa_idx" && break
    oa_idx=$(( oa_idx + 1 ))
  done
  if (( oa_protect_idx < 0 || oa_protect_idx > cfg_exclude_idx )); then
    fail "RSYNC_EXCLUDES includes muso-ops-admin/config/ but '--exclude=muso-ops-admin/config/**' is missing or not ordered before '--exclude=config/' — the server-only tier2-godmode-allowlist.txt would be synced and rsync --delete could destroy it. Restore the protective exclude."
  fi
  if printf '%s\n' "${RSYNC_EXCLUDES[@]}" | grep -qF -- "tier2-godmode-allowlist.txt"; then
    fail "RSYNC_EXCLUDES names tier2-godmode-allowlist.txt — it is server-only (absent from canonical) and must NEVER be synced. Remove it from the rsync rules."
  fi
fi
unset cfg_dir cfg_skill cfg_rule cfg_idx cfg_include_idx cfg_exclude_idx oa_idx oa_protect_idx

# Changed-file set since the server's last-deployed SHA, captured by Step 0's
# drift check for reuse by the Step 6 edge-restart gate. DEPLOY_DIFF_COMPUTED
# stays 0 when Step 0 is skipped (HYDRA_FORCE / HYDRA_SKIP_DRIFT_CHECK / first
# deploy / not-a-checkout), so the gate fails OPEN (restarts) rather than risk a
# stale gateway.
# shellcheck disable=SC2034  # consumed by sourced lib/edge-restart-gate.sh
DEPLOY_CHANGED_FILES=""
# shellcheck disable=SC2034  # consumed by sourced lib/edge-restart-gate.sh
DEPLOY_DIFF_COMPUTED=0

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
log "Step 0/8: Drift check (server vs last-deployed SHA)..."
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

  # Hand the intended-change set to the Step 6 restart gate (below). Only
  # set here — i.e. only when a valid baseline diff was actually computed — so an
  # early-returned/skipped drift check leaves the gate failing OPEN. Consumed by
  # gateway_restart_needed() in the (not-followed-without-`-x`) sourced lib, hence
  # the SC2034 suppressions.
  #
  # Fold in UNTRACKED-but-not-ignored files too: `git diff` lists only tracked
  # changes, but the deploy rsyncs the whole working tree, so a new untracked
  # gateway file (e.g. a not-yet-committed skills-all/ or workspaces/support/
  # file) would otherwise be pushed WITHOUT the gate seeing it → a wrongly
  # skipped edge restart → stale gateway. Including them keeps the gate
  # fail-open. (In CI the tree is a clean checkout, so this adds nothing there.)
  local untracked
  untracked=$(git -C "$HYDRA_ROOT" ls-files --others --exclude-standard 2>/dev/null || true)
  # shellcheck disable=SC2034
  DEPLOY_CHANGED_FILES=$(printf '%s\n%s\n' "$intended" "$untracked" | sed '/^$/d' | sort -u)
  # shellcheck disable=SC2034
  DEPLOY_DIFF_COMPUTED=1

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
log "Step 1/8: Validating config files..."

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
log "Step 2/8: Validating SOUL.md files..."
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
log "Step 3/8: Validating tool-deny-lists.yaml (deny lists can only grow)..."
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
log "Step 4a/8: Pre-flight drift check..."
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
  edited directly on node-8 (often by an operator or an agent) and are not in the
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
  log "Step 4b/8: Local sync (running on Node 8)..."
  rsync -a --delete \
    "${RSYNC_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$DEPLOY_PATH/"
  log "  Config synced locally to $DEPLOY_PATH/"
else
  log "Step 4b/8: Remote sync to Node 8 ($NODE8_IP)..."
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
#
# MAIN_ONLY_SKILLS: skills excluded from the edge/dev sync so a "main
# gateway only" boundary in a SKILL.md is enforced mechanically, not as
# prose (the muso CLI binary, env, and config exist only on main).
MAIN_ONLY_SKILLS=(muso-cli)
log "Step 4c/8: Syncing global skills to per-profile managed-skills dirs..."
if [[ -d "$HYDRA_ROOT/skills-all" ]]; then
  skills_rc=0
  for profile in main edge dev; do
    profile_config="/root/.openclaw-${profile}/openclaw.json"
    # Only sync for profiles that actually exist on this server.
    [[ -f "$profile_config" ]] || continue
    profile_skills_dir="/root/.openclaw-${profile}/skills"
    mkdir -p "$profile_skills_dir"
    profile_skill_excludes=()
    if [[ "$profile" != "main" ]]; then
      for _mos in "${MAIN_ONLY_SKILLS[@]}"; do
        profile_skill_excludes+=(--exclude="/${_mos}/")
      done
    fi
    # RSYNC_EXCLUDES is passed to satisfy .githooks/pre-commit Check 2,
    # which enforces that every rsync call references the shared array.
    # None of the workspace/audit/plugin patterns in RSYNC_EXCLUDES match
    # anything inside skills-all/, so they're no-ops here — same rationale
    # as the install_plugin rsync. See the comment there for more detail.
    rsync -az --delete "${RSYNC_EXCLUDES[@]}" \
      ${profile_skill_excludes[@]+"${profile_skill_excludes[@]}"} \
      "$HYDRA_ROOT/skills-all/" "$profile_skills_dir/" || {
      skills_rc=$?
      fail "skills-all/ → $profile_skills_dir/ sync failed (rsync rc=$skills_rc)"
    }
    # rsync --delete PROTECTS excluded paths from deletion, so the exclude
    # alone never removes a copy that already landed (e.g. a skill later
    # reclassified as main-only). Purge explicitly on non-main profiles.
    if [[ "$profile" != "main" ]]; then
      for _mos in "${MAIN_ONLY_SKILLS[@]}"; do
        rm -rf "${profile_skills_dir:?}/${_mos}"
      done
    fi
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
log "Step 4c.5/8: Pinning openclaw runtime to ${OPENCLAW_VERSION}..."
if ! install_openclaw; then
  fail "openclaw runtime pin failed (target ${OPENCLAW_VERSION})"
fi
if ! OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist \
  bash "$HYDRA_ROOT/scripts/patch-openclaw-codex-native-compaction.sh"; then
  fail "Codex-native automatic compaction backport failed"
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
log "Step 4d/8: Installing plugins..."
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
#   - @openclaw/codex: a stale plugin under a newer runtime CAN reject
#     `openai/*` models so Codex-pinned agents fall back to Sonnet
#     (incident 2026-05-29 — runtime went 5.19->5.27 but the deploy
#     only pinned Slack, leaving the 5.19 Codex plugin behind).
#     NOTE: codex is currently a DELIBERATE exception to lockstep —
#     pinned to 2026.5.27 (below the 6.1 runtime) to dodge the #90925
#     route regression in @openclaw/codex@2026.6.x; verified it does
#     NOT reject models on the 6.1 core. See the OPENCLAW_CODEX_VERSION
#     block near the top of this file for the full rationale.
log "Step 4d.5/8: Pinning externalized plugins (slack=${OPENCLAW_SLACK_VERSION}, codex=${OPENCLAW_CODEX_VERSION})..."
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

# -------------------------------------------------------------------
# Step 4d.6: Pin the muso CLI (main + edge)
# -------------------------------------------------------------------
# muso is the admin-API/policy CLI. main-gateway agents use it (soak phase),
# and as of the Caroline self-serve work the EDGE gateway consumes it too: the
# support-tools gated-write tools (profiles_claim_self, credits_verify,
# profiles_consolidate) shell `muso <verb> --actor-identity` so muso-cli's
# capability gate (ownership re-verify + per-actor caps + audit) is load-bearing
# for Caroline. The binary is host-wide (/usr/local/bin/muso); pin it whenever
# main OR edge is targeted so an edge-only deploy still upgrades it. The edge
# process additionally needs MUSO_STATE_DIR + a muso login (see the edge env
# block) — without them the gated writes fail closed.
if needs_target "main" || needs_target "edge"; then
  log "Step 4d.6/8: Pinning muso CLI to ${MUSO_CLI_VERSION}..."
  if ! install_muso; then
    fail "muso CLI pin failed (target ${MUSO_CLI_VERSION})"
  fi
fi

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
log "Step 5a/8: Running post-sync setup..."

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
# muso_main_env_report + its dependency muso_main_env_missing are sourced into
# the PARENT shell (top of file) but used inside this heredoc's child bash — so
# they MUST be exported too, or the call command-not-founds in the child and the
# main.env validation silently no-ops (this was the true root of the spurious
# "main.env is missing: systemd-run failed" WARN — the function never ran).
export -f fail log notify_slack needs_target muso_main_env_report muso_main_env_missing

bash << 'POSTSYNC'
set -euo pipefail

# Ensure GOG_KEYRING_PASSWORD is set for gog CLI
if ! grep -q "GOG_KEYRING_PASSWORD" /root/.bashrc 2>/dev/null; then
  GOG_PW=$(kubectl get secret -n hydra hydra-service-tokens -o jsonpath='{.data.GOG_KEYRING_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -n "$GOG_PW" ]; then
    echo "export GOG_KEYRING_PASSWORD='${GOG_PW}'" >> /root/.bashrc
    echo "  GOG keyring password set in .bashrc"
  fi
fi

# Guard: ensure both production and dev admin credentials are present in the
# main profile env file. MUSO_ADMIN_EMAIL/PASSWORD remain required by legacy
# wrappers; muso-cli v0.11+ uses MUSO_PROD_ADMIN_* for prod and requires
# MUSO_DEV_ADMIN_* for dev. Without the dev pair, `muso --env dev` fails closed
# instead of sending prod credentials to dev. These vars live in
# /etc/openclaw/main.env (loaded as systemd
# EnvironmentFile by openclaw-gateway-main.service) and are NOT in ~/.zshrc
# — the daemon does not source an interactive shell. Warn loudly on drift so
# a future main.env regeneration can't silently break the ops agent again.
# Note: warn-only (not fail-fast) because creds are manually provisioned;
# failing here would block deploys on new hosts where main.env doesn't exist
# yet.
if needs_target "main"; then
  MAIN_ENV="/etc/openclaw/main.env"
  if [ -f "$MAIN_ENV" ]; then
    # Ask systemd to parse EnvironmentFile with the same quoting,
    # duplicate-key (last assignment wins), and empty-value semantics the
    # gateway uses. Never `source` a systemd env file as shell code.
    while IFS= read -r line; do
      [[ -n "$line" ]] && log "$line"
    done < <(muso_main_env_report "$MAIN_ENV")
  else
    log "WARN: $MAIN_ENV does not exist — ops agent will start with no admin credentials."
    log "WARN: create it, add legacy MUSO_ADMIN_EMAIL/PASSWORD plus scoped MUSO_PROD_ADMIN_EMAIL/PASSWORD,"
    log "WARN: and a separate dev MUSO_DEV_ADMIN_EMAIL/PASSWORD pair (never reuse the prod password),"
    log "WARN: plus the muso CLI vars (MUSO_ENV=prod, MUSO_NONINTERACTIVE=1, MUSO_STATE_DIR=/var/log/muso-ops"
    log "WARN: — see docs/runbooks/RUNBOOK.md, 'muso CLI (main gateway)'), then:"
    log "WARN:   systemctl restart openclaw-gateway-main"
  fi
fi

# Edge gateway muso CLI env (Caroline self-serve). The edge support-tools
# gated-write tools (profiles_claim_self / credits_verify / profiles_consolidate)
# shell `muso <verb> --actor-identity`, so the edge process needs the same muso
# runtime env as main. The binary is host-wide; when edge runs as the same OS
# user as main, the muso login/config (/root/.config/muso) and the audit+caps
# state (/var/log/muso-ops) are SHARED — MUSO_STATE_DIR must point at that same
# dir so PR1's per-actor flock + day caps enforce ACROSS the main and edge
# processes (the flock is cross-process). Warn-only, like the main block: creds
# are manually provisioned, and failing would block deploys on fresh hosts.
if needs_target "edge"; then
  EDGE_ENV="/etc/openclaw/edge.env"
  if [ -f "$EDGE_ENV" ]; then
    edge_missing=()
    grep -qE "^MUSO_ADMIN_EMAIL=.+"    "$EDGE_ENV" || edge_missing+=(MUSO_ADMIN_EMAIL)
    grep -qE "^MUSO_ADMIN_PASSWORD=.+" "$EDGE_ENV" || edge_missing+=(MUSO_ADMIN_PASSWORD)
    grep -qE "^MUSO_ENV=prod$"          "$EDGE_ENV" || edge_missing+=("MUSO_ENV=prod")
    grep -qE "^MUSO_NONINTERACTIVE=1$"  "$EDGE_ENV" || edge_missing+=("MUSO_NONINTERACTIVE=1")
    grep -qE "^MUSO_STATE_DIR=/var/log/muso-ops$" "$EDGE_ENV" || edge_missing+=("MUSO_STATE_DIR=/var/log/muso-ops")
    grep -qE "^MUSO_REQUESTER=.+"       "$EDGE_ENV" || edge_missing+=("MUSO_REQUESTER (e.g. caroline@muso.ai)")
    grep -qE "^MUSO_CAPABILITY_APPROVER=.+" "$EDGE_ENV" || edge_missing+=("MUSO_CAPABILITY_APPROVER (required by profiles_consolidate)")
    if (( ${#edge_missing[@]} > 0 )); then
      log "WARN: $EDGE_ENV is missing: ${edge_missing[*]}"
      log "WARN: Caroline's gated muso writes fail closed until these are added (the tools are dark-shipped OFF regardless)."
      log "WARN: also confirm the edge gateway user shares the muso login (/root/.config/muso) and can write /var/log/muso-ops."
      log "WARN: fix with:  sudo vim $EDGE_ENV  &&  systemctl restart openclaw-gateway-edge"
    fi
  else
    log "WARN: $EDGE_ENV does not exist — Caroline's gated muso writes will fail closed."
  fi
fi

# Guard: each gateway MUST pin OPENCLAW_STATE_DIR to its OWN profile state dir.
# The openclaw daemon resolves the model-invocable "managed" skills tier via a
# profile-BLIND resolveStateDir(process.env): with the var unset it defaults to
# the legacy /root/.openclaw and injects that frozen skill catalog into EVERY
# agent — so every skill added since #336 silently vanishes from agents' invokable
# set (the `openclaw --profile X skills list` CLI hides it, because the CLI —
# unlike the long-running daemon — actually gets --profile). Root-caused
# 2026-06-29: CMO could not invoke muso-streams-lookup / the ship-kit because its
# catalog was the stale May-26 set. FAIL-LOUD (unlike the manual-cred blocks
# above) — the value is deterministic and non-secret and a missing one breaks the
# whole fleet's skills; file-absent => warn only (fresh-host bootstrap).
#
# Per-profile env ONLY — never shared.env, which BOTH gateways load (a value there
# would force them onto a single state dir).
if grep -qE '^OPENCLAW_STATE_DIR=' /etc/openclaw/shared.env 2>/dev/null; then
  fail "OPENCLAW_STATE_DIR is set in /etc/openclaw/shared.env — both gateways load it, forcing them onto one state dir. Remove it there and pin per-profile: main.env=/root/.openclaw-main, edge.env=/root/.openclaw-edge."
fi
check_statedir_pin() {
  local profile="$1"
  local envf="/etc/openclaw/${profile}.env"
  local want="OPENCLAW_STATE_DIR=/root/.openclaw-${profile}"
  if [ ! -f "$envf" ]; then
    log "WARN: $envf does not exist — cannot verify OPENCLAW_STATE_DIR (fresh host?)."
    return 0
  fi
  if ! grep -Fxq "$want" "$envf"; then
    log "✗ $envf does not pin '$want'."
    log "  Without it the $profile gateway injects the STALE /root/.openclaw/skills catalog"
    log "  into every agent — recently-added skills and the ship-kit go missing."
    log "  fix:  echo '$want' >> $envf  &&  systemctl restart openclaw-gateway-$profile"
    fail "OPENCLAW_STATE_DIR not pinned in $envf (expected $want) — refusing to ship a stale-skill-catalog gateway."
  fi
  log "  ✓ $envf pins $want"
}
if needs_target "main"; then check_statedir_pin main; fi
if needs_target "edge"; then check_statedir_pin edge; fi

# muso CLI host config (main profile only; soak phase). Files are RENDERED
# on every deploy from the OPERATIONS WORKSPACE muso-ops-admin config — the
# same files muso-admin-api.sh resolves at runtime (TIER2_APPROVERS_PATH=
# ${SCRIPT_DIR}/../config/, and ops runs the workspace script copy) — so
# muso and the bash wrapper always enforce the IDENTICAL approver/bulk
# policy. NOTE: that config dir is server-owned live policy, deliberately
# NOT synced from git (see the muso-ops-admin exception in the config-
# include guard above) — editing the repo copies does NOT change it.
#   approvers.txt    <- workspaces/operations/skills/muso-ops-admin/config/tier2-approvers.txt
#   bulk-exclude.txt <- workspaces/operations/skills/muso-ops-admin/config/bulk-destructive-exclude.txt
#   config.json      <- prewrite_hook wiring: muso execs
#                       scripts/muso-prewrite-hook.sh (the same
#                       codex-health probe muso-admin-api.sh embeds)
#                       before every write, fail-closed.
# Runtime env (MUSO_ENV etc.) deliberately lives in main.env, NOT here:
# the gateway loads env only from its systemd EnvironmentFile.
if needs_target "main"; then
  MUSO_CFG_DIR="/root/.config/muso"
  MUSO_OPS_CFG="$DEPLOY_PATH/workspaces/operations/skills/muso-ops-admin/config"
  if [ -r "$MUSO_OPS_CFG/tier2-approvers.txt" ] && [ -r "$MUSO_OPS_CFG/bulk-destructive-exclude.txt" ]; then
    install -d -m 700 "$MUSO_CFG_DIR"
    install -m 600 "$MUSO_OPS_CFG/tier2-approvers.txt" "$MUSO_CFG_DIR/approvers.txt"
    install -m 600 "$MUSO_OPS_CFG/bulk-destructive-exclude.txt" "$MUSO_CFG_DIR/bulk-exclude.txt"
    # Scoped capability-approver allowlist (muso-cli v0.6.1+): the autonomous
    # service approver (caroline-autonomous) is valid ONLY for the capability
    # verbs (credits verify / profiles consolidate / claim-self), never the
    # global tier-2 approvers.txt above. Rendered separately so it can be absent
    # without skipping the human approver render; if missing, those capability
    # writes fail closed in muso-cli.
    if [ -r "$MUSO_OPS_CFG/capability-approvers.txt" ]; then
      install -m 600 "$MUSO_OPS_CFG/capability-approvers.txt" "$MUSO_CFG_DIR/capability-approvers.txt"
    else
      log "WARN: $MUSO_OPS_CFG/capability-approvers.txt missing — Caroline's approval-tier capability writes (credits_verify, profiles_consolidate) fail closed until it is rendered."
    fi
    printf '{\n  "prewrite_hook": "%s/scripts/muso-prewrite-hook.sh"\n}\n' "$DEPLOY_PATH" > "$MUSO_CFG_DIR/config.json"
    chmod 600 "$MUSO_CFG_DIR/config.json"
    log "  muso config rendered into $MUSO_CFG_DIR (source: operations workspace muso-ops-admin config)"
  else
    log "WARN: $MUSO_OPS_CFG is missing tier2-approvers.txt and/or bulk-destructive-exclude.txt —"
    log "WARN: muso approval/bulk gates fail closed until the config is rendered (render skipped, deploy continues)."
  fi

  # Smoke (warn-only: prod API health is not this deploy's fault; bounded so
  # a hung admin API cannot stall the deploy).
  if command -v muso >/dev/null 2>&1; then
    if timeout 10 muso health --env prod >/dev/null 2>&1; then
      log "  muso health (prod): OK"
    else
      log "WARN: 'muso health --env prod' failed — admin API unreachable or muso misconfigured"
    fi
  fi
fi

# Note: mention gate patch (patch-openclaw-mention-gate.sh) removed — no longer needed on OpenClaw 2026.4.2+

# Sync cron jobs from repo to the main profile data dir (preserve live state).
#
# IMPORTANT (openclaw 2026.6.1+): cron persistence moved to SQLite. The
# gateway loads crons ONLY from the `cron_jobs` table in the per-profile
# store at /root/.openclaw-main/state/openclaw.sqlite — keyed by store_key
# `/root/.openclaw-main/cron/jobs.json`. It does NOT read cron/jobs.json at
# runtime on 6.x. The one-shot jobs.json -> SQLite import is `doctor --fix`-
# gated, and hydra NEVER runs `doctor --fix` (it fans out into codex-auth/
# voice/transcript migrations we forbid), so jobs.json is a DEAD runtime
# path between deploys. Writing only jobs.json (the pre-6.x behavior) left
# the gateway loading 0 of 22 crons after the Step 6 restart and FATAL'd
# the smoke test (cron count mismatch, 2026-06-16 P0). We therefore treat
# jobs.json as the human-editable SOURCE and explicitly import it into the
# SQLite cron_jobs store via the openclaw SDK below (BEFORE the restart).
#
# `/root/.openclaw-main/cron/jobs.json` remains the canonical store_key
# (the path resolveCronStorePath() returns and the gateway reports as
# storePath); it just isn't a runtime-read FILE anymore — it's the SQLite
# store identity.
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

# Import the synced jobs.json into the SQLite cron_jobs store (openclaw
# 2026.6.1+). This is the step that actually makes the gateway load crons:
# on 6.x jobs.json is no longer read at runtime (see the block comment
# above), so without this import the Step 6 restart loads 0 crons and the
# smoke test FATALs. We import via openclaw's own SDK (saveCronStore ->
# replaceCronRows), which is the exact SQLite write `doctor --fix` performs
# but scoped to cron ONLY — no codex-auth/voice/transcript fanout (the very
# reason hydra forbids `doctor --fix`).
#
# Idempotent by construction: replaceCronRows deletes every row for this
# store_key then re-inserts the repo set, so re-running converges to exactly
# the 22 repo jobs with zero duplicates. Safe to run unconditionally on
# every deploy; do NOT add a skip-if-already-imported guard.
#
# We import the UNFILTERED 22 jobs (11 enabled + 11 disabled). The SDK
# round-trips `enabled` faithfully and the scheduler simply skips disabled
# rows at arm time — identical to pre-6.x jobs.json semantics. Pre-filtering
# to the 11 enabled would drop the disabled definitions and break the
# smoke-test count (which compares against all 22).
#
# Only the `main` store matters at runtime: the gateway runs profile main
# and reads store_key /root/.openclaw-main/cron/jobs.json. The legacy
# /root/.openclaw mirror is runtime-dead and is NOT imported.
if [ -f "$HYDRA_ROOT/cron-jobs.json" ] && needs_target "main"; then
  LIVE_CRON="/root/.openclaw-main/cron/jobs.json"

  # Resolve the openclaw global dist the path-independent way (mirrors the
  # PR #537 `plugins list --json` fix: never hardcode a runtime layout path).
  # openclaw 2026.6.1 is installed GLOBALLY; Node's ESM resolver does NOT
  # search the global npm root for a bare `openclaw/...` specifier and
  # IGNORES NODE_PATH, so the import MUST use the ABSOLUTE dist path
  # (verified live on node-8: a bare specifier -> ERR_MODULE_NOT_FOUND).
  GLOBAL_NODE_MODULES=$(npm root -g 2>/dev/null) || fail "cron SQLite import: 'npm root -g' failed — cannot locate openclaw global install"
  CRON_SDK="$GLOBAL_NODE_MODULES/openclaw/dist/plugin-sdk/cron-store-runtime.js"
  if [ ! -f "$CRON_SDK" ]; then
    fail "cron SQLite import: openclaw cron-store SDK not found at $CRON_SDK (global node_modules: ${GLOBAL_NODE_MODULES:-<empty>}) — openclaw layout changed; mirror PR #537's path-independent discovery"
  fi

  # --- Store-only cron guard: fail-loud BEFORE the destructive import ---
  # saveCronStore below is delete-by-store_key + re-insert, so any cron in the
  # live SQLite store but absent from cron-jobs.json is WIPED. The jobs.json
  # orphan guard above cannot catch these: it reads the stale cron/jobs.json,
  # which the 7.x runtime never writes to, so a cron created directly on the
  # gateway (`openclaw cron add`) is invisible to it and silently lost
  # (incident 2026-07-16: Aaron's ChartMogul MRR/SaaS crons, PR #702). Read the
  # REAL store via loadCronStore and halt if it holds a durable (recurring,
  # non-ephemeral) cron the repo doesn't declare. Halting here (before the
  # import, before the Step 6 restart) leaves the live cron running until an
  # operator commits it or sets HYDRA_ALLOW_ORPHAN_CRON=1 to drop it.
  STORE_DUMP=$(mktemp) || fail "store-only cron guard: mktemp failed"
  DUMP_RC=0
  DUMP_ERR=$(OPENCLAW_STATE_DIR=/root/.openclaw-main CRON_SDK="$CRON_SDK" STORE_DUMP="$STORE_DUMP" \
    node --input-type=module -e '
      import { writeFileSync } from "node:fs";
      try {
        const m = await import(process.env.CRON_SDK);
        const cur = await m.loadCronStore(m.resolveCronStorePath());
        writeFileSync(process.env.STORE_DUMP, JSON.stringify(cur));
        process.exit(0);
      } catch (e) { console.error(e); process.exit(1); }
    ' 2>&1) || DUMP_RC=$?
  if (( DUMP_RC != 0 )); then
    rm -f "$STORE_DUMP"
    log "  ✗ store-only cron guard: loadCronStore read failed (rc=$DUMP_RC):"
    echo "$DUMP_ERR" | sed 's/^/        /'
    fail "store-only cron guard: could not read the live cron store to check for uncommitted crons"
  fi
  if ! python3 "$HYDRA_ROOT/scripts/lib/detect-store-only-crons.py" "$HYDRA_ROOT/cron-jobs.json" "$STORE_DUMP"; then
    rm -f "$STORE_DUMP"
    fail "store-only cron guard: the live cron store holds recurring cron(s) not in cron-jobs.json (see above). Commit them, or set HYDRA_ALLOW_ORPHAN_CRON=1 to drop them."
  fi
  rm -f "$STORE_DUMP"
  # --- end store-only cron guard ---

  # Re-install jobs.json if the RUNNING gateway migrated it out from under us
  # since the cron-sync block above wrote it. openclaw 7.x performs a one-shot
  # jobs.json -> SQLite migration of its own on any read/write of the profile
  # cron dir, and renames the file to jobs.json.migrated.N as it goes
  # (incident 2026-07-22, deploy run 29935762439: FATAL "cron SQLite import
  # failed ... ENOENT ... jobs.json", with a .migrated.37 file timestamped at
  # the exact deploy minute). Most deploys win this race; this loses cleanly
  # by just re-writing the file we already have in hand.
  if [ ! -f "$LIVE_CRON" ]; then
    log "  gateway migrated jobs.json out from under the sync (7.x jobs.json->SQLite migration); re-installing from repo"
    install -m 600 "$HYDRA_ROOT/cron-jobs.json" "$LIVE_CRON" || fail "failed to re-install cron-jobs.json to $LIVE_CRON after migration race"
  fi

  # OPENCLAW_STATE_DIR (NOT OPENCLAW_PROFILE — the SDK resolver ignores it)
  # makes resolveCronStorePath() return /root/.openclaw-main/cron/jobs.json,
  # which is the exact store_key the gateway uses. The node one-liner reads
  # the jobs from the file we just wrote, writes the SQLite rows, then
  # re-loads and prints the persisted count so we can verify the row count
  # below. Fail-loud: the whole body runs inside an explicit try/catch that
  # prints the error and process.exit(1) on any failure (mirrors the
  # dist/index.js load-check at the top of this file); a non-zero node exit
  # chains to `fail` (which fires notify_slack). The explicit exit(1) avoids
  # relying on Node's unhandled-rejection exit semantics.
  #
  # Bounded retry: the migration race above can also land BETWEEN the
  # pre-check just above and this import actually opening the file (same
  # incident — the window is short but real). If the import fails with
  # ENOENT for $LIVE_CRON, re-install once and retry; a second failure falls
  # through to the existing FATAL path unchanged. Safe because the import is
  # idempotent by construction (replaceCronRows delete+re-insert — see
  # comment above).
  IMPORT_ATTEMPT=1
  while :; do
    IMPORT_RC=0
    IMPORT_OUT=$(OPENCLAW_STATE_DIR=/root/.openclaw-main CRON_SDK="$CRON_SDK" LIVE_CRON="$LIVE_CRON" \
      node --input-type=module -e '
        import { readFileSync } from "node:fs";
        try {
          const m = await import(process.env.CRON_SDK);
          const store = JSON.parse(readFileSync(process.env.LIVE_CRON, "utf8"));
          const target = m.resolveCronStorePath();
          // saveCronStore/loadCronStore are ASYNC (the SDK wrappers return a
          // promise even though the underlying SQLite transaction is sync) —
          // they MUST be awaited, else process.exit(0) below fires before the
          // write commits and the store is left empty (verified on node-8:
          // un-awaited -> persisted:0; awaited -> persisted:22).
          await m.saveCronStore(target, store);        // delete-by-store_key + re-insert
          const back = await m.loadCronStore(target);  // read-back from SQLite to verify persistence
          console.log(JSON.stringify({ target, persisted: (back.jobs || []).length }));
          process.exit(0);
        } catch (e) {
          console.error(e);
          process.exit(1);
        }
      ' 2>&1) || IMPORT_RC=$?
    if (( IMPORT_RC == 0 )); then
      break
    fi
    if (( IMPORT_ATTEMPT == 1 )) && echo "$IMPORT_OUT" | grep -qF "ENOENT" && echo "$IMPORT_OUT" | grep -qF "$LIVE_CRON"; then
      log "  cron SQLite import hit ENOENT for $LIVE_CRON (gateway migration race) — re-installing from repo and retrying once"
      install -m 600 "$HYDRA_ROOT/cron-jobs.json" "$LIVE_CRON" || fail "failed to re-install cron-jobs.json to $LIVE_CRON for retry"
      IMPORT_ATTEMPT=2
      continue
    fi
    break
  done
  if (( IMPORT_RC != 0 )); then
    # Surface the node error body indented, like install_external_plugin,
    # then fail loud (fail -> notify_slack -> exit 1).
    log "  ✗ cron SQLite import failed for /root/.openclaw-main (jobs.json -> cron_jobs, rc=$IMPORT_RC):"
    echo "$IMPORT_OUT" | sed 's/^/        /'
    fail "cron SQLite import failed for /root/.openclaw-main — gateway would load 0 crons after restart"
  fi

  # Trust the round-trip, not the exit code: verify the SQLite store now
  # holds exactly the repo job set. A successful save that persisted a
  # different count would otherwise silently ship a wrong cron table.
  EXPECTED_JOBS=$(jq '.jobs | length' "$HYDRA_ROOT/cron-jobs.json") \
    || fail "cron SQLite import: could not count repo jobs in $HYDRA_ROOT/cron-jobs.json"
  PERSISTED_JOBS=$(echo "$IMPORT_OUT" | jq -r '.persisted' 2>/dev/null) || PERSISTED_JOBS=""
  if [ "$PERSISTED_JOBS" != "$EXPECTED_JOBS" ]; then
    fail "cron SQLite import: store persisted ${PERSISTED_JOBS:-<unparseable>} jobs, expected $EXPECTED_JOBS (import output: $IMPORT_OUT)"
  fi
  log "  Imported $PERSISTED_JOBS cron jobs into the SQLite cron_jobs store (store_key /root/.openclaw-main/cron/jobs.json)"
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
log "Step 5b/8: Applying k8s manifests..."
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
  log "Step 5c/8: Installing/refreshing aux systemd units..."
  if [ -x "$DEPLOY_PATH/scripts/install-aux-units.sh" ]; then
    "$DEPLOY_PATH/scripts/install-aux-units.sh" "$DEPLOY_PATH" \
      || fail "install-aux-units.sh failed — see preceding output"
    log "  Aux units installed/refreshed."
  else
    log "  install-aux-units.sh missing or not executable — skipping (laptop deploy?)"
  fi
else
  log "Step 5c/8: skipping aux-units install (not running on node-8)"
fi

# -------------------------------------------------------------------
# Step 6: Restart targeted gateway(s) — drain-aware
# -------------------------------------------------------------------
# The gateway restart is DRAIN-AWARE: we ask the running gateway to finish its
# active work (in-flight LLM turns, pending reply deliveries, queued turns)
# via `openclaw gateway restart --safe` and await the self-restart, so a
# deploy no longer hard-kills Caroline mid-answer or an agent mid-task. Any
# safe-path failure falls back LOUDLY (Slack) to the old `systemctl restart`.
# Mechanics + live-probe evidence: scripts/lib/gateway-restart.sh.
# Escape hatches: HYDRA_HARD_RESTART=1 skips the drain (immediate hard
# restart, the pre-drain behavior); HYDRA_FORCE_RESTART=1 overrides the
# restart-skip gate below (they compose).
log "Step 6/8: Restarting OpenClaw Gateway ($TARGET)..."
# shellcheck source=lib/gateway-restart.sh
source "$SCRIPT_DIR/lib/gateway-restart.sh"
export GATEWAY_EXEC_FN=run_on_node8   # every probe honors $HYDRA_LOCAL (ssh mode too)

# Verify the daemon actually picked up its profile state dir. env-file vars
# appear in /proc/<pid>/environ (unlike the runtime-set OPENCLAW_PROFILE), so
# this gates the exact regression that hid for a month: a gateway whose
# profile-blind resolveStateDir() falls back to the stale /root/.openclaw
# skills catalog. Profile (main/edge) is the last dash-segment of the unit.
verify_gateway_env_pin() {
  local service="$1"
  local profile="${service##*-}"
  local want="OPENCLAW_STATE_DIR=/root/.openclaw-${profile}"
  local vcmd="pid=\$(systemctl show -p MainPID --value $service); tr '\\0' '\\n' < /proc/\$pid/environ | grep -Fxq '$want'"
  run_on_node8 "$vcmd" || fail "$service is active but its process env lacks '$want' — its daemon would inject the STALE /root/.openclaw/skills catalog into EVERY agent. Pin it in /etc/openclaw/${profile}.env (NOT shared.env) and restart."
  log "  ✓ $service process env pins $want"
}

# Phase B of the drain: await the requested self-restart; fall back to a hard
# restart on any failure (deploys must always converge — the drain is an
# optimization, never a gate). Fallbacks Slack-notify so a permanently broken
# safe path can't silently degrade to hard-kill-on-every-deploy.
finish_gateway_restart() {
  local service="$1" old_pid="$2" req_rc="$3"
  case "$req_rc" in
    0)
      if await_gateway_restart "$service" "$old_pid"; then
        verify_gateway_env_pin "$service"
        return 0
      fi
      log "  WARN: drain did not complete for $service — falling back to hard restart"
      notify_slack ":warning: HYDRA deploy: drain-aware restart fell back to HARD restart for $service (active work didn't drain within ${GATEWAY_DRAIN_DEADLINE_SECS:-390}s — in-flight turns may be cut)"
      ;;
    2)
      log "  HYDRA_HARD_RESTART=1 — skipping drain for $service" ;;
    3)
      log "  WARN: no verified pre-request MainPID for $service — a drain result would be unverifiable; hard restart"
      notify_slack ":warning: HYDRA deploy: could not capture a pre-request MainPID for $service — hard restart without drain (in-flight turns may be cut)."
      ;;
    *)
      log "  WARN: safe-restart request failed for $service (rc=$req_rc) — falling back to hard restart"
      notify_slack ":warning: HYDRA deploy: safe-restart request FAILED for $service (rc=$req_rc) — hard restart fallback. If this repeats every deploy, the drain path is broken (see scripts/lib/gateway-restart.sh)."
      ;;
  esac
  hard_restart_gateway "$service" || fail "Failed to restart $service (hard fallback)"
  verify_gateway_env_pin "$service"
}

# gateway_restart_needed(): skip a gateway restart when a deploy provably changed
# nothing that gateway loads (every restart costs ~12-30s of agent rebind, and on
# edge it also pauses the memory_search index — so a needless restart is churn).
# Applies to BOTH main and edge. Strictly fail-open — see the lib header. Reads
# DEPLOY_DIFF_COMPUTED / DEPLOY_CHANGED_FILES (set by Step 0's drift check) +
# HYDRA_FORCE / HYDRA_FORCE_RESTART.
# shellcheck source=lib/edge-restart-gate.sh
source "$SCRIPT_DIR/lib/edge-restart-gate.sh"

if gateway_restart_needed; then
  # Phase A: request the safe restarts up front (each request returns in ~3s;
  # the gateways then drain CONCURRENTLY, so worst-case wall time is one drain
  # budget, not one per gateway). Phase B verifies serially.
  main_old_pid="" main_req="" edge_old_pid="" edge_req=""
  if needs_target "main"; then
    main_old_pid=$(gateway_main_pid "openclaw-gateway-main") || main_old_pid=""
    if [ -z "$main_old_pid" ] || [ "$main_old_pid" = "0" ]; then
      main_req=3   # no verified baseline PID -> drain unverifiable, fail closed
    else
      main_req=0; request_safe_restart "openclaw-gateway-main" "main" || main_req=$?
    fi
  fi
  if needs_target "edge"; then
    edge_old_pid=$(gateway_main_pid "openclaw-gateway-edge") || edge_old_pid=""
    if [ -z "$edge_old_pid" ] || [ "$edge_old_pid" = "0" ]; then
      edge_req=3   # no verified baseline PID -> drain unverifiable, fail closed
    else
      edge_req=0; request_safe_restart "openclaw-gateway-edge" "edge" || edge_req=$?
    fi
  fi
  if needs_target "main"; then finish_gateway_restart "openclaw-gateway-main" "$main_old_pid" "$main_req"; fi
  if needs_target "edge"; then finish_gateway_restart "openclaw-gateway-edge" "$edge_old_pid" "$edge_req"; fi
else
  for svc_profile in main edge; do
    if needs_target "$svc_profile"; then
      log "  Skipping $svc_profile gateway restart: only gateway-inert files (docs/CI/personas/tests/templates/root-docs) changed since last deploy — nothing it loads. Override: HYDRA_FORCE_RESTART=1."
    fi
  done
fi

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
log "Step 7/8: Running smoke test..."
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
# Post-flight: rebuild Caroline's RAG vector index (edge/support)
# -------------------------------------------------------------------
# openclaw PAUSES the memory_search vector index on every runtime
# version bump (reference: memory-index-pause-after-upgrade). A paused
# index returns NOTHING from retrieval, and the mandatory pre-retrieval
# RAG hook (plugins/intercom) depends on it being live, so Caroline
# would answer ungrounded. Force a rebuild here: AFTER the workspaces/
# rsync (so the index covers the just-shipped knowledge base) and BEFORE
# the RAG smoke test below (so the smoke test validates a fresh index,
# not a stale/paused one). Non-fatal but LOUD: a transient reindex hiccup
# must not abort the whole deploy, but it must never pass silently
# either -- the RAG smoke test that follows is the backstop that fails
# the post-flight if the index is still broken.
if needs_target "edge"; then
  # shellcheck source=lib/reindex-verify-retry.sh
  source "$SCRIPT_DIR/lib/reindex-verify-retry.sh"
  log "Post-flight: rebuilding + verifying Caroline RAG index (edge/support)..."
  # Force a rebuild, then VERIFY the index didn't lose the busy-gateway race and
  # re-pause, retrying once if it did. A bare --force here re-paused the index in
  # PR #618's live verify (2026-07-01), leaving retrieval ungrounded until the
  # 10-min watchdog. reindex_verify_retry time-boxes each heal (rc=124 on a hang,
  # never an indefinite stall) and returns non-zero only if the index is STILL
  # paused after the retry (edge heals via `index --force`; HEAL_CMD derives from
  # the profile). Non-fatal but LOUD: the RAG smoke test below is the
  # authoritative backstop.
  if reindex_verify_retry edge support; then
    log "  Caroline RAG index rebuilt and grounded."
  else
    log "  WARNING: Caroline RAG index still paused after rebuild + retry. Continuing deploy; the 10-min watchdog will heal it and the RAG smoke test below will catch a still-broken index."
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
      curl -s -X POST -H "Content-type: application/json" \
        --data "{\"text\":\":warning: Caroline RAG index still paused after post-deploy rebuild + retry. Run: ssh hydra openclaw --profile edge memory index --force --agent support ; then openclaw --profile edge memory status --agent support --deep\"}" \
        "$SLACK_WEBHOOK" >/dev/null || true
    fi
  fi
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
# Post-flight: rebuild + verify Caroline RAG index (main / reference agents)
# -------------------------------------------------------------------
# The main gateway's memorySearch agents (cmo/cto/finance/ceo/operations) carry
# reference/ RAG corpora that ALSO pause on the deploy restart. Uses the SAME
# shared verify+retry helper as edge, but main heals via `status --index` (its
# pause is an IDENTITY-METADATA pause that `index --force` "completes" but does
# NOT clear; `status --index` resets the metadata and actually clears it --
# operator-confirmed 2026-07-01; HEAL_CMD derives from PROFILE=main). devops has
# no reference/ dir, so its heal is a harmless no-op (kept to match the operator's
# validated stopgap loop). Non-fatal but LOUD: the main RAG smoke test below is
# the backstop.
if needs_target "main"; then
  # shellcheck source=lib/reindex-verify-retry.sh
  source "$SCRIPT_DIR/lib/reindex-verify-retry.sh"
  main_reindex_failed=""
  # Reference-bearing main agents. KEEP IN LOCKSTEP with the watchdog's
  # CAROLINE_RAG_HEAL_AGENTS list in scripts/install-aux-units.sh -- a new
  # main agent with a reference/ corpus must be added to BOTH or the
  # deploy-time reindex and the between-deploy watchdog diverge.
  for main_agent in cmo cto finance ceo operations devops; do
    log "Post-flight: rebuilding + verifying Caroline RAG index (main/$main_agent)..."
    # reindex_verify_retry time-boxes each heal (rc=124 on hang -> WARNING path),
    # verifies the index is grounded, and retries once. Returns non-zero only if
    # STILL paused after the retry.
    if reindex_verify_retry main "$main_agent"; then
      log "  main/$main_agent index rebuilt and grounded."
    else
      log "  WARNING: main/$main_agent still paused after rebuild + retry."
      main_reindex_failed="$main_reindex_failed $main_agent"
    fi
  done
  if [ -n "$main_reindex_failed" ] && [ -n "${SLACK_WEBHOOK:-}" ]; then
    curl -s -X POST -H "Content-type: application/json" \
      --data "{\"text\":\":warning: Caroline RAG main index still paused after post-deploy rebuild + retry for:${main_reindex_failed}. Run: ssh hydra 'for a in${main_reindex_failed}; do openclaw --profile main memory status --index --agent \$a; done'\"}" \
      "$SLACK_WEBHOOK" >/dev/null || true
  fi
fi

# -------------------------------------------------------------------
# Post-flight: Caroline RAG smoke test (main / cmo canary, non-fatal)
# -------------------------------------------------------------------
# Verifies the main rebuild above actually cleared the pause. cmo is the canary --
# a restart pauses all main agents' indexes together, so one grounded agent
# confirms the profile. A still-paused main index -> Slack, not a blocked deploy.
if needs_target "main" && [ -x "$SCRIPT_DIR/validate-caroline-rag.sh" ]; then
  log "Post-flight: Caroline RAG check (main/cmo canary)..."
  main_rag_rc=0
  PROFILE=main AGENT=cmo "$SCRIPT_DIR/validate-caroline-rag.sh" || main_rag_rc=$?
  if [ "$main_rag_rc" -eq 0 ]; then
    log "  Caroline RAG main check passed."
  else
    log "  Caroline RAG main check FAILED (rc=$main_rag_rc). Continuing deploy."
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
      curl -s -X POST -H "Content-type: application/json" \
        --data "{\"text\":\":warning: Caroline RAG main post-deploy check failed (rc=$main_rag_rc). Run: ssh hydra PROFILE=main AGENT=cmo ${DEPLOY_PATH}/scripts/validate-caroline-rag.sh\"}" \
        "$SLACK_WEBHOOK" >/dev/null || true
    fi
  fi
fi

# -------------------------------------------------------------------
# Step 8: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
# `git describe` prints either the current tag (`v2026.5.26`) or the most
# recent tag plus distance + sha (`v2026.5.26-3-gabc1234`). Bare commit-sha
# fallback for the pre-first-release window where no tags exist yet.
RELEASE_REF=$(git -C "$HYDRA_ROOT" describe --tags --always 2>/dev/null || echo "$COMMIT_SHA")
log "Step 8/8: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully (target: $TARGET). Release: $RELEASE_REF (sha: $COMMIT_SHA)"
log "Deploy complete. Target: $TARGET. Commit: $COMMIT_SHA"
