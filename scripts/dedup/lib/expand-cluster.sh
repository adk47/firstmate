#!/usr/bin/env bash
# Input: whitespace-separated list of profile IDs (one argument, or stdin).
# Output: unique unordered pairs (lex-sorted), one per line as "a b".
set -euo pipefail

if [ -n "${1:-}" ]; then
  # shellcheck disable=SC2206
  ids=( $1 )
else
  ids=()
  while IFS= read -r tok; do
    [ -n "$tok" ] && ids+=( "$tok" )
  done < <(tr -s ' \n\t' '\n')
fi

if [ "${#ids[@]}" -eq 0 ]; then
  exit 0
fi

uniq=()
while IFS= read -r line; do
  uniq+=( "$line" )
done < <(printf '%s\n' "${ids[@]}" | sort -u)

n=${#uniq[@]}
[ "$n" -lt 2 ] && exit 0

for ((i=0; i<n; i++)); do
  for ((j=i+1; j<n; j++)); do
    a="${uniq[i]}"; b="${uniq[j]}"
    if [[ "$a" < "$b" ]]; then echo "$a $b"; else echo "$b $a"; fi
  done
done
