#!/usr/bin/env bash
# Profile dedup detector. See docs/superpowers/specs/2026-05-18-profile-dedup-detector-design.md
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$DIR/lib"

# Shadow log: append every scored verdict for later precision analysis.
# Silently no-ops if the path isn't writable, so non-root devs don't break.
DEDUP_SHADOW_LOG="${DEDUP_SHADOW_LOG:-/var/log/dedup-shadow.jsonl}"

log_shadow() {
  local result_json="$1"
  [ -z "$result_json" ] && return 0
  local dir; dir=$(dirname "$DEDUP_SHADOW_LOG")
  [ -w "$dir" ] || [ -w "$DEDUP_SHADOW_LOG" ] 2>/dev/null || return 0
  printf '%s\n' "$result_json" \
    | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{ts: $ts, profile_a, profile_b, verdict, hard_signals, soft_signals}' \
    >> "$DEDUP_SHADOW_LOG" 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage:
  find-dupes.sh --profile <uuid>
  find-dupes.sh --email <addr>
  find-dupes.sh --catalog [--limit N]
  find-dupes.sh --pair <uuid_a> <uuid_b>
  find-dupes.sh --name <name> [--anchor <uuid>] [--limit N]

Outputs JSONL on stdout. Requires MUSO_ADMIN_EMAIL + MUSO_ADMIN_PASSWORD
(consumed by skills-all/muso-ops-admin/scripts/muso-admin-api.sh, which
caches the JWT locally) and Trino access via TRINO_QUERY.

--name resolves a free-text artist name to candidate Muso profile UUIDs
via matvw_catalog_profile, then pair-scores. If --anchor is given, each
match is scored against the anchor; otherwise the highest-credit_count
profile is treated as the anchor and the rest are scored against it.
Used for prose-only ClickUp tickets where Caroline captured a name but
no UUIDs.
EOF
}

# Score a (a.json, b.json) pair, enriching with shared_track_ids_count for the
# candidate_dupe soft signal. If shared-track-count.sh fails (Trino down etc),
# we emit a stderr warning and mark the result with shared_track_count_degraded
# so downstream readers can distinguish "0 shared tracks" from "Trino unknown".
score_with_enrichment() {
  local a_path="$1" b_path="$2"
  local a_id b_id stc degraded
  a_id=$(jq -r '.id // ""' "$a_path")
  b_id=$(jq -r '.id // ""' "$b_path")
  stc=0
  degraded=false
  if [ -n "$a_id" ] && [ -n "$b_id" ] && [ "$a_id" != "$b_id" ]; then
    if stc=$(bash "$LIB/shared-track-count.sh" "$a_id" "$b_id" 2>/dev/null); then
      :
    else
      echo "find-dupes: warn: shared-track-count failed for ($a_id, $b_id); candidate_dupe disabled for this pair" >&2
      stc=0
      degraded=true
    fi
  fi
  local scored
  scored=$(SHARED_TRACK_COUNT="$stc" bash "$LIB/score-pair.sh" "$a_path" "$b_path" \
    | jq -c --argjson d "$degraded" '. + {shared_track_count_degraded: $d}')
  log_shadow "$scored"
  printf '%s\n' "$scored"
}

run_pair_mode() {
  local a="$1" b="$2"
  local tmpdir; tmpdir="$TMPDIR_ROOT/pair"
  mkdir -p "$tmpdir"
  bash "$LIB/fetch-profile.sh" "$a" > "$tmpdir/a.json" 2>/dev/null || {
    echo "find-dupes: warn: could not fetch $a" >&2
    return 0
  }
  bash "$LIB/fetch-profile.sh" "$b" > "$tmpdir/b.json" 2>/dev/null || {
    echo "find-dupes: warn: could not fetch $b" >&2
    return 0
  }
  score_with_enrichment "$tmpdir/a.json" "$tmpdir/b.json" \
    | jq -c '. + {detected_via: "pair"}'
}

