#!/usr/bin/env bash
# tests/fm-deepseek-gateway.test.sh - the second local Anthropic-compatible
# gateway (bin/fm-deepseek-gateway.sh and bin/fm-deepseek-gateway.py) against a
# fake upstream and a fixture route picker.
#
# What this pins, all of it through the real executable:
#   - the gateway advertises the model id Claude Code discovers, which is the
#     whole reason a second gateway exists rather than a direct base URL;
#   - the upstream provider, model, and base URL are re-resolved PER REQUEST
#     from the route picker, so a lane that crosses DeepSeek's peak window is
#     re-routed without a restart, and each route is called on its OWN path -
#     the fake upstream serves the two providers' real path shapes and refuses
#     anything else, so the peak route is proven, not assumed;
#   - the provider key never reaches the request log or any error;
#   - an unauthenticated caller is refused, so an open loopback port cannot
#     spend the captain's provider cash, and the per-request rows are readable
#     only behind that token;
#   - a route whose key cannot be read fails closed with a clear status rather
#     than sending an unauthenticated upstream call;
#   - the shared account-pool port is refused outright;
#   - a start that never took the port is reported as a failure, not a success;
#   - an upstream that dies mid-relay is recorded as a request row;
#   - streaming is relayed frame by frame and its usage is accounted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATEWAY="$ROOT/bin/fm-deepseek-gateway.sh"
TMP_ROOT=$(fm_test_tmproot fm-deepseek-gateway-tests)
FAKE_KEY='sk-fake-provider-key-do-not-log'
UPSTREAM_PIDS=()

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

write_upstream() {  # <path>
  cat > "$1" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The real providers hang their Anthropic surface off different path prefixes
# (OpenRouter /api/v1/messages, Fireworks /inference/v1/messages), so this fake
# records the exact path and Host it was called on and refuses anything else.
# A gateway that built the URL wrong for one route fails here instead of
# silently proving only the route the fixture happened to start on.
SERVED = ("/api/v1/messages", "/inference/v1/messages")

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        return

    def do_POST(self):
        with open(log_path, "a") as handle:
            handle.write("POST %s host=%s\n" % (self.path, self.headers.get("host", "")))
        size = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(size) or b"{}")
        if self.path not in SERVED:
            data = json.dumps({"type": "error", "error": {
                "type": "not_found_error",
                "message": "no such upstream path: %s" % self.path,
            }}).encode()
            self.send_response(404)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if body.get("metadata", {}).get("fm_test") == "truncate":
            # Promise more than we send, then hang up: the gateway is already
            # past its own error paths and fails inside the relay.
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", "4096")
            self.end_headers()
            self.wfile.write(b'{"partial":')
            self.wfile.flush()
            self.close_connection = True
            return
        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()

            def chunk(text):
                data = text.encode()
                self.wfile.write(b"%x\r\n" % len(data))
                self.wfile.write(data)
                self.wfile.write(b"\r\n")
                self.wfile.flush()

            chunk('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":40,"cache_read_input_tokens":1600,"output_tokens":0}}}\n\n')
            chunk('event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":9}}\n\n')
            chunk('event: message_stop\ndata: {"type":"message_stop"}\n\n')
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        payload = {
            "id": "msg_fake",
            "type": "message",
            "role": "assistant",
            "model": body.get("model"),
            "content": [{"type": "text", "text": "fake upstream reply"}],
            "usage": {"input_tokens": 200, "output_tokens": 20, "cache_read_input_tokens": 800},
        }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()

port = int(sys.argv[1])
log_path = sys.argv[2]
print("listening %d" % port, flush=True)
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
}

start_upstream() {  # <case-dir> -> sets UPSTREAM_PORT
  local dir=$1 port
  port=$(free_port)
  write_upstream "$dir/upstream.py"
  : > "$dir/upstream-requests.log"
  python3 "$dir/upstream.py" "$port" "$dir/upstream-requests.log" > "$dir/upstream.log" 2>&1 &
  UPSTREAM_PIDS+=("$!")
  local deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q 'listening' "$dir/upstream.log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'listening' "$dir/upstream.log" 2>/dev/null || fail "the fake upstream did not start"
  UPSTREAM_PORT=$port
  UPSTREAM_LOG="$dir/upstream-requests.log"
}

