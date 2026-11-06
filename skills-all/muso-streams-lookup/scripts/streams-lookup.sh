#!/usr/bin/env bash
# streams-lookup.sh — on-demand per-artist lifetime-streams lookup & leaderboard.
#
# Source: postgresql_olap.public.cube_analytics_profile_view.ce_streams (period='all')
# — the per-artist LIFETIME total the muso.ai profile page "Streams" headline shows
# (live, recomputed from track_daily; native bigint, <1s). This is THE canonical source.
# DO NOT use profile_v3_lifetime / profile_v3_tracks — they are DEAD (frozen 2026-06-06).
#
# Three read modes (SELECT-only Trino; reachable only on the main gateway host node-8):
#   leaderboard (default) — top N profiles with ce_streams >= a threshold
#   --artist NAME         — look up one profile by name (exact, then fuzzy)
#   --id UUID             — point read by profile_id
#
# profile_type defaults to 'artist' for the leaderboard (drops the ~235 label/publisher
# 'organization' rows like Kobalt/Sony); pass --type all|organization|professional to widen.
# This skill PRINTS to stdout for the agent to relay — it never posts to Slack itself.
set -euo pipefail

MUSO_BIN="${MUSO_BIN:-$(command -v muso || echo /usr/local/bin/muso)}"
VIEW="postgresql_olap.public.cube_analytics_profile_view"
SEL="profile_id, profile_name, profile_type, ce_streams, ce_spotify_streams, ce_youtube_streams"

TOP=20
MIN="1000000000"        # 1B
TYPE="artist"           # artist | organization | professional | all
ARTIST=""
PROFILE_ID=""
LIMIT=1                 # candidates shown for a by-name lookup
PLATFORMS=0
FORMAT="slack"          # slack | tsv | json

usage() {
  cat <<'USAGE'
streams-lookup.sh — look up per-artist LIFETIME streams (live cube, never v3)

Usage:
  streams-lookup.sh [--top N] [--min T] [--type artist|organization|professional|all]
  streams-lookup.sh --artist "NAME" [--limit N] [--type ...]
  streams-lookup.sh --id <profile-uuid>
  [--platforms] [--format slack|tsv|json]

Modes (pick one; default = leaderboard):
  (no --artist/--id)  Leaderboard: top --top profiles with ce_streams >= --min.
  --artist "NAME"     Look up by profile name (exact match first, then fuzzy LIKE).
  --id <uuid>         Point read by profile_id.

Options:
  --top N        Leaderboard size (default 20).
  --min T        Threshold on lifetime streams; accepts an int or a K/M/B/T suffix
                 (e.g. 1B, 10B, 500M). Default 1B.
  --type T       profile_type filter for the leaderboard: artist (default),
                 organization (labels/publishers), professional, or all.
  --limit N      For --artist: how many matching profiles to show (default 1).
  --platforms    Also show the Spotify / YouTube split.
  --format F     slack (default, mrkdwn) | tsv | json (raw cube rows).
  -h, --help     This help.

Source: postgresql_olap.public.cube_analytics_profile_view.ce_streams (period='all') —
the muso.ai profile-page streams headline. NOT profile_v3_* (dead). For the daily auto-post
of who JUST crossed a milestone, use the billion-streams-club skill instead (cron-only).
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Parse an amount with an optional K/M/B/T suffix into a plain integer.
parse_amount() {
  local v="${1^^}" mult=1
  case "$v" in
    *K) mult=1000;            v="${v%K}" ;;
    *M) mult=1000000;         v="${v%M}" ;;
    *B) mult=1000000000;      v="${v%B}" ;;
    *T) mult=1000000000000;   v="${v%T}" ;;
  esac
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "invalid --min amount: $1"
  awk -v n="$v" -v m="$mult" 'BEGIN { printf "%d", n * m }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)       TOP="${2:?--top needs a value}"; shift 2 ;;
    --min)       MIN="$(parse_amount "${2:?--min needs a value}")"; shift 2 ;;
    --type)      TYPE="${2:?--type needs a value}"; shift 2 ;;
    --artist)    ARTIST="${2:?--artist needs a value}"; shift 2 ;;
    --id)        PROFILE_ID="${2:?--id needs a value}"; shift 2 ;;
    --limit)     LIMIT="${2:?--limit needs a value}"; shift 2 ;;
    --platforms) PLATFORMS=1; shift ;;
    --format)    FORMAT="${2:?--format needs a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[[ "$FORMAT" =~ ^(slack|tsv|json)$ ]] || { echo "--format must be slack|tsv|json (got: $FORMAT)" >&2; exit 2; }
[[ "$TYPE" =~ ^(artist|organization|professional|all)$ ]] || { echo "--type must be artist|organization|professional|all (got: $TYPE)" >&2; exit 2; }
[[ "$TOP" =~ ^[0-9]+$ ]]   || { echo "--top must be a non-negative integer (got: $TOP)" >&2; exit 2; }
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "--limit must be a non-negative integer (got: $LIMIT)" >&2; exit 2; }
[[ -n "$ARTIST" && -n "$PROFILE_ID" ]] && { echo "--artist and --id are mutually exclusive" >&2; exit 2; }

MODE="leaderboard"
[[ -n "$ARTIST" ]] && MODE="name"
[[ -n "$PROFILE_ID" ]] && MODE="id"

# Humanize a stream count: T / B / M / raw.
fmt_b() {
  awk -v n="$1" 'BEGIN {
    n = n + 0;
    if      (n >= 1000000000000) printf "%.2fT", n / 1000000000000;
    else if (n >= 1000000000)    printf "%.2fB", n / 1000000000;
    else if (n >= 1000000)       printf "%.2fM", n / 1000000;
    else                         printf "%d", n;
  }'
}

