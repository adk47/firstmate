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
#     cd /opt/hydra && ./scripts/deploy.sh [--target main|edge|all] [--report-only]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

# Pinned openclaw runtime version. Updated together with this file so the
# version change appears in git history alongside any deploy-script tweaks
# the upgrade requires. Bump in lockstep with docs/guides/REPO-MANAGEMENT.md.
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.8.35}"

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
# shellcheck source=lib/deploy-mutation-marker.sh
source "$SCRIPT_DIR/lib/deploy-mutation-marker.sh"

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
# 0.13.1 makes async capture acceptance verifiable for `tracks capture`,
# `tracks enrich`, and `profiles enrich` (muso-cli#44): the CLI now surfaces
# `accepted`, `captureId`, and `enqueued`, and refuses an empty 2xx response.
# The existing `status: requested` JSON contract stays backward-compatible.
# Verified before bumping: v0.13.1 resolves to #44's merge commit (6100a0e),
# the linux/amd64 asset matches checksums.txt, node-8 reports that exact version
# and commit, a prod track capture returned a non-empty receipt with enqueued=1,
# and an empty-2xx smoke exited 1 with no success output.
#
# 0.13.0 carries `profiles enrich --url --profile-id` (muso-cli#42), which
# skills-all/muso-ops-profiles now documents as the typed, audited path for
# attaching a source to a profile. It also still carries the `tracks sources`
# verb group from 0.11.1 (muso-cli#36) that skills-all/muso-ops-tracks
# documents. The pin and the skill must move together: with the pin behind,
# the skill documents verbs the installed CLI does not have.
#
# 0.11.1 -> 0.13.0 is three commits, all additive, no breaking change:
# muso-cli#39 (typed `collaborators list|rebuild`), #40 (`muso gh` group),
# #42 (`profiles enrich`). Verified against the release before bumping, in
# the order the lockstep rule requires: v0.13.0 contains #42's commit
# (afc3c15); it ships muso_linux_amd64.tar.gz with a matching checksums.txt
# entry (NOT muso-cli_linux_amd64.tar.gz, which install_muso does not use);
# credentials resolve; and the binary was run against prod from node-8 --
# `profiles get <uuid> --env prod --json` returned a real profile.
#
# Prod credentials still resolve — v0.11+ reads the scoped MUSO_PROD_ADMIN_*
# pair but keeps the generic MUSO_ADMIN_* as a production-only fallback
# (internal/auth/env.go), which is what node-8's main.env carries; only
# `--env dev` fails closed, and node-8 has no dev pair to begin with.
MUSO_CLI_VERSION="${MUSO_CLI_VERSION:-0.13.3}"

# FLOOR — the oldest muso the skills in THIS tree can actually run against.
# The default above is overrideable (`MUSO_CLI_VERSION=0.11.1 scripts/deploy.sh`),
# and without this guard that override installs 0.11.1, PASSES install_muso's
# post-install assertion (which only checks installed == requested), and then
# syncs a muso-github-code-review that dies at Step 1 with "unknown command".
# Ordering alone cannot prevent that — the CLI is correctly installed first, it
# is simply too old. Raise this whenever a skill starts calling a newer verb.
#
# 0.12.0 is the floor because skills-all/muso-github-code-review calls
# `muso gh review-bundle` from Step 1, and the `muso gh` group landed in
# muso-cli#40, released as v0.12.0. The default pin above (0.13.1) still
# carries that group — verified in muso-cli at v0.13.1: internal/cli/gh.go
# registers review-bundle/checks/threads/approve, and reviewBundleResult
# still emits `threadsTruncated`, `rebaseIntegrity` and `filesCountMismatch`,
# which is exactly what the skill consumes.
MUSO_CLI_MIN_VERSION="0.12.0"
if ! version_at_least "$MUSO_CLI_MIN_VERSION" "$MUSO_CLI_VERSION"; then
  echo "FATAL: MUSO_CLI_VERSION=$MUSO_CLI_VERSION is below the $MUSO_CLI_MIN_VERSION floor" >&2
  echo "       required by the skills in this tree (muso-github-code-review calls" >&2
  echo "       'muso gh', added in 0.12.0). Deploying would install a CLI too old" >&2
  echo "       for the skills it ships alongside." >&2
  echo "       To roll the CLI back, roll the skills back in the SAME commit and" >&2
  echo "       lower MUSO_CLI_MIN_VERSION with them — do not override past this." >&2
  exit 1
fi

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
# --report-only (env twin HYDRA_REPORT_ONLY=1): run Step 0 + Step 4a, then exit
# before anything mutates. See the exit after preflight_drift_check below.
REPORT_ONLY="${HYDRA_REPORT_ONLY:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ -z "${2:-}" ]] && { echo "Error: --target requires a value (main|edge|all)"; exit 1; }
      TARGET="$2"; shift 2 ;;
    --report-only) REPORT_ONLY=1; shift ;;
    main|edge|all) TARGET="$1"; shift ;;
    *) echo "Usage: deploy.sh [--target main|edge|all] [--report-only]"; exit 1 ;;
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
# A --report-only run is a read-only probe, not a deploy: a blocking rail exits
# non-zero but must not raise a "deploy FAILED" alarm in #hydra-heartbeat.
fail() { log "FATAL: $*"; [[ "$REPORT_ONLY" == "1" ]] || notify_slack ":x: HYDRA deploy FAILED ($TARGET): $*"; exit 1; }
# --report-only reports the rails; HYDRA_FORCE / HYDRA_SKIP_DRIFT_CHECK bypass
# them, so a bypassed run would exit 0 "clean" without having checked anything.
if [[ "$REPORT_ONLY" == "1" ]] && { [[ "${HYDRA_FORCE:-0}" == "1" ]] || [[ "${HYDRA_SKIP_DRIFT_CHECK:-0}" == "1" ]]; }; then
  fail "--report-only refuses to run with HYDRA_FORCE=1 or HYDRA_SKIP_DRIFT_CHECK=1: those bypass the rails it exists to report. Unset them."
fi
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

# plugin_install_version_flags <plugin-version> — prints the version-gated
# extra flags for `openclaw plugins install`. The externalized plugins are
# pinned in lockstep with the runtime, so the plugin version IS the runtime
# generation: >= 2026.8 needs --accept-capabilities (non-interactive
# capability ack; the install is refused without it), while the 7.x CLI does
# not know the option and would fail the whole install on it. An empty or
# unparseable version prints nothing — the caller's install then fails loud
# on the CLI's own error rather than on a guessed flag.
plugin_install_version_flags() {
  local v="${1:-}"
  if [[ -n "$v" ]] && [[ "$v" =~ ^[0-9]{4}(\.[0-9]+)+$ ]] && version_at_least "2026.8" "$v"; then
    printf '%s' "--accept-capabilities"
  fi
}

# stop_gateway_for_plugin_pin <profile> — openclaw fences state-schema mutation
# against a live gateway (dist/state-database-coordinator withStateSchemaFence:
# "refused shared state schema mutation ... because another Gateway owns that
# state directory. Stop that Gateway or perform the update through its managed
# restart path"). The fence exists in 2026.8.2 AND 2026.8.35 alike; what decides
# whether it fires is the fast path in ensureSchema: it skips the fence only when
# the DB's stamped schema_meta.app_version equals the running binary's version.
# So the trigger is "install_openclaw swapped the runtime in THIS deploy" (the
# binary now differs from the version the DBs are stamped with), not a version
# threshold. Deploy HYDRA run 37791745129 (8 Oct): Step 4c.5 made the binary
# 8.35 over DBs stamped 8.2, then Step 4d.5 `plugins install` hit the fence and
# the deploy auto-rolled back. The record install_openclaw writes is that signal
# (Step 4c.5 runs before Step 4d.5), and it is version-free, so it cannot rot.
# The unit stays stopped until Step 6, which must therefore restart it:
# HYDRA_FORCE_RESTART=1 overrides the gateway-inert restart-skip gate. A
# failure between here and Step 6 ends in rollback.sh, which restarts both.
# Direct systemctl, not run_on_node8 (defined later, Step 5a): this function
# already drives the host's own openclaw/npm directly.
# Profiles recorded here were stopped ON PURPOSE: Step 6 then expects no MainPID
# (see missing_pid_restart_req) instead of paging that the drain path is broken.
GATEWAYS_STOPPED_BY_DEPLOY=""
gateway_stopped_by_deploy() { [[ " $GATEWAYS_STOPPED_BY_DEPLOY " == *" $1 "* ]]; }

# missing_pid_restart_req <profile> — Step 6 found no pre-request MainPID.
# Returns finish_gateway_restart's req code: 4 = we stopped the unit ourselves
# (hard restart, no page), 3 = PID genuinely unreadable (hard restart + page).
missing_pid_restart_req() {
  if gateway_stopped_by_deploy "$1"; then return 4; fi
  return 3
}