write_pick() {  # <path> <base-url> <api-key-cmd>
  cat > "$1" <<PY
import json, sys
json.dump({
    "kind": "deepseek",
    "slot": "offpeak",
    "provider": "openrouter-named",
    "model": "deepseek/deepseek-v4.1-flash",
    "base_url": "$2",
    "api_key_cmd": "$3",
    "list_in": 0.15,
    "list_out": 0.60,
}, sys.stdout)
PY
}

cleanup_gateways() {
  local pid
  for pid in "${UPSTREAM_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_gateways; fm_test_cleanup' EXIT
trap 'cleanup_gateways; fm_test_cleanup; exit 130' INT
trap 'cleanup_gateways; fm_test_cleanup; exit 143' TERM

gateway_case() {  # <name> -> sets CASE HOME_DIR STATE GATEWAY_PORT PICK TOKEN
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/state" "$CASE/home/data"
  HOME_DIR="$CASE/home"
  STATE="$HOME_DIR/state"
  GATEWAY_PORT=$(free_port)
  start_upstream "$CASE"
  PICK="$CASE/pick.py"
  # The off-peak route's shape: OpenRouter serves /api/v1/messages.
  write_pick "$PICK" "http://127.0.0.1:$UPSTREAM_PORT/api/v1" "printf $FAKE_KEY"
}

gw() {  # <args...>; sets OUT RC
  local rc=0
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$GATEWAY" "$@" 2>&1) || rc=$?
  RC=$rc
}

gateway_token() {  # <state-dir>
  tr -d ' \n' < "$1/fm-deepseek-gateway.token"
}

api() {  # <method> <path> [body]
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -sS --max-time 10 -X "$method" -H "content-type: application/json" \
      -H "x-api-key: $(gateway_token "$STATE")" -d "$body" "http://127.0.0.1:$GATEWAY_PORT$path"
  else
    curl -sS --max-time 10 -X "$method" -H "x-api-key: $(gateway_token "$STATE")" \
      "http://127.0.0.1:$GATEWAY_PORT$path"
  fi
}

start_gateway() {
  gw start --port "$GATEWAY_PORT" --pick "$PICK"
  expect_code 0 "$RC" "the gateway must start"
  assert_contains "$OUT" "started: pid" "a start must report the pid it launched"
  TOKEN=$(gateway_token "$STATE")
  [ -n "$TOKEN" ] || fail "the gateway must create a local token file"
  local mode
  mode=$(stat -c '%a' "$STATE/fm-deepseek-gateway.token" 2>/dev/null || stat -f '%Lp' "$STATE/fm-deepseek-gateway.token")
  [ "$mode" = "600" ] || fail "the local token file must be mode 0600, got $mode"
}

stop_gateway() {
  gw stop || true
}

test_health_reports_route_and_never_the_key() {
  gateway_case health
  start_gateway
  local body
  body=$(curl -sS --max-time 10 "http://127.0.0.1:$GATEWAY_PORT/healthz")
  assert_contains "$body" '"status": "ok"' "health must report ok when the route and key resolve"
  assert_contains "$body" '"provider": "openrouter-named"' "health must report the routed provider"
  assert_contains "$body" '"slot": "offpeak"' "health must report the route slot"
  assert_contains "$body" '"key_present": true' "health must confirm the key resolved"
  assert_not_contains "$body" "$FAKE_KEY" "health must never echo the provider key"
  gw health --port "$GATEWAY_PORT"
  expect_code 0 "$RC" "the health verb must exit 0 for a healthy gateway"
  assert_contains "$OUT" "status=ok" "the health verb must summarise the route"
  stop_gateway
  pass "fm-deepseek-gateway: health reports the live route and never the provider key"
}

test_request_rows_stay_behind_the_token() {
  gateway_case request-rows
  start_gateway
  api POST /v1/messages '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}]}' > /dev/null
  local body
  body=$(curl -sS --max-time 10 "http://127.0.0.1:$GATEWAY_PORT/healthz")
  # A recorded row carries the provider's own error body, which routinely
  # quotes the part of the lane's request it objected to; /healthz is served
  # to anyone on the loopback port, so no row may appear in it.
  assert_not_contains "$body" 'upstream_status' "the unauthenticated health payload must carry no request detail"
  assert_not_contains "$body" 'last_request' "the unauthenticated health payload must carry no request row"
  assert_contains "$body" '"requests_served": 1' "the unauthenticated payload must still carry the counters"
  # The rows live in the durable request log, which is what `logs` reads.
  local logged
  logged=$(cat "$STATE/fm-deepseek-gateway.log")
  assert_contains "$logged" '"upstream_status": 200' "the request log must carry the row and its detail"
  gw logs --lines 20
  expect_code 0 "$RC" "the logs verb must read the rows back"
  assert_contains "$OUT" '"upstream_status": 200' "the logs verb must surface the recorded row"
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -H "x-api-key: $TOKEN" \
    "http://127.0.0.1:$GATEWAY_PORT/stats")
  expect_code 404 "$code" "there must be no statistics surface beside healthz"
  # /healthz is the only unauthenticated surface; nothing else answers to one.
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GATEWAY_PORT/")
  expect_code 401 "$code" "the root path must not answer an unauthenticated caller"
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GATEWAY_PORT/health")
  expect_code 401 "$code" "there must be no second unauthenticated spelling of healthz"
  # The same rows are written to the request log, so it carries the same mode
  # as the token beside it rather than whatever the umask happened to be.
  local mode
  mode=$(stat -c '%a' "$STATE/fm-deepseek-gateway.log" 2>/dev/null || stat -f '%Lp' "$STATE/fm-deepseek-gateway.log")
  [ "$mode" = "600" ] || fail "the request log must be mode 0600, got $mode"
  mode=$(stat -c '%a' "$STATE/fm-deepseek-gateway.out" 2>/dev/null || stat -f '%Lp' "$STATE/fm-deepseek-gateway.out")
  [ "$mode" = "600" ] || fail "the gateway process output must be mode 0600, got $mode"
  stop_gateway
  pass "fm-deepseek-gateway: request rows are readable only behind the local token"
}

