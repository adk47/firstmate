#!/usr/bin/env bash
# clickup-muso.sh — SOURCED, never executed. The USE_MUSO_CLI seam shared by the
# ClickUp cron scripts (clickup-sla-digest, stale-ticket-watchdog,
# close-merged-tickets): translate a ClickUp REST call onto `muso clickup raw`,
# peeling muso's one-object {data:…} envelope so callers get the bare ClickUp
# body — byte-identical to the curl path. Writes (non-GET) carry --requester for
# attribution + audit; the provider also adds 429 backoff for free.
#
# Single source of truth for the translation so the three scripts don't each
# reimplement it (the same rationale as company-finder's run_nocodb seam).
#
# Usage:  clickup_muso <METHOD> <relpath[?query]> [jsonBody]
#   <relpath> is the path after /api/v2 (/list/<id>/task, /task/<id>,
#   /task/<id>/comment, …) exactly as the curl callers already build it. An
#   embedded ?query is split and url-DECODED into repeatable `--query k=v`
#   (muso re-encodes), so a pre-encoded query such as
#   `tags%5B%5D=action%3Aprofile-merge` round-trips correctly.

# Attribution for the cron's gated writes — passed explicitly per call, never a
# static MUSO_REQUESTER (which would freeze attribution).
: "${CLICKUP_REQUESTER:=clickup-cron@hydra-ops}"

# _clickup_urldecode <str> — percent-decode only well-formed %XX (and + → space).
# A stray % (not followed by two hex digits) and any literal backslash are left
# intact: we must NOT feed the raw value straight to `printf %b`, since %b also
# expands \t, \\, etc. and would corrupt values or error on a bare %.
_clickup_urldecode() {
  local s="${1//+/ }"
  s="${s//\\/\\\\}"                                    # shield literal backslashes from %b
  s="$(sed -E 's/%([0-9A-Fa-f]{2})/\\x\1/g' <<<"$s")"  # convert only valid %XX → \xXX
  printf '%b' "$s"
}

clickup_muso() {
  local method="$1" full="$2" body="${3:-}"
  local path="${full%%\?*}" qs=""
  [[ "$full" == *\?* ]] && qs="${full#*\?}"
  local args=(clickup raw "$method" "$path")
  if [[ -n "$qs" ]]; then
    local pair pairs=()
    IFS='&' read -ra pairs <<<"$qs"
    for pair in "${pairs[@]}"; do
      [[ -z "$pair" ]] && continue
      local k="${pair%%=*}" v=""
      [[ "$pair" == *=* ]] && v="${pair#*=}"   # value-less key → empty value, not key=key
      args+=(--query "$(_clickup_urldecode "$k")=$(_clickup_urldecode "$v")")
    done
  fi
  [[ "$method" != GET ]] && args+=(--requester "$CLICKUP_REQUESTER")
  [[ -n "$body" ]] && args+=(--data "$body")
  # Default to the absolute path (cron/systemd PATH may omit /usr/local/bin) at
  # the point of use — never assign MUSO_BIN globally, since a sourcing script
  # (e.g. close-merged-tickets.sh) reads MUSO_BIN for its own Trino binary.
  local out
  out=$("${MUSO_BIN:-/usr/local/bin/muso}" "${args[@]}" --json) || return $?
  # Peel the {data:…} envelope back to the raw ClickUp body the curl path
  # returned. No -e: a successful muso call returns 0 and we defer a degenerate
  # body to the caller's shape-check, exactly as the curl path does.
  jq -c '.data' <<<"$out"
}
