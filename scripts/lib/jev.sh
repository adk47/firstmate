#!/bin/bash
# ──────────────────────────────────────────────────────────────
# jev.sh — one-shot client for TypeSafe's System One ("Jev") typed-judgment
# model. Sends {state, model, questions} and prints the `answers` object on
# stdout. Humans go on stderr only — stdout is the machine channel (same
# contract as release-watch.sh --dry-run).
#
# Provider (JEV_PROVIDER, default "openrouter"):
#   openrouter  Jev via OpenRouter's decisions endpoint (alpha), 32k context.
#               URL default: https://openrouter.ai/api/alpha/decisions
#               Model default: ~typesafe/jev-latest
#               Key: OPENROUTER_API_KEY
#   typesafe    Jev direct from TypeSafe's own API, 64k context.
#               URL default: https://api.typesafe.ai/v1/systemone
#               Model default: jev-latest
#               Key: TYPESAFE_API_KEY
# An explicitly set JEV_API_URL, JEV_MODEL, or --model still wins over the
# provider default.
#
# Kill switch: JEV_DISABLED_FILE (default /etc/hydra/jev.disabled) — when
# that path exists, every call exits 6 with no network request. See rc 6
# below.
#
# Usage:
#   jev.sh --surface <name> --item-id <id> --state-file <path.json> \
#     --questions-file <path.json> [--actual <string or JSON object keyed by question id>] [--model jev-latest] \
#     [--timeout-ms 1500] [--max-state-bytes 200000] [--no-shadow]
#
# Exit codes:
#   0  ok, answers object on stdout
#   2  curl failure / timeout / non-2xx HTTP response
#   3  200 response with no .answers object
#   4  state file larger than --max-state-bytes (refused, never truncated)
#   5  missing/invalid input (bad JSON, missing flag, missing API key,
#      invalid JEV_PROVIDER, invalid --surface / --item-id)
#   6  disabled via the kill switch: ${JEV_DISABLED_FILE:-/etc/hydra/jev.disabled}
#      exists. Checked before any network call. Still shadow-logged (unless
#      --no-shadow) with rc 6, so a disabled window shows up in the report as
#      "disabled", not as indistinguishable silence.
#
# Every call — success or failure, including rc 4/5 pre-request failures once
# --surface/--item-id are parsed — appends one JSON line to the shadow log
# at ${JEV_SHADOW_DIR:-/var/lib/hydra-jev/shadow}/<surface>.jsonl unless
# --no-shadow is given. The shadow line never carries the API key or the
# questions text — only a sha256 of the questions. The state SHA is always
# recorded, and (default on; JEV_SHADOW_STORE_STATE=0 to disable) the raw
# state object is stored next to it too, so a misclassification can be
# replayed against Jev directly. Shadow files carry customer text, so they
# are created/kept at mode 0600 — a looser-permission file left from before
# this behavior is tightened on the next write. Every append is taken under
# an flock on the sibling "<file>.lock" (the same lock format-digest.sh and
# jev-shadow-log.ts's flock-subprocess append use, and the one
# jev-shadow-prune.sh's rewrite holds exclusively) so an append can never
# land on a discarded pre-rewrite inode or interleave with another writer.
# A lock that can't be taken within 5s skips the row (WARN on stderr) rather
# than writing unlocked. Shadow-logging failures are best-effort: a WARN on
# stderr, never a failed call (same posture as slack_notify — the log is not
# allowed to make the primary action less reliable).
# ──────────────────────────────────────────────────────────────
set -euo pipefail

: "${JEV_ENV_FILE:=/etc/hydra/jev.env}"
: "${JEV_SHADOW_DIR:=/var/lib/hydra-jev/shadow}"
: "${JEV_SHADOW_STORE_STATE:=1}"

_jev_die() {
  # $1=rc $2=message
  echo "jev.sh: $2" >&2
  exit "$1"
}

_jev_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _jev_sha256 <file>: portable sha256 (macOS has no sha256sum by default).
_jev_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

