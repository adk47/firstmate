#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Memory Health Check
#
# Weekly probe: measures every agent's INJECTED bootstrap files
# (SOUL, MEMORY, TOOLS, AGENTS, IDENTITY, USER, HEARTBEAT, and
# BOOTSTRAP when present — openclaw's canonical set) against that
# agent's EFFECTIVE `bootstrapMaxChars` (per-agent override, else
# its profile's default) in CHARACTERS, plus the aggregate against
# `bootstrapTotalMaxChars`, and
# posts a summary to #clio_devops. Guardrail against the silent
# truncation regression described in hydra issue #165.
#
# Runs weekly via root crontab ON NODE-8 (local to the gateways).
# Must run as root — reads /root/.openclaw-<profile>/openclaw.json.
#
# Install on node-8 (deploy.sh already syncs this file to
# /opt/hydra/scripts/, so you only need the crontab line):
#   sudo crontab -e:
#     17 9 * * 1 /opt/hydra/scripts/memory-health-check.sh >> /var/log/memory-health-check.log 2>&1
#
# Flags:
#   --dry-run    compute + print the Slack payload, don't post.
#                Useful for rehearsing migrations without paging
#                #clio_devops.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# slack_load_env (token sourcing from main.env) lives in the shared lib; the
# local slack_notify below overrides the lib's silent best-effort variant.
# shellcheck source=lib/slack-notify.sh
source "$(dirname "$0")/lib/slack-notify.sh"

LOGPREFIX="[memory-health-check $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
# All three gateway profiles run on the same host. We check each.
# Entries are "<profile>:/path/to/config.json". Edit only in unison.
# Overridable for the bats suite (hermetic fixtures); production uses the
# defaults. Same seam idiom as the other node-8 scripts.
PROFILES=(
  "main:${MEMORY_HEALTH_MAIN_CONFIG:-/root/.openclaw-main/openclaw.json}"
  "edge:${MEMORY_HEALTH_EDGE_CONFIG:-/root/.openclaw-edge/openclaw.json}"
)
# The "authoritative" config for pulling the Slack token and the
# shared-cap expectation is main — edge should match but we
# alert on any drift rather than picking one silently.
AUTH_CONFIG="${MEMORY_HEALTH_MAIN_CONFIG:-/root/.openclaw-main/openclaw.json}"
SLACK_CHANNEL="${MEMORY_HEALTH_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops
WORKSPACES_DIR="${MEMORY_HEALTH_WORKSPACES_DIR:-/opt/hydra/workspaces}"
# Emit a warning at this fraction of the configured cap, and alert
# at 100%. 80% gives two weeks of headroom at typical drift rates.
WARN_FRACTION_PCT=80
# Expected minimum per-file cap. Anything below is treated as a
# regression vs the hydra issue #165 fix (which set 40000). Fire an
# alert if caught in the wild, regardless of whether it's the
# openclaw default (12000) or a deliberate downgrade.
EXPECTED_MIN_PER_FILE_CAP=40000
LOCKFILE="/var/run/memory-health-check.lock"
DRY_RUN=0

log() { echo "$LOGPREFIX $1"; }

# ──────────────────────────────────────────────────────────────
# Parse flags
# ──────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────────────────────
# Sanity: host guard + required tools + single-run lock.
# Wrong node → no-op (prevents orphaned cron after host migration).
# ──────────────────────────────────────────────────────────────
if [ "${MEMORY_HEALTH_SKIP_HOST_GUARD:-0}" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { log "ERROR: jq required but not on PATH"; exit 2; }

# Fail fast if another run is active (overlapping weekly ticks after
# a reboot or a manual run colliding with cron would otherwise
# double-post to Slack).
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another memory-health-check run holds $LOCKFILE"; exit 0; }
fi

# ──────────────────────────────────────────────────────────────
# resolve_cap: read a positive-integer key from agents.defaults of
# $config_path. Returns tri-state via stdout + exit code:
#   stdout = the resolved integer (or $default on any failure)
#   exit 0 = key present, valid int > 0
#   exit 3 = config file missing or unreadable
#   exit 4 = key absent
#   exit 5 = key present but not a positive int (bad type / value)
# Callers use the exit code to distinguish "fallback fired" from
# "key set deliberately" and emit distinct Slack alerts. Without
# this, the script's own guardrail degrades to the same silent-
# failure class the PR was designed to eliminate.
# ──────────────────────────────────────────────────────────────
resolve_cap() {
  local config_path="$1" key="$2" default="$3" val
  if [ ! -r "$config_path" ]; then
    echo "$default"
    return 3
  fi
  val=$(jq -r --arg k "$key" '.agents.defaults[$k] // "__ABSENT__"' "$config_path" 2>/dev/null || echo "__ERROR__")
  if [ "$val" = "__ERROR__" ]; then
    echo "$default"
    return 3
  fi
  if [ "$val" = "__ABSENT__" ]; then
    echo "$default"
    return 4
  fi
  if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ]; then
    echo "$val"
    return 0
  fi
  echo "$default"
  return 5
}

