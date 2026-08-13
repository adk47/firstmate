#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-usage.sh — sourceable helpers that build the twice-daily
# Codex (ChatGPT OAuth) usage report for the operations agent.
#
# Sourced by scripts/codex-usage-report.sh; unit-tested by
# scripts/tests/codex-usage.bats with mktemp fixtures, so every
# function here is PURE: it reads files/STDIN and echoes data, never
# calling openclaw/ssh/Slack. Same pattern as scripts/lib/codex-health.sh.
#
# WHY this exists (hydra#382): the cron used to be an agentTurn whose
# agent hand-rolled `jq 'map({...})'` against auth-profiles.json each
# run. That file is an OBJECT — `{ "profiles": {<id>: {...}}, "version": N }`
# — so `map()` iterated its VALUES, hit the `version` number, and died
# with `Cannot index number with string "id"`. The agent now just runs
# the report script (this lib) and relays its output, so the query can
# no longer drift.
#
# WHERE the data lives (verified live on node-8, openclaw 2026.5.27):
#   • auth-profiles.json  — account identity + token expiry + plan ONLY.
#                           NO usage/quota. Shape: {profiles:{"openai-codex:<email>":
#                           {provider,type,email,chatgptPlanType,expires,accountId,
#                            access,refresh}}, version}. We read ONLY id/email/plan
#                           — never `access`/`refresh` (redaction by omission).
#   • auth-state.json     — {lastGood:{"openai-codex":"openai-codex:<email>"}, ...}.
#                           lastGood = the currently-active account.
#   • codex-home rollout  — .../agent/codex-home/sessions/YYYY/MM/DD/rollout-*.jsonl
#                           carries the ONLY real usage signal: event_msg lines with
#                           a `rate_limits` object holding up to two windows
#                           (primary/secondary), each with window_minutes +
#                           used_percent + resets_at (epoch s) + plan_type, plus a
#                           top-level rate_limit_reached_type. The window SET is not
#                           stable: through early Jul 2026 primary=5h (300) and
#                           secondary=weekly (10080); on ~Jul 12 OpenAI removed the
#                           5h window ("temporarily" — undocumented, may return) and
#                           primary BECAME the weekly window with secondary null
#                           (observed live 2026-07-21). Parse by window_minutes,
#                           NEVER by position. `openclaw status --usage` does NOT
#                           surface any of this for codex.
#
# ATTRIBUTION (deliberately simple): the whole fleet shares ONE codex
# auth store, so the freshest rate_limits snapshot anywhere reflects
# whichever account was `lastGood` at the time. We therefore attribute
# the freshest snapshot to the active (lastGood) account and report any
# other configured account as "no fresh snapshot". In practice the
# standby account almost never runs, so an exact per-account join
# (rollout id → *.codex-app-server.json `threadId` → `authProfileId`)
# would resolve to the active account anyway — that join is the
# documented upgrade path if a standby ever needs its own numbers.
# ──────────────────────────────────────────────────────────────