test_a_refused_request_leaves_the_connection_usable() {
  gateway_case keep-alive
  start_gateway
  # HTTP/1.1 keep-alive: a 401 that never reads the POST body would leave that
  # body in the socket to be parsed as the next request line. A lane holding a
  # stale token must see a plain repeated auth failure, not alternating 401s
  # and malformed responses.
  cat > "$CASE/keepalive.py" <<'PY'
import http.client, json, sys

port, token = int(sys.argv[1]), sys.argv[2]
body = json.dumps({"model": "deepseek-v4.1-flash", "max_tokens": 16,
                   "messages": [{"role": "user", "content": "hi"}]})
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
statuses = []
for headers in ({"content-type": "application/json"},
                {"content-type": "application/json", "x-api-key": "wrong-token"},
                {"content-type": "application/json", "x-api-key": token}):
    conn.request("POST", "/v1/messages", body=body, headers=headers)
    response = conn.getresponse()
    payload = response.read().decode("utf-8", "replace")
    statuses.append(response.status)
print(" ".join(str(s) for s in statuses))
print("last=%s" % ("reply" if "fake upstream reply" in payload else payload[:120]))
PY
  local out
  out=$(python3 "$CASE/keepalive.py" "$GATEWAY_PORT" "$TOKEN" 2>&1) \
    || fail "three POSTs on one connection must all complete: $out"
  assert_contains "$out" "401 401 200" "a refused POST must not desynchronise the connection it arrived on"
  assert_contains "$out" "last=reply" "the authorized request on that same connection must be served normally"
  stop_gateway
  pass "fm-deepseek-gateway: a refused request leaves its keep-alive connection usable"
}