# Escape Slack mrkdwn control chars in untrusted text (profile names) — & first, then < >.
slack_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Lowercase + double single-quotes so a name is safe inside a single-quoted SQL literal.
sql_lit() { local s="${1,,}"; printf '%s' "${s//\'/\'\'}"; }

# Count rows matching a predicate. Used only for the (best-effort) exact-vs-fuzzy choice
# and the homonym hint — callers MUST treat a non-zero exit as fail-soft (|| n=0), never
# conflate a query error with "0 rows" (that would silently downgrade exact→fuzzy). No
# 2>/dev/null: a real failure should be visible on stderr (JSON mode already suppresses
# muso's normal status output).
count_pred() {
  "$MUSO_BIN" query "SELECT count(*) AS n FROM $VIEW WHERE period='all' AND $1" --format json \
    | jq -r '.n // 0' | head -1
}

# Run a SELECT and emit TSV: id<TAB>name<TAB>type<TAB>streams<TAB>spotify<TAB>youtube
run_tsv() {
  "$MUSO_BIN" query "$1" --format json \
    | jq -r 'select(.profile_id != null)
             | [.profile_id, (.profile_name // ""), (.profile_type // ""),
                (.ce_streams // 0 | tostring), (.ce_spotify_streams // 0 | tostring),
                (.ce_youtube_streams // 0 | tostring)] | @tsv'
}

# --- choose the final SQL for the selected mode ---
NAME_PRED=""
case "$MODE" in
  id)
    SQL="SELECT $SEL FROM $VIEW WHERE period='all' AND profile_id='$(sql_lit "$PROFILE_ID")' LIMIT 1"
    ;;
  name)
    nlit="$(sql_lit "$ARTIST")"
    NAME_PRED="lower(profile_name)='${nlit}'"
    exact_n="$(count_pred "$NAME_PRED")" || exact_n=0   # fail-soft: error ≠ "no exact match"
    [[ "${exact_n:-0}" -gt 0 ]] || NAME_PRED="lower(profile_name) LIKE '%${nlit}%'"
    SQL="SELECT $SEL FROM $VIEW WHERE period='all' AND ${NAME_PRED} ORDER BY ce_streams DESC LIMIT ${LIMIT}"
    ;;
  *)
    where="period='all' AND ce_streams >= ${MIN}"
    [[ "$TYPE" != "all" ]] && where="${where} AND lower(profile_type) = '${TYPE}'"
    SQL="SELECT $SEL FROM $VIEW WHERE ${where} ORDER BY ce_streams DESC LIMIT ${TOP}"
    ;;
esac

# --- json: emit the raw cube rows, no formatting ---
if [[ "$FORMAT" == "json" ]]; then
  "$MUSO_BIN" query "$SQL" --format json || die "cube query failed"
  exit 0
fi

rows="$(run_tsv "$SQL")" || die "cube query failed (cube_analytics_profile_view)"

if [[ -z "$rows" ]]; then
  case "$MODE" in
    name) echo "No profile found matching '${ARTIST}'. Try a different spelling, or --type all." ;;
    id)   echo "No profile found with id '${PROFILE_ID}'." ;;
    *)    echo "No ${TYPE} profiles found at or above $(fmt_b "$MIN") lifetime streams." ;;
  esac
  exit 0
fi

# --- tsv: id<TAB>streams<TAB>name<TAB>type (+ spotify/youtube when --platforms) ---
if [[ "$FORMAT" == "tsv" ]]; then
  while IFS=$'\t' read -r id name type streams sp yt; do
    [[ -n "$id" ]] || continue
    if [[ "$PLATFORMS" -eq 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$streams" "$name" "$type" "$sp" "$yt"
    else
      printf '%s\t%s\t%s\t%s\n' "$id" "$streams" "$name" "$type"
    fi
  done <<<"$rows"
  exit 0
fi

# --- slack (default) ---
case "$MODE" in
  leaderboard) header=":bar_chart: *Top $(printf '%s' "$TYPE" | sed 's/^all$/profiles/;s/^artist$/artists/') by lifetime streams* (≥ $(fmt_b "$MIN"))" ;;
  name)        header=":bar_chart: *Streams lookup* — \`$(slack_escape "$ARTIST")\`" ;;
  id)          header=":bar_chart: *Streams lookup*" ;;
esac
printf '%s\n' "$header"

shown=0
while IFS=$'\t' read -r id name type streams sp yt; do
  [[ -n "$id" ]] || continue
  shown=$((shown + 1))
  disp="$(slack_escape "${name:-$id}")"
  extra=""
  [[ "$PLATFORMS" -eq 1 ]] && extra="  _(Spotify $(fmt_b "$sp") · YouTube $(fmt_b "$yt"))_"
  printf '• *%s* — *%s* lifetime streams%s  <https://muso.ai/profile/%s|view>\n' \
    "$disp" "$(fmt_b "$streams")" "$extra" "$id"
done <<<"$rows"

# Homonym hint: if more profiles match the name than we showed, point to disambiguation.
if [[ "$MODE" == "name" ]]; then
  total="$(count_pred "$NAME_PRED")" || total=0   # fail-soft: results already printed; just drop the hint
  if [[ "${total:-0}" -gt "$shown" ]]; then
    printf '_%s other profile(s) also match "%s" — use --limit N or --id <uuid> to disambiguate._\n' \
      "$((total - shown))" "$(slack_escape "$ARTIST")"
  fi
fi