# cu_list_accounts <auth-profiles-path>
# Echo one TSV row per configured codex account: <profileId>\t<email>\t<plan>.
# THE BUG FIX lives in this jq: iterate `.profiles` as an object via to_entries
# (NOT map() over the root). Reads only non-secret identity fields — never the
# access/refresh tokens. Missing/"malformed file → zero rows, exit 0.
cu_list_accounts() {
  local f="$1"
  [ -f "$f" ] || return 0
  jq -r '
    (.profiles // {})
    | to_entries[]
    | select(.key | startswith("openai-codex:"))
    | [ .key, (.value.email // ""), (.value.chatgptPlanType // "") ]
    | @tsv
  ' "$f" 2>/dev/null || true
}

# cu_active_account <auth-state-path>
# Echo the active codex profile id (lastGood["openai-codex"]) or empty string.
cu_active_account() {
  local f="$1"
  [ -f "$f" ] || return 0
  jq -r '.lastGood["openai-codex"] // empty' "$f" 2>/dev/null || true
}

# cu_latest_rate_limits <rollout-file>...
# Echo the single freshest rate_limits snapshot across the given rollout files
# as one WINDOW-KEYED TSV row:
#   <ts_epoch> \t <reached_type|-> \t <w1_min> \t <w1_pct> \t <w1_reset> \t <w2_min> \t <w2_pct> \t <w2_reset>
# with "-" for an absent window/field. Windows are read GENERICALLY from
# primary/secondary via their own `window_minutes` — NEVER positionally: the
# 7.x app-server was observed live (2026-07-21) emitting primary as the WEEKLY
# window (window_minutes 10080) with secondary null, so "primary = 5h" is a
# false assumption. `rate_limit_reached_type` is the direct in-data cap signal.
# Reads only the LAST rate_limits line per file (the most recent snapshot in
# that session), parses each with jq, then keeps the global max-ts row. ISO ts
# is converted to epoch INSIDE jq (fromdateiso8601) so this is portable across
# macOS (bats host) and Linux (node-8) without GNU `date -d`. No snapshot → no
# output, exit 0.
cu_latest_rate_limits() {
  local f line row rows=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    line="$(grep '"rate_limits"' "$f" 2>/dev/null | tail -1)" || true
    [ -n "$line" ] || continue
    row="$(printf '%s' "$line" | jq -r '
      (first(.. | objects | select(has("rate_limits")) | .rate_limits)) as $rl
      | (.ts // .timestamp // "") as $tss
      | ( if $tss == "" then 0
          else ($tss | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) end ) as $ts
      | def win($w): if ($w // null) == null then ["-","-","-"]
          else [ ($w.window_minutes // "-"), ($w.used_percent // 0), ($w.resets_at // 0) ] end;
      [ $ts, ($rl.rate_limit_reached_type // "-") ]
        + win($rl.primary) + win($rl.secondary)
      | @tsv
    ' 2>/dev/null)" || continue
    [ -n "$row" ] || continue
    rows+="$row"$'\n'
  done
  [ -n "$rows" ] || return 0
  # Greatest ts (column 1) wins.
  printf '%s' "$rows" | sort -t$'\t' -k1,1n | tail -1
}

# cu_window_label <window_minutes>
# Human label for a quota window: 300→"5h", 10080→"weekly", other numerics
# scaled, anything else → "window".
cu_window_label() {
  local m="${1:-}"
  case "$m" in
    300)   echo "5h window" ;;
    10080) echo "weekly" ;;
    *)
      if ! [[ "$m" =~ ^[0-9]+$ ]] || [ "$m" -eq 0 ]; then echo "window"
      elif [ "$m" -lt 60 ];    then echo "${m}m"
      elif [ "$m" -lt 1440 ];  then echo "$(( m / 60 ))h"
      else                          echo "$(( m / 1440 ))d"
      fi ;;
  esac
}

# cu_collect_rollouts <root> [lookback_hours]
# Echo rollout files (one per line) modified within the lookback window across
# the whole fleet under <root>. Shared by the report, the rotate actuator's
# snapshot archive, and the keepalive's proactive check. No matches → nothing.
cu_collect_rollouts() {
  local root="$1" hours="${2:-48}"
  find "$root"/.openclaw-*/agents/*/agent/codex-home/sessions \
       -type f -name 'rollout-*.jsonl' -mmin "-$(( hours * 60 ))" 2>/dev/null
}

# ── per-account snapshot archive ─────────────────────────────────────────────
# Rollouts carry NO account identity on 7.x (the codex-app-server.json
# threadId→authProfileId join documented above is dead — verified 2026-07-21),
# so per-account quota knowledge is built by ARCHIVING the outgoing account's
# freshest snapshot at rotation time. `resets_at` is an absolute epoch, so an
# archived snapshot stays meaningful after the account goes standby: it says
# exactly when that account's cap lapses.

# cu_archive_path <dir> <profile-key>
cu_archive_path() {
  printf '%s/%s.snapshot.tsv' "$1" "$(printf '%s' "$2" | tr '/:@' '___')"
}

# cu_archive_write <dir> <profile-key> <tsv-row>
# Persist a cu_latest_rate_limits row for an account (atomic, 0600).
cu_archive_write() {
  local dir="$1" key="$2" row="$3" path tmp
  [ -n "$row" ] || return 1
  mkdir -p "$dir"
  path="$(cu_archive_path "$dir" "$key")"
  tmp="$path.tmp.$$"
  printf '%s\n' "$row" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$path"
}

# cu_archive_read <dir> <profile-key>
# Echo the archived TSV row for an account, or nothing (rc 1) if absent.
cu_archive_read() {
  local path
  path="$(cu_archive_path "$1" "$2")"
  [ -r "$path" ] || return 1
  head -n1 "$path"
}

# cu_row_capped_until <tsv-row> <max_pct> [now_epoch_s]
# Given a snapshot row, echo the LATEST resets_at among windows whose
# used_percent >= max_pct and whose reset is still in the future — i.e. "this
# account is capped until <epoch>". Echoes nothing (rc 1) if no window blocks.
cu_row_capped_until() {
  local row="$1" max="$2" now="${3:-$(date +%s)}"
  local blocked="" w wp wr f3 f4 f5 f6 f7 f8
  IFS=$'\t' read -r _ _ f3 f4 f5 f6 f7 f8 <<<"$row"
  for w in "$f3:$f4:$f5" "$f6:$f7:$f8"; do
    IFS=: read -r _ wp wr <<<"$w"
    [[ "$wr" =~ ^[0-9]+$ ]] || continue
    # awk handles the fractional used_percent values a snapshot can carry
    if awk -v p="$wp" -v m="$max" 'BEGIN{exit !(p+0 >= m+0)}' && [ "$wr" -gt "$now" ]; then
      if [ -z "$blocked" ] || [ "$wr" -gt "$blocked" ]; then blocked="$wr"; fi
    fi
  done
  [ -n "$blocked" ] || return 1
  printf '%s' "$blocked"
}

# cu_is_fresh <ts_epoch_s> [freshness_hours]
# Echo fresh | stale | none. none = non-numeric / zero / missing ts.
cu_is_fresh() {
  local ts="$1" hours="${2:-${FRESHNESS_HOURS:-6}}" now
  [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -gt 0 ] || { echo none; return; }
  now="$(date +%s)"
  if [ "$(( now - ts ))" -le "$(( hours * 3600 ))" ]; then echo fresh; else echo stale; fi
}

# cu_human_resets_in <resets_at_epoch_s> [now_epoch_s]
# Echo a human "resets in …" phrase: "in 2d 3h" / "in 4h 12m" / "in 9m" / "now".
# Unknown/invalid input → "at an unknown time".
cu_human_resets_in() {
  local resets="$1" now="${2:-$(date +%s)}" diff d h m
  [[ "$resets" =~ ^[0-9]+$ ]] && [ "$resets" -gt 0 ] || { echo "at an unknown time"; return; }
  diff="$(( resets - now ))"
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  d="$(( diff / 86400 ))"; h="$(( (diff % 86400) / 3600 ))"; m="$(( (diff % 3600) / 60 ))"
  if   [ "$d" -gt 0 ]; then echo "in ${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "in ${h}h ${m}m"
  else                      echo "in ${m}m"
  fi
}

# cu_fmt_pct <number>
# Render a used_percent the way Slack should see it: integers stay integers
# (0.0 -> 0, 1.0 -> 1), fractions keep one decimal (12.5 -> 12.5).
cu_fmt_pct() {
  awk -v p="${1:-0}" 'BEGIN{ if (p=="") p=0; if (p==int(p)) printf "%d", p; else printf "%.1f", p }'
}

# NOTE: cu_format_window_lines() and cu_format_account_block() were removed on
# 2026-08-06. They rendered the old per-window bullets for codex-usage-report.sh,
# which now renders one evidence line per account via cq_format_evidence() in
# codex-quota.sh — the only sanctioned renderer of a quota claim, because it
# cannot print a percentage without its age and provenance. Nothing else called
# them. cu_window_label/cu_fmt_pct/cu_human_resets_in survive; they still have
# live callers.
