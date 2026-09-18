#!/usr/bin/env bash
# fm-deepseek-gateway.sh - lifecycle for the SECOND local Anthropic-compatible
# gateway: the one that serves DeepSeek V4.1 Flash to opt-in Claude Code lanes.
#
# WHY A SECOND GATEWAY: 127.0.0.1:8080 is the shared Claude account-pool
# gateway (better-ccflare) that every lane in the fleet already points at, so a
# change there has fleet-wide blast radius. This gateway is a separate process
# on its own port serving only the lanes explicitly pointed at it, which is the
# shape the fleet's DeepSeek offload investigation proved end to end.
# This script refuses port 8080 by construction.
#
# WHAT IT SERVES: the Anthropic Messages API for DeepSeek V4.1 Flash, under the
# exact model id Claude Code discovers from GET /v1/models. Claude Code 2.x
# gates every model id through its compiled catalog, so a lane cannot be
# pointed straight at OpenRouter or Fireworks; it accepts a model only when a
# gateway advertises it. The upstream provider, model id, base URL, and key are
# resolved PER REQUEST through the captain's ~/.config/llm-route/pick.py, so a
# long-running lane is on OpenRouter off DeepSeek's UTC peak and on Fireworks
# at peak (~/.config/llm-route/README.md owns that clock). The provider key is
# read through the api_key_cmd pick.py itself names, so no secret location is
# hardcoded here, and no secret is ever printed, logged, or committed. The
# server itself is bin/fm-deepseek-gateway.py; its header owns the wire
# contract and docs/deepseek-lane-gateway.md owns the mechanism, the proof
# sequence, and the rollout order.
#
# LOCAL TOKEN: every request except /healthz needs the local bearer token in
# $STATE/fm-deepseek-gateway.token (created mode 0600 on first use). It gates
# this port, not the providers: it is what stops any other local process from
# spending the captain's provider cash through an open loopback port. `env`
# prints the exports a lane needs, including that token.
#
# Usage:
#   fm-deepseek-gateway.sh start [--port N] [--pick PATH] [--foreground]
#   fm-deepseek-gateway.sh stop [--force]
#   fm-deepseek-gateway.sh status
#   fm-deepseek-gateway.sh health [--json]
#   fm-deepseek-gateway.sh model
#   fm-deepseek-gateway.sh env [--port N]
#   fm-deepseek-gateway.sh logs [--lines N]
#
# SUPERVISION IS THE HOME'S, NOT THIS SCRIPT'S: `start` runs the gateway under
# whatever supervisor the home already uses. docs/deepseek-lane-gateway.md
# carries a launchctl recipe for a macOS home that wants the gateway back after
# a reboot; it points at `start --foreground` and carries no secret.
#
# Defaults: port 8799 (the port the offload investigation proved), host
# 127.0.0.1, route picker ~/.config/llm-route/pick.py, route kind deepseek.
# Runtime records live in this home's state directory:
#   fm-deepseek-gateway.pid    pid of an instance this script started
#   fm-deepseek-gateway.out    stdout/stderr of the server process
#   fm-deepseek-gateway.log    one JSON line per request (rotated at 5 MB)
#   fm-deepseek-gateway.token  the local bearer token, mode 0600
#
# Exit codes: 0 success; 1 the requested state could not be reached; 2 a usage
# or safety refusal (a bad port, the shared pool port, a missing tool).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

GATEWAY_PY="$SCRIPT_DIR/fm-deepseek-gateway.py"
DEFAULT_PORT="${FM_DEEPSEEK_GATEWAY_PORT:-8799}"
SHARED_POOL_PORT=8080
DEFAULT_PICK="${FM_DEEPSEEK_GATEWAY_PICK:-$HOME/.config/llm-route/pick.py}"
DEFAULT_KIND="${FM_DEEPSEEK_GATEWAY_KIND:-deepseek}"
START_TIMEOUT="${FM_DEEPSEEK_GATEWAY_START_TIMEOUT:-20}"

PID_FILE="$STATE/fm-deepseek-gateway.pid"
OUT_FILE="$STATE/fm-deepseek-gateway.out"
LOG_FILE="$STATE/fm-deepseek-gateway.log"
TOKEN_FILE="$STATE/fm-deepseek-gateway.token"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {  # <message> [code]
  printf 'fm-deepseek-gateway: %s\n' "$1" >&2
  exit "${2:-1}"
}