test_mid_relay_upstream_failure_is_recorded() {
  gateway_case mid-relay-failure
  start_gateway
  # The upstream dies after the gateway has committed to relaying it. There is
  # no error response left to send, so the request log row IS the report - the
  # documented promise that this gateway reports its errors instead of hiding
  # them, which matters most for the provider the docs call capacity-variable.
  curl -sS --max-time 20 -o /dev/null -X POST -H "x-api-key: $TOKEN" \
    -H 'content-type: application/json' \
    -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"metadata":{"fm_test":"truncate"}}' \
    "http://127.0.0.1:$GATEWAY_PORT/v1/messages" 2>/dev/null || true
  local logged
  logged=$(cat "$STATE/fm-deepseek-gateway.log")
  assert_contains "$logged" '"outcome": "relay-failed"' "a mid-relay upstream failure must be recorded as a request row"
  assert_contains "$logged" '"provider": "openrouter-named"' "the recorded failure must name the route it was on"
  assert_contains "$logged" '"error"' "the recorded failure must carry the reason"
  assert_not_contains "$logged" "$FAKE_KEY" "the recorded failure must never contain the provider key"
  local body
  body=$(curl -sS --max-time 10 "http://127.0.0.1:$GATEWAY_PORT/healthz")
  assert_contains "$body" '"errors": 1' "the failure must move the error counter the operator reads"
  stop_gateway
  pass "fm-deepseek-gateway: an upstream that dies mid-relay is recorded, not swallowed"
}

test_start_refuses_a_port_held_by_another_instance() {
  gateway_case foreign-listener
  # The holder is DEGRADED, not healthy: its route cannot resolve a key, which
  # is the supported state the fail-closed test pins. That is precisely when a
  # "does this port answer healthily" guard looks away, so it is the state a
  # second start has to be refused in.
  write_pick "$PICK" "http://127.0.0.1:$UPSTREAM_PORT/api/v1" "exit 3"
  gw start --port "$GATEWAY_PORT" --pick "$PICK"
  expect_code 0 "$RC" "a degraded gateway must still start and hold its port"
  local body
  body=$(curl -sS --max-time 10 "http://127.0.0.1:$GATEWAY_PORT/healthz")
  assert_contains "$body" '"status": "degraded"' "the holder must be degraded, or this case proves nothing"

  # A second home starting on that port never binds. It must not report a start
  # it never made, and must leave no pid file naming a process that died.
  local other="$CASE/other" rc=0 out
  mkdir -p "$other/state"
  out=$(FM_HOME="$other" FM_STATE_OVERRIDE="$other/state" bash "$GATEWAY" \
    start --port "$GATEWAY_PORT" --pick "$PICK" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a start that never took the port must not exit 0: $out"
  assert_not_contains "$out" "started: pid" "a start that never bound must not report a pid as started"
  assert_absent "$other/state/fm-deepseek-gateway.pid" "a start that never took the port must record no pid"
  stop_gateway
  pass "fm-deepseek-gateway: a start onto a port another instance holds is refused, not reported as started"
}

test_models_advertise_the_discoverable_id() {
  gateway_case models
  start_gateway
  local body
  body=$(api GET /v1/models)
  assert_contains "$body" '"id": "deepseek-v4.1-flash"' "the gateway must advertise the model Claude Code discovers"
  assert_contains "$body" '"id": "deepseek-v4.1-flash[1m]"' "the 1M row must be advertised too"
  assert_contains "$body" '"has_more": false' "the model list must be a complete page"
  # The fetch is logged, so an operator can prove a client read this gateway's
  # list rather than inferring it from a model that happened to be accepted.
  assert_grep '"outcome": "models"' "$STATE/fm-deepseek-gateway.log" \
    "the gateway must log the model-list fetch"
  assert_contains "$body" '"display_name"' "the list rows must carry a display name"
  # GET /v1/models is the one advertised-model surface; there is no per-id path.
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -H "x-api-key: $TOKEN" \
    "http://127.0.0.1:$GATEWAY_PORT/v1/models/deepseek-v4.1-flash")
  expect_code 404 "$code" "there must be no second read path for an advertised model"
  stop_gateway
  pass "fm-deepseek-gateway: the advertised model list carries the id Claude Code discovers"
}