stop_gateway_for_plugin_pin() {
  local profile="$1"
  if [[ -f "$DEPLOY_PATH/.pre-deploy-openclaw-version" ]]; then
    log "    Stopping openclaw-gateway-${profile} for the plugin install (runtime was swapped this deploy; the state DB migration is fenced against a live gateway)"
    systemctl stop "openclaw-gateway-${profile}" || return 1
    gateway_stopped_by_deploy "$profile" || GATEWAYS_STOPPED_BY_DEPLOY="$GATEWAYS_STOPPED_BY_DEPLOY $profile"
    export HYDRA_FORCE_RESTART=1
  fi
  return 0
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
  # can never float it off the pinned build. --accept-capabilities is
  # openclaw 2026.8+'s new non-interactive ack for a plugin's declared
  # capability manifest (unattested capabilities are refused otherwise).
  # It is added ONLY when the target plugin version is >= 2026.8 (the plugins
  # are pinned in lockstep with the runtime): the 7.x CLI rejects the unknown
  # option, so the supported OPENCLAW_VERSION=2026.7.1 override (a rollback
  # deploy) would otherwise install the 7.1 runtime and then fail every plugin
  # install — see plugin_install_version_flags() above.
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
    stop_gateway_for_plugin_pin "$profile" || {
      log "    ✗ could not stop openclaw-gateway-${profile}; not installing ${pkg} against a live gateway"
      return 1
    }
    local install_out install_rc=0
    local -a extra_flags=()
    read -r -a extra_flags <<< "$(plugin_install_version_flags "$version")"
    install_out=$(openclaw --profile "$profile" plugins install "${pkg}@${version}" --force --pin "${extra_flags[@]}" 2>&1) || install_rc=$?
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

# state_user_versions <root> — "main=15 edge=15": each profile's state DB
# PRAGMA user_version, "absent" if the DB file does not exist, "unreadable" if
# it exists but cannot be read. rollback.sh Step 1c computes the same string
# (inline, the restored tree may predate this function) and compares.
state_user_versions() {
  local p f v out=""
  for p in main edge; do
    f="$1/.openclaw-$p/state/openclaw.sqlite"
    if [[ ! -f "$f" ]]; then
      v=absent
    else
      v=$(sqlite3 -readonly "$f" 'pragma user_version;' 2>/dev/null) || v=""
      [[ "$v" =~ ^[0-9]+$ ]] || v=unreadable
    fi
    out="${out:+$out }$p=$v"
  done
  printf '%s' "$out"
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
    # Record what rollback.sh must restore: the swap below outlives a failed
    # deploy (8 Oct run 37791745129 left runtime 8.35 under 8.2 plugins).
    # Cleared once Step 6 has restarted the gateways.
    # Line 1: the runtime to restore. Line 2: each state DB's user_version at
    # swap time; rollback.sh restores the binary only while they are unchanged
    # (a newer-schema DB makes the old binary refuse to boot).
    local state_uv
    state_uv=$(state_user_versions "${OPENCLAW_PROFILE_ROOT:-/root}")
    printf '%s\n%s\n' "$installed" "$state_uv" > "$DEPLOY_PATH/.pre-deploy-openclaw-version" \
      || { log "    ✗ cannot record the pre-swap runtime in $DEPLOY_PATH/.pre-deploy-openclaw-version"; return 1; }
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
    --pattern "$asset" --pattern checksums.txt --dir "$tmp" 2>&1) || dl_rc=$?  # hydra-hook: reviewed-indirection reviewed-argv (gh by literal name; the expansion is a version ARG)
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

# wait_for_agents_bound — polls the RUNNING gateway via `openclaw health
# --json` until the agents it reports match the expected count for the given
# profile, or the timeout elapses. Called between Step 6 (gateway restart)
# and Step 7 (smoke test) to close the warm-up race — and, since Step 6b
# queries the gateway directly, to close the readiness race with it too.
# See the probe comment in the poll loop for why a local `agents list` read
# cannot serve as this gate.
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
  local health_json=""
  while (( elapsed < timeout_sec )); do
    # Probe the RUNNING gateway, not local state. `openclaw agents list
    # --bindings` reads the on-disk agent config and answers the full count
    # even when no gateway is listening (verified 2026-08-18 on node-8: it
    # printed 9 against a dead --url AND under --timeout 1), so it made this
    # entire warmup a no-op. `openclaw health` is a live round-trip to the
    # gateway ("Fetch health from the running gateway"): it exits non-zero
    # when unreachable, and its .agents array is exactly the bound set.
    #
    # This matters because Step 6b runs immediately after and its
    # `cron list --all --json` DOES require the gateway — on 2026-08-18 the
    # no-op probe returned "bound after 0s" one second before the gateway's
    # HTTP server started listening, so Step 6b read a refused connection as
    # an unverifiable cron store and rolled the whole deploy back.
    #
    # Any failure (unreachable, non-JSON, ok=false) must yield 0 so the loop
    # keeps polling — never a spurious match.
    # Two statements, not one pipeline: under `set -o pipefail` a failing
    # `openclaw` makes the whole pipeline non-zero even though python already
    # printed its 0 for EOF, so a trailing `|| echo 0` appends a SECOND zero and
    # `bound` becomes "0\n0" — every poll then dies with an arithmetic syntax
    # error and the timeout line reads "0\n0/9". Absorbing the CLI's status
    # first keeps the fallback to exactly one value.
    health_json=$(openclaw --profile "$profile" health --json 2>/dev/null || true)
    bound=$(printf '%s' "$health_json" \
      | python3 -c 'import json,sys
try:
    h = json.load(sys.stdin)
    print(len(h["agents"]) if h.get("ok") is True and isinstance(h.get("agents"), list) else 0)
except Exception:
    print(0)' 2>/dev/null || echo 0)
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
if [[ "$REPORT_ONLY" != "1" ]] && [[ -x "$SCRIPT_DIR/setup-hooks.sh" ]] && [[ -d "$HYDRA_ROOT/.git" ]]; then
  if ! hook_setup_out=$("$SCRIPT_DIR/setup-hooks.sh" 2>&1); then  # hydra-hook: reviewed-indirection (repo script by path)
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
  # In-progress marker (server-owned, written/removed by deploy.sh and
  # rollback.sh); must survive rsync --delete like .deployed-sha above.
  --exclude='.deploy-mutating'
  # Pre-swap openclaw runtime version (written by install_openclaw, cleared by
  # Step 6, consumed by rollback.sh Step 1c); same survive-rsync rule.
  --exclude='.pre-deploy-openclaw-version'
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
  # The SAME audit trail, written at the REPO ROOT instead of inside a
  # workspace. scripts/qa-pr-approve.sh:74 defaults LOG_DIR to the relative
  # `api-logs/github`, so a caller whose cwd is /opt/hydra (rather than an
  # agent workspace) lands it here. First appeared 2026-09-09 when the QA
  # agent approved a PR through that path, and it blocked the deploy: the
  # exclude above is scoped one directory too deep to cover it. These are
  # records of real agent write actions with no backup, so they are protected
  # rather than deleted. ANCHORED with a leading slash on purpose — a bare
  # `api-logs/` would also match inside plugin trees, which install_plugin()
  # rsyncs with this same array (see the note on that call site).
  --exclude='/api-logs/'
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
  # deploy after it, then #805). No 'tmp' marker, no 'final-' prefix, no leading
  # dot, so none of the three globs above match. Server-owned per-run scratch
  # (stage inputs and survivor/reject sets), recreatable by re-running the
  # pipeline, never in the repo. Mirrored KEEP globs in
  # scripts/qa-clean-merge-scratch.sh (lockstep rule, asserted by
  # scripts/tests/qa-clean-merge-scratch.bats).
  --exclude='workspaces/*/finder-input-*.json'
  --exclude='workspaces/*/prep-output-*.json'
  # FIFTH shape, and the only self-inflicting one: the QA bot's own per-PR
  # review scratch ('.pr-review-<N>.json', observed on node-8 2026-08-05 while
  # it reviewed #805). The auto-review writes it INTO workspaces/qa/ during the
  # very review that gates the PR, so the pre-flight on the next push sees a
  # file the repo does not have and reds — on every PR the bot reviews.
  # Server-owned per-run scratch, recreatable, never in the repo. Mirrored KEEP
  # glob in scripts/qa-clean-merge-scratch.sh (lockstep rule).
  #
  # Widened 2026-08-19 from '.pr-review-*.json' to '.*pr-review-*.json': the QA
  # bot's EXTERNAL cross-repo PR review (source PR core-backend#9398) writes a
  # differently-prefixed sibling shape, 'workspaces/qa/.qa-pr-review-<repo>-<pr>-
  # <sha>.json' (observed on node-8 2026-08-19, run 32230870418, blocking file
  # '.qa-pr-review-core-backend-9398-960314e.json'). It matched neither this
  # glob (extra 'qa-' before 'pr-review-' breaks the fixed dot-prefix) nor
  # 'workspaces/qa/pr-review*.json' below (leading dot breaks that one), so
  # every deploy hard-failed at Step 4a. Same writer, same server-owned
  # per-run scratch, never in the repo — the widened glob subsumes both
  # shapes without matching anything tracked (verified: no workspaces/*/
  # tracked file contains 'pr-review'). Mirrored KEEP glob in
  # scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/.*pr-review-*.json'
  # Ops agent run-manifest ('TRIBUTARIES_EXECUTION_MANIFEST_2026-10-02.md',
  # observed on node-8 workspaces/operations 2026-10-02, flagged by the Step 4a
  # pre-flight) — dated per-run working state, never in the repo. Mirrored KEEP
  # glob in scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/*_MANIFEST_*.md'
  # Ops agent run artifact, dot-prefixed ('.ops-2026-10-02-profile-916514bf-
  # seven-track-metadata-followup-0232.json', observed on node-8 workspaces/
  # operations 2026-10-02) — per-run scratch, never in the repo. Mirrored KEEP
  # glob in scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/.ops-*.json'
  # QA credit-verification todo inventory — dated per-run working state the QA
  # agent writes on node-8 (e.g. credit-verification-todo-inventory-2026-07-21.json),
  # never in the repo. Server-owned scratch; mirrored KEEP glob in
  # scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/credit-verification-todo-inventory-*.json'
  # SIXTH shape: npm's lockfile, regenerated in-place by anything that runs
  # `npm`/`npx` inside a workspace. Observed on node-8 2026-09-08 15:03:17Z as
  # workspaces/qa/package-lock.json -- 81 bytes, lockfileVersion 3, "packages":
  # {}, with no package.json and no node_modules/ beside it, so nothing on the
  # server consumes it. It first reddened Step 4a on #915, a PR whose diff
  # touches nothing under workspaces/; the file's mtime falls inside the gap
  # between #914's green pre-flight (2026-09-07T15:25:55Z) and #915's red
  # (2026-09-09T07:16:01Z), which dates it to the server rather than to any PR.
  # Until excluded it blocks EVERY hydra PR, the same failure class as the five
  # scratch shapes above.
  #
  # Deleting it on node-8 unblocks once but does not hold: unlike the invented
  # scratch names above, 'package-lock.json' is a fixed name npm regenerates on
  # any future run in any workspace, so cleanup alone recurs. The exclude is the
  # durable fix and it matches nothing tracked (git ls-files finds no
  # package-lock.json anywhere in the repo) -- cf. the identical treatment for
  # plugins at 'plugins/*/package-lock.json' below. Server-owned install
  # artifact, recreatable, never in the repo. Mirrored KEEP glob in
  # scripts/qa-clean-merge-scratch.sh (lockstep rule).
  --exclude='workspaces/*/package-lock.json'
  # Agent long-term memory (written by agents at runtime, should survive
  # deploys — see docs/guides/WORKSPACE-FILE-OWNERSHIP.md). MEMORY.md IS tracked
  # in git as a seed, but agents modify it post-deploy and we must not
  # overwrite those modifications with the seed on subsequent deploys.
  --exclude='workspaces/*/MEMORY.md'
  # Caroline's shipped-work feed, GENERATED on the server by
  # scripts/support-changelog-sync.sh (daily timer) into a directory the repo
  # otherwise owns. It is deliberately inside reference/ because that is the
  # ONLY path Caroline's RAG index covers (openclaw-edge.json:
  # support.memorySearch.extraPaths=["reference"]), so it cannot live anywhere
  # else and still reach her. Without this exclude rsync --delete would wipe it
  # on every deploy (blinding her until the next timer tick) AND the Step 4a
  # pre-flight would read it as a would-delete server file and red every PR --
  # the same failure class as the five scratch shapes above. Server-owned,
  # regenerated daily, never tracked in the repo.
  #
  # NOTE the shape: this is workspaces/<agent>/<subdir>/<file>, not the
  # workspaces/*/<file> form that scripts/qa-clean-merge-scratch.sh mirrors, so
  # the KEEP_GLOBS drift guard (which extracts exclude='workspaces/*/[^/]+')
  # does not require a mirror here. Keep it that way: a depth-1 rename would
  # silently start requiring one.
  --exclude='workspaces/support/reference/recent-changes.md'
  # Caroline's platform.muso.ai API feed, GENERATED on the server by
  # scripts/sync-platform-llms.sh from the PUBLIC
  # https://platform.muso.ai/llms-full.txt. Same shape and same reasoning as
  # recent-changes.md directly above: it must live inside reference/ to be
  # RAG-indexed at all, so rsync --delete would wipe it every deploy and the
  # Step 4a pre-flight would red every PR. It exists because hand-copied
  # pricing is what went stale in api-access.md for ten weeks; the numbers are
  # fetched, never written here. Server-owned, never tracked in the repo.
  # Depth-2 shape, so the KEEP_GLOBS drift guard needs no mirror (see NOTE above).
  --exclude='workspaces/support/reference/platform-api.md'
  # Caroline's Muso-app plan pricing, GENERATED on the server by
  # scripts/sync-app-pricing.sh from the PUBLIC anonymous plans API. Same shape and
  # same reasoning as the two excludes above. It exists because the hand-written
  # table blended monthly and annual rate cards and under-quoted monthly customers
  # by ~25%; the numbers are now fetched per cadence, never typed. Server-owned,
  # never tracked. Depth-2, so the KEEP_GLOBS drift guard needs no mirror.
  --exclude='workspaces/support/reference/app-pricing.md'
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
  #
  # Keep it a PREFIX match. Nothing in this repo writes these files — the AGENT
  # picks the name at runtime, so the suffix is not guaranteed and re-narrowing
  # the glob to a known shape would just reopen the same live-gate outage.
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
  # ruff's lint cache. Created when a skill-workshop session lints python it
  # authored inside a workspace skill dir (tripped the deploy pre-flight on
  # 2026-09-09, blocking the #917 merge-deploy 45s after the skill landed).
  # Build-tool cache, regenerated on each ruff run, never seeded from the
  # repo. Same category as __pycache__ and .wrangler.
  --exclude='.ruff_cache/'
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
  # sentry-issue-triage ships watchdog-exclude-patterns.txt. Added 2026-08-28 after
  # #874 landed the config without this pair: the deploy's own guard caught it, but at
  # DEPLOY time, so every deploy on main failed from 4539ddb0 onward until this line.
  --include='sentry-issue-triage/config/'
  --include='sentry-issue-triage/config/**'
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
  # Agent ad-hoc analytics SQL at the workspace top level (e.g. Ops writing
  # workspaces/operations/roc_legion_*.sql during a catalog investigation).
  # Same category as the scratch *.csv/*.txt above: generated per-investigation,
  # never tracked, and rsync --delete would destroy it mid-session.
  --exclude='workspaces/*/*.sql'
  # agent-bridge in-flight request state (scripts/agent-bridge-request.sh),
  # written into the agent workspace while a request is open and removed when
  # it closes. Transient by design, so a deploy that lands mid-request would
  # otherwise delete the state of a live escalation -- and the pre-flight
  # dry-run fails on it, which twice blocked THIS PR on an unrelated lane.
  --exclude='workspaces/*/.bridge-*.json'
  # Same state again, with an 'agent-' infix: workspaces/operations/
  # .agent-bridge-215476152669042.json (838 B, opened 2026-10-01 17:38:14Z) is a
  # live in-flight request on node-8. The dotted '.bridge-*' sibling above misses
  # it (no 'agent-' infix) and 'bridge-*' misses the leading dot, so a deploy would
  # delete it mid-escalation. Mirrored KEEP glob in qa-clean-merge-scratch.sh.
  --exclude='workspaces/*/.agent-bridge-*.json'
  # Same state, un-dotted: the AGENT names its request payload at runtime and
  # wrote workspaces/operations/bridge-request-<conversationId>.json (2026-09-15,
  # blocked #943). Top-level workspace files never auto-classify, so the shape
  # needs its own exclude. Mirrored KEEP glob in qa-clean-merge-scratch.sh.
  --exclude='workspaces/*/bridge-request-*.json'
  # The agent also names bridge payloads by CASE, not by shape
  # (workspaces/operations/bridge-lirika-sbk-20260916.json, written 2026-09-16
  # 15:38Z DURING a deploy and flagged by #950's pre-flight). Keep it a PREFIX
  # match like the qa pr-review glob: the agent picks the suffix at runtime.
  --exclude='workspaces/*/bridge-*.json'
  # Agent ad-hoc scratch python at the workspace top level (NOT skills/scripts,
  # which are tracked). Iterative throwaway investigations — hardcoded test
  # filenames, demo API keys, near-duplicate files. Same category as the
  # scratch *.csv/*.txt above; legit code lives under skills/ or scripts/.
  # Tripped the deletion rail on 2026-05-28 with 6 support-agent OCR/PDF
  # experiments (free_ocr*.py, read_pdf.py, test_ocr.py, ...).
  --exclude='workspaces/*/*.py'
  # Same class for ad-hoc shell at the workspace top level (an agent wrote
  # workspaces/operations/wait-lirika-bridge-reply.sh, a 20-attempt poll for an
  # escalation reply, 2026-09-16). Tracked shell lives under skills/ or
  # scripts/, never at a workspace root (verified: none tracked).
  --exclude='workspaces/*/*.sh'
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
# Extracted to scripts/lib/check-skills-config-includes.sh on 2026-08-28 so that
# pr-validate's rsync pre-flight — which already exists as a deliberate "shift-left copy"
# of this step — can run the SAME implementation. It could not before, and that is how
# #874 shipped a config dir with no include pair: this guard fired correctly, but at
# deploy time, blocking every deploy on main from 4539ddb0 until the pair was added.
# A second copy of the check in the workflow would have been the drift it exists to stop.
if ! "$HYDRA_ROOT/scripts/lib/check-skills-config-includes.sh" "$HYDRA_ROOT" "$HYDRA_ROOT/scripts/deploy.sh"; then  # hydra-hook: reviewed-indirection reviewed-argv (repo script by literal path)
  fail "a skills-all config directory would silently not reach the server — see the include pair suggested above."
fi

# muso-ops-admin/config/ is a SELECTIVE include (the 3 repo-authoritative files
# above). The server-only tier2-godmode-allowlist.txt must stay protected from
# BOTH transfer and rsync --delete. Enforce that here so a future edit can't
# widen the include and ship/destroy the godmode allowlist:
#   - if the dir is included, '--exclude=muso-ops-admin/config/**' MUST be present
#     and ordered before '--exclude=config/' (rsync is first-match-wins), else the
#     server-only godmode file leaks into the sync;
#   - no rule may ever NAME tier2-godmode-allowlist.txt in an include.
if printf '%s\n' "${RSYNC_EXCLUDES[@]}" | grep -qFx -- "--include=muso-ops-admin/config/"; then
  # Recomputed here rather than inherited. The generic config-include guard moved into
  # scripts/lib/check-skills-config-includes.sh, which runs in its own process, so this
  # index is no longer left behind in this shell. Deriving it locally is what keeps this
  # check independent of that extraction instead of silently comparing against an unset
  # variable — which under `set -u` would abort, and without it would compare against 0
  # and pass everything.
  cfg_exclude_idx=-1
  cfg_idx=0
  for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do
    [[ "$cfg_rule" == "--exclude=config/" ]] && cfg_exclude_idx="$cfg_idx" && break
    cfg_idx=$(( cfg_idx + 1 ))
  done
  (( cfg_exclude_idx >= 0 )) || fail "RSYNC_EXCLUDES no longer contains --exclude='config/' — the muso-ops-admin godmode protection check needs updating."
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

# decide_marker_takeover <owner-token> [repo]
#
# Belt-and-braces for the leftover-marker WARN below: a rollback that dies
# before clear_mutation_marker (SIGKILL, ssh drop — incident 2026-09-21, GHA
# run 35636138551) leaves .deploy-mutating owned by a GitHub Actions run that
# is provably dead, and nothing takes that over automatically, so the fleet
# stays stranded until a human logs into node-8. This decides whether THAT
# is the situation: only an owner shaped like `gha-<run_id>-<attempt>` (a
# GitHub Actions run — NEVER a `manual-...` owner, which may be a laptop
# deploy genuinely mid-flight) whose run is reported `completed` by the
# GitHub API is taken over. Any other outcome (owner not a gha token, gh
# missing, an API error/timeout, or a live status such as in_progress/
# queued) leaves today's behaviour untouched: the WARN below, and later the
# rc-2 refusal at the claim site. An operator-set
# HYDRA_TAKEOVER_MUTATION_MARKER is never overridden.
#
# On takeover, exports HYDRA_TAKEOVER_MUTATION_MARKER so the existing claim
# (claim_mutation_marker, below) performs its compare-and-swap. Logs its
# reasoning either way via `log` (must be defined by the caller).
decide_marker_takeover() {
  local owner="${1:-}" repo="${2:-}"
  if [[ -n "${HYDRA_TAKEOVER_MUTATION_MARKER:-}" ]]; then
    log "  HYDRA_TAKEOVER_MUTATION_MARKER is already set by the operator; leaving it as is."
    return 0
  fi
  if [[ ! "$owner" =~ ^gha-([0-9]+)-[0-9]+$ ]]; then
    log "  owner '$owner' is not a GitHub Actions run token (gha-<run_id>-<attempt>); no automatic takeover (it may be a manual deploy genuinely mid-flight)."
    return 0
  fi
  local run_id="${BASH_REMATCH[1]}"
  if ! command -v gh >/dev/null 2>&1; then
    log "  owner run $run_id: gh is not on PATH, cannot check whether it finished; no automatic takeover."
    return 0
  fi
  local run_status="" gh_rc=0
  run_status="$(timeout 20 gh api "repos/${repo}/actions/runs/${run_id}" --jq .status 2>/dev/null)" || gh_rc=$?  # hydra-hook: reviewed-indirection reviewed-argv (gh by literal name under a literal timeout; the gate cannot see through the substitution)
  if [[ "$gh_rc" -ne 0 || -z "$run_status" ]]; then
    log "  owner run $run_id: could not read its status from GitHub (gh rc=$gh_rc); no automatic takeover."
    return 0
  fi
  if [[ "$run_status" != "completed" ]]; then
    log "  owner run $run_id is '$run_status' on GitHub (not completed); no automatic takeover."
    return 0
  fi
  log "  owner run $run_id is completed on GitHub; taking the marker over (compare-and-swap on token $owner)"
  export HYDRA_TAKEOVER_MUTATION_MARKER="$owner"
}

# A leftover .deploy-mutating marker means a PREVIOUS run wrote it (right
# after its Step 4a passed) and never reached a clean end state (neither
# the .deployed-sha baseline write nor rollback.sh cleared it). That is a
# WARN, not a halt: Step 0/4a below still run and will make their own
# decision, but it's worth flagging: a halt in THIS run will trigger the
# workflow's rollback step (see scripts/lib/deploy-rollback-gate.sh), which
# is not what a fresh Step 0/4a halt normally does.
marker_precheck=false
if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
  if [[ -f "$DEPLOY_PATH/.deploy-mutating" ]]; then
    marker_precheck=true
  fi
else
  if ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
    "[ -f '$DEPLOY_PATH/.deploy-mutating' ]" 2>/dev/null; then
    marker_precheck=true
  fi
fi
if $marker_precheck; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
  marker_owner="$(cat "$DEPLOY_PATH/.deploy-mutating" 2>/dev/null || echo unreadable)"
  log "WARN: $DEPLOY_PATH/.deploy-mutating already exists (owner: $marker_owner); a previous deploy never completed or rolled back, or another deploy is mid-flight."
  log "WARN: a halt in this run will therefore trigger a rollback (the marker looks the same either way)."
  decide_marker_takeover "$marker_owner" "${REPO:-${GITHUB_REPOSITORY:-Muso-AI/hydra}}"
  unset marker_owner
fi
unset marker_precheck

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
# Step 0 diagnostics (MUS-4098): name the skill-workshop proposal behind a
# drifted SKILL.md. The workshop leaves the body it applied on disk at
#   <proposals>/<skill>-<date>-<hash>/generations/<uuid>/PROPOSAL.md
# so a proposal whose body equals the live file (proposal-only frontmatter
# keys status/version/date stripped from BOTH sides) is the writer. Causal,
# never temporal: no mtime, SSH-login or auth.log proximity is used (that
# heuristic named the wrong writer on MUS-4069).
#
# Reads only, and fail-soft: stdout is `<path>\t<proposal>\t<date>` per
# attributed file and nothing else; every error yields no output. It is
# called only from the reporting block and never feeds the drift verdict.
# stdin: drifted paths, one per line.
drift_proposal_attribution() {
  local script
  script=$(cat <<'ATTRIB'
  norm() {
    awk 'NR==1 && $0=="---" {fm=1; print; next}
         fm && $0=="---" {fm=0; print; next}
         fm && /^(status|version|date):/ {next}
         {print}' "$1"
  }
  while IFS= read -r p; do
    [ "$(basename "$p")" = SKILL.md ] || continue
    skill=$(basename "$(dirname "$p")")
    live="$1/$p"
    [ -r "$live" ] || continue
    live_body=$(norm "$live") || continue
    matches=""
    for prop in $2/"$skill"-*/generations/*/PROPOSAL.md; do
      [ -r "$prop" ] || continue
      [ "$(norm "$prop")" = "$live_body" ] || continue
      d=$(sed -n 's/^date: *//p' "$prop" | head -1)
      matches="$matches$prop	$d"$'\n'
    done
    [ -n "$matches" ] || continue
    printf '%s\t%s\n' "$p" "$(printf '%s' "$matches" | sort -t'	' -k2,2r | head -1)"
  done
ATTRIB
)
  local roots="${HYDRA_PROPOSALS_GLOB:-/root/.openclaw-*/skill-workshop/proposals}"
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
    bash -c "$script" _ "$DEPLOY_PATH" "$roots" 2>/dev/null || true  # hydra-hook: reviewed-indirection (read-only; literal heredoc above)
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "bash -c $(printf '%q' "$script") _ $(printf '%q' "$DEPLOY_PATH") $(printf '%q' "$roots")" 2>/dev/null || true
  fi
}

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
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
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
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
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

  # Reporting only: annotate each drifted file with the workshop proposal
  # that wrote it. Falls back to the plain listing on any failure; nothing
  # above this point or the verdict below depends on it.
  local attribution drift_listing
  attribution=$(echo "$drift" | drift_proposal_attribution 2>/dev/null || true)
  drift_listing=$(echo "$drift" | ATTR="$attribution" awk '
    BEGIN { n = split(ENVIRON["ATTR"], L, "\n"); for (i = 1; i <= n; i++) { split(L[i], f, "\t"); if (f[1] != "") A[f[1]] = f[2] " (date: " f[3] ")" } }
    { print "  " $0; if ($0 in A) print "    ↳ skill-workshop proposal: " A[$0] }
  ') || drift_listing=$(echo "$drift" | sed 's/^/  /')

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
$drift_listing

WHAT TO DO (the only safe path, mirrors \`git pull --rebase\`):
  1. Pull the server-side edits into your local repo, ONE PATH AT A TIME.
     sync-from-server.sh pulls ONLY files git already tracks, so:
       - an edited TRACKED file (skills-all/ or workspaces/):
           scripts/sync-from-server.sh skills     --apply --only <path>
           scripts/sync-from-server.sh workspaces --apply --only <path>
       - a NEW file that exists only on the server is untracked, and
         sync-from-server.sh will NOT pull it (even if it says "matches").
         Capture it by hand, review it (no secrets/tokens), then add it
         explicitly by path:
           scp -i "\$SSH_KEY" "\$NODE8_USER@\$NODE8_IP:$DEPLOY_PATH/<path>" ./<path>
           git add <path>
       - audit/ is gitignored (nothing to commit); its target pulls the
         whole subtree, which is large:
           scripts/sync-from-server.sh audit --apply
     # NEVER bulk-pull workspaces/: it is 125 GB / 6.2M files on node-8 (8 Oct).
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
    "$LINT_OPENCLAW_CFG" "${lint_targets[@]}" || fail "openclaw config lint: repo contains mcp-remote stdio entries"  # hydra-hook: reviewed-indirection reviewed-argv (repo linter by path)
    log "  openclaw configs free of mcp-remote stdio entries."
  fi
fi

# Run drift check when deploying all or multiple profiles
if [[ "$TARGET" == "all" ]] || [[ "$TARGET" == *","* ]]; then
  "$SCRIPT_DIR/validate-shared-config.sh" || fail "Shared config drift detected"  # hydra-hook: reviewed-indirection (repo script by path)
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
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
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
  if $HYDRA_LOCAL && [[ -f "$DEPLOY_PATH/.deployed-sha" ]]; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
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
✗ DEPLOY BLOCKED — skill drift between node-8 and the repo (skills-all/ or workspaces/)
================================================================================

WHAT THIS MEANS:
  These skill files differ between node-8 (under /opt/hydra/skills-all/ or
  /opt/hydra/workspaces/<workspace>/skills/) and this commit in a way the repo
  does NOT account for. Lines tagged SERVER-AHEAD were edited directly on
  node-8 (often by an operator or an agent) and are not in the repo; lines
  tagged CONFLICT were edited on BOTH sides. Your own intended skill edits
  (REPO-AHEAD) are allowed through and are NOT listed here. If you push past
  this check, rsync --delete OVERWRITES the server bytes with this commit's
  bytes and there is NO backup — losing server-side work agents rely on.
  (Lines shown as raw rsync flags mean no baseline was available, so this fell
  back to a blunt "any difference" check — treat every line as SERVER-AHEAD.)

DRIFTED FILES:
$(echo "$skills_drift" | sed 's/^/  /')

THE SAFE FIX — capture per file. Do NOT bulk-pull: a full sync-from-server.sh
pull would clobber your OTHER skill edits in this branch.
  SERVER-AHEAD — pull just that file and commit it:
$(format_skill_capture_commands "$skills_drift")
  CONFLICT — 3-way merge by hand (both sides changed); the baseline is the
  commit in /opt/hydra/.deployed-sha:
$(format_skill_conflict_commands "$skills_drift")
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
      fail "skill drift — refusing to deploy (override: HYDRA_FORCE=1)"
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
     (a) Is it real data? → Pull it into the repo. sync-from-server.sh
         pulls only TRACKED files, so a path the repo has never seen is
         NOT pulled by it. Capture it by hand and review it first (no
         secrets/tokens):
           scp -i "\$SSH_KEY" "\$NODE8_USER@\$NODE8_IP:$DEPLOY_PATH/<path>" ./<path>
           git add <path>
         (an already-tracked file: sync-from-server.sh skills --apply --only <path>
          or workspaces --apply --only <path>; audit/* is gitignored: audit --apply.
          NEVER bulk-pull workspaces/: 125 GB / 6.2M files on node-8, 8 Oct.)
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
# --report-only: both read-only rails (Step 0 drift, Step 4a pre-flight) passed
# — a blocking rail has already exited non-zero through fail() with its normal
# briefing. Stop HERE, before the muso CLI pin (Step 4a.5), the mutation-marker
# claim and every non-dry-run rsync, so nothing on the server is touched and
# .deployed-sha is never written. Reuses the functions and RSYNC_EXCLUDES above;
# it deliberately has no rail logic of its own.
# -------------------------------------------------------------------
if [[ "$REPORT_ONLY" == "1" ]]; then
  log "--report-only: Step 0 and Step 4a are clean. Exiting before any mutation (no marker, no sync, no .deployed-sha)."
  exit 0
fi

# -------------------------------------------------------------------
# Step 4a.5: pin the muso CLI — BEFORE anything is synced.
# -------------------------------------------------------------------
# Ordering is a correctness requirement, not tidiness. Skills call muso verbs,
# so the two directions of skew are NOT symmetric:
#   CLI newer than skills  -> safe (verbs are additive; an older skill calls
#                             only verbs that still exist)
#   skills newer than CLI  -> BROKEN (e.g. muso-github-code-review calling
#                             `muso gh` against 0.11.1 dies "unknown command",
#                             which reads as a broken skill, not a stale pin)
# This block used to run at Step 4d.6, i.e. AFTER the Step 4b rsync and the
# Step 4c managed-skills sync. That left a window where new skills were live
# against the old CLI — and because a failed pin calls `fail`, an install error
# ABORTED the deploy with the incompatible skills already on the server and no
# rollback. Pinning first makes the failure mode safe: nothing has been synced
# yet, so aborting here leaves the fleet exactly as it was.
if needs_target "main" || needs_target "edge"; then
  log "Step 4a.5/8: Pinning muso CLI to ${MUSO_CLI_VERSION} (before sync)..."
  if ! install_muso; then
    fail "muso CLI pin failed (target ${MUSO_CLI_VERSION}) — aborting BEFORE any sync, fleet unchanged"
  fi
fi

# -------------------------------------------------------------------
# Mark the deploy as mutating: every read-only gate (Step 0 drift check,
# Step 4a pre-flight) and the pre-sync muso CLI pin (Step 4a.5, which fails
# "BEFORE any sync, fleet unchanged") are behind us, so the next thing that
# happens is the Step 4b rsync. From here on a failure genuinely means
# node-8 may have been touched, so the workflow's rollback step should run
# scripts/rollback.sh. Before this point it should not. The marker carries
# an OWNER token: the workflow passes its run id as HYDRA_DEPLOY_RUN_ID and
# hands the same token to scripts/lib/deploy-rollback-gate.sh, which only
# answers rollback=true for a marker this run wrote. A marker owned by some
# other deploy (a manual one mid-flight while a scheduled run fails to get
# the lock) must never trigger a rollback underneath it. Removed once the
# .deployed-sha baseline write below is verified, and by rollback.sh after
# a successful rollback.
# -------------------------------------------------------------------
DEPLOY_RUN_TOKEN="${HYDRA_DEPLOY_RUN_ID:-manual-$(hostname 2>/dev/null || echo host)-$$-$(date -u +%Y%m%dT%H%M%SZ)}"
# The claim is ATOMIC on the server and owner-aware (lib/deploy-mutation-
# marker.sh): the deploy lock above is per source host, so a laptop deploy
# and the node-8 runner can both reach this line for the same baseline. A
# marker held by another live owner is a refusal, never an overwrite; a
# dead owner is cleared by hand or compare-and-swapped away with
# HYDRA_TAKEOVER_MUTATION_MARKER=<that owner's token>.
log "Claiming the mutation marker ($DEPLOY_PATH/.deploy-mutating, owner $DEPLOY_RUN_TOKEN)"
marker_rc=0
if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
  claim_mutation_marker "$DEPLOY_PATH/.deploy-mutating" "$DEPLOY_RUN_TOKEN" "${HYDRA_TAKEOVER_MUTATION_MARKER:-}" || marker_rc=$?
else
  # Stream the lib to node-8 and run the claim THERE, so noclobber's O_EXCL
  # applies on the server's filesystem, not on a copy.
  ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
    "bash -s -- claim '$DEPLOY_PATH/.deploy-mutating' '$DEPLOY_RUN_TOKEN' '${HYDRA_TAKEOVER_MUTATION_MARKER:-}'" \
    < "$SCRIPT_DIR/lib/deploy-mutation-marker.sh" || marker_rc=$?
fi
case "$marker_rc" in
  0) ;;
  2) fail "another deploy holds $DEPLOY_PATH/.deploy-mutating (see the owner above); refusing to sync underneath it. If that deploy is dead, remove the marker on node-8 or rerun with HYDRA_TAKEOVER_MUTATION_MARKER=<that owner token> (a compare-and-swap; a bare 1 is refused)." ;;
  4) fail "$DEPLOY_PATH/.deploy-mutating exists but cannot be read; owner unknown, refusing to sync. Inspect it on node-8." ;;
  *) fail "could not claim the mutation marker (rc=$marker_rc)" ;;
esac
unset marker_rc

# -------------------------------------------------------------------
# Step 4b: rsync repo to Node 8
# -------------------------------------------------------------------
if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
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
# Codex-native automatic compaction backport retired: upstream #95831 ships
# it natively in the 2026.8.1 dist (staging-verified —
# docs/runbooks/UPGRADE-2026.8.1.md). scripts/patch-openclaw-codex-native-compaction.sh
# is deleted; do not reintroduce the invocation.
#
# The remaining dist patches (inactive-session-delete, mention-gate) anchor
# against known-good source text and fail loud on a mismatch, so they are
# not silently harmful on 2026.8+ — but their upstream anchors are UNVERIFIED
# against the 2.0 dist and the mention-gate patch is already retired (no
# longer invoked, see the historical note near the cron sync below). Gate
# both behind the runtime so a 2026.8+ deploy makes the "not re-evaluated
# yet" intent explicit instead of relying on the patch's own anchor-fail to
# discover it. Re-evaluate for docs/runbooks/UPGRADE-2026.8.1.md Phase 3.
if version_at_least "2026.8" "$OPENCLAW_VERSION"; then
  log "  openclaw ${OPENCLAW_VERSION} >= 2026.8 — inactive-session-delete/mention-gate dist patches are retired-pending-reevaluation on 2.0, skipping (docs/runbooks/UPGRADE-2026.8.1.md)"
  # gpt-6-sol/gpt-6-luna subscription route (MUS-5128). 2026.8.x routes these ids
  # to the Platform (api-key) transport only, so the oauth-only fleet fell back to
  # paid OpenRouter on every turn. 2026.9.x ships the same ids natively: the gate
  # retires the backport there. Anchor-checked; fails the deploy on drift.
  if version_at_least "2026.9" "$OPENCLAW_VERSION"; then
    log "  openclaw ${OPENCLAW_VERSION} >= 2026.9 — gpt-6 subscription route is native, backport skipped"
  elif ! OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist \
    bash "$HYDRA_ROOT/scripts/patch-openclaw-gpt6-subscription-route.sh"; then
    fail "OpenClaw gpt-6 subscription route backport failed"
  fi
else
  if ! OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist \
    bash "$HYDRA_ROOT/scripts/patch-openclaw-inactive-session-delete.sh"; then
    fail "OpenClaw inactive-session delete backport failed"
  fi
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
# muso CLI pin: MOVED to Step 4a.5 (before the Step 4b rsync).
# -------------------------------------------------------------------
# It used to run here, after skills were already on the server. Skills call
# muso verbs, so a skill newer than the CLI is a live breakage while a CLI
# newer than the skills is harmless — the pin therefore has to happen first.
# See the Step 4a.5 block for the full rationale.
#
# Context kept here because it explains WHY the pin covers both profiles:
# muso is the admin-API/policy CLI. main-gateway agents use it (soak phase),
# and as of the Caroline self-serve work the EDGE gateway consumes it too: the
# support-tools gated-write tools (profiles_claim_self, credits_verify,
# profiles_consolidate) shell `muso <verb> --actor-identity` so muso-cli's
# capability gate (ownership re-verify + per-actor caps + audit) is load-bearing
# for Caroline. The binary is host-wide (/usr/local/bin/muso); pin it whenever
# main OR edge is targeted so an edge-only deploy still upgrades it. The edge
# process additionally needs MUSO_STATE_DIR + a muso login (see the edge env
# block) — without them the gated writes fail closed.

# NOTE: drift baseline (.deployed-sha) is updated AFTER Step 7 (smoke test
# passes), not here. Writing it now would advance the baseline before we
# know the deploy actually works — a half-failed deploy would leave a
# stale baseline that masks real drift on the next run.

# ─── Caddy delivery + the loopback-bind ordering gate ───────────────────────
#
# WHY THIS EXISTS. `gateway.bind: "loopback"` is only safe while Caddy is the
# thing listening publicly and reverse-proxying to localhost. Those two facts
# live in DIFFERENT places -- the bind in openclaw-*.json (which deploy.sh
# syncs, just below) and the reverse proxy in /etc/caddy/Caddyfile (which
# NOTHING deployed until this block). So "Caddy first, then the loopback bind"
# was enforced only by whoever read a PR description, while the reverse order
# shipped automatically on the next scheduled deploy and took the Control UI
# dark.
#
# That asymmetry is how the 2026-09-21 exposure survived ~5 months: on
# 2026-04-28 the live Caddyfile became a 2-line
# `respond "MINIMAL_RESTART_OK" 200` stub, and because the gateway was ALSO
# bound to 0.0.0.0, nothing broke visibly -- traffic bypassed basic_auth and
# hit :18789 directly. Untracked infra config plus a permissive bind hid an
# authentication bypass.
#
# Ordering inside the function is the point: it INSTALLS before it GATES, so a
# single deploy carrying both the Caddyfile and the loopback bind satisfies the
# order by construction. Both halves are no-ops until the repo carries the
# Caddyfile AND a profile asks for loopback, so this lands safely ahead of the
# bind change instead of racing it.
#
# Seams exist so the block is unit testable; a gate no test can falsify is how
# the last one rotted. `caddy_reload` is a FUNCTION, not a command in a
# variable: the pre-commit indirection gate refuses a command word it cannot
# read statically, and it is right to -- `cmd=rsync; $cmd --delete` is exactly
# what that gate exists to catch. Tests redefine this function instead.
caddy_reload() { systemctl reload caddy; }

caddy_deliver_and_gate_bind() {
  local deploy_path="$1" live="$2"
  local repo_file="$deploy_path/infra/node-8/Caddyfile"

  # (a) DELIVER first.
  if [ -f "$repo_file" ]; then
    if ! command -v caddy >/dev/null 2>&1; then
      fail "infra/node-8/Caddyfile is in the repo but caddy is not installed — refusing to sync a config whose public entry point is missing."
    fi
    if cmp -s "$repo_file" "$live"; then
      log "  Caddy: $live already matches the repo."
    else
      # Validate the REPO file before it may replace a working live one.
      if ! caddy validate --config "$repo_file" --adapter caddyfile >/dev/null 2>&1; then
        fail "caddy validate rejected infra/node-8/Caddyfile — refusing to install it."
      fi
      local backup=""
      if [ -f "$live" ]; then
        backup="${live}.pre-deploy-$(date -u +%Y%m%dT%H%M%SZ)"
        cp -a "$live" "$backup"
      fi
      install -m 644 "$repo_file" "$live" \
        || fail "could not install infra/node-8/Caddyfile to $live"
      # A failed reload must ROLL THE FILE BACK. Otherwise the candidate is
      # already installed, so the NEXT scheduled run sees `cmp -s` succeed,
      # skips the reload, and the bind gate then reads routing out of a file
      # Caddy never loaded -- permitting the loopback sync while the old stub
      # is still being served. The retry this block exists to make safe would
      # become the outage. (QA finding on #994.)
      if ! caddy_reload; then
        # FAIL CLOSED, in every branch. The candidate is already installed, so
        # the next run must not be able to reach the `cmp -s` equality
        # shortcut and skip the reload -- that is how a failed reload became a
        # false success. Two branches, both of which an earlier cut got wrong:
        #   - no predecessor  -> the installed candidate must be REMOVED
        #   - restore fails   -> removing $live is the only fail-closed state
        # An ignored restore failure left the candidate in place, which the
        # reviewer reproduced adversarially. (QA findings on #994.)
        if [ -n "$backup" ] && install -m 644 "$backup" "$live"; then
          caddy_reload || true   # best effort: return Caddy to known-good
          fail "caddy reload failed after installing the new Caddyfile — restored the previous file so the next run retries the install instead of trusting byte equality."
        fi
        rm -f "$live"
        fail "caddy reload failed after installing the new Caddyfile and there was no restorable predecessor — REMOVED $live so the next run cannot skip the reload on byte equality. Caddy is still serving its previously loaded config; install a known-good Caddyfile before the next deploy."
      fi
      log "  Caddy: installed repo Caddyfile and reloaded (previous kept as .pre-deploy-*)."
    fi
  else
    log "  Caddy: no infra/node-8/Caddyfile in the repo — skipping (nothing to deliver)."
  fi

  # (b) GATE second: a loopback bind requires the REVIEWED Caddyfile to be the
  # one Caddy is serving.
  #
  # This deliberately does NOT analyse the config's routing. Three review
  # rounds produced six distinct ways a Caddyfile can adapt cleanly and still
  # not serve "/" to the gateway: a proxy in another site block, in an
  # unimported snippet, scoped to a narrow path, placed after a terminal
  # `respond` handler, or pointed at a non-loopback host that merely ends in
  # the right port. Each fix produced another evasion, which is evidence the
  # CONTRACT was wrong rather than the implementation.
  #
  # So the contract is now the narrow, unevadable one: `bind: loopback` is
  # permitted only when /etc/caddy/Caddyfile is byte-identical to the repo's
  # infra/node-8/Caddyfile. Whether THAT file routes "/" correctly is a code
  # review question about a tracked, human-reviewed artifact -- not something
  # this script should infer at 04:00 from an arbitrary file on disk. It also
  # closes a case none of the routing checks covered: shipping loopback while
  # Caddy serves some hand-edited config nobody reviewed.
  #
  # Delivery ran above, so on a correct deploy the files already match. A
  # mismatch here means either no Caddyfile in the repo, or a reload that did
  # not take -- both of which must block the bind.
  local prof cfg mode
  local reloaded_for_gate=0
  for prof in main edge; do
    case "$prof" in
      main) cfg="$deploy_path/openclaw-main.json" ;;
      edge) cfg="$deploy_path/openclaw-edge.json" ;;
    esac
    [ -f "$cfg" ] || continue
    # Unreadable config is NOT a pass: it is the one state where we cannot
    # tell whether a loopback bind is about to ship.
    mode=$(jq -er '.gateway.bind // "unset"' "$cfg" 2>/dev/null) \
      || fail "could not read gateway.bind from $cfg — refusing to sync configs blind while the bind gate cannot be evaluated."
    [ "$mode" = "loopback" ] || continue
    if [ ! -f "$repo_file" ]; then
      fail "$prof requests gateway.bind=loopback but the repo carries no infra/node-8/Caddyfile — there is no reviewed public entry point to bind behind."
    fi
    if ! cmp -s "$repo_file" "$live"; then
      fail "$prof requests gateway.bind=loopback but $live is not byte-identical to the repo's infra/node-8/Caddyfile — Caddy is serving something that was not reviewed, or the reload did not take. Refusing to take the surface dark."
    fi
    # Byte equality on DISK does not prove the running process LOADED it. If
    # someone hand-copies the repo bytes over $live while Caddy still serves
    # the prior stub, the delivery step above skips the reload on `cmp -s`,
    # this identity check then compares the same two on-disk files and passes,
    # and loopback ships against a stale in-memory config -- the exact
    # file-versus-process gap the identity contract was meant to escape.
    # So force ONE reload before clearing any loopback gate, even when the
    # files already match, and fail closed if it does not take. Idempotence
    # for the ordinary case is preserved: this runs only when a profile
    # actually requests loopback. (QA finding on #994.)
    if [ "$reloaded_for_gate" -eq 0 ]; then
      caddy_reload || fail "$prof requests gateway.bind=loopback and $live matches the repo, but 'caddy reload' failed — cannot prove Caddy is serving the reviewed config, so refusing to take the surface dark."
      reloaded_for_gate=1
      log "  Bind gate: reloaded Caddy so the reviewed file is proven loaded, not merely on disk."
    fi
    log "  Bind gate: $prof loopback is safe — Caddy is serving the reviewed repo Caddyfile."
  done
}

caddy_deliver_and_gate_bind "$DEPLOY_PATH" "${CADDY_LIVE_FILE:-/etc/caddy/Caddyfile}"

# Sync per-profile configs to profile state dirs.
# Preserves `.mcp.servers` from the live file across deploys so
# server-side `openclaw mcp set` registrations (e.g. NocoDB, which
# carries an auth token we don't want to commit) survive. The repo
# copy wins for every other field. Mirrors the cron-state preservation
# pattern used in Step 5a (below) for the same reason: deploys must
# not silently wipe server-registered runtime state.
# sync_profile_config now lives in scripts/lib/sync-profile-config.sh so that
# rollback.sh uses the SAME implementation. It previously existed only here, and
# rollback.sh restored profile configs with a plain `cp` -- so the forward path
# preserved runtime MCP registrations and the rollback path destroyed them
# (2026-08-26, deploy run 32933062895 attempt 1). Two copies of this rule
# drifted, and the drift was the bug. Do not re-inline it.
# shellcheck source=lib/sync-profile-config.sh
. "$SCRIPT_DIR/lib/sync-profile-config.sh"

log "  Syncing profile configs..."
if needs_target "main"; then
  sync_profile_config "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw-main/openclaw.json deploy.sh \
    || fail "profile config sync failed for /root/.openclaw-main/openclaw.json"
  # Mirror to legacy default path as defense-in-depth (see cron sync below
  # for the same rationale) — preserve its `.mcp.servers` the same way as
  # the profile-specific path, so if the pre-multi-profile gateway ever
  # reanimates (smoke-test.sh hard-fails the deploy if it does) it will
  # still have the server list rather than being silently stripped.
  sync_profile_config "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw/openclaw.json deploy.sh \
    || fail "profile config sync failed for /root/.openclaw/openclaw.json"
  log "  Synced main profile config (+ default openclaw.json)"
fi
if needs_target "edge"; then
  sync_profile_config "$DEPLOY_PATH/openclaw-edge.json" /root/.openclaw-edge/openclaw.json deploy.sh \
    || fail "profile config sync failed for /root/.openclaw-edge/openclaw.json"
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
      || fail "openclaw config lint failed on live config — see preceding stderr for the profile + server name; rewrite with \`openclaw --profile <p> mcp set\` to transport: \"streamable-http\""  # hydra-hook: reviewed-indirection reviewed-argv (repo linter by path)
    log "  Live openclaw configs free of mcp-remote stdio entries."
  fi
fi

# -------------------------------------------------------------------
# Step 4d.6: Refuse un-archived legacy stores ahead of the 2.0 cutover
# -------------------------------------------------------------------
# openclaw 2026.8+ moves shared auth into
# <state-dir>/state/openclaw.sqlite (config_machine_state row
# authProfiles.store) and the session-lifecycle/cron-claim machinery no
# longer reads the per-agent sessions.json index. Restarting a >=2026.8
# gateway with the pre-8.1 JSON stores still in place risks the runtime
# either ignoring live state (a silent downgrade of session/auth data)
# or a doctor-driven migration racing the cold-archive procedure this
# repo requires — docs/runbooks/UPGRADE-2026.8.1.md Phase 2 (cold state
# archive, gateways stopped) MUST run before this deploy, and Phase 4
# (post-mint verification) depends on it having run cleanly. Refuse
# past config-sync, before the Step 6 restart, rather than find out via
# a broken smoke test.
if version_at_least "2026.8" "$OPENCLAW_VERSION"; then
  for _profile in main edge; do
    needs_target "$_profile" || continue
    _legacy_state_dir="/root/.openclaw-${_profile}"
    if [[ ! -d "$_legacy_state_dir" ]]; then
      log "  Step 4d.6: ${_legacy_state_dir} does not exist — skipping legacy-store gate (fresh host / CI)."
      continue
    fi
    _legacy_found=()
    for _lf in "$_legacy_state_dir"/agents/*/sessions/sessions.json; do
      [[ -e "$_lf" ]] && _legacy_found+=("$_lf")
    done
    for _lf in "$_legacy_state_dir"/agents/*/agent/auth-profiles.json; do
      { [[ -f "$_lf" ]] || [[ -L "$_lf" ]]; } && _legacy_found+=("$_lf")
    done
    if [[ -f "$_legacy_state_dir/exec-approvals.json" ]]; then
      _legacy_found+=("$_legacy_state_dir/exec-approvals.json")
    fi
    if (( ${#_legacy_found[@]} > 0 )); then
      fail "un-archived pre-2026.8.1 legacy store(s) found on profile=${_profile}: ${_legacy_found[*]} — cold-archive state per docs/runbooks/UPGRADE-2026.8.1.md Phase 2, then re-run; see Phase 4 for the mint step this gate protects"
    fi
  done
  log "  Step 4d.6: no un-archived legacy stores found."
fi

# -------------------------------------------------------------------
# Step 5a: Post-sync setup on Node 8
# -------------------------------------------------------------------
# Renamed from Step 5 → Step 5a on 2026-04-08 to make room for
# Step 5b (k8s manifest apply). If you're grepping deploy logs for
# "Step 5:" you'll need to update filters to "Step 5[ab]:".
log "Step 5a/8: Running post-sync setup..."

run_on_node8() {
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
    bash -c "$1"  # hydra-hook: reviewed-indirection (local/ssh dispatcher; the ssh branch below passes the same string)
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" "$1"
  fi
}

# -------------------------------------------------------------------
# Host media-binary pre-flight (WARN ONLY — never halts a deploy)
# -------------------------------------------------------------------
# The intercom plugin shells out to two HOST binaries rather than bundling a
# JS decoder, because deploy rsyncs plugins with --exclude=node_modules and
# native deps are fragile under the openclaw single-file packaging contract
# (see plugins/intercom/src/attachments.ts):
#
#   pdftoppm     (poppler-utils)      — PDF pages → PNG for the vision path
#   heif-convert (libheif-examples)   — HEIC/HEIF → JPEG
#
# Install on node-8 with:
#   apt-get install -y poppler-utils libheif-examples
#
# Until 2026-08-18 this requirement lived ONLY in a source comment, so a
# missing package was invisible until a customer's attachment came back
# unreadable in production. Both paths degrade gracefully (the PDF still goes
# for text extraction; a HEIC resolves to an explicit `unreadable` result), so
# this WARNS rather than halting — a deploy must never wedge on a missing
# optional package, and this check is brand new. Promote to a hard failure only
# after it has been observed green for a while.
check_media_host_binaries() {
  local missing_bins="" probe_rc=0 probe_out
  probe_out=$(run_on_node8 'for b in pdftoppm heif-convert; do command -v "$b" >/dev/null 2>&1 || printf "%s " "$b"; done' 2>&1) || probe_rc=$?
  if (( probe_rc != 0 )); then
    log "  ⚠ could not probe node-8 for media binaries (rc=$probe_rc): $probe_out"
    return 0
  fi
  missing_bins="$(printf '%s' "$probe_out" | tr -d '\r\n' | sed 's/[[:space:]]*$//')"
  if [[ -n "$missing_bins" ]]; then
    log "  ⚠ node-8 is missing media binaries: $missing_bins"
    log "    Intercom attachments will degrade (PDFs not rasterized / HEIC not decoded)."
    log "    Fix: ssh node-8 && apt-get install -y poppler-utils libheif-examples"
  else
    log "  ✓ media binaries present on node-8 (pdftoppm, heif-convert)"
  fi
  return 0
}

log "  Pre-flight: host media binaries (pdftoppm, heif-convert)..."
check_media_host_binaries

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
preserved = 0
for j in repo.get('jobs', []):
    if j['id'] in live_states:
        j['state'] = live_states[j['id']]
        preserved += 1

# NOTE: no orphan guard here (MUS-3346). This block reads cron/jobs.json, which
# the 7.x runtime never writes, so a guard here was redundant with the
# store-only cron guard below (detect-store-only-crons.py against a live
# loadCronStore dump) and blind to live-created crons.

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
  # live SQLite store but absent from cron-jobs.json is WIPED. A
  # jobs.json-based orphan guard (removed, MUS-3346) could not catch these: it
  # read the stale cron/jobs.json, which the 7.x runtime never writes to, so a cron created directly on the
  # gateway (`openclaw cron add`) is invisible to it and silently lost
  # (incident 2026-07-16: Aaron's ChartMogul MRR/SaaS crons, PR #702). Read the
  # REAL store via loadCronStore and halt if it holds a durable (recurring,
  # non-ephemeral) cron the repo doesn't declare. Halting here (before the
  # import, before the Step 6 restart) leaves the live cron running until an
  # operator commits it or sets HYDRA_ALLOW_ORPHAN_CRON=1 to drop it.
  STORE_DUMP=$(mktemp) || fail "store-only cron guard: mktemp failed"
  DUMP_RC=0
  DUMP_ERR=$(OPENCLAW_STATE_DIR=/root/.openclaw-main CRON_SDK="$CRON_SDK" \
    bash "$HYDRA_ROOT/scripts/lib/dump-cron-store.sh" "$STORE_DUMP" 2>&1) || DUMP_RC=$?
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
          // LAST-MOMENT store-only re-check.
          //
          // The guard above (detect-store-only-crons.py) reads the store ~50
          // lines earlier and halts on a durable cron the repo does not
          // declare. saveCronStore is delete-by-store_key + re-insert, so a
          // cron created in the gap between that guard and this save is
          // silently DELETED — the guard has already passed and never runs
          // again. That is the 2026-07-16 ChartMogul loss shape (PR #702/#706)
          // reachable through a window the guard cannot see.
          //
          // Re-checking against the store we read HERE shrinks that window from
          // ~50 lines of deploy work to the microseconds before the save. It
          // halts rather than dropping, exactly like the guard, and honours the
          // same HYDRA_ALLOW_ORPHAN_CRON=1 override. Same check, same
          // reasoning, same override as cron_store_reimport in
          // scripts/lib/cron-store.sh — which is bats-covered; keep them in step.
          if (process.env.HYDRA_ALLOW_ORPHAN_CRON !== "1") {
            const declared = new Set((store.jobs || []).map((j) => j.id));
            const cur = await m.loadCronStore(target);
            // Runtime-declared rows (declarationKey) belong to the openclaw runtime, created
            // from config at boot with regenerating ids — never committable.
            // Mirrors runtime_declared in scripts/lib/cron-store.sh and
            // is_runtime_declared in detect-store-only-crons.py; keep all three
            // in step (the comment above this block says why).
            // Namespace + the runtime payload invariant: the key alone is
            // forgeable via cron add --declaration-key (QA finding, PR #924).
            // Mirrors runtime_declared in scripts/lib/cron-store.sh and
            // is_runtime_declared in detect-store-only-crons.py; all four stay
            // in step. NOTE: embedded in a SINGLE-QUOTED shell string — no
            // apostrophes and no backticks anywhere in this block.
            const isRuntimeDeclared = (j) => {
              const k = j.declarationKey;
              if (typeof k !== "string") return false;
              const p = j.payload && typeof j.payload === "object" ? j.payload : {};
              if (k.startsWith("heartbeat:")) return p.kind === "heartbeat";
              if (k.startsWith("heartbeat-task:")) return true;
              if (k.startsWith("skill-collection-review:")) return p.kind === "skillCollectionReview";
              if (k === "memory-core:memory-dreaming-promotion")
                return p.kind === "agentTurn" &&
                  p.message === "__openclaw_memory_core_short_term_promotion_dream__";
              return false;
            };
            const undeclared = (cur.jobs || [])
              .filter((j) => !(j.schedule && j.schedule.kind === "at" && j.deleteAfterRun === true))
              .filter((j) => !isRuntimeDeclared(j))
              .filter((j) => !declared.has(j.id))
              .map((j) => j.id);
            if (undeclared.length > 0) {
              console.error("STORE_ONLY_CRON_APPEARED " + undeclared.join(","));
              process.exit(9);
            }
          }
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
  if (( IMPORT_RC == 9 )); then
    # A durable cron appeared between the store-only guard and this save. The
    # store was NOT written, so the job is still there — halt and let a human
    # decide, exactly as the guard would have.
    log "  ✗ cron SQLite import: a durable cron the repo does not declare appeared AFTER the store-only guard ran:"
    echo "$IMPORT_OUT" | sed 's/^/        /'
    fail "cron SQLite import: the live cron store gained durable cron(s) after the store-only guard passed, so the import REFUSED to overwrite them (nothing was written). Commit them to cron-jobs.json, or re-run with HYDRA_ALLOW_ORPHAN_CRON=1 to drop them deliberately."
  fi
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
if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
  log "Step 5c/8: Installing/refreshing aux systemd units..."
  if [ -x "$DEPLOY_PATH/scripts/install-aux-units.sh" ]; then
    "$DEPLOY_PATH/scripts/install-aux-units.sh" "$DEPLOY_PATH" \
      || fail "install-aux-units.sh failed — see preceding output"  # hydra-hook: reviewed-indirection reviewed-argv (deployed script by path)
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
    4)
      log "  $service was stopped by this deploy for the plugin install — starting it (no PID to drain, by design)" ;;
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

# check_gateway_not_crashlooping <service> <baseline_nrestarts> — the
# 2026-09-22 incident gate (deploy run 35773324797): edge crash-looped 43
# times over ~17 min after a restart while Step 6/6b logged only a
# non-fatal warning, and the smoke test didn't reach edge for ~12 more
# minutes (main's #984 post-restart freeze stalled every earlier probe).
# Deploy reported success the whole time.
#
# Called right after EVERY wait_for_agents_bound call site (the normal
# warmup wait below, and the cron-store heal's own restart) so a gateway
# that is merely SLOW to bind still just warns as before — this only fires
# on a gateway that is actually crash-looping (systemd restarting it more
# than it had immediately AFTER this deploy's own restart completed — see
# each call site's comment for why the baseline is captured post-restart,
# never pre-restart — or stuck failed / repeatedly auto-restarting). See
# gateway_crash_looping in lib/gateway-restart.sh for why a frozen main
# (#984) can never trip this: a freeze holds one PID, active, with an
# unmoving NRestarts.
#
# baseline carries exactly THREE distinct meanings — never overload the
# empty string to mean more than one of them (2026-09-23 QA finding on
# #1010): an unreadable baseline after a restart that DID happen used to
# collapse into the same "" a skipped restart passes, so a crash loop right
# after a transient `systemctl show`/SSH hiccup was a silent no-op — exactly
# the class this whole gate exists to close.
#   ""                    this deploy did NOT restart the unit (the
#                         gateway_restart_needed skip branch, or needs_target
#                         false for this profile) — no-op, nothing to compare.
#   a number              the normal path: gateway_crash_looping's numeric
#                         NRestarts-since-baseline compare (falls back to the
#                         is-failed/auto-restart sampling on its own if it
#                         can't decide from the counter alone).
#   UNREADABLE_BASELINE   this deploy DID restart the unit, but every
#                         gateway_nrestarts_retry attempt right after still
#                         failed to read a number. Falls back to
#                         gateway_crash_looping_state_only (is-failed /
#                         auto-restart sampling only — see that function's
#                         header for why a raw "read NRestarts once more,
#                         fail if > 0" heuristic is deliberately NOT used
#                         here: it would false-fail every healthy
#                         safe-restart deploy).
check_gateway_not_crashlooping() {
  local service="$1" baseline="$2"
  case "$baseline" in
    "") return 0 ;;
    UNREADABLE_BASELINE)
      log "  WARN: $service's NRestarts baseline was unreadable after this deploy's restart (systemctl/SSH hiccup?) — falling back to state-only crash-loop detection"
      gateway_crash_looping_state_only "$service" || return 0
      ;;
    *)
      gateway_crash_looping "$service" "$baseline" || return 0
      ;;
  esac
  local current
  current="$(gateway_nrestarts "$service")" || current="?"
  # The journal tail goes to the deploy LOG (multi-line, unescaped, complete),
  # never into the fail() message: fail() forwards its text to notify_slack,
  # which interpolates it raw into a JSON body, so newlines or quotes from a
  # journal would make that payload invalid. The message stays one bounded,
  # quote-free line; the evidence is right above it in the log.
  log "  $service journal tail (last 40 lines) follows:"
  gateway_journal_tail "$service" 40 | sed 's/^/    | /' | while IFS= read -r line; do log "$line"; done
  fail "$service is CRASH-LOOPING after this deploy's restart (NRestarts ${baseline} -> ${current}, or the unit is failed/auto-restarting); refusing to report success. Journal tail is in the deploy log above."
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
  main_baseline_nrestarts="" edge_baseline_nrestarts=""
  if needs_target "main"; then
    main_old_pid=$(gateway_main_pid "openclaw-gateway-main") || main_old_pid=""
    if [ -z "$main_old_pid" ] || [ "$main_old_pid" = "0" ]; then
      main_req=0; missing_pid_restart_req "main" || main_req=$?   # 4 = stopped by this deploy, 3 = unverifiable, fail closed
    else
      main_req=0; request_safe_restart "openclaw-gateway-main" "main" || main_req=$?
    fi
  fi
  if needs_target "edge"; then
    edge_old_pid=$(gateway_main_pid "openclaw-gateway-edge") || edge_old_pid=""
    if [ -z "$edge_old_pid" ] || [ "$edge_old_pid" = "0" ]; then
      edge_req=0; missing_pid_restart_req "edge" || edge_req=$?   # 4 = stopped by this deploy, 3 = unverifiable, fail closed
    else
      edge_req=0; request_safe_restart "openclaw-gateway-edge" "edge" || edge_req=$?
    fi
  fi
  # *_baseline_nrestarts is captured AFTER finish_gateway_restart returns —
  # i.e. once THIS deploy's own restart of the unit (whichever of the safe or
  # hard path actually fired) has completed — never before it. Live-measured
  # on node-8 (systemd 255): an explicit `systemctl restart` RESETS NRestarts
  # to 0, so a baseline read before our restart is worthless against a unit
  # that was ALREADY crash-looping when the deploy touched it (exactly the
  # 2026-09-22 incident — see gateway_crash_looping's header in
  # lib/gateway-restart.sh for the full measurement and the safe-path case).
  # check_gateway_not_crashlooping (called after the warmup wait below) then
  # only ever sees restarts that happened AFTER this deploy finished
  # restarting the unit.
  #
  # gateway_nrestarts_retry retries a bounded few times before giving up —
  # a single transient read failure right here must not disable the gate for
  # the rest of this deploy. On total failure the baseline is set to the
  # UNREADABLE_BASELINE sentinel, never "" — see check_gateway_not_crashlooping's
  # header for why conflating that with "this deploy never restarted the
  # unit" was the 2026-09-23 QA finding on #1010.
  if needs_target "main"; then
    finish_gateway_restart "openclaw-gateway-main" "$main_old_pid" "$main_req"
    main_baseline_nrestarts=$(gateway_nrestarts_retry "openclaw-gateway-main") || main_baseline_nrestarts="UNREADABLE_BASELINE"
  fi
  if needs_target "edge"; then
    finish_gateway_restart "openclaw-gateway-edge" "$edge_old_pid" "$edge_req"
    edge_baseline_nrestarts=$(gateway_nrestarts_retry "openclaw-gateway-edge") || edge_baseline_nrestarts="UNREADABLE_BASELINE"
  fi
else
  for svc_profile in main edge; do
    if needs_target "$svc_profile"; then
      log "  Skipping $svc_profile gateway restart: only gateway-inert files (docs/CI/personas/tests/templates/root-docs) changed since last deploy — nothing it loads. Override: HYDRA_FORCE_RESTART=1."
    fi
  done
fi

# Step 6 is done: the gateways run on the new runtime. Clear the record
# install_openclaw wrote (rollback.sh Step 1c consumes it). A failure INSIDE
# Step 6 keeps it on purpose: Step 1c then restores the binary only if every
# state DB's user_version is unchanged, which is the real safety measure.
rm -f "$DEPLOY_PATH/.pre-deploy-openclaw-version"

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
  check_gateway_not_crashlooping "openclaw-gateway-main" "${main_baseline_nrestarts:-}"
fi
if needs_target "edge"; then
  wait_for_agents_bound "edge" 30 || true
  check_gateway_not_crashlooping "openclaw-gateway-edge" "${edge_baseline_nrestarts:-}"
fi

# -------------------------------------------------------------------
# Step 6b: Converge the cron store (post-restart anti-clobber heal)
# -------------------------------------------------------------------
# The Step 5a import runs BEFORE the restart and is verified by a read-back —
# but the still-running gateway can rewrite its stale in-memory cron table over
# those rows at any point in the drain window, silently dropping the cron this
# deploy was adding. Full mechanism, evidence, and the 2026-08-11 timeline:
# scripts/lib/cron-store.sh.
#
# Detect it HERE, not in the smoke test: by Step 7 the only available outcome is
# a rollback (which is what happened on 2026-08-11 — main sat undeployed and
# every later push would have failed identically). One re-import + restart is
# enough because the window we are re-opening is seconds, not the 320s drain.
# A second failure is a real anomaly and fails loud rather than looping.
if needs_target "main" && [ -f "$HYDRA_ROOT/cron-jobs.json" ]; then
  log "Step 6b/8: Verifying the restarted gateway loaded the repo cron set..."
  # shellcheck source=lib/cron-store.sh
  source "$SCRIPT_DIR/lib/cron-store.sh"

  # The decision itself lives in the lib so bats can drive every branch;
  # deploy.sh supplies the real gateway lifecycle and turns exit codes into
  # messages.
  #
  # The heal runs with the gateway STOPPED: saveCronStore is replace-all with no
  # compare-and-swap, and the gateway is the only process that writes the cron
  # store, so stopping it is what makes the import exclusive instead of racing
  # a concurrent `cron add`. `Restart=always` does NOT apply after an explicit
  # stop, so the start is guaranteed by a trap as well as by the lib.
  cron_store_heal_stop() {
    local svc="openclaw-gateway-${1}"
    log "    stopping $svc for an exclusive cron-store import"
    run_on_node8 "timeout 120 ${SYSTEMCTL_BIN:-systemctl} stop $svc" || return 1
    run_on_node8 "${SYSTEMCTL_BIN:-systemctl} is-active --quiet $svc" && return 1
    CRON_HEAL_STOPPED="$svc"
    return 0
  }
  cron_store_heal_start() {
    local profile="$1" svc="openclaw-gateway-${1}"
    # Baseline captured immediately AFTER this restart completes, mirroring
    # Step 6's Phase A/B above (see the comment there for why: a `systemctl
    # restart` — this is always the hard path, since the unit was just
    # explicitly stopped — resets NRestarts to 0, so reading it before the
    # restart would be worthless against a unit that was already
    # crash-looping when this heal restarted it). Retries a bounded few times
    # on a read failure and falls back to the UNREADABLE_BASELINE sentinel
    # rather than "" — see check_gateway_not_crashlooping's header.
    local baseline
    hard_restart_gateway "$svc" || return 1
    baseline=$(gateway_nrestarts_retry "$svc") || baseline="UNREADABLE_BASELINE"
    verify_gateway_env_pin "$svc"
    wait_for_agents_bound "$profile" 30 || true
    check_gateway_not_crashlooping "$svc" "$baseline"
    CRON_HEAL_STOPPED=""
    return 0
  }
  # Belt and braces: if anything between the stop and the start kills this
  # script (set -e, a signal, an unexpected exit), bring the gateway back rather
  # than leaving the fleet down. The lib already starts it on every path; this
  # covers the paths the lib never reaches.
  CRON_HEAL_STOPPED=""
  cron_store_heal_trap() {
    if [ -n "${CRON_HEAL_STOPPED:-}" ]; then
      log "  ✗ deploy exited with $CRON_HEAL_STOPPED stopped — starting it back up"
      run_on_node8 "${SYSTEMCTL_BIN:-systemctl} start $CRON_HEAL_STOPPED" || true
      notify_slack ":rotating_light: HYDRA deploy: exited mid cron-store heal with $CRON_HEAL_STOPPED stopped; attempted an emergency start. VERIFY the gateway is up."
    fi
  }
  # COMPOSE with the existing EXIT trap (deploy lock release, set near the top
  # of this script) — a bare `trap ... EXIT` here would REPLACE it and leak the
  # deploy lock forever. Gateway first, lock second.
  trap 'cron_store_heal_trap; release_deploy_lock "$LOCK_DIR"' EXIT
  cron_store_heal_log() { log "    $*"; }
  # Exported like GATEWAY_EXEC_FN above — same seam convention, and the export
  # is also what tells the linter these are consumed by the sourced lib.
  export CRON_STORE_STOP_FN=cron_store_heal_stop
  export CRON_STORE_START_FN=cron_store_heal_start
  export CRON_STORE_LOG_FN=cron_store_heal_log

  cron_rc=0
  cron_store_converge main "$HYDRA_ROOT/cron-jobs.json" || cron_rc=$?
  case "$cron_rc" in
    0)
      log "  ✓ Main: gateway cron set matches the repo ($CRON_STORE_LOADED durable cron(s), compared by identity + schedule)" ;;
    1)
      log "  ✓ Main: cron store healed — gateway now matches the repo ($CRON_STORE_LOADED durable cron(s))"
      notify_slack ":white_check_mark: HYDRA deploy: pre-restart cron import had been clobbered; the store was re-imported and the main gateway restarted. Now loaded $CRON_STORE_LOADED cron(s), matching the repo." ;;
    2)
      fail "cron convergence: could not count jobs in $HYDRA_ROOT/cron-jobs.json" ;;
    3)
      fail "cron convergence: 'openclaw --profile main cron list --all --json' failed or returned unparseable JSON within ${CRON_STORE_READ_DEADLINE_SECS:-420}s (attempt timeout ${CRON_STORE_READ_ATTEMPT_TIMEOUT_SECS:-60}s) — refusing to assume the cron store is correct (the CLI's own error is logged directly above)" ;;
    4)
      fail "cron convergence: the gateway's cron list came back PAGINATED (hasMore=true). The durable count cannot be derived from a truncated page and this openclaw build exposes no paging flag, so the store is unverifiable — refusing to assume it is correct." ;;
    5)
      fail "cron convergence: re-import into the SQLite cron store FAILED — the gateway is running a stale cron set ($CRON_STORE_LOADED of $CRON_STORE_EXPECTED)" ;;
    6)
      fail "cron convergence: re-import persisted $CRON_STORE_PERSISTED row(s), expected $CRON_STORE_EXPECTED" ;;
    7)
      fail "cron convergence: the gateway stop/start seams were not supplied — refusing to import without an exclusive critical section" ;;
    15)
      fail "cron convergence: the repo-vs-gateway diff could not be COMPUTED before the heal, so the cron store is unverifiable. Nothing was stopped, imported or restarted. This usually means jq failed or the gateway returned an unexpected shape — check 'openclaw --profile main cron list --all --json'." ;;
    16)
      fail "cron convergence: the cron store WAS re-imported and openclaw-gateway-main WAS restarted, but the verifying diff could not be COMPUTED afterwards — convergence is UNVERIFIED, not known-bad. Check 'openclaw --profile main cron list --all --json' against /opt/hydra/cron-jobs.json before re-deploying." ;;
    13)
      fail "cron convergence: openclaw-gateway-main could not be STOPPED, so the import never ran and nothing was touched. The gateway is still up; investigate systemd before re-deploying." ;;
    14)
      fail "cron convergence: openclaw-gateway-main could not be STARTED after the cron import — THE MAIN GATEWAY IS DOWN. Run 'systemctl start openclaw-gateway-main' on node-8 now, then check 'systemctl status'." ;;
    8)
      fail "cron convergence: could not re-read the main gateway's cron list after the heal restart" ;;
    12)
      fail "cron convergence: the live cron store could not be READ, so the re-import refused to save — it could neither preserve scheduler state nor prove that no undeclared durable cron was about to be deleted. Nothing was changed. Check the gateway and the SQLite store at /root/.openclaw-main/state/openclaw.sqlite." ;;
    11)
      fail "cron convergence: a durable cron the repo does not declare appeared BETWEEN the drift check and the re-import, so the re-import ABORTED rather than delete it (saveCronStore is replace-all). Nothing was changed. Re-run the deploy; if the job is legitimate, commit it to cron-jobs.json first." ;;
    10)
      fail "cron convergence: the gateway holds durable cron(s) that cron-jobs.json does not declare (diff=$CRON_STORE_DIFF). REFUSING to heal — the re-import is delete-by-store-key and would DELETE them (this is the 2026-07-16 ChartMogul loss, PR #702/#706). Commit the job(s) to cron-jobs.json, or re-run with HYDRA_ALLOW_ORPHAN_CRON=1 to drop them deliberately." ;;
    9)
      fail "cron convergence: the gateway's cron set still does not match the repo after a re-import + restart (loaded $CRON_STORE_LOADED, repo declares $CRON_STORE_EXPECTED; diff=$CRON_STORE_DIFF). Either the clobber recurred or the store rejected a row — check 'journalctl -u openclaw-gateway-main' for 'cron: job added' around this deploy." ;;
    *)
      fail "cron convergence: unrecognized status $cron_rc from cron_store_converge" ;;
  esac
