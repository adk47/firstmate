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
#                           a `rate_limits` object — primary=5h window (window_minutes
#                           300), secondary=weekly (10080) — each with used_percent +
#                           resets_at (epoch seconds) + plan_type. `openclaw status
#                           --usage` does NOT surface this for codex.
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
# as one TSV row: <ts_epoch>\t<pct5h>\t<reset5h>\t<pctWeek>\t<resetWeek>.
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
      | [ $ts,
          ($rl.primary.used_percent   // 0),
          ($rl.primary.resets_at      // 0),
          ($rl.secondary.used_percent // 0),
          ($rl.secondary.resets_at    // 0) ]
      | @tsv
    ' 2>/dev/null)" || continue
    [ -n "$row" ] || continue
    rows+="$row"$'\n'
  done
  [ -n "$rows" ] || return 0
  # Greatest ts (column 1) wins.
  printf '%s' "$rows" | sort -t$'\t' -k1,1n | tail -1
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

# cu_format_account_block <email> <active|standby> <fresh|stale|none> \
#                         [pct5h reset5h pctWeek resetWeek plan]
# Emit the Slack-mrkdwn block for one account (bullets, no tables). Only the
# active account with a fresh snapshot shows numbers; everything else degrades
# to a plain, honest line (fail-loud-in-content).
cu_format_account_block() {
  local email="$1" role="$2" fresh="$3"
  local pct5="${4:-}" r5="${5:-}" pctw="${6:-}" rw="${7:-}" plan="${8:-}"
  local now plan_sfx; now="$(date +%s)"
  plan_sfx="${plan:+ (plan: $plan)}"
  if [ "$role" = "active" ] && [ "$fresh" = "fresh" ]; then
    printf '*%s* — active%s\n' "$email" "$plan_sfx"
    printf '  • 5h window: %s%% used · resets %s\n' "$(cu_fmt_pct "$pct5")" "$(cu_human_resets_in "$r5" "$now")"
    printf '  • weekly: %s%% used · resets %s\n'    "$(cu_fmt_pct "$pctw")" "$(cu_human_resets_in "$rw" "$now")"
  elif [ "$role" = "active" ]; then
    printf '*%s* — active%s\n' "$email" "$plan_sfx"
    printf '  • fresh quota snapshot unavailable — could not read current 5h/weekly usage\n'
  else
    printf '*%s* — idle standby%s\n' "$email" "$plan_sfx"
    printf '  • no fresh quota snapshot (account has not run recently)\n'
  fi
}
