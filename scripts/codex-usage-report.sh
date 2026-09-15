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
# Measured-quota helpers — cq_measure_read + cq_format_evidence are what make
# every number in this report carry its age and provenance.
# shellcheck source=scripts/lib/codex-quota.sh
. "$HERE/lib/codex-quota.sh"
# shellcheck source=scripts/lib/codex-auth-store.sh
. "$HERE/lib/codex-auth-store.sh"

CODEX_USAGE_ROOT="${CODEX_USAGE_ROOT:-/root}"
AUTH_DIR_EXPLICIT=0
[ "${AUTH_DIR+x}" = x ] && AUTH_DIR_EXPLICIT=1
AUTH_DIR="${AUTH_DIR:-$CODEX_USAGE_ROOT/.openclaw-main/agents/main/agent}"
CAS_ROOT="${CAS_ROOT:-$CODEX_USAGE_ROOT}"
if [ "$AUTH_DIR_EXPLICIT" -eq 1 ]; then
  # shellcheck disable=SC2034 # Read by the sourced codex-auth-store helpers.
  CAS_LEGACY_JSON="$AUTH_DIR/auth-profiles.json"
  # shellcheck disable=SC2034 # Read by the sourced codex-auth-store helpers.
  CAS_LEGACY_STATE="$AUTH_DIR/auth-state.json"
fi
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

  # OpenClaw 2026.8 archived auth-profiles.json and moved the shared store to
  # state/openclaw.sqlite. Materialize only the redacted id/email/plan view that
  # the existing report helpers consume; token fields never leave the adapter.
  local profiles rc=0
  profiles="$(mktemp "${TMPDIR:-/tmp}/codex-usage-profiles.XXXXXX")" || {
    echo "*Codex usage* — report unavailable: could not create a temp file"
    return 0
  }
  cas_profiles_redacted main > "$profiles" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$profiles"
    echo "*Codex usage* — report unavailable: codex auth store could not be read"
    return 0
  fi
  # Active account: the rotation state file is authoritative when present and
  # valid; auth-state.json's lastGood is the fallback — the 7.x runtime no
  # longer maintains it, so after an account rotation it names the OLD account
  # and the freshest quota snapshot was being attributed to the wrong
  # subscription (observed live 2026-07-21).
  local active
  active="$(caa_state_key "$profiles" 2>/dev/null)" || active=""
  if [ -z "$active" ]; then
    active="$(cas_active_key main 2>/dev/null)" || active=""
  fi

  # No rollout scan here any more. This report used to derive the active
  # account's numbers from the freshest rate_limits snapshot anywhere in the
  # fleet, guarded by a rotation-boundary check. Rollouts carry no account
  # identity on 7.x, so that attributed one subscription's usage to whichever
  # account was nominally active — and every standby fell back to an archive
  # written at rotation time. Both are replaced by per-account measurements
  # (scripts/codex-quota-refresh.sh); see codex-quota.sh for the incident.
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
  rm -f "$profiles"
  return 0
}

