#!/usr/bin/env bash
set -euo pipefail

# HYDRA Deploy Script
# ===================
# CD entrypoint: validate config, sync to Node 8, restart gateway, smoke test.
# Supports targeted deployment: --target main|edge|dev|all
#
# Run from node-8 itself (preferred — CI does this) or via SSH from a
# laptop. Laptop deploys go through the rsync-over-SSH branches but the
# POSTSYNC heredoc, Steps 4c/4d, and the profile config sync run on
# the local box, so a laptop deploy is only viable when the local box
# IS node-8 or a similar Linux host with /root/.openclaw/ access.
# In practice: SSH into node-8 first, then run deploy.sh from there.
#     ssh -i ~/.ssh/nick_ovh root@40.160.32.80
#     cd /opt/hydra && ./scripts/deploy.sh [--target main|edge|dev|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

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
      [[ -z "${2:-}" ]] && { echo "Error: --target requires a value (main|edge|dev|all)"; exit 1; }
      TARGET="$2"; shift 2 ;;
    main|edge|dev|all) TARGET="$1"; shift ;;
    *) echo "Usage: deploy.sh [--target main|edge|dev|all]"; exit 1 ;;
  esac
done

# Validate target value (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|dev|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|dev|all"; exit 1 ;;
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
# Plugin helpers (new in 2026-04-08 CD consolidation)
# -------------------------------------------------------------------

# plugin_profile — returns the target profile(s) for a given plugin name.
# Stdout is a space-separated list of profiles (caller iterates);
# diagnostic notices go to stderr to avoid polluting the captured value.
#
#   intercom       → "main edge"   (both main and edge reference it — see
#                                    openclaw-main.json and openclaw-edge.json
#                                    `plugins.installs`/`channels.intercom`)
#   support-tools  → "edge"
#   openclaw-gmail → "main"
#   everything else → "main" (with a stderr warning, so a typo in plugin
#                              dir name is at least visible in deploy logs)
#
# If the mapping ever grows, extend the case statement here — there is no
# other source of truth. Note that no plugins currently target the dev
# profile; if a dev-only plugin is added in the future, the case statement
# will need a new branch.
#
# History: intercom was previously mapped to "edge" only, which caused
# /root/.openclaw-main/extensions/intercom to drift missing even though
# openclaw-main.json pins intercom in plugins.load.paths. The main gateway
# crashlooped with "plugin path not found" on 2026-04-24 (deploy of PR #170)
# until the plugin dir was hot-patched in. See memory
# project_deploy_plugin_path_drift.md.
plugin_profile() {
  local plugin_name="$1"
  case "$plugin_name" in
    intercom)       echo "main edge" ;;
    support-tools)  echo "edge" ;;
    openclaw-gmail) echo "main" ;;
    *)
      echo "main"
      echo "    plugin_profile: '$plugin_name' is not in the known mapping (intercom→main+edge, support-tools→edge, openclaw-gmail→main); defaulting to main. Verify this is intended — typos in plugin directory names land here silently." >&2
      ;;
  esac
}

