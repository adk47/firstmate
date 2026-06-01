#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-usage-report.sh — emit Aaron's twice-daily Hydra Codex OAuth
# usage report (hydra#382). Read-only, agent- and human-callable.
#
# The operations cron (codex-usage-report-{aaron,nick}-twice-daily) runs
# this via the shell (exec) tool and relays stdout verbatim to a Slack DM.
# Centralizing the queries here is the whole fix: the agent no longer
# hand-rolls jq against auth-profiles.json (which is an object, not an
# array, and holds no usage data anyway — that was the original bug).
#
# Output (default): Slack mrkdwn, bullets, no tables —
#   *Codex usage* — <America/Chicago timestamp>
#   *<email>* — active (plan: pro)
#     • 5h window: <pct>% used · resets in <…>
#     • weekly: <pct>% used · resets in <…>
#   *<email>* — idle standby
#     • no fresh quota snapshot (account has not run recently)
# `--json` emits the same data as a structured object.
#
# Always exits 0 on partial/missing data (fail-loud IN the content, so the
# cron's bestEffort delivery never silently drops to nothing). Never prints
# access/refresh tokens — see scripts/lib/codex-usage.sh.
#
# Env overrides (for tests / non-default layouts):
#   CODEX_USAGE_ROOT        default /root
#   AUTH_DIR                default $CODEX_USAGE_ROOT/.openclaw-main/agents/main/agent
#   FRESHNESS_HOURS         default 6   (snapshot older than this → "cannot read")
#   ROLLOUT_LOOKBACK_HOURS  default 48  (only scan rollouts modified within window)
# ──────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/codex-usage.sh
. "$HERE/lib/codex-usage.sh"

CODEX_USAGE_ROOT="${CODEX_USAGE_ROOT:-/root}"
AUTH_DIR="${AUTH_DIR:-$CODEX_USAGE_ROOT/.openclaw-main/agents/main/agent}"
FRESHNESS_HOURS="${FRESHNESS_HOURS:-6}"
ROLLOUT_LOOKBACK_HOURS="${ROLLOUT_LOOKBACK_HOURS:-48}"

report_timestamp() { TZ=America/Chicago date '+%Y-%m-%d %I:%M %p %Z'; }

print_help() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)     json=1 ;;
      -h|--help)  print_help; return 0 ;;
      *)          echo "codex-usage-report.sh: unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done

  if ! command -v jq >/dev/null 2>&1; then
    echo "*Codex usage* — report unavailable: jq not found on PATH" >&2
    echo "*Codex usage* — report unavailable: jq not found"
    return 0
  fi

  local profiles="$AUTH_DIR/auth-profiles.json"
  local state="$AUTH_DIR/auth-state.json"
  local active; active="$(cu_active_account "$state")"

  # Freshest rate_limits snapshot anywhere in the fleet within the lookback
  # window — attributed to the active (lastGood) account. Quoting the root but
  # leaving the *.openclaw-*/agents/* globs unquoted lets the shell expand them;
  # a no-match leaves a literal path that find ignores (stderr suppressed).
  local mins="$(( ROLLOUT_LOOKBACK_HOURS * 60 ))"
  local -a rollouts=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && rollouts+=("$p")
  done < <(find "${CODEX_USAGE_ROOT}"/.openclaw-*/agents/*/agent/codex-home/sessions \
                -type f -name 'rollout-*.jsonl' -mmin "-$mins" 2>/dev/null)

  local snap=""
  if [ "${#rollouts[@]}" -gt 0 ]; then
    snap="$(cu_latest_rate_limits "${rollouts[@]}")"
  fi

  local s_ts="" s_p5="" s_r5="" s_pw="" s_rw=""
  if [ -n "$snap" ]; then
    IFS=$'\t' read -r s_ts s_p5 s_r5 s_pw s_rw <<<"$snap"
  fi
  local snap_fresh; snap_fresh="$(cu_is_fresh "${s_ts:-0}" "$FRESHNESS_HOURS")"

  local -a acct_rows=()
  local r
  while IFS= read -r r; do
    [ -n "$r" ] && acct_rows+=("$r")
  done < <(cu_list_accounts "$profiles")

  if [ "$json" -eq 1 ]; then
    emit_json
  else
    emit_text
  fi
  return 0
}

# Resolve (role, freshness) for an account id against the active account +
# snapshot freshness. Echoes "<role>\t<freshness>".
acct_role() {
  local pid="$1"
  if [ -n "$active" ] && [ "$pid" = "$active" ]; then
    printf 'active\t%s' "$snap_fresh"
  else
    printf 'standby\tnone'
  fi
}

emit_text() {
  printf '*Codex usage* — %s\n' "$(report_timestamp)"
  if [ "${#acct_rows[@]}" -eq 0 ]; then
    printf '\n• no codex accounts found in auth-profiles.json\n'
    return
  fi
  local row pid email plan role fresh
  for row in "${acct_rows[@]}"; do
    IFS=$'\t' read -r pid email plan <<<"$row"
    IFS=$'\t' read -r role fresh <<<"$(acct_role "$pid")"
    printf '\n'
    if [ "$role" = active ] && [ "$fresh" = fresh ]; then
      cu_format_account_block "$email" active fresh "$s_p5" "$s_r5" "$s_pw" "$s_rw" "$plan"
    else
      cu_format_account_block "$email" "$role" "$fresh" "" "" "" "" "$plan"
    fi
  done
}

emit_json() {
  local row pid email plan role fresh obj objs=""
  if [ "${#acct_rows[@]}" -gt 0 ]; then
    for row in "${acct_rows[@]}"; do
      IFS=$'\t' read -r pid email plan <<<"$row"
      IFS=$'\t' read -r role fresh <<<"$(acct_role "$pid")"
      if [ "$role" = active ] && [ "$fresh" = fresh ]; then
        obj="$(jq -n \
          --arg email "$email" --arg role "$role" --arg fresh "$fresh" --arg plan "$plan" \
          --argjson p5 "${s_p5:-0}" --argjson r5 "${s_r5:-0}" \
          --argjson pw "${s_pw:-0}" --argjson rw "${s_rw:-0}" \
          '{email:$email, role:$role, freshness:$fresh, plan:$plan,
            used_percent_5h:$p5, resets_5h:$r5,
            used_percent_weekly:$pw, resets_weekly:$rw}')"
      else
        obj="$(jq -n \
          --arg email "$email" --arg role "$role" --arg fresh "$fresh" --arg plan "$plan" \
          '{email:$email, role:$role, freshness:$fresh, plan:$plan,
            used_percent_5h:null, resets_5h:null,
            used_percent_weekly:null, resets_weekly:null}')"
      fi
      objs+="$obj"$'\n'
    done
  fi
  local accounts_json="[]"
  [ -n "$objs" ] && accounts_json="$(printf '%s' "$objs" | jq -s '.')"
  jq -n \
    --arg generated_at "$(report_timestamp)" \
    --arg tz "America/Chicago" \
    --arg active "$active" \
    --argjson accounts "$accounts_json" \
    '{generated_at:$generated_at, tz:$tz, active_account:$active, accounts:$accounts}'
}

main "$@"