run_profile_mode() {
  local pid="$1"
  local tmpdir; tmpdir="$TMPDIR_ROOT/$pid"
  mkdir -p "$tmpdir"

  bash "$LIB/fetch-profile.sh" "$pid" > "$tmpdir/self.json"

  local siblings sibling_status=0
  siblings=$(bash "$LIB/find-siblings.sh" "$pid" < "$tmpdir/self.json") || sibling_status=$?

  if [ "$sibling_status" -eq 4 ]; then
    echo "find-dupes: warn: sibling lookup hit Trino errors for $pid; results may be incomplete" >&2
  fi
  if [ -z "$siblings" ]; then
    if [ "$sibling_status" -eq 0 ]; then
      # spec §7: empty external IDs on input profile -> single stderr line, exit 0.
      echo "profile $pid has no profile-level external identifiers; no hard match possible" >&2
    fi
    return 0
  fi

  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    bash "$LIB/fetch-profile.sh" "$sid" > "$tmpdir/sib.json" 2>/dev/null || {
      echo "find-dupes: warn: could not fetch $sid" >&2
      continue
    }
    local result
    result=$(score_with_enrichment "$tmpdir/self.json" "$tmpdir/sib.json")
    local verdict
    verdict=$(echo "$result" | jq -r '.verdict')
    if [ "$verdict" = "hard_dupe" ] || [ "$verdict" = "candidate_dupe" ]; then
      echo "$result" | jq -c '. + {detected_via: "profile"}'
    fi
  done <<< "$siblings"
}

run_email_mode() {
  local email="$1"
  local profile_ids
  profile_ids=$(bash "$LIB/fetch-claimed-profiles.sh" "$email")
  if [ -z "$profile_ids" ]; then
    echo "find-dupes: no claimed profiles for $email" >&2
    return 0
  fi
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    run_profile_mode "$pid" | jq -c '. + {detected_via: "email"}'
  done <<< "$profile_ids"
}

run_name_mode() {
  local name="$1" anchor="$2" limit="$3"
  local matches anchor_id others tmpdir
  tmpdir="$TMPDIR_ROOT/name"
  mkdir -p "$tmpdir"

  matches=$(bash "$LIB/find-name-matches.sh" "$name" --limit "$limit") || {
    echo "find-dupes: name resolution failed for '$name'" >&2
    return 4
  }
  if [ -z "$matches" ]; then
    echo "find-dupes: no profile matches for name '$name'" >&2
    return 0
  fi

  if [ -n "$anchor" ]; then
    anchor_id="$anchor"
    # If the anchor isn't in the match set, that's fine — we still score
    # everything in the match set against the user-specified anchor.
    others=$(printf %s "$matches" | grep -vxF "$anchor_id" || true)
  else
    # First UUID is highest-credit_count thanks to the ORDER BY in
    # find-name-matches.sh. Use it as the implicit anchor.
    anchor_id=$(printf %s "$matches" | head -n1)
    others=$(printf %s "$matches" | tail -n +2)
  fi

  if [ -z "$others" ]; then
    echo "find-dupes: name '$name' resolved to only one profile ($anchor_id); nothing to compare" >&2
    return 0
  fi

  bash "$LIB/fetch-profile.sh" "$anchor_id" > "$tmpdir/anchor.json" 2>/dev/null || {
    echo "find-dupes: could not fetch anchor profile $anchor_id" >&2
    return 0
  }

  while IFS= read -r other; do
    [ -z "$other" ] && continue
    bash "$LIB/fetch-profile.sh" "$other" > "$tmpdir/other.json" 2>/dev/null || {
      echo "find-dupes: warn: could not fetch $other" >&2
      continue
    }
    local result verdict
    result=$(score_with_enrichment "$tmpdir/anchor.json" "$tmpdir/other.json")
    verdict=$(echo "$result" | jq -r '.verdict')
    if [ "$verdict" = "hard_dupe" ] || [ "$verdict" = "candidate_dupe" ]; then
      echo "$result" | jq -c --arg name "$name" --arg anchor "$anchor_id" \
        '. + {detected_via: "name", search_name: $name, anchor_profile_id: $anchor}'
    fi
  done <<< "$others"
}

