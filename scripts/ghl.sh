#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ghl.sh — the canonical GoHighLevel (LeadConnector) API client.
#
#   ghl.sh [--account b2b|winback] [--all] [--data-file FILE] METHOD PATH [key=value ...]
#
# Born from MUS-20329 (Oct 2026): Cloudflare in front of
# services.leadconnectorhq.com bans Python urllib's default User-Agent
# (HTTP 403, body "error code: 1010"), and every fresh CMO session hand-rolled
# a GHL call, hit it, and stopped. Same key, same URL: curl -> 200, urllib with
# no UA -> 403, urllib with a real UA -> 200. So the UA is the fix, and this is
# the one place that sets it. (scripts/lib/muso_outreach/ghl_client.py is a
# deliberate NotImplementedError stub the sender worker relies on: leave it.)
#
# Key: read from the PROCESS env only — GHL_API_KEY (--account b2b, default) or
# GHL_WINBACK_API_KEY (--account winback). Those live in the gateway env
# (/etc/openclaw/main.env), which gateway_exec children inherit; they are NOT in
# ~/.zshrc, so an SSH shell has neither. Unset -> exit 3.
#
# The bearer reaches curl on STDIN (`-H @-`), never on argv: `ps` on this box is
# readable by every agent. Same mechanism and rationale as
# scripts/lib/ensure-mercury-token.sh. It is never in any log or error line.
#
# key=value args go into the query string, URL-encoded. --data-file sends that
# file as a JSON body. 2xx: body on stdout, exit 0. Failure: ONE stderr line
#   ghl: HTTP <code> <class>: <next action>: <first 300 bytes of body>
# and the exit code:
#   0  2xx
#   1  any other non-2xx
#   2  transport failure, curl/jq missing, or bad usage
#   3  key unset in this process
#   4  --all hit the page cap (50 pages)
#   10 401: key rejected — DevOps re-sets <VAR> in /etc/openclaw/main.env
#   11 403 with 1010 / browser_signature_banned: Cloudflare client-signature
#      block. NOT an account or key problem.
#   12 any other 403
#
# --all (GET only): limit=100 unless given, loops page=1,2,..., concatenates the
# response's top-level array, stops on a short page. POST search caps at 100
# (workspaces/cmo/skills/muso-outreach-engine/references/config.md), so use GET
# page=N. Prints {"<key>":[...],"pages":N}.
#
# Env knobs (mainly for tests): GHL_BASE_URL, CURL_BIN, JQ_BIN.
#
# set -uo pipefail (NOT -e): every failure path here returns a designed code.
# ──────────────────────────────────────────────────────────────
# jq programs use $vars inside single quotes on purpose.
# shellcheck disable=SC2016
set -uo pipefail
# `bash -x ghl.sh` would trace the key into the terminal/log. Nothing here needs it.
set +x

GHL_BASE_URL="${GHL_BASE_URL:-https://services.leadconnectorhq.com}"
CURL_BIN="${CURL_BIN:-curl}"
if [ -z "${JQ_BIN:-}" ]; then
  # node-8's jq-1.7 is in a compat dir that is on the gateway PATH but not on
  # cron's; fall back to it by absolute path.
  JQ_BIN="$(command -v jq 2>/dev/null || true)"
  [ -n "$JQ_BIN" ] || JQ_BIN=/usr/local/libexec/muso-devops-envset-compat/jq
fi

UA="muso-hydra-ghl/1.0 (+ops@muso.ai)"
PAGE_CAP=50

die() { echo "ghl: $*" >&2; exit 2; }

account=b2b; all=0; data_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --account) [ $# -ge 2 ] || die "--account needs b2b|winback"; account="$2"; shift 2 ;;
    --all) all=1; shift ;;
    --data-file) [ $# -ge 2 ] || die "--data-file needs a file"; data_file="$2"; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

case "$account" in
  b2b) VAR=GHL_API_KEY ;;
  winback) VAR=GHL_WINBACK_API_KEY ;;
  *) die "unknown account: $account (expected b2b or winback)" ;;
esac