jev_main() {
  local surface="" item_id="" state_file="" questions_file="" actual=""
  # Env defaults (documented in docs/plans/jev-adoption.md); CLI flags win.
  # model/api_url start empty here and are filled from the provider's
  # default below, unless JEV_MODEL/JEV_API_URL/--model already set them.
  local model="${JEV_MODEL:-}" api_url="${JEV_API_URL:-}"
  local timeout_ms="${JEV_TIMEOUT_MS:-1500}" max_state_bytes="200000"
  local provider="${JEV_PROVIDER:-openrouter}"
  local no_shadow=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --surface) surface="$2"; shift 2 ;;
      --item-id) item_id="$2"; shift 2 ;;
      --state-file) state_file="$2"; shift 2 ;;
      --questions-file) questions_file="$2"; shift 2 ;;
      --actual) actual="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --timeout-ms) timeout_ms="$2"; shift 2 ;;
      --max-state-bytes) max_state_bytes="$2"; shift 2 ;;
      --no-shadow) no_shadow=1; shift ;;
      *) _jev_die 5 "unknown argument: $1" ;;
    esac
  done

  [ -n "$surface" ] || _jev_die 5 "--surface is required"
  [ -n "$item_id" ] || _jev_die 5 "--item-id is required"
  [ -n "$state_file" ] || _jev_die 5 "--state-file is required"
  [ -n "$questions_file" ] || _jev_die 5 "--questions-file is required"

  # --surface becomes a path component ($JEV_SHADOW_DIR/<surface>.jsonl) in
  # both this script and jev-shadow-report.sh's --surface filter, so it must
  # never contain a slash, whitespace, or a leading dot (path traversal /
  # escaping the shadow dir, e.g. "../escape"). Reject before any shadow row
  # is written under it -- a row logged under an invalid surface is the bug.
  case "$surface" in
    [A-Za-z0-9]*) ;;
    *) _jev_die 5 "--surface has an invalid shape: $surface" ;;
  esac
  case "$surface" in
    *[!A-Za-z0-9._-]*) _jev_die 5 "--surface has an invalid shape: $surface" ;;
  esac
  # --item-id is embedded via jq --arg (never a path), so only newlines and
  # other control characters are forbidden.
  case "$item_id" in
    *[[:cntrl:]]*) _jev_die 5 "--item-id contains control characters" ;;
  esac
  # From here on surface/item_id are known, so every failure — including the
  # pre-request ones (unreadable path, bad JSON, oversize state, missing key)
  # — is recorded in the shadow log with answers=null. A caller that keeps
  # hitting the size cap, lost its key, or points at a stale path must show
  # up in the report as rc≠0 rows, not as silence. Hashes are null until the
  # inputs have been read. state_json stays "null" until the state file has
  # been read AND validated as JSON (below) — a pre-validation failure (bad
  # flags, missing key, unreadable path) never has real state content to log.
  local state_sha="" questions_sha="" state_json="null"

  _jev_fail() {
    # $1=rc $2=message — shadow-log the failure (unless --no-shadow), then die.
    if [ "$no_shadow" -eq 0 ]; then
      _jev_shadow_log "$surface" "$item_id" "$state_sha" "$questions_sha" \
        "$model" "null" "null" "0" "$actual" "$1" "null" "$provider" "$state_json"
    fi
    _jev_die "$1" "$2"
  }

  # Provider selects the URL/model/key-var defaults; an explicitly set
  # JEV_API_URL, JEV_MODEL, or --model still wins over the provider default.
  local provider_url_default="" provider_model_default="" key_var=""
  case "$provider" in
    openrouter)
      provider_url_default="https://openrouter.ai/api/alpha/decisions"
      provider_model_default="~typesafe/jev-latest"
      key_var="OPENROUTER_API_KEY"
      ;;
    typesafe)
      provider_url_default="https://api.typesafe.ai/v1/systemone"
      provider_model_default="jev-latest"
      key_var="TYPESAFE_API_KEY"
      ;;
    *)
      _jev_fail 5 "JEV_PROVIDER must be 'openrouter' or 'typesafe' (got: $provider)"
      ;;
  esac
  [ -n "$api_url" ] || api_url="$provider_url_default"
  [ -n "$model" ] || model="$provider_model_default"

  # Kill switch: refuse immediately, before any network call, if the disabled
  # marker file exists. Checked here (after surface/item-id/provider/model are
  # known, so the shadow row carries a real model) but before any file I/O or
  # network work below.
  local disabled_file="${JEV_DISABLED_FILE:-/etc/hydra/jev.disabled}"
  if [ -e "$disabled_file" ]; then
    if [ "$no_shadow" -eq 0 ]; then
      _jev_shadow_log "$surface" "$item_id" "$state_sha" "$questions_sha" \
        "$model" "null" "null" "0" "$actual" "6" "null" "$provider" "$state_json"
    fi
    _jev_die 6 "disabled via $disabled_file — no call made"
  fi

  # Numeric knobs must be decimal integers >= 1 before they reach arithmetic
  # or `-gt`: a typo like JEV_TIMEOUT_MS=abc would otherwise die with no
  # shadow row, and --max-state-bytes abc would make the cap check false and
  # let the request through.
  case "$timeout_ms" in
    ''|*[!0-9]*|0) _jev_fail 5 "--timeout-ms / JEV_TIMEOUT_MS must be a positive integer (got: $timeout_ms)" ;;
  esac
  case "$max_state_bytes" in
    ''|*[!0-9]*|0) _jev_fail 5 "--max-state-bytes must be a positive integer (got: $max_state_bytes)" ;;
  esac

  [ -r "$state_file" ] || _jev_fail 5 "state file not readable: $state_file"
  [ -r "$questions_file" ] || _jev_fail 5 "questions file not readable: $questions_file"
  state_sha="$(_jev_sha256 "$state_file")"
  questions_sha="$(_jev_sha256 "$questions_file")"

  jq -e . "$state_file" >/dev/null 2>&1 || _jev_fail 5 "state file is not valid JSON: $state_file"
  jq -e . "$questions_file" >/dev/null 2>&1 || _jev_fail 5 "questions file is not valid JSON: $questions_file"

  if [ "$JEV_SHADOW_STORE_STATE" != "0" ]; then
    state_json="$(jq -c . "$state_file")"
  fi

  local api_key="${!key_var:-}"
  if [ -z "$api_key" ] && [ -r "$JEV_ENV_FILE" ]; then
    api_key="$(grep -m1 "^${key_var}=" "$JEV_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  fi
  [ -n "$api_key" ] || _jev_fail 5 "$key_var is not set and not found in $JEV_ENV_FILE"

  local state_bytes
  state_bytes=$(wc -c < "$state_file" | tr -d '[:space:]')
  if [ "$state_bytes" -gt "$max_state_bytes" ]; then
    _jev_fail 4 "state file ($state_bytes bytes) exceeds --max-state-bytes ($max_state_bytes)"
  fi

  # curl accepts fractional seconds for --max-time, so convert ms -> s.sss
  # exactly (no float arithmetic in bash: split into whole seconds + the
  # zero-padded remainder in milliseconds). timeout_ms is already validated
  # above as a positive decimal integer.
  local timeout_s
  timeout_s=$(printf '%d.%03d' $((timeout_ms / 1000)) $((timeout_ms % 1000)))
  # A connect timeout only matters when it is below the overall budget, so
  # it is min(2s, budget). Compare on timeout_ms (exact integer) rather than
  # the formatted timeout_s string -- 2000ms is exactly curl's 2s default.
  local connect_timeout_s="2"
  [ "$timeout_ms" -lt 2000 ] && connect_timeout_s="$timeout_s"

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/jev.XXXXXX")"
  # Expand $work_dir NOW (double-quoted trap) rather than at trigger time:
  # work_dir is `local` to this function, so a single-quoted trap referencing
  # it by name would hit an unbound-variable error under `set -u` once the
  # function returns and the local goes out of scope.
  # shellcheck disable=SC2064 # intentional: expand $work_dir now, not at trigger time (see comment above)
  trap "rm -rf '$work_dir'" EXIT

  local body_file="$work_dir/body.json"
  local resp_file="$work_dir/resp.json"
  local hdr_file="$work_dir/auth.hdr"

  jq -n --slurpfile state "$state_file" --slurpfile questions "$questions_file" \
    --arg model "$model" \
    '{state: $state[0], model: $model, questions: $questions[0]}' > "$body_file"

  # The bearer token goes through a header FILE (mktemp -d is mode 700), never
  # on curl's argv, so it is not readable in `ps` for the length of the call.
  ( umask 077; printf 'Authorization: Bearer %s\n' "$api_key" > "$hdr_file" )

  local start_ms end_ms latency_ms http_code rc curl_rc
  start_ms=$(($(date +%s%N) / 1000000))

  set +e
  http_code=$(curl -sS \
    --max-time "$timeout_s" \
    --connect-timeout "$connect_timeout_s" \
    -H @"$hdr_file" \
    -H "Content-Type: application/json" \
    -X POST \
    --data @"$body_file" \
    -o "$resp_file" \
    -w '%{http_code}' \
    "$api_url")
  curl_rc=$?
  set -e

  end_ms=$(($(date +%s%N) / 1000000))
  latency_ms=$((end_ms - start_ms))

  local answers="null" resp_model="$model" usage="null" http_code_json="null"
  rc=0

  if [ "$curl_rc" -ne 0 ]; then
    rc=2
  elif [ "${http_code:0:1}" != "2" ]; then
    rc=2
    http_code_json="$http_code"
  else
    http_code_json="$http_code"
    if ! jq -e '.answers | type == "object"' "$resp_file" >/dev/null 2>&1; then
      rc=3
    else
      answers="$(jq -c '.answers' "$resp_file")"
      resp_model="$(jq -r '.model // $m' --arg m "$model" "$resp_file")"
      usage="$(jq -c '.usage // null' "$resp_file")"
    fi
  fi

  if [ "$no_shadow" -eq 0 ]; then
    _jev_shadow_log "$surface" "$item_id" "$state_sha" "$questions_sha" \
      "$resp_model" "$answers" "$usage" "$latency_ms" "$actual" "$rc" "$http_code_json" "$provider" "$state_json"
  fi

  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2) echo "jev.sh: request failed (curl_rc=$curl_rc http=${http_code:-none})" >&2 ;;
      3) echo "jev.sh: response had no .answers object" >&2 ;;
    esac
    exit "$rc"
  fi

  printf '%s\n' "$answers"
}