fi

# -------------------------------------------------------------------
# Step 7: Run smoke test
# -------------------------------------------------------------------
log "Step 7/8: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh" "$TARGET"; then  # hydra-hook: reviewed-indirection reviewed-argv (repo script by literal path)
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
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
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

# The baseline landed, so this deploy reached a clean end state; clear the
# mutation marker written above (right after Step 4a passed). See
# scripts/lib/deploy-rollback-gate.sh for why this must happen before the
# workflow can ever decide "no rollback needed" on a LATER run.
# A leftover marker blocks every later deploy (foreign owner), so the clear
# is checked on BOTH paths and retried once by the lib helper.
if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
  clear_mutation_marker "$DEPLOY_PATH/.deploy-mutating" \
    || fail "deploy landed but could not clear $DEPLOY_PATH/.deploy-mutating; remove it by hand or every later deploy refuses to claim it"
else
  ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
    "bash -s -- clear '$DEPLOY_PATH/.deploy-mutating'" \
    < "$SCRIPT_DIR/lib/deploy-mutation-marker.sh" \
    || fail "deploy landed but could not clear $DEPLOY_PATH/.deploy-mutating on node-8; remove it by hand or every later deploy refuses to claim it"
fi
log "  Cleared mutation marker"

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
  PROFILE=edge AGENT=support "$SCRIPT_DIR/validate-caroline-rag.sh" || rag_rc=$?  # hydra-hook: reviewed-indirection (repo script by literal path)
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
  PROFILE=main AGENT=cmo "$SCRIPT_DIR/validate-caroline-rag.sh" || main_rag_rc=$?  # hydra-hook: reviewed-indirection (repo script by literal path)
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