# install_plugin — installs a single plugin into its target profile's
# openclaw extension directory. Single-arg: derives the profile
# internally via plugin_profile. Idempotent: re-running reinstalls.
#
# Fails with a structured error on npm install failure. The caller
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

  # Run npm install, capture both exit code and stderr for clear
  # error reporting.  Check the directory exists first so a missing
  # plugin_dir reports "not found" rather than lying about npm.
  local npm_out
  local npm_rc=0
  if [[ ! -d "$plugin_dir" ]]; then
    log "    ✗ plugin_dir not found: $plugin_dir"
    return 1
  fi
  npm_out=$(cd "$plugin_dir" && npm install --production 2>&1) || npm_rc=$?
  if (( npm_rc != 0 )); then
    log "    ✗ npm install failed for $plugin_name (rc=$npm_rc):"
    echo "$npm_out" | sed 's/^/        /'
    return 1
  fi

  # Determine the target extension paths per profile.
  #
  # Historically install_plugin only wrote to the legacy unified path
  # (/root/.openclaw/extensions/). That path pre-dates the multi-profile
  # migration (PR #43) and the running gateway services now read from
  # PROFILE-specific dirs:
  #
  #   openclaw-gateway-main.service  → /root/.openclaw-main/extensions/
  #   openclaw-gateway-edge.service  → /root/.openclaw-edge/extensions/
  #   openclaw-gateway-dev.service   → /root/.openclaw-dev/extensions/
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
  # existing installPath pinnings in openclaw-main.json for openclaw-gmail
  # and intercom). Once all `installs` entries are moved to profile-specific
  # paths, the legacy write can go.
  local ext_paths=()
  for profile in $profiles; do
    if ! needs_target "$profile"; then continue; fi
    case "$profile" in
      main|edge|dev)
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
  #    legacy path today (openclaw-gmail, intercom — both main-scoped).
  #    openclaw-edge.json and openclaw-dev.json do not pin anything at the
  #    legacy path, so mirroring from those profiles is dead weight.
  #
  # 2. Without this gate, `deploy.sh --target edge` would overwrite
  #    /root/.openclaw/extensions/<plugin> with the EDGE build. Today every
  #    profile ships identical plugin code, so it is a no-op — but if edge
  #    or dev ever diverges (feature flags, alternate entrypoints, vendored
  #    deps), a last-writer-wins race silently breaks main's pinned plugins.
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
  # Python bytecode cache. Created at runtime when any python3 process
  # imports from /opt/hydra/scripts/lib/. Server-owned, rebuilt on each
  # import, never in the repo. Tripped the deploy pre-flight on
  # 2026-04-14 (PR #102) after running worker sanity checks on node-8.
  --exclude='__pycache__/'
  --exclude='*.pyc'
  # Hot-patch timestamped backups (convention: <orig>.bak.YYYYMMDDTHHMMSSZ).
  # Created on the live server when an operator hot-patches a script or
  # SKILL.md and copies the original aside before editing — see
  # feedback_hot_patch_pattern memory note. The .bak files are operator
  # safety nets, not durable repo content. Server-owned, never seeded
  # from repo, would trip pre-flight if not excluded.
  --exclude='*.bak.*'
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
  # Plugin install artifacts (server runs npm install in-place)
  --exclude='plugins/*/node_modules/'
  --exclude='plugins/*/package-lock.json'
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
  # Skill daily batch outputs (runtime data generated by CMO outreach engine)
  --exclude='workspaces/*/skills/*/references/daily-batches/'
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
if needs_target "dev"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-dev.json" >/dev/null 2>&1 || fail "openclaw-dev.json is not valid JSON"
  log "  openclaw-dev.json is valid JSON."
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
  needs_target "dev"  && lint_targets+=("$HYDRA_ROOT/openclaw-dev.json")
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
if needs_target "dev"; then validate_souls "$HYDRA_ROOT/openclaw-dev.json" "dev"; fi
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

  # Content drift in skills-all/: itemize cols are YXcstpoguax.
  # We require col 2 = 'f' (file, not dir) AND (col 3 = 'c' or col 4 = 's').
  # Without the col-2 'f' filter we'd false-match directory entries with
  # `cd+++++++++` flags. The Step 0 awk uses the same shape — keeping
  # them symmetric so a future bug fix to one applies to the other.
  local skills_drift
  skills_drift=$(echo "$dry_out" \
    | awk '{ if (substr($0,2,1)=="f" && (substr($0,3,1)=="c" || substr($0,4,1)=="s")) print }' \
    | grep -F 'skills-all/' || true)

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
✗ DEPLOY BLOCKED — skills-all/ content drift detected on node-8
================================================================================

WHAT THIS MEANS:
  Someone (often Fede) edited files under /opt/hydra/skills-all/ DIRECTLY
  on node-8. The repo does NOT have those edits. If you push past this
  check, the rsync --delete will permanently OVERWRITE their work and
  there is NO backup. Skill files are how Muso's agents do real work —
  losing them silently breaks production.

