#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Memory Health Check
#
# Weekly probe: measures every agent's SOUL.md and MEMORY.md
# against the per-profile `bootstrapMaxChars` cap (plus the
# total-size aggregate against `bootstrapTotalMaxChars`) and
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

LOGPREFIX="[memory-health-check $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
# All three gateway profiles run on the same host. We check each.
# Entries are "<profile>:/path/to/config.json". Edit only in unison.
PROFILES=(
  "main:/root/.openclaw-main/openclaw.json"
  "edge:/root/.openclaw-edge/openclaw.json"
  "dev:/root/.openclaw-dev/openclaw.json"
)
# The "authoritative" config for pulling the Slack token and the
# shared-cap expectation is main — edge/dev should match but we
# alert on any drift rather than picking one silently.
AUTH_CONFIG="/root/.openclaw-main/openclaw.json"
SLACK_CHANNEL="${MEMORY_HEALTH_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops
WORKSPACES_DIR="/opt/hydra/workspaces"
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
if ! hostname | grep -q '^ovh-node-8$'; then
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

# ──────────────────────────────────────────────────────────────
# slack_notify: post $msg to #clio_devops. Raises on Slack API-
# level errors (ok:false) not just HTTP errors.
# ──────────────────────────────────────────────────────────────
slack_notify() {
  local msg="$1" token
  token=$(jq -r '.channels.slack.accounts.devops.botToken // empty' "$AUTH_CONFIG" 2>/dev/null || true)
  if [ -z "${token:-}" ]; then
    log "ERROR: could not read devops bot token from $AUTH_CONFIG — skipping Slack notify"
    return 1
  fi

  # Env vars MUST precede the command; positional args after
  # `python3 -c "…"` go to sys.argv, not os.environ. Pass
  # everything via env so $msg (multi-line, backticks, quotes) is
  # JSON-escaped by python, not by bash.
  TOK="$token" CHAN="$SLACK_CHANNEL" MSG="$msg" python3 - <<'PY' 2>>/var/log/memory-health-check.log
import json, os, sys, urllib.request
req = urllib.request.Request(
    'https://slack.com/api/chat.postMessage',
    data=json.dumps({'channel': os.environ['CHAN'], 'text': os.environ['MSG']}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['TOK'], 'Content-Type': 'application/json'},
)
body = json.loads(urllib.request.urlopen(req, timeout=10).read())
if not body.get('ok'):
    print(f"slack api error: {body.get('error')}", file=sys.stderr)
    sys.exit(1)
PY
}

# ──────────────────────────────────────────────────────────────
# check_file: classify a single workspace file by size against
# the per-file cap. Populates the shared `alerts` / `warnings`
# arrays. Safe to call with size=0 (missing files).
# ──────────────────────────────────────────────────────────────
check_file() {
  local label="$1" size="$2" pct="$3"
  if [ "$size" -ge "$per_file_cap" ]; then
    alerts+=("🚨 \`$label\` is ${size}B — over the ${per_file_cap} cap.")
  elif [ "$size" -ge "$warn_threshold" ]; then
    warnings+=("⚠️ \`$label\` is ${size}B — ${pct}% of cap.")
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
  local total_warn_threshold=$((total_cap * WARN_FRACTION_PCT / 100))

  if [ ! -d "$WORKSPACES_DIR" ]; then
    alerts+=("❗ WORKSPACES_DIR $WORKSPACES_DIR does not exist — nothing to measure.")
  fi

  local -a rows=()
  local ws agent soul_size mem_size total_size soul_pct mem_pct
  if [ -d "$WORKSPACES_DIR" ]; then
    while IFS= read -r ws; do
      agent=$(basename "$ws")
      soul_size=0; mem_size=0
      [ -f "$ws/SOUL.md" ]   && soul_size=$(wc -c < "$ws/SOUL.md")
      [ -f "$ws/MEMORY.md" ] && mem_size=$(wc -c < "$ws/MEMORY.md")
      total_size=$((soul_size + mem_size))
      soul_pct=$((soul_size * 100 / per_file_cap))
      mem_pct=$((mem_size * 100 / per_file_cap))

      printf -v row "• \`%-16s\` SOUL=%5d (%d%%) MEMORY=%5d (%d%%)  total=%d" \
        "$agent" "$soul_size" "$soul_pct" "$mem_size" "$mem_pct" "$total_size"
      rows+=("$row")

      check_file "$agent/SOUL.md"   "$soul_size" "$soul_pct"
      check_file "$agent/MEMORY.md" "$mem_size"  "$mem_pct"

      # Aggregate guard: if SOUL + MEMORY alone exceeds total cap,
      # injection will truncate even though neither file is
      # individually over. (Other bootstrap files — AGENTS.md,
      # TOOLS.md, USER.md — are not measured here; this is a
      # lower-bound check.)
      if [ "$total_size" -ge "$total_cap" ]; then
        alerts+=("🚨 \`$agent\` SOUL+MEMORY total is ${total_size}B — over the ${total_cap} total cap.")
      elif [ "$total_size" -ge "$total_warn_threshold" ]; then
        warnings+=("⚠️ \`$agent\` SOUL+MEMORY total is ${total_size}B — $((total_size * 100 / total_cap))% of total cap.")
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
