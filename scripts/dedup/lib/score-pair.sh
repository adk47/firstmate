#!/usr/bin/env bash
# Pure scorer. Takes two canonical-profile JSON file paths, prints
# one JSON object describing the verdict.
set -euo pipefail

lev() {
  local s="$1" t="$2"
  local m=${#s} n=${#t}
  if [ "$m" -eq 0 ]; then echo "$n"; return; fi
  if [ "$n" -eq 0 ]; then echo "$m"; return; fi
  local -a prev curr
  local i j
  for ((i=0; i<=n; i++)); do prev[i]=$i; done
  for ((i=1; i<=m; i++)); do
    curr[0]=$i
    for ((j=1; j<=n; j++)); do
      local cost=1
      [ "${s:i-1:1}" = "${t:j-1:1}" ] && cost=0
      local del=$(( prev[j] + 1 ))
      local ins=$(( curr[j-1] + 1 ))
      local sub=$(( prev[j-1] + cost ))
      local min=$del
      [ $ins -lt $min ] && min=$ins
      [ $sub -lt $min ] && min=$sub
      curr[j]=$min
    done
    prev=("${curr[@]}")
  done
  echo "${prev[n]}"
}

normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
            | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null \
            | tr -s '[:space:]' ' ' \
            | sed 's/^ //; s/ $//'
}

a_path="${1:?usage: score-pair.sh <profile_a.json> <profile_b.json>}"
b_path="${2:?usage: score-pair.sh <profile_a.json> <profile_b.json>}"

A=$(jq -c '.' "$a_path")
B=$(jq -c '.' "$b_path")

shared_raw=$(jq -n --argjson a "$A" --argjson b "$B" '
  ($a.raw_ids // []) as $ar |
  ($b.raw_ids // []) as $br |
  [$ar[] | select(. as $x | $br | index($x))]
')

shared_ipi=$(jq -n --argjson a "$A" --argjson b "$B" '
  ($a.ipis // []) as $ai |
  ($b.ipis // []) as $bi |
  [$ai[] | select(. as $x | $bi | index($x))]
')

hard=$(jq -n --argjson r "$shared_raw" --argjson i "$shared_ipi" '
  ([ $r[] | (split(":") | { type: "same_raw_id", source: .[0], value: (.[1:] | join(":")) }) ])
  +
  ([ $i[] | { type: "same_ipi", value: . } ])
')

verdict="no_match"
if [ "$(echo "$hard" | jq 'length')" -gt 0 ]; then verdict="hard_dupe"; fi

# SHARED_TRACK_COUNT is the count of tracks where both profiles appear in
# matvw_catalog_track.profiles[].profile_id. Optional; absent -> 0.
shared_tracks="${SHARED_TRACK_COUNT:-0}"
case "$shared_tracks" in
  ''|*[!0-9]*) shared_tracks=0 ;;
esac

claim_state=$(jq -rn --argjson a "$A" --argjson b "$B" '
  ($a.claim.user_id // null) as $au |
  ($b.claim.user_id // null) as $bu |
  if   $au == null and $bu == null then "both_unclaimed"
  elif $au != null and $bu == null then "a_claimed_b_unclaimed"
  elif $au == null and $bu != null then "b_claimed_a_unclaimed"
  elif $au == $bu                  then "both_claimed_same_user"
  else                                  "both_claimed_different_users"
  end
')

a_name=$(jq -r '.name // ""' "$a_path")
b_name=$(jq -r '.name // ""' "$b_path")
a_norm=$(normalize_name "$a_name")
b_norm=$(normalize_name "$b_name")
name_lev=$(lev "$a_norm" "$b_norm")

a_legal=$(jq -r '.legal_name // ""' "$a_path")
b_legal=$(jq -r '.legal_name // ""' "$b_path")
legal_match=false
if [ -n "$a_legal" ] && [ "$(normalize_name "$a_legal")" = "$(normalize_name "$b_legal")" ]; then
  legal_match=true
fi

alias_overlap=$(jq -n --argjson a "$A" --argjson b "$B" '
  (($a.known_as_names // []) | map(ascii_downcase)) as $ax |
  (($b.known_as_names // []) | map(ascii_downcase)) as $bx |
  [$ax[] | select(. as $x | $bx | index($x))] | length
')

pop_delta=$(jq -n --argjson a "$A" --argjson b "$B" '(($a.popularity // 0) - ($b.popularity // 0)) | fabs | floor')
cred_delta=$(jq -n --argjson a "$A" --argjson b "$B" '(($a.credit_count // 0) - ($b.credit_count // 0)) | fabs | floor')

country_match=false
if [ "$(jq -r '.country // "" | ascii_downcase' "$a_path")" = "$(jq -r '.country // "" | ascii_downcase' "$b_path")" ] && [ -n "$(jq -r '.country // ""' "$a_path")" ]; then
  country_match=true
fi

# candidate_dupe: only if no hard signal already fired. Two arms:
#   (a) classic cross-credit corroboration — shared_tracks >= 3
#   (b) "auto-created near-empty duplicate" pattern — one profile has at most
#       2 credits, the other has at least 5. This is the dominant real-world
#       case in customer-reported merges: an auto-created stub profile with
#       0-2 credits that the customer wants merged into their main profile.
#       Validated against ticket 869dbq3gc (Ilija Stajic case): main profile
#       has 69 credits, duplicate has 1, name distance 1 — both arm (a) and
#       a strict shared_tracks rule miss this; arm (b) catches it.
a_cc=$(jq -r '.credit_count // 0' "$a_path")
b_cc=$(jq -r '.credit_count // 0' "$b_path")
min_cc=$(( a_cc < b_cc ? a_cc : b_cc ))
max_cc=$(( a_cc > b_cc ? a_cc : b_cc ))

if [ "$verdict" = "no_match" ] \
  && [ "$name_lev" -le 2 ] \
  && [ "$claim_state" != "both_claimed_different_users" ]; then
  if [ "$shared_tracks" -ge 3 ]; then
    verdict="candidate_dupe"
  elif [ "$min_cc" -le 2 ] && [ "$max_cc" -ge 5 ]; then
    verdict="candidate_dupe"
  fi
fi

jq -n \
  --argjson a "$A" --argjson b "$B" \
  --argjson hard "$hard" \
  --arg verdict "$verdict" \
  --arg claim_state "$claim_state" \
  --argjson name_lev "$name_lev" \
  --argjson legal_match "$legal_match" \
  --argjson alias_overlap "$alias_overlap" \
  --argjson pop_delta "$pop_delta" \
  --argjson cred_delta "$cred_delta" \
  --argjson country_match "$country_match" \
  --argjson shared_tracks "$shared_tracks" \
  '{
    profile_a: $a.id,
    profile_b: $b.id,
    verdict: $verdict,
    hard_signals: $hard,
    soft_signals: {
      claim_state: $claim_state,
      name_levenshtein: $name_lev,
      legal_name_match: $legal_match,
      alias_overlap: $alias_overlap,
      popularity_delta: $pop_delta,
      credit_count_delta: $cred_delta,
      country_match: $country_match,
      shared_track_ids_count: $shared_tracks
    },
    names: {a: $a.name, b: $b.name},
    credit_counts: {a: ($a.credit_count // 0), b: ($b.credit_count // 0)},
    claim: {a: ($a.claim.user_id // null), b: ($b.claim.user_id // null)}
  }'
