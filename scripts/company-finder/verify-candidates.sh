#!/usr/bin/env bash
# verify-candidates.sh — deterministic website liveness gate for the CMO
# Company Finder. Sits between dedupe and the ledger write:
#   dedupe-candidates.sh → verify-candidates.sh → ledger.sh suggest → post
#
# WHY: "the company is still active" was previously model recall — 6 dead
# companies shipped in the 2026-06-10 batch. This makes liveness a cheap,
# mechanical HTTP check. LinkedIn is deliberately NOT curl-checked here
# (LinkedIn bot-walls anonymous requests with 999/redirects); the skill
# requires the agent to web_fetch each survivor's LinkedIn page and attach
# dated evidence instead.
#
# INPUT  (stdin): JSON array of candidates (typically dedupe's .new).
#   Extra keys are preserved.
# OUTPUT (stdout): JSON
#   { "alive":   [ <candidate + {verification:"alive",   verified_at, http_code}> ],
#     "blocked": [ <candidate + {verification:"blocked", verified_at, http_code}> ],
#     "dead":    [ <candidate + {verification:"dead",    reason, http_code}> ],
#     "stats":   {checked, alive, blocked, dead} }
#
# CLASSIFICATION (final code after retry + http:// fallback):
#   2xx/3xx          → alive
#   401/403/429/5xx  → blocked   (site responds but bot-walls or errors at us;
#                                 KEPT, flagged for human eyes — 5xx is retried
#                                 once first. Never terminal: dead[] gets
#                                 ledgered as a permanent reject downstream, and
#                                 a transient 500/502/503 — or a bot-wall served
#                                 as 503 — must not be suppressed forever)
#   000/404/410/4xx  → dead      (dropped; reason connect_failed / http_<code>)
#
# Domains are checked CONCURRENTLY (default 8 workers) — a few dead/black-holed
# domains at ~60s each would otherwise eat the cron's 600s budget.
#
# NETWORK-SUSPECT GUARD: if >=3 candidates were checked and ALL failed to
#   connect, this is almost certainly local egress trouble, not 100% dead
#   companies — exit 2 with VERIFY_NETWORK_SUSPECT so the caller marks the
#   batch PARTIAL/UNSAFE instead of nuking it.
#
# Env overrides (mainly for tests):
#   CURL_BIN         default curl
#   VERIFY_SLEEP     seconds between retry attempts (default 2; 0 in tests)
#   VERIFY_PARALLEL  concurrent checks (default 8)
#
# Exit codes: 0 ok (dead entries are a normal outcome), 1 input error,
#             2 network suspect.
set -euo pipefail

export CURL_BIN="${CURL_BIN:-curl}"
export VERIFY_SLEEP="${VERIFY_SLEEP:-2}"
export UA="Mozilla/5.0 (compatible; MusoCompanyFinder/1.0)"
VERIFY_PARALLEL="${VERIFY_PARALLEL:-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

CANDS="$(read_candidates_stdin)"

http_code_for() { # <url> → echoes the http code, or 000 on curl failure
  local code
  code=$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' -L --max-redirs 5 \
          --connect-timeout 8 --max-time 20 -A "$UA" "$1" 2>/dev/null) || code="000"
  [[ -z "$code" ]] && code="000"
  echo "$code"
}

check_domain() { # <normalized-domain> → echoes final http code
  local nd="$1" code
  code=$(http_code_for "https://$nd/")
  if [[ "$code" == "000" || "$code" == 5?? ]]; then
    sleep "$VERIFY_SLEEP"
    code=$(http_code_for "https://$nd/")
  fi
  if [[ "$code" == "000" ]]; then
    code=$(http_code_for "http://$nd/")
  fi
  echo "$code"
}
export -f http_code_for check_domain

# ── Normalize once, check concurrently, classify in one pass ────────────────
NORMED=$(jqn -c \
  'include "normalize"; to_entries | map({i: .key, c: .value, nd: (.value.domain | norm_domain)})' \
  <<<"$CANDS")

codes_file="$(mktemp)"
trap 'rm -f "$codes_file"' EXIT
jq -r '.[] | select(.nd != "") | "\(.i)\t\(.nd)"' <<<"$NORMED" \
  | xargs -r -P "$VERIFY_PARALLEL" -L 1 bash -c 'printf "%s\t%s\n" "$1" "$(check_domain "$2")"' _ \
  >"$codes_file"

CODES=$(jq -Rcn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' <"$codes_file")

TODAY="$(date -u +%F)"
RESULT=$(jq -n --argjson normed "$NORMED" --argjson codes "$CODES" --arg today "$TODAY" '
  [ $normed[]
    | (if .nd == "" then "" else ($codes[(.i | tostring)] // "000") end) as $code
    | (if .nd == ""                         then {v: "dead",    reason: "empty_domain",          code: "000"}
       elif ($code | test("^[23]"))          then {v: "alive",   reason: "",                      code: $code}
       elif ($code == "401" or $code == "403" or $code == "429"
             or ($code | test("^5"))) then {v: "blocked", reason: "", code: $code}
       elif $code == "000"                   then {v: "dead",    reason: "connect_failed",        code: $code}
       else                                       {v: "dead",    reason: ("http_" + $code),       code: $code}
       end) as $r
    | .c + {verification: $r.v, http_code: $r.code}
      + (if $r.v == "dead" then {reason: $r.reason} else {verified_at: $today} end)
  ] as $results
  | ($results | map(select(.verification == "alive")))   as $alive
  | ($results | map(select(.verification == "blocked"))) as $blocked
  | ($results | map(select(.verification == "dead")))    as $dead
  | {alive: $alive, blocked: $blocked, dead: $dead,
     stats: {checked: ($results | length), alive: ($alive | length),
             blocked: ($blocked | length), dead: ($dead | length)}}')

n=$(jq '.stats.checked' <<<"$RESULT")
conn_failed=$(jq '[.dead[] | select(.reason == "connect_failed")] | length' <<<"$RESULT")
if [[ "$n" -ge 3 && "$conn_failed" -eq "$n" ]]; then
  echo "VERIFY_NETWORK_SUSPECT: all $n candidates failed to connect — check egress before trusting this." >&2
  exit 2
fi

jq . <<<"$RESULT"