# resolve_agent_cap <agent> <key> <default> — the EFFECTIVE cap for one agent,
# resolved the way openclaw resolves it:
#     resolveAgentConfig(cfg, agentId)?.<key> ?? cfg.agents.defaults.<key>
# (dist/embedded-agent-helpers-*.js, verified on 2026.7.1).
#
# Why this is not just resolve_cap: this script scans EVERY workspace but read
# only main's agents.defaults, so an edge agent was measured against main's cap.
# support carries agents.list[id=support].bootstrapMaxChars=50000 while main's
# default is 40000 — that mismatch reported support/SOUL.md at "99% of cap" when
# it is really 79%, and would have hard-alerted the moment TOOLS.md (46k) was
# added to the scan. Per-agent resolution is a precondition for measuring it.
# Tri-state, deliberately — mirroring resolve_cap above. A listed agent whose cap
# is invalid (`"bad"`, `0`) must NOT look like an unlisted workspace: that is the
# silent-fallback class this whole script exists to catch, and collapsing the two
# would let it measure against the wrong threshold and say nothing.
#   exit 0 = resolved, valid int > 0
#   exit 1 = agent is listed in NO profile (orphan dir / defaults stub) — the one
#            case where falling back to the caller's default is legitimate
#   exit 6 = agent IS listed but its per-agent value (or that profile's default)
#            is missing/non-numeric/<=0 — caller must alert
#   exit 7 = the owning profile's config is unreadable — caller must alert
resolve_agent_cap() {
  local agent="$1" key="$2" default="$3" entry path val listed=0 unreadable=0
  for entry in "${PROFILES[@]}"; do
    path="${entry#*:}"
    if [ ! -r "$path" ]; then unreadable=1; continue; fi
    # Is this the profile that owns the agent? Ask separately from the value so
    # "listed with a bad value" stays distinguishable from "not listed".
    if [ "$(jq -r --arg a "$agent" '(.agents.list // []) | map(.id) | index($a) != null' "$path" 2>/dev/null)" != "true" ]; then
      continue
    fi
    listed=1
    val=$(jq -r --arg a "$agent" --arg k "$key" '
      ((.agents.list[] | select(.id==$a) | .[$k]) // (.agents.defaults[$k]) // empty)
      ' "$path" 2>/dev/null | head -1)
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ]; then echo "$val"; return 0; fi
  done
  echo "$default"
  [ "$listed" -eq 1 ] && return 6
  [ "$unreadable" -eq 1 ] && return 7
  return 1
}

# ──────────────────────────────────────────────────────────────
# slack_notify: post $msg to #clio_devops via `muso slack send`
# (gated CLI, devops bot). muso decodes Slack's HTTP-200 ok:false
# trap itself, so its exit code is real delivery status — $msg
# never touches a shell-built JSON body. Tokens come from
# MUSO_SLACK_BOT_TOKEN_* (pulled from main.env when the unit env
# lacks them).
# ──────────────────────────────────────────────────────────────
slack_notify() {
  local msg="$1"
  if ! slack_load_env devops; then
    log "ERROR: no MUSO_SLACK_BOT_TOKEN_DEVOPS in env or main.env — skipping Slack notify"
    return 1
  fi
  "${MUSO_BIN:-muso}" slack send --bot devops \
    --channel "$SLACK_CHANNEL" --text "$msg" \
    --requester "memory-health-check@hydra-ops" \
    >/dev/null 2>>/var/log/memory-health-check.log
}

# ──────────────────────────────────────────────────────────────
# check_file: classify a single workspace file by size against
# the per-file cap. Populates the shared `alerts` / `warnings`
# arrays. Safe to call with size=0 (missing files).
# ──────────────────────────────────────────────────────────────
# check_file <label> <chars> <pct> [cap] [warn] — cap/warn default to the
# global (main) values for callers outside the per-agent workspace loop.
# Sizes are CHARACTERS (openclaw caps on chars, not bytes) — see the wc -m note
# at the measurement site.
check_file() {
  local label="$1" size="$2" pct="$3"
  local cap="${4:-$per_file_cap}" warn="${5:-$warn_threshold}"
  if [ "$size" -ge "$cap" ]; then
    alerts+=("🚨 \`$label\` is ${size} chars — over the ${cap} cap.")
  elif [ "$size" -ge "$warn" ]; then
    warnings+=("⚠️ \`$label\` is ${size} chars — ${pct}% of cap.")
  fi
}

# ──────────────────────────────────────────────────────────────
# Collect sizes and flag anything over the warn fraction.
# ──────────────────────────────────────────────────────────────
main() {
  # ── Phase 1: resolve + cross-profile cap check ──────────────
  local -a profile_rows=()
  local -a alerts=() warnings=()
  local auth_cap auth_total_cap auth_warn_mode
  local auth_rc auth_total_rc

  # Pull the authoritative cap from main. Any failure at this step
  # is itself a critical alert — we do NOT want to fall back and
  # then declare "all clear".
  auth_cap=$(resolve_cap "$AUTH_CONFIG" bootstrapMaxChars 12000) || auth_rc=$?
  auth_rc=${auth_rc:-0}
  auth_total_cap=$(resolve_cap "$AUTH_CONFIG" bootstrapTotalMaxChars 60000) || auth_total_rc=$?
  auth_total_rc=${auth_total_rc:-0}
  auth_warn_mode=$(jq -r '.agents.defaults.bootstrapPromptTruncationWarning // "missing"' "$AUTH_CONFIG" 2>/dev/null || echo "missing")

  # Translate resolve_cap exit codes to human alerts.
  case "$auth_rc" in
    0) ;;
    3) alerts+=("❗ $AUTH_CONFIG unreadable or missing — cap fallback 12000 in effect.") ;;
    4) alerts+=("❗ agents.defaults.bootstrapMaxChars absent in $AUTH_CONFIG — fallback 12000 in effect.") ;;
    5) alerts+=("❗ agents.defaults.bootstrapMaxChars in $AUTH_CONFIG is not a positive integer — fallback 12000 in effect.") ;;
  esac
  case "$auth_total_rc" in
    0) ;;
    3|4|5) alerts+=("❗ agents.defaults.bootstrapTotalMaxChars unreadable/absent/invalid in $AUTH_CONFIG (rc=$auth_total_rc).") ;;
  esac

  if [ "$auth_rc" -eq 0 ] && [ "$auth_cap" -lt "$EXPECTED_MIN_PER_FILE_CAP" ]; then
    alerts+=("❗ bootstrapMaxChars=${auth_cap} in main profile is below expected minimum ${EXPECTED_MIN_PER_FILE_CAP}. Silent truncation risk restored.")
  fi

  # Compare each profile against main; flag drift.
  local profile path prof_cap prof_total prof_warn
  for entry in "${PROFILES[@]}"; do
    profile="${entry%%:*}"
    path="${entry#*:}"
    # Reset rc vars EACH iteration — `|| prof_rc=$?` only fires on
    # failure, so a previous iteration's error code would leak into
    # the next one and wrongly re-flag a healthy profile.
    local prof_rc=0 prof_total_rc=0
    prof_cap=$(resolve_cap "$path" bootstrapMaxChars 12000) || prof_rc=$?
    prof_total=$(resolve_cap "$path" bootstrapTotalMaxChars 60000) || prof_total_rc=$?
    prof_warn=$(jq -r '.agents.defaults.bootstrapPromptTruncationWarning // "missing"' "$path" 2>/dev/null || echo "missing")

    profile_rows+=("$(printf '• %-6s perFile=%-7s total=%-7s warn=%s' "$profile" "$prof_cap" "$prof_total" "$prof_warn")")

    if [ "$prof_rc" -ne 0 ] || [ "$prof_total_rc" -ne 0 ]; then
      alerts+=("❗ profile \`$profile\`: cap resolution failed (rc=$prof_rc/$prof_total_rc) — silent truncation risk.")
      continue
    fi
    if [ "$prof_cap" -ne "$auth_cap" ] || [ "$prof_total" -ne "$auth_total_cap" ] || [ "$prof_warn" != "$auth_warn_mode" ]; then
      alerts+=("❗ profile \`$profile\` drifted from main: perFile=$prof_cap (expected $auth_cap), total=$prof_total (expected $auth_total_cap), warn=$prof_warn (expected $auth_warn_mode).")
    fi
  done

  # ── Phase 2: per-workspace size scan ────────────────────────
  local per_file_cap="$auth_cap"
  local total_cap="$auth_total_cap"
  local warn_threshold=$((per_file_cap * WARN_FRACTION_PCT / 100))

  if [ ! -d "$WORKSPACES_DIR" ]; then
    alerts+=("❗ WORKSPACES_DIR $WORKSPACES_DIR does not exist — nothing to measure.")
  fi

  local -a rows=()
  # openclaw's canonical injected set (workspace-DkQ7irPD.js). BOOTSTRAP.md is
  # canonical too but is the un-onboarded marker, so absence is healthy — it is
  # sized when present and never demanded.
  local -a INJECTED_FILES=(SOUL.md MEMORY.md TOOLS.md AGENTS.md IDENTITY.md USER.md HEARTBEAT.md BOOTSTRAP.md)
  local ws agent soul_size mem_size total_size soul_pct mem_pct
  local f fsize tools_size agent_cap agent_warn agent_total_cap
  if [ -d "$WORKSPACES_DIR" ]; then
    while IFS= read -r ws; do
      agent=$(basename "$ws")
      # Effective caps for THIS agent (per-agent override ?? its profile's
      # defaults), not main's defaults for everyone.
      local cap_rc=0 tcap_rc=0
      agent_cap=$(resolve_agent_cap "$agent" bootstrapMaxChars "$per_file_cap") || cap_rc=$?
      agent_total_cap=$(resolve_agent_cap "$agent" bootstrapTotalMaxChars "$total_cap") || tcap_rc=$?
      # rc 1 (unlisted workspace) is the only benign fallback. 6/7 mean we are
      # measuring against a threshold the agent does not actually run under —
      # alert rather than silently mis-measure.
      case "$cap_rc" in
        6) alerts+=("❗ \`$agent\` bootstrapMaxChars is invalid in its own profile — measuring against fallback ${agent_cap}.") ;;
        7) alerts+=("❗ \`$agent\` owning profile config unreadable — measuring against fallback ${agent_cap}.") ;;
      esac
      case "$tcap_rc" in
        6) alerts+=("❗ \`$agent\` bootstrapTotalMaxChars is invalid in its own profile — measuring against fallback ${agent_total_cap}.") ;;
        7) alerts+=("❗ \`$agent\` owning profile config unreadable (total cap) — measuring against fallback ${agent_total_cap}.") ;;
      esac
      agent_warn=$((agent_cap * WARN_FRACTION_PCT / 100))

      soul_size=0; mem_size=0; tools_size=0; total_size=0
      for f in "${INJECTED_FILES[@]}"; do
        [ -f "$ws/$f" ] || continue
        # CHARACTERS, not bytes: openclaw caps on chars, so `wc -c` over-counts
        # any multibyte content and under-reports headroom. Forced UTF-8 locale
        # because `wc -m` silently falls back to bytes in a non-UTF-8 context.
        fsize=$(LC_ALL=C.UTF-8 wc -m < "$ws/$f" | tr -d '[:space:]')
        total_size=$((total_size + fsize))
        case "$f" in
          SOUL.md)   soul_size=$fsize ;;
          MEMORY.md) mem_size=$fsize ;;
          TOOLS.md)  tools_size=$fsize ;;
        esac
        check_file "$agent/$f" "$fsize" "$((fsize * 100 / agent_cap))" "$agent_cap" "$agent_warn"
      done
      soul_pct=$((soul_size * 100 / agent_cap))
      mem_pct=$((mem_size * 100 / agent_cap))

      # TOOLS is shown explicitly: it is the file that actually truncated on
      # edge, and it is invisible to the CI gate (rsync-excluded, so CI sees
      # only a repo seed). A healthy TOOLS.md must still be readable here or
      # nobody sees it approaching the cap until it is already warning.
      printf -v row "• \`%-16s\` SOUL=%5d (%d%%) MEMORY=%5d (%d%%) TOOLS=%5d (%d%%)  total=%d/%d" \
        "$agent" "$soul_size" "$soul_pct" "$mem_size" "$mem_pct" \
        "$tools_size" "$((tools_size * 100 / agent_cap))" "$total_size" "$agent_total_cap"
      rows+=("$row")

      # Aggregate guard: once the sum of injected files exceeds the total cap,
      # openclaw drops whole files even when none is individually over. This is
      # now the REAL total (all injected files, per-agent cap), not the
      # SOUL+MEMORY lower bound it used to be.
      if [ "$total_size" -ge "$agent_total_cap" ]; then
        alerts+=("🚨 \`$agent\` injected total is ${total_size} chars — over the ${agent_total_cap} total cap.")
      elif [ "$total_size" -ge $((agent_total_cap * WARN_FRACTION_PCT / 100)) ]; then
        warnings+=("⚠️ \`$agent\` injected total is ${total_size} chars — $((total_size * 100 / agent_total_cap))% of total cap.")
      fi
    done < <(find "$WORKSPACES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi

  if [ -d "$WORKSPACES_DIR" ] && [ "${#rows[@]}" -eq 0 ]; then
    alerts+=("❗ No workspaces found under $WORKSPACES_DIR — scan produced zero rows.")
  fi

  # ── Phase 3: build + post message ───────────────────────────
  local status="✅ all clear"
  [ "${#warnings[@]}" -gt 0 ] && status="⚠️ ${#warnings[@]} warning(s)"
  [ "${#alerts[@]}"   -gt 0 ] && status="🚨 ${#alerts[@]} alert(s)"

  local rows_block="(no workspace rows)"
  [ "${#rows[@]}" -gt 0 ] && rows_block=$(printf '%s\n' "${rows[@]}")
  local profiles_block
  profiles_block=$(printf '%s\n' "${profile_rows[@]}")
  local alerts_block=""
  [ "${#alerts[@]}" -gt 0 ] && alerts_block=$'\n\n*Alerts*\n'$(printf '%s\n' "${alerts[@]}")
  local warnings_block=""
  [ "${#warnings[@]}" -gt 0 ] && warnings_block=$'\n\n*Warnings*\n'$(printf '%s\n' "${warnings[@]}")

  local msg
  msg=$(cat <<EOF
*Memory health check*  ${status}
_main cap: perFile=${per_file_cap} total=${total_cap} warn=${auth_warn_mode} · warn at ${WARN_FRACTION_PCT}%_

*Profiles*
${profiles_block}

*Workspaces*
${rows_block}${alerts_block}${warnings_block}
EOF
)

  log "status=${status} per_file_cap=${per_file_cap} total_cap=${total_cap} warnings=${#warnings[@]} alerts=${#alerts[@]} dry_run=${DRY_RUN}"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "--- DRY-RUN PAYLOAD (channel=${SLACK_CHANNEL}) ---"
    echo "$msg"
    echo "--- END DRY-RUN ---"
  else
    slack_notify "$msg" || log "WARN: Slack post failed (see /var/log/memory-health-check.log)"
  fi
}

main "$@"