DRIFTED FILES (server has changes the repo doesn't):
$(echo "$skills_drift" | sed 's/^/  /')

THE ONLY SAFE FIX (do this, in order):
  1. scripts/sync-from-server.sh skills           # dry-run, see what's there
  2. scripts/sync-from-server.sh skills --apply   # actually pull into repo
  3. git status skills-all/ && git diff skills-all/
  4. Read each diff. If the changes are intentional, commit them:
       git add skills-all/
       git commit -m "chore: pull skill edits from node-8"
  5. Re-run deploy. Pre-flight should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  - You have explicit confirmation from the editor that they want their
    changes discarded, AND
  - You have verified each file in the list above is safe to overwrite,
    AND
  - You understand this destroys the work permanently.

  If ANY of those is not true, STOP. Run sync-from-server.sh first.
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
# Step 4c: Sync global skills to openclaw skills dir
# -------------------------------------------------------------------
# Moved from deploy.yml's "Sync global skills" step on 2026-04-08
# (CD consolidation). skills-all/ is a global library used by agents
# across ALL profiles — muso-intercom is used by edge's support agent,
# muso-devops by main's devops agent, etc. Runs unconditionally when
# skills-all/ exists, regardless of --target.
log "Step 4c/9: Syncing global skills..."
if [[ -d "$HYDRA_ROOT/skills-all" ]]; then
  mkdir -p /root/.openclaw/skills/skills/
  skills_rc=0
  # RSYNC_EXCLUDES is passed to satisfy .githooks/pre-commit Check 2,
  # which enforces that every rsync call references the shared array.
  # None of the workspace/audit/plugin patterns in RSYNC_EXCLUDES match
  # anything inside skills-all/, so they're no-ops here — same rationale
  # as the install_plugin rsync. See the comment there for more detail.
  rsync -az --delete "${RSYNC_EXCLUDES[@]}" "$HYDRA_ROOT/skills-all/" /root/.openclaw/skills/skills/ || skills_rc=$?
  if (( skills_rc != 0 )); then
    fail "skills-all/ sync failed (rsync rc=$skills_rc)"
  fi
  skill_count=$(find /root/.openclaw/skills/skills/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  log "  ✓ Synced $skill_count skills to /root/.openclaw/skills/skills/"
else
  log "  skills-all/ not found in repo — skipping"
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
  SRC="$src" DST="$dst" python3 - <<'PYEOF' || fail "profile config sync failed for $dst"
import json, os, sys, tempfile, time
src_path = os.environ['SRC']
dst_path = os.environ['DST']

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
    tmp.close()
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
if needs_target "dev"; then
  sync_profile_config "$DEPLOY_PATH/openclaw-dev.json" /root/.openclaw-dev/openclaw.json
  log "  Synced dev profile config"
fi

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
  if needs_target "dev" && [ -f /root/.openclaw-dev/openclaw.json ]; then
    live_lint_targets+=(/root/.openclaw-dev/openclaw.json)
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

# Use local embeddings for memory search on main profile
python3 -c "
import json
cfg = '/root/.openclaw/main/openclaw.json'
with open(cfg) as f:
    c = json.load(f)
defaults = c.setdefault('agents', {}).setdefault('defaults', {})
defaults['memorySearch'] = {'enabled': True, 'provider': 'local'}
c.get('models', {}).get('providers', {}).pop('openai', None)
with open(cfg, 'w') as f:
    json.dump(c, f, indent=2)
print('  Memory search: local embeddings (no OpenAI)')
"

# Gmail plugin patches are now baked into the forked source at
# plugins/openclaw-gmail/ — no deploy-time sed needed.
POSTSYNC

log "  Post-sync setup complete."

# -------------------------------------------------------------------
# Step 5b: Apply k8s manifests
# -------------------------------------------------------------------
# Moved from deploy.yml's "Apply K8s manifests" step on 2026-04-08
# (CD consolidation). Captures current state to /tmp for the
# rollback.sh kubectl-apply path, then kubectl apply the manifests.
# Skips silently if k8s/prod/hydra/ is missing (verified 2026-04-08:
# directory does not currently exist on node-8 — Step 5b exercises
# the skip branch on every live deploy until someone populates it).
log "Step 5b/9: Applying k8s manifests..."
if [[ -d "$HYDRA_ROOT/k8s/prod/hydra" ]]; then
  # Capture current state for rollback. Use namespace from env, fallback
  # to hydra which is the production namespace. The 2>/dev/null || true
  # tolerates "namespace not found" / "kubectl not configured" so the
  # snapshot is best-effort, but we explicitly check the resulting
  # files are non-empty before referencing them in the failure message.
  k8s_ns="${HYDRA_NAMESPACE:-hydra}"
  kubectl get deployments -n "$k8s_ns" -o yaml > /tmp/hydra-rollback-deployments.yaml 2>/dev/null || true
  kubectl get configmaps -n "$k8s_ns" -o yaml > /tmp/hydra-rollback-configmaps.yaml 2>/dev/null || true

  # Apply the manifests.
  apply_rc=0
  kubectl apply -f "$HYDRA_ROOT/k8s/prod/hydra/" --namespace="$k8s_ns" || apply_rc=$?
  if (( apply_rc != 0 )); then
    # Build a recovery hint that's honest about whether the rollback
    # snapshot actually contains anything useful.
    rollback_hint="rollback yaml at /tmp/hydra-rollback-{deployments,configmaps}.yaml"
    if [[ ! -s /tmp/hydra-rollback-deployments.yaml ]]; then
      rollback_hint="WARNING: /tmp/hydra-rollback-deployments.yaml is empty (kubectl get deployments returned nothing — namespace missing or kubectl not configured?). No automatic recovery available; manual investigation required."
    fi
    fail "kubectl apply failed (rc=$apply_rc) — $rollback_hint. To revert manually if the snapshot is non-empty: kubectl apply -f /tmp/hydra-rollback-deployments.yaml -n $k8s_ns"
  fi
  log "  ✓ K8s manifests applied to namespace=$k8s_ns"
else
  log "  k8s/prod/hydra/ not found in repo — skipping k8s apply"
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
if needs_target "dev"; then restart_gateway "openclaw-gateway-dev"; fi

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
if needs_target "dev"; then
  wait_for_agents_bound "dev" 30 || true
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
# Step 9: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
log "Step 9/9: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully (target: $TARGET). Commit: $COMMIT_SHA"
log "Deploy complete. Target: $TARGET. Commit: $COMMIT_SHA"
