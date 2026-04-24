#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Memory Health Check
#
# Weekly probe: measures every agent's SOUL.md and MEMORY.md
# against the configured bootstrapMaxChars cap and posts a
# summary to #clio_devops. Guardrail against the silent
# truncation regression described in hydra issue #165.
#
# Runs weekly via root crontab ON NODE-8 (local to the gateways).
#
# Install on node-8:
#   cp scripts/memory-health-check.sh /opt/hydra/scripts/memory-health-check.sh
#   chmod +x /opt/hydra/scripts/memory-health-check.sh
#   crontab -e:
#     17 9 * * 1 /opt/hydra/scripts/memory-health-check.sh >> /var/log/memory-health-check.log 2>&1
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[memory-health-check $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
OPENCLAW_CONFIG="/root/.openclaw-main/openclaw.json"
SLACK_CHANNEL="${MEMORY_HEALTH_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops
WORKSPACES_DIR="/opt/hydra/workspaces"
# Emit a warning at this fraction of the configured cap, and alert
# at 100%. 80% gives two weeks of headroom at typical drift rates.
WARN_FRACTION_PCT=80

log() { echo "$LOGPREFIX $1"; }

# ──────────────────────────────────────────────────────────────
# Resolve caps from live config. Falls back to openclaw defaults
# (12000 per-file, 60000 total) if the keys are unset — which is
# itself the regression we are guarding against, so we flag it.
# ──────────────────────────────────────────────────────────────
resolve_cap() {
  local key="$1" default="$2"
  python3 -c "
import json, sys
with open('${OPENCLAW_CONFIG}') as f:
    c = json.load(f)
v = c.get('agents', {}).get('defaults', {}).get('${key}')
print(v if isinstance(v, int) and v > 0 else ${default})
" 2>/dev/null || echo "$default"
}

slack_notify() {
  local msg="$1"
  local token
  token=$(python3 -c "
import json
with open('${OPENCLAW_CONFIG}') as f:
    c = json.load(f)
print(c['channels']['slack']['accounts']['devops']['botToken'])
" 2>/dev/null) || true

  if [ -z "${token:-}" ]; then
    log "WARN: Could not read devops bot token — skipping Slack notify"
    return
  fi

  # Slack payload via python to handle JSON escaping safely.
  # Env assignments MUST precede the command; positional args after
  # `python3 -c "…"` go to sys.argv, not os.environ.
  TOK="$token" CHAN="$SLACK_CHANNEL" MSG="$msg" python3 -c "
import json, os, urllib.request
req = urllib.request.Request(
    'https://slack.com/api/chat.postMessage',
    data=json.dumps({'channel': os.environ['CHAN'], 'text': os.environ['MSG']}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['TOK'], 'Content-Type': 'application/json'}
)
urllib.request.urlopen(req, timeout=10).read()
" 2>/dev/null || log "WARN: Slack post failed"
}

# ──────────────────────────────────────────────────────────────
# Collect sizes and flag anything over the warn fraction.
# ──────────────────────────────────────────────────────────────
main() {
  local per_file_cap
  local total_cap
  per_file_cap=$(resolve_cap bootstrapMaxChars 12000)
  total_cap=$(resolve_cap bootstrapTotalMaxChars 60000)
  local warn_threshold=$((per_file_cap * WARN_FRACTION_PCT / 100))

  local -a rows=()
  local -a warnings=()
  local -a alerts=()

  # config-level sanity: if either cap resolves to the openclaw
  # default, the override is missing — that's itself worth a ping
  # because it means the regression is unguarded.
  if [ "$per_file_cap" -le 12000 ]; then
    alerts+=("❗ *bootstrapMaxChars override missing or <=12000* — silent truncation will resume on any file above that cap.")
  fi

  local ws agent soul_size mem_size total_size soul_pct mem_pct
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

    if [ "$soul_size" -ge "$per_file_cap" ]; then
      alerts+=("🚨 \`$agent/SOUL.md\` is ${soul_size}B — over the ${per_file_cap} cap.")
    elif [ "$soul_size" -ge "$warn_threshold" ]; then
      warnings+=("⚠️ \`$agent/SOUL.md\` is ${soul_size}B — ${soul_pct}% of cap.")
    fi
    if [ "$mem_size" -ge "$per_file_cap" ]; then
      alerts+=("🚨 \`$agent/MEMORY.md\` is ${mem_size}B — over the ${per_file_cap} cap.")
    elif [ "$mem_size" -ge "$warn_threshold" ]; then
      warnings+=("⚠️ \`$agent/MEMORY.md\` is ${mem_size}B — ${mem_pct}% of cap.")
    fi
  done < <(find "$WORKSPACES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  # Build the Slack message
  local status="✅ all clear"
  [ "${#warnings[@]}" -gt 0 ] && status="⚠️ ${#warnings[@]} warning(s)"
  [ "${#alerts[@]}"   -gt 0 ] && status="🚨 ${#alerts[@]} alert(s)"

  local msg
  msg=$'*Memory health check*  '"${status}"$'\n'
  msg+="_per-file cap: ${per_file_cap} · total cap: ${total_cap} · warn at ${WARN_FRACTION_PCT}%_"$'\n'
  msg+=$'\n'
  msg+=$(printf '%s\n' "${rows[@]}")

  if [ "${#alerts[@]}" -gt 0 ]; then
    msg+=$'\n\n*Alerts*\n'
    msg+=$(printf '%s\n' "${alerts[@]}")
  fi
  if [ "${#warnings[@]}" -gt 0 ]; then
    msg+=$'\n\n*Warnings*\n'
    msg+=$(printf '%s\n' "${warnings[@]}")
  fi

  log "status=${status} per_file_cap=${per_file_cap} warnings=${#warnings[@]} alerts=${#alerts[@]}"
  slack_notify "$msg"
}

main "$@"