emit_text() {
  printf '*Codex usage* — %s\n' "$(report_timestamp)"
  if [ "${#acct_rows[@]}" -eq 0 ]; then
    printf '\n• no codex accounts found in the canonical auth store\n'
    return
  fi
  # Every account is now reported from its OWN measurement, taken by
  # scripts/codex-quota-refresh.sh against account/rateLimits/read.
  #
  # The previous shape reported the ACTIVE account from the freshest fleet-wide
  # rollout and every standby from an archive written at rotation time. Because
  # rollouts carry no account identity on 7.x, that attributed one subscription's
  # numbers to whichever account was nominally active — and on 2026-08-06 this
  # report told a human all three accounts were at 95-97% when a direct probe
  # measured 100% / 4% / 0%. Two Pro subscriptions were reported as spent while
  # sitting untouched.
  #
  # Rendering goes through cq_format_evidence, which structurally cannot print a
  # percentage without its age and provenance, and prints "quota UNKNOWN (why)"
  # rather than a stale number when there is no fresh reading.
  local row pid email plan mrow now marker
  now="$(date +%s)"
  for row in "${acct_rows[@]}"; do
    IFS=$'\t' read -r pid email plan <<<"$row"
    mrow="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$pid" 2>/dev/null || true)"
    marker="idle standby"
    [ -n "$active" ] && [ "$pid" = "$active" ] && marker="active"
    printf '\n*%s* — %s (plan: %s)\n' "$email" "$marker" "${plan:--}"
    printf '  • %s\n' "$(cq_format_evidence "$email" "$mrow" "$now")"
  done
  # Fail loud IN THE CONTENT when the measurement layer is not running: a report
  # that silently shows every account as UNKNOWN looks the same as one nobody
  # has looked at, and this cron is often the only thing a human reads.
  if [ ! -d "$CODEX_USAGE_ARCHIVE_DIR" ] || ! ls "$CODEX_USAGE_ARCHIVE_DIR"/*.measure.tsv >/dev/null 2>&1; then
    printf '\n:warning: no per-account measurements on disk — check `codex-quota-refresh` cron and `/var/log/codex-quota-refresh.log` (kill switch: `/etc/hydra/codex-quota-probe.disabled`).\n'
  fi
}

# _row_windows_json <tsv-row> — [{minutes,label,used_percent,resets_at},…]
_row_windows_json() {
  local row="$1" f3 f4 f5 f6 f7 f8 w wm wp wr out="[]"
  # TEN fields, not eight: measurement rows append `source` and `plan`. With an
  # 8-field read the last name swallows the tail, so f8 becomes
  # "<reset>\tprobe-live\tpro" — `jq --argjson r` then gets non-JSON, jq fails,
  # and the `|| out="[]"` fallback nulls every field in the --json report. It
  # is latent only while the weekly window is the sole window; it fires the
  # moment OpenAI restores the 5h one.
  IFS=$'\t' read -r _ _ f3 f4 f5 f6 f7 f8 _ _ <<<"$row"
  for w in "$f3|$f4|$f5" "$f6|$f7|$f8"; do
    IFS='|' read -r wm wp wr <<<"$w"
    [[ "$wm" =~ ^[0-9]+$ ]] || continue
    # Validate the numerics BEFORE jq sees them. cq_parse_ratelimits emits "-"
    # for a missing usedPercent (deliberately — an absent reading must not
    # become a synthetic 0), and `--argjson p -` is a jq parse error. The
    # `|| out="[]"` fallback below would then discard windows already
    # accumulated, so one partial window erased a perfectly good primary and
    # the --json report came back with empty windows and null legacy fields.
    # Skip only the incomplete window; keep everything valid.
    [[ "$wp" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$wr" =~ ^[0-9]+$ ]] || continue
    out="$(jq -n --argjson prev "$out" --argjson m "$wm" \
                 --argjson p "$wp" --argjson r "$wr" \
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
  # Same source of truth as emit_text — the per-account MEASUREMENT. These two
  # renderers must never diverge: a --json consumer reading the old inferred
  # archive while the text report reads measurements would put two different
  # numbers for the same account into circulation, which is the class of bug
  # this whole change exists to remove.
  local row pid email plan role obj objs="" mrow state now
  now="$(date +%s)"
  if [ "${#acct_rows[@]}" -gt 0 ]; then
    for row in "${acct_rows[@]}"; do
      IFS=$'\t' read -r pid email plan <<<"$row"
      role=standby
      [ -n "$active" ] && [ "$pid" = "$active" ] && role=active
      mrow="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$pid" 2>/dev/null || true)"
      # `freshness` carries the tri-state directly so a consumer cannot mistake
      # "we could not measure it" for "it is fine".
      state="$(cq_row_state "$mrow" "$CQ_CAP_PCT" "$CQ_MEASURE_MAX_AGE_MIN" "$now")"
      if [ "$state" = unknown ]; then
        obj="$(_acct_json "$email" "$role" unknown "$plan" "")"
      else
        obj="$(_acct_json "$email" "$role" "$state" "$plan" "$mrow")"
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
