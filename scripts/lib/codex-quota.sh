#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-quota.sh — sourceable helpers that turn a MEASURED codex quota
# reading into a decision and into honest human text.
#
# Sourced by scripts/codex-quota-refresh.sh, scripts/codex-usage-report.sh,
# scripts/codex-keepalive.sh and scripts/lib/codex-account-rotate.sh;
# unit-tested by scripts/tests/codex-quota.bats with mktemp fixtures. Same
# contract as codex-usage.sh / codex-health.sh: every function here is PURE —
# it reads files/STDIN and echoes data, and never calls codex/openclaw/ssh/Slack.
#
# WHY THIS EXISTS (incident 2026-08-05/06):
#   Standby quota was never MEASURED, only inferred. codex-usage.sh archived
#   the fleet-freshest rollout snapshot under whichever account happened to be
#   rotating out, and rollouts carry no account identity on 7.x. The result was
#   provably wrong: on 2026-08-06 the archives read
#     aaron@muso.ai  95% resets 1786160293
#     gmail          97% resets 1786160293   <-- IDENTICAL reset second,
#     me.com         95% resets 1785258161       snapshots 2h15m apart
#   Weekly resets are per-account anchored (me.com's anchor is not congruent
#   mod 604800 with the Aug 8 anchor), so two subscriptions cannot share a
#   reset second — every row was really aaron@muso.ai's. A live probe the same
#   afternoon measured the truth: muso.ai 100%, gmail 4%, me.com 0%. Two Pro
#   subscriptions were sitting untouched while the fleet paged "every alternate
#   account is known-capped" and rode the paid OpenRouter rung.
#
#   The lesson encoded here: an ABSENT or STALE measurement is not evidence of
#   health. cu_row_capped_until answers "capped until when" and correctly
#   returned nothing for a 13-day-old row whose reset had already lapsed — the
#   defect was the CALLER reading "not capped" as "healthy". cq_row_state makes
#   that read unrepresentable by returning a THIRD value: unknown.
#
# ROW FORMAT (a "measurement row"), tab-separated, extending the 8-column
# window-keyed shape cu_latest_rate_limits emits so both can share formatters:
#   1 measured_at   epoch s — when WE took the reading (not the server's clock)
#   2 reached_type  rate_limit_reached | - (the direct in-data cap signal)
#   3 w1_min        window_minutes of the first window, or -
#   4 w1_pct        used_percent
#   5 w1_reset      resets_at epoch s
#   6 w2_min        second window (OpenAI dropped the 5h window ~Jul 12 2026
#   7 w2_pct        "temporarily"; it may return — never assume the set)
#   8 w2_reset
#   9 source        probe-live | probe-empty | rollout | archive
#  10 plan          pro | plus | … | -
# ──────────────────────────────────────────────────────────────

# ── constants ────────────────────────────────────────────────────────────────
# A measurement older than this is not evidence of anything.
CQ_MEASURE_MAX_AGE_MIN="${CQ_MEASURE_MAX_AGE_MIN:-60}"
# used_percent at/above which a window counts as capped.
CQ_CAP_PCT="${CQ_CAP_PCT:-95}"
# How far into the future a measurement's timestamp may sit before we stop
# believing it. Absorbs NTP slew; anything beyond is a clock problem, and a
# future-dated row must never read as fresh (see cq_row_state).
CQ_MAX_CLOCK_SKEW_SEC="${CQ_MAX_CLOCK_SKEW_SEC:-120}"