run_catalog_mode() {
  local limit="${1:-}"
  local trino="${TRINO_QUERY:-/opt/hydra/scripts/trino-query.sh}"
  local sql="$DIR/sql/catalog-clusters.sql"
  local sqltxt; sqltxt=$(cat "$sql")
  if [ -n "$limit" ]; then
    sqltxt="$sqltxt
LIMIT $limit"
  fi

  # Park the dedup file inside TMPDIR_ROOT so the script-level EXIT trap
  # cleans it up. A local + RETURN trap looked tidier but bash unwinds the
  # local before the RETURN trap fires; under `set -u` the trap's
  # "$seen_pairs" expansion then trips and emits a spurious stderr error
  # at function return.
  local tmpdir; tmpdir="$TMPDIR_ROOT"
  local seen_pairs="$tmpdir/seen-pairs"
  : > "$seen_pairs"

  "$trino" "$sqltxt" | while IFS=, read -r kind key ids _size; do
    kind="${kind#\"}"; kind="${kind%\"}"
    key="${key#\"}"; key="${key%\"}"
    ids="${ids#\"}"; ids="${ids%\"}"
    bash "$LIB/expand-cluster.sh" "$ids" | while read -r pa pb; do
      local pair_key="$pa|$pb"
      grep -qxF "$pair_key" "$seen_pairs" && continue
      echo "$pair_key" >> "$seen_pairs"
      bash "$LIB/fetch-profile.sh" "$pa" > "$tmpdir/a.json" 2>/dev/null || continue
      bash "$LIB/fetch-profile.sh" "$pb" > "$tmpdir/b.json" 2>/dev/null || continue
      local result
      # Catalog mode intentionally skips score_with_enrichment (the per-pair
      # Trino round-trip for shared_track_count would multiply Trino load by
      # cluster-size^2). The shadow log still gets the verdict so precision
      # analysis isn't asymmetric across modes.
      result=$(bash "$LIB/score-pair.sh" "$tmpdir/a.json" "$tmpdir/b.json")
      log_shadow "$result"
      [ "$(echo "$result" | jq -r '.verdict')" = "hard_dupe" ] || continue
      echo "$result" | jq -c '. + {detected_via: "catalog"}'
    done
  done
}

main() {
  [ $# -eq 0 ] && { usage; exit 1; }
  TMPDIR_ROOT=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_ROOT"' EXIT
  case "$1" in
    --profile) run_profile_mode "$2" ;;
    --email)   run_email_mode "$2" ;;
    --pair)    run_pair_mode "$2" "$3" ;;
    --name)
      local nm="$2" anch="" lim="20"
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --anchor) anch="$2"; shift 2 ;;
          --limit)  lim="$2"; shift 2 ;;
          *) echo "find-dupes: unknown --name flag: $1" >&2; exit 1 ;;
        esac
      done
      # Guard --limit before it flows into Trino via find-name-matches.sh.
      if ! [[ "$lim" =~ ^[0-9]+$ ]]; then
        echo "find-dupes: --limit must be a non-negative integer, got '$lim'" >&2
        exit 1
      fi
      run_name_mode "$nm" "$anch" "$lim"
      ;;
    --catalog)
      local lim=""
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --limit) lim="$2"; shift 2 ;;
          *) echo "find-dupes: unknown --catalog flag: $1" >&2; exit 1 ;;
        esac
      done
      # Guard --limit before raw interpolation into the catalog-cluster SQL.
      if [ -n "$lim" ] && ! [[ "$lim" =~ ^[0-9]+$ ]]; then
        echo "find-dupes: --limit must be a non-negative integer, got '$lim'" >&2
        exit 1
      fi
      run_catalog_mode "$lim"
      ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