refuse() {  # <message>
  printf 'fm-deepseek-gateway: %s\n' "$1" >&2
  exit 2
}

require_python() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to run the gateway"
  [ -f "$GATEWAY_PY" ] || fail "gateway server is missing: $GATEWAY_PY"
}

require_curl() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to probe the gateway"
}

validate_port() {  # <port>
  local port=$1
  case "$port" in
    ''|*[!0-9]*) refuse "port must be a number: ${port:-<empty>}" ;;
  esac
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || refuse "port must be between 1024 and 65535: $port"
  [ "$port" -ne "$SHARED_POOL_PORT" ] \
    || refuse "port $SHARED_POOL_PORT is the shared Claude account-pool gateway; this gateway must not use it"
}

base_url() { printf 'http://127.0.0.1:%s' "$1"; }

# --- runtime records ---------------------------------------------------------

pid_is_gateway() {  # <pid>
  local pid=$1 command
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -o command= -p "$pid" 2>/dev/null || true)
  case "$command" in
    *fm-deepseek-gateway.py*) return 0 ;;
  esac
  return 1
}

running_pid() {  # prints the live gateway pid, or nothing
  local pid
  [ -f "$PID_FILE" ] || return 0
  pid=$(tr -d ' \t\r\n' < "$PID_FILE" 2>/dev/null || true)
  if pid_is_gateway "$pid"; then
    printf '%s' "$pid"
    return 0
  fi
  return 0
}

ensure_state_dir() {
  [ -d "$STATE" ] || fail "state directory is missing: $STATE"
}

ensure_token() {
  local token=''
  ensure_state_dir
  if [ ! -f "$TOKEN_FILE" ]; then
    (umask 077; : > "$TOKEN_FILE") || fail "cannot create $TOKEN_FILE"
  fi
  [ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] || fail "gateway token file is unsafe: $TOKEN_FILE"
  token=$(tr -d ' \t\r\n' < "$TOKEN_FILE" 2>/dev/null || true)
  if [ -z "$token" ]; then
    token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
    [ -n "$token" ] || fail "cannot generate a gateway token"
    (umask 077; printf '%s\n' "$token" > "$TOKEN_FILE") || fail "cannot write $TOKEN_FILE"
  fi
  chmod 0600 "$TOKEN_FILE" 2>/dev/null || true
  printf '%s' "$token"
}

# The process output can carry the same provider diagnostics the request log
# does, so it is created 0600 like the log and the token beside it. A
# supervisor that opens this path itself - launchd's StandardOutPath does -
# opens it before the script runs, so the file has to already exist with that
# mode or the supervisor creates it at its own umask instead.
ensure_out_file() {
  [ -e "$OUT_FILE" ] || (umask 077; : > "$OUT_FILE") || fail "cannot create $OUT_FILE"
}

health_body() {  # <port>
  require_curl
  curl -sS --max-time 5 "$(base_url "$1")/healthz" 2>/dev/null || true
}

# health_body_authed: the same one surface, read WITH the local token, which is
# the only way its payload carries the route picker's own message. `status`
# uses it; `health` deliberately does not, so the unauthenticated view an
# operator sees is the one any other local process would get.
health_body_authed() {  # <port>
  local token
  require_curl
  token=$(ensure_token 2>/dev/null || true)
  [ -n "$token" ] || { health_body "$1"; return 0; }
  # Through a config file on stdin, never as an argument: argv is world-readable
  # through ps, and this token is the whole reason the token FILE is 0600.
  printf 'header = "x-api-key: %s"\n' "$token" \
    | curl -sS --max-time 5 -K - "$(base_url "$1")/healthz" 2>/dev/null || true
}

health_ok() {  # <port>
  local body
  body=$(health_body "$1")
  [ -n "$body" ] || return 1
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
sys.exit(0 if body.get("status") == "ok" else 1)
'
}

# health_answers: 0 when the port answers /healthz with a parseable payload.
# Deliberately weaker than health_ok: a gateway whose route is temporarily
# unresolvable is still up, still inspectable, and must not be reported as a
# failed start - `health` is the gate for "can it actually serve".
health_answers() {  # <port>
  local body
  body=$(health_body "$1")
  [ -n "$body" ] || return 1
  printf '%s' "$body" | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null
}