[ $# -ge 2 ] || die "usage: ghl.sh [--account b2b|winback] [--all] [--data-file FILE] METHOD PATH [key=value ...]"
method="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; path="$2"; shift 2
case "$method" in GET|POST|PUT|PATCH|DELETE) ;; *) die "unsupported method: $1" ;; esac
case "$path" in /*) ;; *) die "PATH must start with /: $path" ;; esac

if [ "$all" -eq 1 ] && [ "$method" != GET ]; then
  die "--all is GET only: POST search caps at 100, use GET page=N"
fi
if [ -n "$data_file" ] && [ ! -r "$data_file" ]; then
  die "--data-file not readable: $data_file"
fi

# ${!VAR} reads the named variable from the process env; empty counts as unset.
key="${!VAR:-}"
if [ -z "$key" ]; then
  echo "ghl: $VAR is unset in this process. It lives in the gateway env (/etc/openclaw/main.env), not ~/.zshrc: run through gateway_exec, not an SSH shell." >&2
  exit 3
fi

command -v "$CURL_BIN" >/dev/null 2>&1 || die "curl not found (CURL_BIN=$CURL_BIN)"
command -v "$JQ_BIN" >/dev/null 2>&1 || die "jq not found (JQ_BIN=$JQ_BIN)"

# Validate and URL-encode the key=value args once.
pairs=(); user_limit=""
for kv in "$@"; do
  case "$kv" in
    *=*) ;;
    *) die "bad argument (expected key=value): $kv" ;;
  esac
  [ "${kv%%=*}" = limit ] && user_limit="${kv#*=}"
  if [ "$all" -eq 1 ] && [ "${kv%%=*}" = page ]; then die "--all manages page itself; drop page="; fi
  pairs+=("$kv")
done

enc() { "$JQ_BIN" -rn --arg v "$1" '$v|@uri'; }

# build_url <extra key=value ...> — base + path + ?query
build_url() {
  local q="" kv
  for kv in "${pairs[@]+"${pairs[@]}"}" "$@"; do
    q+="${q:+&}$(enc "${kv%%=*}")=$(enc "${kv#*=}")"
  done
  printf '%s%s%s' "$GHL_BASE_URL" "$path" "${q:+?$q}"
}

body_file="$(mktemp)"
acc_file="$(mktemp)"   # --all accumulator: a file, because one argv string tops out near 128 KiB
trap 'rm -f "$body_file" "$acc_file" "$acc_file.new"' EXIT

# fail <code> — print the one error line for the response in $body_file; exit.
fail() {
  local code="$1" class action rc excerpt
  case "$code" in
    401) class="key rejected"; action="page DevOps to re-set ${VAR} in /etc/openclaw/main.env"; rc=10 ;;
    403) if grep -qE '1010|browser_signature_banned' "$body_file" 2>/dev/null; then
           class="Cloudflare client-signature block"; action="not an account or key problem; page DevOps with this line"; rc=11
         else
           class="forbidden"; action="the key lacks access to this location or scope"; rc=12
         fi ;;
    *) class="unexpected status"; action="read the body"; rc=1 ;;
  esac
  excerpt="$(head -c 300 "$body_file" | tr '\r\n' '  ')"
  excerpt="${excerpt//"$key"/[redacted]}"
  echo "ghl: HTTP ${code} ${class}: ${action}: ${excerpt}" >&2
  exit "$rc"
}

# request <url> — leaves the body in $body_file, exits on any failure.
request() {
  local url="$1" code rc
  local args=(-sS -m 30 --proto '=https' --noproxy '*' -o "$body_file" -w '%{http_code}'
    -X "$method" -H "User-Agent: ${UA}" -H "Version: 2021-07-28" -H "Accept: application/json" -H @-)
  if [ -n "$data_file" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "@${data_file}")
  fi
  code="$(printf 'Authorization: Bearer %s' "$key" | "$CURL_BIN" "${args[@]}" "$url" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ghl: transport failure (curl rc=${rc}): check node-8 egress to ${GHL_BASE_URL}" >&2
    exit 2
  fi
  case "$code" in
    2??) ;;
    *) fail "$code" ;;
  esac
}

if [ "$all" -eq 0 ]; then
  request "$(build_url)"
  cat "$body_file"
  exit 0
fi

limit="${user_limit:-100}"
[[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || die "limit must be a positive integer: $limit"

printf '[]' > "$acc_file"; arrkey=""; page=1
while :; do
  if [ "$page" -gt "$PAGE_CAP" ]; then
    echo "ghl: page cap: still full after ${PAGE_CAP} pages of ${limit}; narrow the query" >&2
    exit 4
  fi
  if [ -n "$user_limit" ]; then request "$(build_url "page=${page}")"
  else request "$(build_url "limit=${limit}" "page=${page}")"; fi
  if [ -z "$arrkey" ]; then
    arrkey="$("$JQ_BIN" -r 'if type=="object" then (to_entries | map(select(.value|type=="array")) | .[0].key // empty) else empty end' "$body_file" 2>/dev/null)"
    if [ -z "$arrkey" ]; then
      echo "ghl: --all: no top-level array in the HTTP ${page} response body" >&2
      exit 1
    fi
  fi
  n="$("$JQ_BIN" --arg k "$arrkey" '.[$k] | length' "$body_file" 2>/dev/null)" \
    || { echo "ghl: --all: page ${page} is not the expected JSON" >&2; exit 1; }
  "$JQ_BIN" -c --arg k "$arrkey" --slurpfile acc "$acc_file" '$acc[0] + .[$k]' "$body_file" > "$acc_file.new" \
    && mv "$acc_file.new" "$acc_file" \
    || { echo "ghl: --all: could not merge page ${page}" >&2; exit 1; }
  if [ "$n" -lt "$limit" ]; then break; fi
  page=$((page + 1))
done

"$JQ_BIN" -c --arg k "$arrkey" --argjson p "$page" '{($k):., pages:$p}' "$acc_file"
