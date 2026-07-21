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
#     • weekly: <pct>% used · resets in <…>      ← one line per window the
#     • 5h window: <pct>% used · resets in <…>     snapshot actually carries
#   *<email>* — idle standby
#     • last known (<age> ago): …               ← archived at rotation time
#     • no fresh quota snapshot (account has not run recently)
# Windows are rendered from the snapshot's own window_minutes (OpenAI dropped
# the 5h window ~Jul 12 2026, "temporarily" — the set may change again).
# `--json` emits the same data as a structured object: per-account `windows`
# array + legacy used_percent_5h/_weekly keys (null when that window is absent).
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
# shellcheck source=scripts/lib/codex-active-account.sh
. "$HERE/lib/codex-active-account.sh"

CODEX_USAGE_ROOT="${CODEX_USAGE_ROOT:-/root}"
AUTH_DIR="${AUTH_DIR:-$CODEX_USAGE_ROOT/.openclaw-main/agents/main/agent}"
FRESHNESS_HOURS="${FRESHNESS_HOURS:-6}"
ROLLOUT_LOOKBACK_HOURS="${ROLLOUT_LOOKBACK_HOURS:-48}"
# Per-account snapshot archive written by codex-account-rotate.sh at rotation
# time — the only per-account quota knowledge on 7.x (rollouts are account-blind).
CODEX_USAGE_ARCHIVE_DIR="${CODEX_USAGE_ARCHIVE_DIR:-/var/lib/hydra/codex-usage}"
# Rotation boundary (epoch, written by codex-account-rotate.sh): snapshots
# OLDER than the last rotation belong to the OUTGOING account and must not be
# attributed to the new active one.
CODEX_ROTATE_STAMP="${CODEX_ROTATE_STAMP:-/var/lib/hydra/codex-account-rotate.last}"

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
  # Active account: the rotation state file is authoritative when present and
  # valid; auth-state.json's lastGood is the fallback — the 7.x runtime no
  # longer maintains it, so after an account rotation it names the OLD account
  # and the freshest quota snapshot was being attributed to the wrong
  # subscription (observed live 2026-07-21).
  local active
  active="$(caa_state_key "$profiles" 2>/dev/null)" || active=""
  [ -n "$active" ] || active="$(cu_active_account "$state")"

  # Freshest rate_limits snapshot anywhere in the fleet within the lookback
  # window — attributed to the active account (the fleet runs ONE account at a
  # time, so the freshest snapshot is the active account's).
  local -a rollouts=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && rollouts+=("$p")
  done < <(cu_collect_rollouts "$CODEX_USAGE_ROOT" "$ROLLOUT_LOOKBACK_HOURS")

  local snap=""
  if [ "${#rollouts[@]}" -gt 0 ]; then
    snap="$(cu_latest_rate_limits "${rollouts[@]}")"
  fi

  local s_ts=""
  [ -n "$snap" ] && s_ts="$(printf '%s' "$snap" | cut -f1)"

  # Rotation-boundary guard: a snapshot that PREDATES the last account switch
  # was emitted by the OUTGOING account — attributing it to the new active
  # account would show the old (likely capped) quota under the wrong email,
  # duplicated against the same numbers in the outgoing account's archive.
  # Until the new account emits a snapshot, degrade honestly to "unavailable".
  if [ -n "$snap" ] && [ -r "$CODEX_ROTATE_STAMP" ]; then
    local rot_ts; rot_ts="$(head -n1 "$CODEX_ROTATE_STAMP" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$rot_ts" =~ ^[0-9]+$ ]] && [[ "$s_ts" =~ ^[0-9]+$ ]] && [ "$s_ts" -lt "$rot_ts" ]; then
      snap=""; s_ts=""
    fi
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

# _acct_archive_row <pid> — archived snapshot TSV for a standby account (or
# nothing). Kept as a function so emit_text/emit_json can't drift apart.
_acct_archive_row() {
  cu_archive_read "$CODEX_USAGE_ARCHIVE_DIR" "$1" 2>/dev/null || true
}