# _jev_shadow_log surface item_id state_sha questions_sha model answers usage \
#   latency_ms actual rc http provider state_json
_jev_shadow_log() {
  local surface="$1" item_id="$2" state_sha="$3" questions_sha="$4" model="$5"
  local answers="$6" usage="$7" latency_ms="$8" actual="$9" rc="${10}" http="${11}" provider="${12}"
  local state_json="${13:-null}"

  if ! mkdir -p "$JEV_SHADOW_DIR" 2>/dev/null; then
    echo "jev.sh: WARN could not create shadow dir $JEV_SHADOW_DIR" >&2
    return 0
  fi

  local line_file
  line_file="$(mktemp "${TMPDIR:-/tmp}/jev-shadow.XXXXXX")" || {
    echo "jev.sh: WARN could not create shadow line tmpfile" >&2
    return 0
  }

  # --actual is either one string (applied to every question) or a JSON object
  # keyed by question id ({"router_intent":"credit_verification",...}) — a call
  # carries several questions, and the report compares per question.
  local actual_json="null"
  if [ -n "$actual" ]; then
    actual_json="$(printf '%s' "$actual" | jq -c 'if type == "object" then . else error("not object") end' 2>/dev/null)" \
      || actual_json="$(jq -n --arg a "$actual" '$a')"
  fi

  jq -nc \
    --arg ts "$(_jev_now_iso)" \
    --arg surface "$surface" \
    --arg item_id "$item_id" \
    --arg state_sha256 "$state_sha" \
    --arg questions_sha256 "$questions_sha" \
    --arg model "$model" \
    --argjson answers "$answers" \
    --argjson usage "$usage" \
    --argjson latency_ms "$latency_ms" \
    --argjson actual "$actual_json" \
    --argjson rc "$rc" \
    --argjson http "$http" \
    --arg provider "$provider" \
    --argjson state "$state_json" \
    '{ts:$ts, surface:$surface, item_id:$item_id,
      state_sha256:(if $state_sha256 == "" then null else $state_sha256 end),
      questions_sha256:(if $questions_sha256 == "" then null else $questions_sha256 end),
      state:$state,
      model:$model, answers:$answers,
      usage:$usage, latency_ms:$latency_ms, actual:$actual, rc:$rc, http:$http,
      provider:$provider}' \
    > "$line_file" 2>/dev/null

  if [ ! -s "$line_file" ]; then
    echo "jev.sh: WARN could not build shadow log line" >&2
    rm -f "$line_file"
    return 0
  fi

  local target="$JEV_SHADOW_DIR/${surface}.jsonl"
  local lock_file="${target}.lock"
  # Every writer to $JEV_SHADOW_DIR/*.jsonl (this function, format-digest.sh's
  # _jev_email_triage_classify_shadow, and jev-shadow-log.ts via the flock
  # binary) and the prune rewrite (jev-shadow-prune.sh) share this exact
  # "<file>.lock" lock file, so append vs. append and append vs. rewrite can
  # never interleave or land on a discarded inode. Create-at-0600 and the
  # 0600-tighten of a pre-existing looser file both happen INSIDE the lock —
  # doing either outside it would let two writers race the existence check.
  # Fail-soft on both axes: a lock timeout skips this row (WARN, never
  # blocks the caller) rather than writing unlocked, and any other failure
  # here is a WARN, never a failed call. scripts/tests/jev.bats exercises
  # this by holding $lock_file itself with a real flock before invoking
  # jev.sh -- no test hook needed, the lock is real.
  if ! command -v flock >/dev/null 2>&1; then
    echo "jev.sh: WARN flock not found -- skipping shadow row for $target" >&2
    rm -f "$line_file"
    return 0
  fi
  if ! ( flock -w 5 9 || exit 1
         if [ ! -e "$target" ]; then
           ( umask 077; : > "$target" ) 2>/dev/null || true
         fi
         chmod 0600 "$target" 2>/dev/null || true
         cat "$line_file" >> "$target"
       ) 9>>"$lock_file" 2>/dev/null; then
    echo "jev.sh: WARN could not lock $lock_file within 5s -- skipping shadow row for $target" >&2
  fi
  rm -f "$line_file"
  return 0
}

jev_main "$@"
