#!/usr/bin/env bash
# streams-milestones.sh — detect & announce artists who newly crossed 1B / 10B streams.
#
# Metric: postgresql_core.public.profile_v3_lifetime.streams — the canonical
# lifetime total shown on the muso.ai profile.
#
# Why an "already-announced" set (not a track_daily history diff): profile_v3_lifetime
# has no history, and the stats DB that holds daily history (track_daily) is a hot
# standby that cancels any multi-minute query (verified: full and candidate-scoped
# track_daily crossing queries were both killed at 7–15 min by transaction /
# recovery-conflict timeouts). Reading the canonical club is ~1s. So this skill:
#   1. reads the current ≥1B club (one fast filtered read; ~3.9k rows, 10B ⊂ 1B),
#   2. announces each profile that is ≥1B / ≥10B and is NOT already in the persisted
#      per-tier "announced" set, by POSTING to Slack itself, then
#   3. records the announced ids ONLY after Slack confirms ok:true (atomically).
# The first run seeds the announced set from the whole current club and posts nothing.
#
# At-least-once delivery: state is committed only after a confirmed Slack post, so a
# delivery failure leaves the entrants un-recorded and the next run retries them
# (rather than the cron's best-effort relay silently dropping the milestone). Using an
# announced-set (not a prev-vs-now diff) means a profile is congratulated at most once
# per tier — immune to threshold flap and to a missed/extra run.
#
# Read-only against Muso (SELECT-only Trino; names via a batched IN-list lookup on
# profile_track — no admin API). Writes: the skill's own state files + the Slack post.
# Trino is reachable only on the main gateway host (node-8).
set -euo pipefail

MUSO_BIN="${MUSO_BIN:-$(command -v muso || echo /usr/local/bin/muso)}"
STATE_DIR="${BILLION_STREAMS_STATE_DIR:-${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/billion-streams-club-state}"
SLACK_CHANNEL="${BILLION_STREAMS_SLACK_CHANNEL:-}"
SLACK_TOKEN="${BILLION_STREAMS_SLACK_TOKEN:-${MUSO_SLACK_BOT_TOKEN_CMO:-}}"

T_1B=1000000000
T_10B=10000000000

FORMAT="slack"      # slack | tsv
DRY_RUN=0           # compute + print, never post, never update the announced set
NO_ENRICH=0         # skip the name lookup (entrants show their id)
MAX_ANNOUNCE="${BILLION_STREAMS_MAX_ANNOUNCE:-50}"   # safety cap; above this we refuse

usage() {
  cat <<'USAGE'
streams-milestones.sh — announce who newly crossed 1B / 10B lifetime streams

Usage:
  streams-milestones.sh [--channel C…] [--format slack|tsv] [--dry-run]
                        [--no-enrich] [--state-dir DIR] [--max-announce N]

  --channel C…      Slack channel id to POST new crossings to. The state is updated
                    only after Slack confirms the post (at-least-once). Without it,
                    the message is printed to stdout and state is NOT updated (preview).
                    Token comes from BILLION_STREAMS_SLACK_TOKEN or
                    MUSO_SLACK_BOT_TOKEN_CMO.
  --format slack    Build the Slack mrkdwn message (default). Prints NO_REPLY when
                    nobody new crossed (and on the seed run); posts nothing then.
  --format tsv      New entrants as TSV "tier<TAB>profileid<TAB>streams<TAB>name"
                    (debug; never posts, never updates the announced set).
  --dry-run         Compute + print but never post and never update the set (repeatable).
  --no-enrich       Skip the batched Trino name lookup (entrants show their id).
  --state-dir DIR   State directory (default
                    ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/billion-streams-club-state).
  --max-announce N  Refuse (NO_REPLY + loud stderr, no post, no state change) if more
                    than N profiles would be announced in one run — a corrupt/lost
                    state file can't dump the whole club to Slack (default 50).
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)      SLACK_CHANNEL="${2:?--channel needs a value}"; shift 2 ;;
    --format)       FORMAT="${2:?--format needs a value}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --no-enrich)    NO_ENRICH=1; shift ;;
    --state-dir)    STATE_DIR="${2:?--state-dir needs a value}"; shift 2 ;;
    --max-announce) MAX_ANNOUNCE="${2:?--max-announce needs a value}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$FORMAT" =~ ^(slack|tsv)$ ]] || die "--format must be slack or tsv (got: $FORMAT)"
[[ "$MAX_ANNOUNCE" =~ ^[0-9]+$ ]] || die "--max-announce must be a non-negative integer (got: $MAX_ANNOUNCE)"