# health_pid: the pid the instance answering this port reports as its own, or
# nothing when the probe could not be read. `start` compares it with the
# process it just launched, because "the port answers" and "the port answers
# US" are different facts - but an unreadable probe is no evidence either way.
health_pid() {  # <port>
  health_body "$1" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
pid = body.get("pid")
if isinstance(pid, int):
    print(pid)
'
}

health_summary() {  # reads the health payload on stdin
  python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except ValueError:
    print("unreadable health payload")
    sys.exit(0)
print("status=%s route_ok=%s provider=%s slot=%s upstream_model=%s key_present=%s requests=%s errors=%s"
      % (body.get("status"), body.get("route_ok"), body.get("provider"), body.get("slot"),
         body.get("upstream_model"), body.get("key_present"),
         body.get("requests_served"), body.get("errors")))
# Only an authenticated read carries this; the unauthenticated view stops at
# the boolean above.
if body.get("route_error"):
    print("route_error=%s" % body["route_error"])
'
}

# probe_answering_pid: read the answering pid, retrying while it disagrees with
# the pid we launched, and print it ONLY when a different live pid is proven.
# An unreadable or empty read prints nothing, which the caller reads as "no
# evidence" rather than as proof of a foreign listener - a start must never
# SIGTERM the gateway it just launched on the strength of one flaky probe.
probe_answering_pid() {  # <port> <our-pid>
  local port=$1 ours=$2 answering='' attempt=0
  while [ "$attempt" -lt 5 ]; do
    answering=$(health_pid "$port")
    if [ -n "$answering" ] && [ "$answering" = "$ours" ]; then
      return 0
    fi
    if [ -n "$answering" ] && ! pid_is_gateway "$ours"; then
      printf '%s' "$answering"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.3
  done
  if [ -n "$answering" ] && [ "$answering" != "$ours" ] && kill -0 "$answering" 2>/dev/null; then
    printf '%s' "$answering"
  fi
  return 0
}

wait_for_answer() {  # <port> <seconds>
  local port=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    health_answers "$port" && return 0
    sleep 0.3
  done
  return 1
}

# report_start: the one start-time report, so a degraded route is always
# visible without being fatal.
report_start() {  # <port> <lead>
  local port=$1 lead=$2 body
  body=$(health_body_authed "$port")
  printf '%s %s model %s\n' "$lead" "$(base_url "$port")" "$(cmd_model)"
  if [ -n "$body" ]; then
    printf 'health: '
    printf '%s' "$body" | health_summary
  fi
  health_ok "$port" || printf 'warning: the gateway is up but its route is not ready; run health for the reason\n' >&2
  return 0
}

# --- verbs -------------------------------------------------------------------

cmd_start() {
  local port=$DEFAULT_PORT pick=$DEFAULT_PICK foreground=0 pid answering=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; port=${1:-} ;;
      --pick) shift; pick=${1:-} ;;
      --foreground) foreground=1 ;;
      --kind) shift; DEFAULT_KIND=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_port "$port"
  require_python
  ensure_state_dir
  if [ "$foreground" = 1 ]; then
    # launchd runs this shape: no pidfile, no nohup, the supervisor owns life.
    ensure_out_file
    exec python3 "$GATEWAY_PY" --port "$port" --pick "$pick" --kind "$DEFAULT_KIND" --state "$STATE" --log "$LOG_FILE"
  fi
  pid=$(running_pid)
  if [ -n "$pid" ]; then
    printf 'already running: pid %s url %s\n' "$pid" "$(base_url "$port")"
    return 0
  fi
  if health_answers "$port"; then
    refuse "something already answers $(base_url "$port")/healthz but this home has no pid recorded for it; stop it before starting"
  fi
  ensure_token >/dev/null
  ensure_out_file
  nohup python3 "$GATEWAY_PY" --port "$port" --pick "$pick" --kind "$DEFAULT_KIND" \
    --state "$STATE" --log "$LOG_FILE" >> "$OUT_FILE" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  if wait_for_answer "$port" "$START_TIMEOUT"; then
    # Every /healthz hit makes the server run the route picker and the key
    # command, so one probe can time out on a loaded machine even though the
    # gateway is fine. Retry, and treat an unreadable probe as no evidence:
    # only a DIFFERENT live pid proves someone else holds the port.
    # Liveness of what we launched is the authoritative half; the answering pid
    # only adds "and nobody else holds it". An inconclusive probe is no proof of
    # a foreign listener, and equally no proof that our own process survived.
    answering=$(probe_answering_pid "$port" "$pid")
    if pid_is_gateway "$pid" && { [ -z "$answering" ] || [ "$answering" = "$pid" ]; }; then
      printf 'started: pid %s\n' "$pid"
      report_start "$port" "ready:"
      return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    rm -f -- "$PID_FILE"
    if [ -n "$answering" ] && [ "$answering" != "$pid" ]; then
      printf 'fm-deepseek-gateway: %s is held by pid %s, not the process this start launched (pid %s), which never took the port; last output:\n' \
        "$(base_url "$port")" "$answering" "$pid" >&2
    else
      printf 'fm-deepseek-gateway: the process this start launched (pid %s) is not running; last output:\n' "$pid" >&2
    fi
    tail -n 20 "$OUT_FILE" >&2 2>/dev/null || true
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null || true
  rm -f -- "$PID_FILE"
  printf 'fm-deepseek-gateway: gateway did not become healthy within %ss; last output:\n' "$START_TIMEOUT" >&2
  tail -n 20 "$OUT_FILE" >&2 2>/dev/null || true
  return 1
}

