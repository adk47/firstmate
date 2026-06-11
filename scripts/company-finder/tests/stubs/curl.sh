#!/usr/bin/env bash
# Hermetic curl stub for verify-candidates.sh tests.
#
# VERIFY_STUB_MAP maps domains to outcomes, comma-separated:
#   "alive.example=200,dead.example=404,conn.example=FAIL"
# FAIL → exit 6 (curl's couldn't-resolve-host), like a dead DNS name.
# "<first>THEN<second>" (e.g. FAILTHEN200, 503THEN200) → return <first> on the
# first invocation for that domain, <second> afterwards (exercises the retry
# paths). Invocation counts are kept in $VERIFY_STUB_COUNTER_DIR (one file
# per domain).
set -euo pipefail

url=""
for a in "$@"; do
  case "$a" in
    http://*|https://*) url="$a" ;;
  esac
done
domain=$(sed -E 's|^https?://||; s|/.*$||' <<<"$url")

outcome=""
IFS=',' read -ra pairs <<<"${VERIFY_STUB_MAP:-}"
for p in "${pairs[@]}"; do
  k="${p%%=*}"; v="${p#*=}"
  [[ "$k" == "$domain" ]] && outcome="$v"
done

if [[ -z "$outcome" ]]; then
  echo "curl stub: no VERIFY_STUB_MAP entry for $domain" >&2
  exit 6
fi

if [[ "$outcome" == *THEN* ]]; then
  counter="${VERIFY_STUB_COUNTER_DIR:?}/${domain}"
  count=$(cat "$counter" 2>/dev/null || echo 0)
  echo $((count + 1)) >"$counter"
  if [[ "$count" -eq 0 ]]; then
    outcome="${outcome%%THEN*}"
  else
    outcome="${outcome#*THEN}"
  fi
fi

if [[ "$outcome" == "FAIL" ]]; then
  exit 6
fi

printf '%s' "$outcome"