# cq_parse_ratelimits [source] [now_epoch]
# Read `codex app-server` JSONL from STDIN and echo ONE measurement row for the
# account that store authenticated as. Selects the `account/rateLimits/read`
# RESULT by its `.result.rateLimits` shape rather than by JSON-RPC id, so the
# caller is free to renumber requests.
#
# Windows are read GENERICALLY from primary/secondary via their own
# windowDurationMins — NEVER positionally. The 7.x app-server was observed live
# (2026-07-21, and again 2026-08-06) emitting the WEEKLY window as `primary`
# with `secondary` null, so "primary = 5h" is a false assumption.
#
# We deliberately read ONLY the top-level `.rateLimits` (limitId "codex"), not
# `rateLimitsByLimitId` — the latter also carries per-model sub-limits such as
# `codex_bengalfox` (GPT-5.3-Codex-Spark) which sit at 0% while the account that
# owns them is fully spent. Averaging or min-ing across those would report a
# 100%-used account as healthy.
#
# No parsable result → no output, exit 0. Absence IS the signal here: every
# caller turns an empty row into `unknown` via cq_row_state, which is the safe
# state. Malformed input must therefore look the same as absent input — note
# the trailing `|| true`, because `jq -rs` exits 5 on non-JSON stdin and
# 2>/dev/null suppresses only its stderr, not its status. Without it this
# function would propagate rc 5 into callers that run under `set -e`
# (codex-account-rotate.sh does), turning "the probe returned garbage" into a
# hard abort instead of an honest `unknown`.
cq_parse_ratelimits() {
  local source="${1:-probe-live}" now="${2:-$(date +%s)}"
  jq -rs --arg source "$source" --argjson now "$now" '
    # The rate-limit result is the object carrying .result.rateLimits.
    ( [ .[] | select(type == "object")
             | select(has("result"))
             | .result
             | select(type == "object" and has("rateLimits"))
             | .rateLimits
             | select(. != null) ] | first ) as $rl
    | if $rl == null then empty else
        # An ABSENT usedPercent must stay absent ("-"), never become a synthetic
        # 0. `// 0` on a partial window (resetsAt present, usedPercent null)
        # manufactured a fresh 0%-used row, which cq_row_state read as `healthy`
        # — and _check_usage_cap would then dismiss a real cap signature as
        # auth.order noise and veto rotation. A real 0 is unaffected: the jq
        # alternative operator fires on null/false only, and 0 is truthy.
        def win($w): if ($w // null) == null then ["-","-","-"]
          else [ ($w.windowDurationMins // "-"),
                 ($w.usedPercent // "-"),
                 ($w.resetsAt // 0) ] end;
        [ $now, ($rl.rateLimitReachedType // "-") ]
          + win($rl.primary) + win($rl.secondary)
          + [ $source, ($rl.planType // "-") ]
        | @tsv
      end
  ' 2>/dev/null || true
}

# cq_row_load <row> [now_epoch]
# Echo the account's LOAD: max used_percent across windows whose reset is still
# in the future. A window whose reset has lapsed describes a quota period that
# is already over and contributes nothing. Echoes nothing (rc 1) when no window
# is live — that is `unknown` territory, not 0%.
cq_row_load() {
  local row="$1" now="${2:-$(date +%s)}"
  local best="" w wp wr f3 f4 f5 f6 f7 f8
  IFS=$'\t' read -r _ _ f3 f4 f5 f6 f7 f8 _ _ <<<"$row"
  for w in "$f3|$f4|$f5" "$f6|$f7|$f8"; do
    IFS='|' read -r _ wp wr <<<"$w"
    [[ "$wr" =~ ^[0-9]+$ ]] || continue
    [ "$wr" -gt "$now" ] || continue
    [[ "$wp" =~ ^[0-9.]+$ ]] || continue
    if [ -z "$best" ] || awk -v a="$wp" -v b="$best" 'BEGIN{exit !(a+0 > b+0)}'; then
      best="$wp"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# cq_row_state <row> [cap_pct] [max_age_min] [now_epoch]
# Echo exactly one of: capped | healthy | unknown.
#
# THE POINT OF THIS FUNCTION is that `unknown` exists. It is returned when:
#   - the row is empty/absent            (we never measured this account)
#   - measured_at is missing/non-numeric (a malformed row proves nothing)
#   - measured_at is older than max_age  (a stale reading proves nothing)
#   - no window has a future reset       (every quota period we know about is
#                                         over — the 2026-08-06 me.com case,
#                                         13 days stale with a lapsed reset,
#                                         which the old caller read as healthy
#                                         and rotated the whole fleet onto)
# `capped` requires a LIVE window at/above cap_pct, or an explicit in-data
# rate_limit_reached signal alongside a live window.
cq_row_state() {
  local row="$1" cap="${2:-$CQ_CAP_PCT}" max_age="${3:-$CQ_MEASURE_MAX_AGE_MIN}" now="${4:-$(date +%s)}"
  [ -n "${row//[[:space:]]/}" ] || { echo unknown; return; }

  local ts reached
  IFS=$'\t' read -r ts reached _ _ _ _ _ _ _ _ <<<"$row"
  [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -gt 0 ] || { echo unknown; return; }
  # A measurement dated in the FUTURE is not evidence of anything. Without this
  # check `now - ts` goes negative, which trivially satisfies the freshness
  # comparison below — so after a clock rollback a stale 0%-used row would read
  # `healthy` indefinitely, and _check_usage_cap would keep vetoing rotation
  # during a real cap as "auth.order noise". Unknown is the fail-safe answer:
  # it never asserts health, and it lets the rotate actuator apply its own
  # gates. A small tolerance absorbs benign NTP slew between the writer and the
  # reader (same host, same clock) without masking a real rollback.
  [ "$ts" -le "$(( now + CQ_MAX_CLOCK_SKEW_SEC ))" ] || { echo unknown; return; }
  [ "$(( now - ts ))" -le "$(( max_age * 60 ))" ] || { echo unknown; return; }

  local load
  load="$(cq_row_load "$row" "$now")" || { echo unknown; return; }

  if awk -v p="$load" -v m="$cap" 'BEGIN{exit !(p+0 >= m+0)}'; then echo capped; return; fi
  # An explicit reached-type from the provider outranks our percentage floor.
  case "$reached" in
    ""|-|null) : ;;
    *) echo capped; return ;;
  esac
  echo healthy
}

# cq_row_reset_at <row> [now_epoch]
# Echo the resets_at of the window that OWNS the row's load — i.e. the same
# window cq_row_load reports the percentage for — or nothing (rc 1).
#
# This deliberately does NOT return the latest reset across all windows. That
# is what it used to do, and it silently paired one window's percentage with a
# different window's clock: an account at 100% on a 5h window resetting in 40
# minutes, with 30% weekly resetting in 5 days, rendered as "100% used ·
# resets in 5d". An operator reads a 40-minute stall as a five-day outage.
# (The 5h window was dropped ~Jul 2026 "temporarily" and may return, so this is
# a live hazard, not a hypothetical one.) The percentage and the ETA must come
# from the same window or the sentence is a lie.
cq_row_reset_at() {
  local row="$1" now="${2:-$(date +%s)}"
  local best="" best_pct="" w wp wr f3 f4 f5 f6 f7 f8
  IFS=$'\t' read -r _ _ f3 f4 f5 f6 f7 f8 _ _ <<<"$row"
  for w in "$f3|$f4|$f5" "$f6|$f7|$f8"; do
    IFS='|' read -r _ wp wr <<<"$w"
    [[ "$wr" =~ ^[0-9]+$ ]] && [ "$wr" -gt "$now" ] || continue
    [[ "$wp" =~ ^[0-9.]+$ ]] || continue
    if [ -z "$best_pct" ] || awk -v a="$wp" -v b="$best_pct" 'BEGIN{exit !(a+0 > b+0)}'; then
      best_pct="$wp"; best="$wr"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# ── measurement store ────────────────────────────────────────────────────────
# One file per account, written by scripts/codex-quota-refresh.sh. Deliberately
# a DIFFERENT filename from codex-usage.sh's `.snapshot.tsv` archive so the two
# layers can coexist during the bake and so reverting the code leaves no
# ambiguous file behind.

# cq_measure_path <dir> <profile-key>
cq_measure_path() {
  printf '%s/%s.measure.tsv' "$1" "$(printf '%s' "$2" | tr '/:@' '___')"
}

# cq_measure_write <dir> <profile-key> <row>   (atomic, 0600)
cq_measure_write() {
  local dir="$1" key="$2" row="$3" path tmp
  [ -n "$row" ] || return 1
  mkdir -p "$dir" || return 1
  path="$(cq_measure_path "$dir" "$key")"
  tmp="$path.tmp.$$"
  printf '%s\n' "$row" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$path"
}

# cq_measure_read <dir> <profile-key>   (nothing + rc 1 when absent)
cq_measure_read() {
  local path
  path="$(cq_measure_path "$1" "$2")"
  [ -r "$path" ] || return 1
  head -n1 "$path"
}

# ── active-account ledger ────────────────────────────────────────────────────
# Append-only, one line per switch: <epoch>\t<profile-key>\t<reason>.
# Written by codex-account-rotate.sh. This is what lets a rollout snapshot at
# time t be attributed to whoever was ACTUALLY active at t, retiring the
# "freshest snapshot belongs to the current account" heuristic that produced
# the identical-reset-epoch corruption described at the top of this file.

# cq_ledger_append <file> <profile-key> <reason> [epoch]
cq_ledger_append() {
  local f="$1" key="$2" reason="${3:-}" ts="${4:-$(date +%s)}"
  [ -n "$key" ] || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # Reason is free text from a caller; keep the row parseable by stripping tabs
  # and newlines rather than rejecting it (a page must never be lost to a quote).
  printf '%s\t%s\t%s\n' "$ts" "$key" "$(printf '%s' "$reason" | tr '\t\n' '  ')" >> "$f"
}

# cq_ledger_account_at <file> <epoch>
# Echo the profile key that was active at <epoch> — the last entry at or before
# it. Malformed lines are skipped. Nothing + rc 1 when the ledger is absent or
# every entry postdates <epoch> (we cannot know who was active before the
# ledger began, and guessing is what caused the incident).
cq_ledger_account_at() {
  local f="$1" at="$2" ts key best=""
  [ -r "$f" ] || return 1
  while IFS=$'\t' read -r ts key _; do
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    [ -n "$key" ] || continue
    [ "$ts" -le "$at" ] || continue
    best="$key"
  done < "$f"
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# cq_ledger_count_since <file> <since_epoch> [reason_grep]
# Count ledger entries at/after <since_epoch>, optionally only those whose
# reason matches a fixed string. Used to enforce a rotation budget.
cq_ledger_count_since() {
  local f="$1" since="$2" want="${3:-}" ts reason n=0
  [ -r "$f" ] || { printf '0'; return; }
  while IFS=$'\t' read -r ts _ reason; do
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    [ "$ts" -ge "$since" ] || continue
    if [ -n "$want" ]; then
      case "$reason" in *"$want"*) : ;; *) continue ;; esac
    fi
    n=$(( n + 1 ))
  done < "$f"
  printf '%s' "$n"
}

# ── evidence rendering ───────────────────────────────────────────────────────
# THE ENFORCEABLE RULE: no script may interpolate a quota number into a Slack
# string directly. Every per-account quota claim goes through cq_format_evidence,
# which cannot render a percentage without also rendering when it was measured
# and where the number came from — and which renders "quota UNKNOWN (<why>)"
# when there is no fresh measurement. This is the mechanical version of "never
# assert a fact the system did not measure", and it is what the false
# 2026-08-05 page would have failed.
#
# scripts/tests/codex-quota.bats asserts: no emitted line containing a percent
# sign lacks the substring "measured".

# cq_human_age <epoch> [now]
cq_human_age() {
  local ts="$1" now="${2:-$(date +%s)}" d
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  d=$(( now - ts ))
  [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 90 ];    then printf '%ds' "$d"
  elif [ "$d" -lt 5400 ];  then printf '%dm' "$(( d / 60 ))"
  elif [ "$d" -lt 172800 ];then printf '%dh' "$(( d / 3600 ))"
  else                          printf '%dd' "$(( d / 86400 ))"
  fi
}

# cq_human_in <epoch> [now]  — "in 2d 3h" / "now"
cq_human_in() {
  local at="$1" now="${2:-$(date +%s)}" d
  [[ "$at" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  d=$(( at - now ))
  [ "$d" -le 0 ] && { printf 'now'; return; }
  if   [ "$d" -lt 3600 ];  then printf 'in %dm' "$(( d / 60 ))"
  elif [ "$d" -lt 86400 ]; then printf 'in %dh %dm' "$(( d / 3600 ))" "$(( (d % 3600) / 60 ))"
  else                          printf 'in %dd %dh' "$(( d / 86400 ))" "$(( (d % 86400) / 3600 ))"
  fi
}

# cq_format_evidence <account-label> <row> [now_epoch] [why-if-unknown]
# ONE line. Either a measured claim with its age and provenance, or an explicit
# UNKNOWN carrying no number at all.
cq_format_evidence() {
  local label="$1" row="$2" now="${3:-$(date +%s)}" why="${4:-}"
  local state load ts src reset
  state="$(cq_row_state "$row" "$CQ_CAP_PCT" "$CQ_MEASURE_MAX_AGE_MIN" "$now")"

  if [ "$state" = unknown ]; then
    if [ -z "$why" ]; then
      if [ -z "${row//[[:space:]]/}" ]; then
        why="no measurement on record"
      else
        IFS=$'\t' read -r ts _ _ _ _ _ _ _ _ _ <<<"$row"
        if [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -gt 0 ]; then
          why="last measured $(cq_human_age "$ts" "$now") ago; no live quota window in that reading"
        else
          why="measurement unreadable"
        fi
      fi
    fi
    printf '%s — quota UNKNOWN (%s)' "$label" "$why"
    return
  fi

  IFS=$'\t' read -r ts _ _ _ _ _ _ _ src _ <<<"$row"
  load="$(cq_row_load "$row" "$now")" || load="?"
  printf '%s — %s%% used (measured %s ago, %s)' \
    "$label" "$load" "$(cq_human_age "$ts" "$now")" "${src:--}"
  if reset="$(cq_row_reset_at "$row" "$now")"; then
    printf ' · resets %s' "$(cq_human_in "$reset" "$now")"
  fi
  [ "$state" = capped ] && printf ' · CAPPED'
  return 0
}