cmd_stop() {
  local force=0 pid
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  pid=$(running_pid)
  if [ -z "$pid" ]; then
    rm -f -- "$PID_FILE"
    printf 'stopped: no gateway process recorded\n'
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  local deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pid_is_gateway "$pid" || break
    sleep 0.3
  done
  if pid_is_gateway "$pid"; then
    if [ "$force" = 1 ]; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
    if pid_is_gateway "$pid"; then
      fail "gateway pid $pid did not stop; retry with --force only if you intend to kill it"
    fi
  fi
  rm -f -- "$PID_FILE"
  printf 'stopped: pid %s\n' "$pid"
}

cmd_status() {
  local port=$DEFAULT_PORT pid body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; port=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_port "$port"
  pid=$(running_pid)
  if [ -n "$pid" ]; then
    printf 'process: running pid %s\n' "$pid"
  else
    printf 'process: not running\n'
  fi
  printf 'port: %s\n' "$port"
  body=$(health_body_authed "$port")
  if [ -n "$body" ]; then
    printf 'health: '
    printf '%s' "$body" | health_summary
  else
    printf 'health: no answer on %s\n' "$(base_url "$port")"
  fi
}

cmd_health() {
  local port=$DEFAULT_PORT json=0 body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; port=${1:-} ;;
      --json) json=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_port "$port"
  body=$(health_body "$port")
  [ -n "$body" ] || fail "gateway is not answering $(base_url "$port")/healthz"
  if [ "$json" = 1 ]; then
    printf '%s\n' "$body"
  else
    printf 'health: '
    printf '%s' "$body" | health_summary
  fi
  health_ok "$port" || return 1
  return 0
}

cmd_model() {
  require_python
  python3 "$GATEWAY_PY" --print-model
}

cmd_env() {
  local port=$DEFAULT_PORT token
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; port=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_port "$port"
  token=$(ensure_token)
  cat <<ENV
# Source or export these in the lane's Claude Code environment. The base URL and
# token are what point the lane at this gateway; the model id is what
# \`/model\` accepts once Claude Code has discovered it.
export ANTHROPIC_BASE_URL=$(base_url "$port")
export ANTHROPIC_AUTH_TOKEN=$token
# Claude Code caches a gateway's model list per base URL where it keeps one.
# After changing the advertised models, clear any cached copy so a lane cannot
# keep discovering the old list:
#   rm -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/gateway-models.json"
# Then select the model in the lane, adding the 1M marker for the full window:
#   /model $(cmd_model)
#   /model $(cmd_model)[1m]
ENV
}

cmd_logs() {
  local lines=40
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lines) shift; lines=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$lines" in ''|*[!0-9]*) refuse "--lines must be a number" ;; esac
  [ -f "$LOG_FILE" ] || fail "no request log yet: $LOG_FILE"
  tail -n "$lines" "$LOG_FILE"
}

main() {
  local verb=${1:-}
  [ -n "$verb" ] || { usage >&2; exit 2; }
  shift
  case "$verb" in
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    health) cmd_health "$@" ;;
    model) cmd_model "$@" ;;
    env) cmd_env "$@" ;;
    logs) cmd_logs "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