emit_text() {
  printf '*Codex usage* — %s\n' "$(report_timestamp)"
  if [ "${#acct_rows[@]}" -eq 0 ]; then
    printf '\n• no codex accounts found in auth-profiles.json\n'
    return
  fi
  local row pid email plan role fresh arow age
  for row in "${acct_rows[@]}"; do
    IFS=$'\t' read -r pid email plan <<<"$row"
    IFS=$'\t' read -r role fresh <<<"$(acct_role "$pid")"
    printf '\n'
    if [ "$role" = active ] && [ "$fresh" = fresh ]; then
      cu_format_account_block "$email" active fresh "$plan" "$snap"
    elif [ "$role" = active ]; then
      cu_format_account_block "$email" active "$fresh" "$plan"
    else
      arow="$(_acct_archive_row "$pid")"
      age=""
      if [ -n "$arow" ]; then
        local ats; ats="$(printf '%s' "$arow" | cut -f1)"
        [[ "$ats" =~ ^[0-9]+$ ]] && age="$(( $(date +%s) - ats ))"
      fi
      cu_format_account_block "$email" standby none "$plan" "$arow" "$age"
    fi
  done
}

# _row_windows_json <tsv-row> — [{minutes,label,used_percent,resets_at},…]
_row_windows_json() {
  local row="$1" f3 f4 f5 f6 f7 f8 w wm wp wr out="[]"
  IFS=$'\t' read -r _ _ f3 f4 f5 f6 f7 f8 <<<"$row"
  for w in "$f3|$f4|$f5" "$f6|$f7|$f8"; do
    IFS='|' read -r wm wp wr <<<"$w"
    [[ "$wm" =~ ^[0-9]+$ ]] || continue
    out="$(jq -n --argjson prev "$out" --argjson m "$wm" \
                 --argjson p "${wp:-0}" --argjson r "${wr:-0}" \
                 --arg l "$(cu_window_label "$wm")" \
                 '$prev + [{minutes:$m,label:$l,used_percent:$p,resets_at:$r}]' 2>/dev/null)" || out="[]"
  done
  printf '%s' "$out"
}

# _acct_json <email> <role> <fresh> <plan> <row> — one account object; legacy
# used_percent_5h/_weekly keys are derived from the matching window (null when
# that window is absent) so existing consumers keep working.
_acct_json() {
  local email="$1" role="$2" fresh="$3" plan="$4" arow="${5:-}" winjson="[]"
  [ -n "$arow" ] && winjson="$(_row_windows_json "$arow")"
  jq -n \
    --arg email "$email" --arg role "$role" --arg fresh "$fresh" --arg plan "$plan" \
    --argjson windows "$winjson" \
    '{email:$email, role:$role, freshness:$fresh, plan:$plan, windows:$windows,
      used_percent_5h:    ($windows | map(select(.minutes==300))   | (.[0].used_percent // null)),
      resets_5h:          ($windows | map(select(.minutes==300))   | (.[0].resets_at    // null)),
      used_percent_weekly:($windows | map(select(.minutes==10080)) | (.[0].used_percent // null)),
      resets_weekly:      ($windows | map(select(.minutes==10080)) | (.[0].resets_at    // null))}'
}

emit_json() {
  local row pid email plan role fresh obj objs="" arow
  if [ "${#acct_rows[@]}" -gt 0 ]; then
    for row in "${acct_rows[@]}"; do
      IFS=$'\t' read -r pid email plan <<<"$row"
      IFS=$'\t' read -r role fresh <<<"$(acct_role "$pid")"
      if [ "$role" = active ] && [ "$fresh" = fresh ]; then
        obj="$(_acct_json "$email" "$role" "$fresh" "$plan" "$snap")"
      elif [ "$role" = active ]; then
        obj="$(_acct_json "$email" "$role" "$fresh" "$plan" "")"
      else
        arow="$(_acct_archive_row "$pid")"
        fresh="none"; [ -n "$arow" ] && fresh="archived"
        obj="$(_acct_json "$email" "$role" "$fresh" "$plan" "$arow")"
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