test_messages_are_proxied_and_logged_without_the_key() {
  gateway_case messages
  start_gateway
  local body
  body=$(api POST /v1/messages '{"model":"deepseek-v4.1-flash[1m]","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}')
  assert_contains "$body" 'fake upstream reply' "the upstream reply must reach the caller"
  assert_grep "POST /api/v1/messages host=127.0.0.1:$UPSTREAM_PORT" "$UPSTREAM_LOG" \
    "the OpenRouter-shaped route must be called on its own /api/v1/messages path and host"
  assert_contains "$body" '"model": "deepseek/deepseek-v4.1-flash"' "the upstream must receive the provider's own model id"
  body=$(cat "$STATE/fm-deepseek-gateway.log")
  assert_contains "$body" '"provider": "openrouter-named"' "the request log must record the provider"
  assert_contains "$body" '"outcome": "ok"' "the request log must record the outcome"
  assert_contains "$body" '"cost_usd"' "the request log must record an estimated cost"
  assert_not_contains "$body" "$FAKE_KEY" "the request log must never contain the provider key"
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d '{"model":"deepseek-v4.1-flash","messages":[]}' "http://127.0.0.1:$GATEWAY_PORT/v1/messages")
  expect_code 401 "$code" "an unauthenticated caller must be refused"
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H "x-api-key: $TOKEN" \
    -H 'content-type: application/json' -d '{"model":"gpt-9","messages":[]}' \
    "http://127.0.0.1:$GATEWAY_PORT/v1/messages")
  expect_code 404 "$code" "a model this gateway does not serve must 404"
  # Only the two advertised spellings are served; a lookalike id is not ours to
  # forward upstream, whatever it claims about its context window.
  local requested
  for requested in 'deepseek-v4.1-flash[200k]' 'deepseek-v4.1-flash[' 'deepseek-v4.1-flash[1m][1m]'; do
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H "x-api-key: $TOKEN" \
      -H 'content-type: application/json' \
      -d "$(printf '{"model":"%s","messages":[]}' "$(printf '%s' "$requested" | sed 's/\\/\\\\/g')")" \
      "http://127.0.0.1:$GATEWAY_PORT/v1/messages")
    expect_code 404 "$code" "an id this gateway never advertised must 404: $requested"
  done
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H "x-api-key: $TOKEN" \
    "http://127.0.0.1:$GATEWAY_PORT/v1/not-an-endpoint")
  expect_code 404 "$code" "an unknown endpoint must 404"
  body=$(api POST /v1/messages/count_tokens '{"messages":[{"role":"user","content":"12345678"}]}')
  assert_contains "$body" '"input_tokens"' "count_tokens must answer with a token count"
  assert_not_contains "$body" '"input_tokens": 0' "the estimate must be a positive count"
  stop_gateway
  pass "fm-deepseek-gateway: messages are proxied under the provider model id and logged without the key"
}

test_streaming_is_relayed_and_accounted() {
  gateway_case streaming
  start_gateway
  local body
  body=$(api POST /v1/messages '{"model":"deepseek-v4.1-flash","stream":true,"messages":[{"role":"user","content":"hi"}]}')
  assert_contains "$body" 'event: message_start' "the stream must be relayed frame by frame"
  assert_contains "$body" 'event: message_stop' "the stream must run to its end"
  local logged
  logged=$(cat "$STATE/fm-deepseek-gateway.log")
  assert_contains "$logged" '"stream": true' "a streamed request must be logged as streamed"
  # Usage arrives split across events; the logged totals must cover both.
  assert_contains "$logged" '"input_tokens": 40' "the stream's input usage must be accounted"
  assert_contains "$logged" '"output_tokens": 9' "the stream's output usage must be accounted"
  stop_gateway
  pass "fm-deepseek-gateway: a streamed request is relayed and its split usage is accounted"
}