mkdir -p "$STATE_DIR"
CURRENT_FILE="$STATE_DIR/club-current.tsv"   # scratch, rewritten every run
ANN_1B="$STATE_DIR/announced-1b.txt"
ANN_10B="$STATE_DIR/announced-10b.txt"

# State changes (seed or commit) require the real posting shape: a non-dry-run slack
# run WITH a channel. A no-channel preview (or tsv/dry-run) never mutates the set.
writes_allowed() { [[ "$DRY_RUN" -eq 0 && "$FORMAT" == "slack" && -n "$SLACK_CHANNEL" ]]; }

# Atomic publish: write stdin to a temp file in the same dir, then rename. A kill or
# ENOSPC mid-write leaves the old file intact, never a truncated one.
atomic_write() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat > "$tmp"
  mv -f "$tmp" "$dest"
}

# Post text to a Slack channel; return 0 only on a confirmed ok:true response.
post_slack() {
  local ch="$1" txt="$2" resp err
  [[ -n "$SLACK_TOKEN" ]] || { echo "ERROR: no Slack token (BILLION_STREAMS_SLACK_TOKEN / MUSO_SLACK_BOT_TOKEN_CMO)" >&2; return 1; }
  resp="$(jq -n --arg ch "$ch" --arg txt "$txt" '{channel:$ch, text:$txt}' \
    | curl -sS -m 30 \
        -H "Authorization: Bearer ${SLACK_TOKEN}" \
        -H "Content-type: application/json; charset=utf-8" \
        --data @- https://slack.com/api/chat.postMessage 2>/dev/null)" || {
    echo "ERROR: Slack post request failed (network/curl)" >&2; return 1; }
  if [[ "$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
    return 0
  fi
  err="$(printf '%s' "$resp" | jq -r '.error // "unknown"' 2>/dev/null)"
  echo "ERROR: Slack post rejected: ${err}" >&2
  return 1
}

# --- read the current >=1B club (fast: one filtered read of the canonical table) ---
read -r -d '' CLUB_SQL <<SQL || true
SELECT profileid, streams
FROM postgresql_core.public.profile_v3_lifetime
WHERE streams >= ${T_1B}
ORDER BY streams DESC
SQL

"$MUSO_BIN" query "$CLUB_SQL" --format json \
  | jq -r 'select(.profileid != null) | [.profileid, (.streams|tostring)] | @tsv' \
  > "$CURRENT_FILE" || die "failed to read current club from profile_v3_lifetime"

[[ -s "$CURRENT_FILE" ]] || die "current club query returned no rows — refusing to touch state"

# --- bootstrap: no announced set yet → seed from the whole club, announce nothing ---
if [[ ! -f "$ANN_1B" ]]; then
  if writes_allowed; then
    cut -f1 "$CURRENT_FILE" | atomic_write "$ANN_1B"
    awk -F'\t' -v t="$T_10B" '($2+0)>=t {print $1}' "$CURRENT_FILE" | atomic_write "$ANN_10B"
    echo "baseline recorded: seeded announced-set from $(wc -l < "$CURRENT_FILE" | tr -d ' ') profiles >= 1B (nothing to announce on the seed run)" >&2
  else
    echo "no announced-set yet (bootstrap) — run once with --channel (non-dry-run) to seed" >&2
  fi
  [[ "$FORMAT" == "slack" ]] && echo "NO_REPLY"
  exit 0
fi

# --- load the per-tier announced sets ---
declare -A ann1=() ann10=()
while read -r pid; do [[ -n "$pid" ]] && ann1["$pid"]=1; done < "$ANN_1B"
[[ -f "$ANN_10B" ]] && while read -r pid; do [[ -n "$pid" ]] && ann10["$pid"]=1; done < "$ANN_10B"

# --- find profiles over a tier that have not been announced at that tier yet ---
fmt_b() { awk -v n="$1" 'BEGIN { printf "%.2fB", n / 1000000000 }'; }

# Escape Slack mrkdwn control chars in untrusted text (profile names) — & first, then
# < > so a name with <@U…> / <!channel> / <url|label> can't inject markup or mentions
# into the channel message. The profile URL below is our own intentional link.
slack_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

entrants=""        # tier<TAB>pid<TAB>streams, one per line (club order = streams desc)
new1b=()           # ids to add to announced-1b
new10b=()          # ids to add to announced-10b
ids_sql=""         # 'id1','id2',... for one batched name lookup
n_entrants=0
while IFS=$'\t' read -r pid streams; do
  [[ -n "$pid" && "$streams" =~ ^[0-9]+$ ]] || continue

  tier=""
  if (( streams >= T_10B )) && [[ -z "${ann10[$pid]:-}" ]]; then
    tier="10B"; new10b+=("$pid")
    [[ -z "${ann1[$pid]:-}" ]] && new1b+=("$pid")   # also a first-time 1B member
  elif (( streams >= T_1B )) && [[ -z "${ann1[$pid]:-}" ]]; then
    tier="1B"; new1b+=("$pid")
  fi
  [[ -n "$tier" ]] || continue

  entrants+="${tier}"$'\t'"${pid}"$'\t'"${streams}"$'\n'
  ids_sql+="${ids_sql:+,}'${pid}'"
  n_entrants=$((n_entrants + 1))
done < "$CURRENT_FILE"

# --- safety cap: a corrupt/lost state file must never dump the whole club to Slack.
#     Fail LOUD (non-zero) so the cron surfaces it as an error, not a quiet no-crossing
#     day — NO_REPLY here would let a lost/corrupt state look healthy. ---
if (( n_entrants > MAX_ANNOUNCE )); then
  die "REFUSING to announce $n_entrants profiles (> --max-announce=$MAX_ANNOUNCE) — likely a lost/corrupt announced-set or a bulk data event. Nothing posted, state left UNCHANGED; investigate $STATE_DIR before re-running."
fi

# --- persist the announced set (atomic, union with what we just announced) ---
commit_state() {
  if (( ${#new1b[@]} > 0 )); then
    { cat "$ANN_1B"; printf '%s\n' "${new1b[@]}"; } | sort -u | atomic_write "$ANN_1B"
  fi
  if (( ${#new10b[@]} > 0 )); then
    { [[ -f "$ANN_10B" ]] && cat "$ANN_10B"; printf '%s\n' "${new10b[@]}"; } | sort -u | atomic_write "$ANN_10B"
  fi
}

# --- one fast IN-list lookup resolves all entrants' names (index pushdown, seconds) ---
declare -A name=()
if [[ -n "$ids_sql" && "$NO_ENRICH" -eq 0 ]]; then
  while IFS=$'\t' read -r pid nm; do
    [[ -n "$pid" ]] && name["$pid"]="$nm"
  done < <("$MUSO_BIN" query "SELECT profile_id, MAX(profile_name) AS name FROM postgresql_stats.public.profile_track WHERE profile_id IN (${ids_sql}) GROUP BY profile_id" --format json 2>/dev/null \
    | jq -r 'select(.profile_id != null) | [.profile_id, (.name // "")] | @tsv')
fi

# --- tsv (debug): dump entrants, never post, never commit ---
if [[ "$FORMAT" == "tsv" ]]; then
  while IFS=$'\t' read -r tier pid streams; do
    [[ -n "$tier" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$tier" "$pid" "$streams" "${name[$pid]:-$pid}"
  done < <(printf '%s' "$entrants")
  exit 0
fi

if [[ -z "$entrants" ]]; then
  echo "NO_REPLY"
  exit 0
fi

# --- build the Slack message ---
section_10b=""
section_1b=""
while IFS=$'\t' read -r tier pid streams; do
  [[ -n "$tier" ]] || continue
  disp="$(slack_escape "${name[$pid]:-$pid}")"
  line="• *${disp}* — *$(fmt_b "$streams")* lifetime streams  <https://muso.ai/profile/${pid}|view>"
  if [[ "$tier" == "10B" ]]; then
    section_10b+="${line}"$'\n'
  else
    section_1b+="${line}"$'\n'
  fi
done < <(printf '%s' "$entrants")

msg=":tada: *Streams milestone club* — new crossings"
[[ -n "$section_10b" ]] && msg+=$'\n\n'"*:crown: 10 BILLION streams*"$'\n'"${section_10b%$'\n'}"
[[ -n "$section_1b" ]]  && msg+=$'\n\n'"*:first_place_medal: 1 BILLION streams*"$'\n'"${section_1b%$'\n'}"

# --- deliver, THEN commit: record entrants only after Slack confirms the post, so a
#     failed delivery leaves them un-recorded and the next run retries them. ---
if writes_allowed; then
  post_slack "$SLACK_CHANNEL" "$msg" \
    || die "Slack delivery to $SLACK_CHANNEL failed — state NOT committed; the next run will retry these ${n_entrants} crossing(s)"
  commit_state
  echo "posted ${n_entrants} new crossing(s) to ${SLACK_CHANNEL}"
else
  # Preview (no --channel, or --dry-run): show the message, do NOT commit.
  printf '%s\n' "$msg"
fi
