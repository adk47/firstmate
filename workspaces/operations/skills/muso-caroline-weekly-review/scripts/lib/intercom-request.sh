#!/usr/bin/env bash
# Shared Intercom request helper, sourced by fetch-conversations.sh and
# check-escalated.sh so the 429/Retry-After + backoff logic lives in ONE place.
# Defines intercom_request only; sets no top-level shell options (the caller owns
# `set -euo pipefail`). Requires MUSOAI_INTERCOM_TOKEN in the environment.

# Generic Intercom request with 429/Retry-After + exponential backoff (max 3).
# Prints the response body to stdout. $1=method $2=url $3=body(optional).
intercom_request() {
  local method="$1" url="$2" body="${3:-}" attempt=0 max=3 rc
  while [ "$attempt" -lt "$max" ]; do
    local tmp_headers tmp_body
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    set +e
    if [ -n "$body" ]; then
      curl -sS -D "$tmp_headers" -o "$tmp_body" -X "$method" \
        -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
        -H "Intercom-Version: 2.11" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$body" "$url"
    else
      curl -sS -D "$tmp_headers" -o "$tmp_body" -X "$method" \
        -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
        -H "Intercom-Version: 2.11" \
        -H "Accept: application/json" "$url"
    fi
    rc=$?
    set -e
    local status
    # `|| true` is REQUIRED: under `set -euo pipefail`, a curl connect failure
    # (DNS/TLS/connect blip) writes no headers, so grep finds no match and exits
    # 1; pipefail propagates that, the assignment returns non-zero, and set -e
    # would abort the helper here — BEFORE the `rc != 0` retry branch below. That
    # turned a retryable transient into a hard single-attempt failure.
    status=$(grep -oiE '^HTTP/[0-9.]+ +[0-9]+' "$tmp_headers" 2>/dev/null | head -1 | awk '{print $NF}' || true)
    if [ "$status" = "429" ]; then
      local wait
      # Same `|| true` reason: a 429 may omit Retry-After (it is optional), so
      # grep can no-match and abort under set -e before the fallback below.
      wait=$(grep -i "^Retry-After:" "$tmp_headers" | awk '{print $2}' | tr -d '\r' || true)
      [ -z "$wait" ] && wait=$((1 << attempt))
      sleep "$wait"
      attempt=$((attempt + 1))
      rm -f "$tmp_headers" "$tmp_body"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$tmp_headers" "$tmp_body"
      attempt=$((attempt + 1))
      sleep $((1 << attempt))
      continue
    fi
    case "${status:-}" in
      2*)
        cat "$tmp_body"
        rm -f "$tmp_headers" "$tmp_body"
        return 0
        ;;
      5*)
        # Transient server error — retry with backoff.
        rm -f "$tmp_headers" "$tmp_body"
        attempt=$((attempt + 1))
        sleep $((1 << attempt))
        continue
        ;;
      *)
        # 4xx (auth/not-found/bad-request) or unparseable: fail loud so an error
        # response can never become a silently-empty candidate set or a dropped
        # conversation.
        echo "intercom_request: $method $url returned HTTP ${status:-unknown}" >&2
        rm -f "$tmp_headers" "$tmp_body"
        return 1
        ;;
    esac
  done
  echo "intercom_request: exhausted retries for $method $url" >&2
  return 1
}