test_route_is_resolved_per_request() {
  gateway_case per-request-route
  start_gateway
  # Rewrite the route picker between two calls: the second call must take the
  # new provider without a restart, which is what keeps a long lane on the
  # right side of DeepSeek's UTC peak. The two routes carry the two providers'
  # real path shapes, so this also proves the peak route's URL - the one every
  # opted-in lane takes for seven hours each weekday - and not just the
  # off-peak one the fixture starts on.
  local body
  body=$(api POST /v1/messages '{"model":"deepseek-v4.1-flash","messages":[]}')
  assert_contains "$body" 'fake upstream reply' "the off-peak route must reach a served upstream path"
  # The peak route: Fireworks serves /inference/v1/messages.
  write_pick "$PICK" "http://127.0.0.1:$UPSTREAM_PORT/inference/v1" "printf $FAKE_KEY"
  python3 - "$PICK" <<'PY'
import sys
path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
text = text.replace('"provider": "openrouter-named"', '"provider": "fireworks-us"')
text = text.replace('"slot": "offpeak"', '"slot": "peak"')
text = text.replace('"model": "deepseek/deepseek-v4.1-flash"', '"model": "accounts/fireworks/models/deepseek-v4p1-flash"')
text = text.replace('"list_in": 0.15', '"list_in": 0.22').replace('"list_out": 0.60', '"list_out": 0.66')
with open(path, "w") as handle:
    handle.write(text)
PY
  body=$(api POST /v1/messages '{"model":"deepseek-v4.1-flash","messages":[]}')
  assert_contains "$body" 'fake upstream reply' "the peak route must reach a served upstream path too"
  assert_contains "$body" '"model": "accounts/fireworks/models/deepseek-v4p1-flash"' \
    "the peak route must forward the provider's own model id"
  local logged
  logged=$(cat "$STATE/fm-deepseek-gateway.log")
  assert_contains "$logged" '"provider": "openrouter-named"' "the first call must use the first route"
  assert_contains "$logged" '"provider": "fireworks-us"' "the second call must use the route as it stands now, not at startup"
  assert_contains "$logged" '"slot": "peak"' "the re-resolved slot must be recorded"
  assert_grep "POST /api/v1/messages host=127.0.0.1:$UPSTREAM_PORT" "$UPSTREAM_LOG" \
    "the off-peak route must be called on the OpenRouter path"
  assert_grep "POST /inference/v1/messages host=127.0.0.1:$UPSTREAM_PORT" "$UPSTREAM_LOG" \
    "the peak route must be called on the Fireworks path, not the off-peak one"
  stop_gateway
  pass "fm-deepseek-gateway: the upstream route is re-resolved per request and each provider's own URL is used"
}

test_unreadable_key_fails_closed() {
  gateway_case unreadable-key
  write_pick "$PICK" "http://127.0.0.1:$UPSTREAM_PORT/api/v1" "exit 3"
  gw start --port "$GATEWAY_PORT" --pick "$PICK"
  # A gateway that cannot read the key still binds and reports degraded: it
  # must never call upstream unauthenticated.
  expect_code 0 "$RC" "the gateway must still start so its state is visible"
  local body
  body=$(curl -sS --max-time 10 "http://127.0.0.1:$GATEWAY_PORT/healthz")
  assert_contains "$body" '"status": "degraded"' "a missing key must report degraded"
  assert_contains "$body" '"key_present": false' "a missing key must be reported as absent"
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H "x-api-key: $(gateway_token "$STATE")" \
    -H 'content-type: application/json' -d '{"model":"deepseek-v4.1-flash","messages":[]}' \
    "http://127.0.0.1:$GATEWAY_PORT/v1/messages")
  expect_code 503 "$code" "a request with no resolvable key must fail closed"
  [ ! -s "$UPSTREAM_LOG" ] \
    || fail "no upstream call may be made when the key is unavailable, got: $(cat "$UPSTREAM_LOG")"
  gw health --port "$GATEWAY_PORT"
  expect_code 1 "$RC" "the health verb must exit nonzero for a degraded gateway"
  stop_gateway
  pass "fm-deepseek-gateway: an unreadable provider key fails closed instead of calling upstream"
}

test_shared_pool_port_is_refused() {
  gateway_case shared-port
  gw start --port 8080 --pick "$PICK"
  expect_code 2 "$RC" "the shared account-pool port must be refused"
  assert_contains "$OUT" "shared Claude account-pool gateway" "the refusal must name why"
  gw start --port 80 --pick "$PICK"
  expect_code 2 "$RC" "a privileged port must be refused"
  pass "fm-deepseek-gateway: the shared account-pool port and privileged ports are refused"
}

test_status_and_stop_track_the_lifecycle() {
  gateway_case lifecycle
  gw status --port "$GATEWAY_PORT"
  expect_code 0 "$RC" "status must be readable before a start"
  assert_contains "$OUT" "process: not running" "status must report a stopped gateway"
  start_gateway
  gw status --port "$GATEWAY_PORT"
  expect_code 0 "$RC" "status must exit 0 for a running gateway"
  assert_contains "$OUT" "process: running" "status must report the running process"
  assert_contains "$OUT" "status=ok" "status must include the live health summary"
  stop_gateway
  assert_contains "$OUT" "stopped: pid" "stop must report the pid it stopped"
  gw health --port "$GATEWAY_PORT"
  expect_code 1 "$RC" "health must fail once the gateway is stopped"
  pass "fm-deepseek-gateway: status and stop track the real process lifecycle"
}

test_foreground_start_owns_the_output_file_mode() {
  gateway_case foreground-out
  # A supervisor that opens this path itself - launchd's StandardOutPath, the
  # doc's recipe - opens it before the script runs, so the file has to already
  # exist at 0600. The supervised command line IS this foreground start.
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$GATEWAY" \
    start --foreground --port "$GATEWAY_PORT" --pick "$PICK" > "$CASE/foreground.log" 2>&1 &
  local pid=$!
  local deadline=$(( $(date +%s) + 15 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/healthz" 2>/dev/null && break
    sleep 0.2
  done
  curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/healthz" \
    || { kill "$pid" 2>/dev/null; fail "the foreground gateway must answer: $(cat "$CASE/foreground.log")"; }
  assert_present "$STATE/fm-deepseek-gateway.out" "a foreground start must pre-create the process output file"
  local mode
  mode=$(stat -c '%a' "$STATE/fm-deepseek-gateway.out" 2>/dev/null || stat -f '%Lp' "$STATE/fm-deepseek-gateway.out")
  [ "$mode" = "600" ] || fail "the process output file must be mode 0600 before a supervisor opens it, got $mode"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-deepseek-gateway: the supervised foreground start pre-creates its output file at 0600"
}

test_env_prints_the_lane_exports() {
  gateway_case env
  gw env --port "$GATEWAY_PORT"
  expect_code 0 "$RC" "env must print the lane exports"
  assert_contains "$OUT" "export ANTHROPIC_BASE_URL=http://127.0.0.1:$GATEWAY_PORT" "env must point a lane at this gateway"
  assert_contains "$OUT" "export ANTHROPIC_AUTH_TOKEN=" "env must carry the local token"
  assert_contains "$OUT" "$(cat "$STATE/fm-deepseek-gateway.token")" "env must print the token the gateway expects"
  assert_contains "$OUT" "/model $(bash "$GATEWAY" model)" "env must name the model a lane selects"
  pass "fm-deepseek-gateway: env prints the exports a lane needs"
}

test_health_reports_route_and_never_the_key
test_request_rows_stay_behind_the_token
test_a_refused_request_leaves_the_connection_usable
test_mid_relay_upstream_failure_is_recorded
test_start_refuses_a_port_held_by_another_instance
test_models_advertise_the_discoverable_id
test_messages_are_proxied_and_logged_without_the_key
test_streaming_is_relayed_and_accounted
test_route_is_resolved_per_request
test_unreadable_key_fails_closed
test_shared_pool_port_is_refused
test_status_and_stop_track_the_lifecycle
test_foreground_start_owns_the_output_file_mode
test_env_prints_the_lane_exports
