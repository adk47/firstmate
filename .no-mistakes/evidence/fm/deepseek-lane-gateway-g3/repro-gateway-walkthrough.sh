#!/usr/bin/env bash
# End-to-end operator demo for the DeepSeek V4.1 Flash lane gateway.
# Runs the real bin/fm-deepseek-gateway.sh + bin/fm-lane-model-switch.sh
# against a fixture route picker and a fake provider upstream that serves
# OpenRouter's real path shape (/api/v1/messages).
set -u

ROOT=${ROOT:?}
WORK=${WORK:?}
rm -rf "$WORK"
mkdir -p "$WORK/home/state" "$WORK/home/data"
HOME_DIR="$WORK/home"
STATE="$HOME_DIR/state"
FAKE_KEY='sk-fake-provider-key-do-not-log'

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

say() { printf '\n\033[1m$ %s\033[0m\n' "$*"; }
note() { printf '\n# %s\n' "$*"; }

# --- fake provider upstream (OpenRouter path shape) -------------------------
cat > "$WORK/upstream.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): return
    def do_POST(self):
        size = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(size) or b"{}")
        with open(sys.argv[2], "a") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("authorization", ""),
                "model": body.get("model"),
                "tools": [t.get("name") for t in body.get("tools", [])],
                "cache_control_markers": json.dumps(body).count("cache_control"),
                "stream": bool(body.get("stream")),
            }) + "\n")
        if self.path != "/api/v1/messages":
            self.send_response(404); self.send_header("content-length","0"); self.end_headers(); return
        if body.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()
            def chunk(t):
                d = t.encode()
                self.wfile.write(b"%x\r\n" % len(d)); self.wfile.write(d); self.wfile.write(b"\r\n"); self.wfile.flush()
            chunk('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":40,"cache_read_input_tokens":1600,"output_tokens":0}}}\n\n')
            chunk('event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello from DeepSeek"}}\n\n')
            chunk('event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":9}}\n\n')
            chunk('event: message_stop\ndata: {"type":"message_stop"}\n\n')
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush(); return
        payload = {"id":"msg_upstream","type":"message","role":"assistant","model":body.get("model"),
                   "content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"cat sample.txt"}}],
                   "stop_reason":"tool_use",
                   "usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":800}}
        d = json.dumps(payload).encode()
        self.send_response(200); self.send_header("content-type","application/json")
        self.send_header("content-length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        self.send_response(404); self.send_header("content-length","0"); self.end_headers()

print("listening", flush=True)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

UP_PORT=$(free_port)
: > "$WORK/upstream-requests.log"
python3 "$WORK/upstream.py" "$UP_PORT" "$WORK/upstream-requests.log" > "$WORK/upstream.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 50); do grep -q listening "$WORK/upstream.log" 2>/dev/null && break; sleep 0.1; done

# --- the captain's off-peak route picker (fixture stand-in) ------------------
cat > "$WORK/pick.py" <<PY
import json, sys
json.dump({
  "kind": "deepseek", "slot": "offpeak", "provider": "openrouter",
  "model": "deepseek/deepseek-v4.1-flash",
  "base_url": "http://127.0.0.1:$UP_PORT/api/v1",
  "api_key_cmd": "printf $FAKE_KEY",
  "list_in": 0.15, "list_out": 0.60,
}, sys.stdout)
PY

PORT=$(free_port)
gw() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$ROOT/bin/fm-deepseek-gateway.sh" "$@"; }
cleanup() { gw stop >/dev/null 2>&1 || true; kill "$UP_PID" 2>/dev/null || true; }
trap cleanup EXIT

cat <<'BANNER'
================================================================================
 DeepSeek V4.1 Flash lane gateway - operator walkthrough
 (real bin/ scripts; fixture route picker + fake provider upstream on loopback)
================================================================================
BANNER

note "1. An operator starts the SECOND gateway. Port 8080 (the shared account pool) is refused by construction."
say "bin/fm-deepseek-gateway.sh start --port 8080"
gw start --port 8080 --pick "$WORK/pick.py"; echo "exit=$?"

say "bin/fm-deepseek-gateway.sh start --port $PORT --pick ~/.config/llm-route/pick.py"
gw start --port "$PORT" --pick "$WORK/pick.py"; echo "exit=$?"

TOKEN=$(tr -d ' \n' < "$STATE/fm-deepseek-gateway.token")
BASE="http://127.0.0.1:$PORT"
redact() { sed -e "s/$TOKEN/<local-token-redacted>/g" -e "s/$FAKE_KEY/<provider-key-redacted>/g"; }

note "2. The reason a gateway exists at all: Claude Code fetches the model list at session start."
note "   This is the exact request Claude Code 2.1.274 makes, verbatim user agent."
say "curl -H 'x-api-key: <token>' -A 'claude-code/2.1.274' $BASE/v1/models"
curl -sS --max-time 10 -H "x-api-key: $TOKEN" -A 'claude-code/2.1.274' "$BASE/v1/models" \
  | python3 -m json.tool | redact

note "3. An unauthenticated caller on the same loopback port cannot spend provider cash."
say "curl -o /dev/null -w '%{http_code}' $BASE/v1/models          # no token"
curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' "$BASE/v1/models"
say "curl -o /dev/null -w '%{http_code}' $BASE/status             # no token"
curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' "$BASE/status"

note "4. Liveness is the one open path, and it runs no subprocess (no picker, no provider key command)."
say "curl $BASE/healthz                                            # no token"
curl -sS --max-time 10 "$BASE/healthz" | python3 -m json.tool

note "5. The resolved route lives behind the token: provider, slot, upstream model, key presence."
say "curl -H 'x-api-key: <token>' $BASE/status"
curl -sS --max-time 10 -H "x-api-key: $TOKEN" "$BASE/status" | python3 -m json.tool | redact

note "6. A real agentic turn: an advertised model id, a tool definition, and a cache_control marker."
say "curl -H 'x-api-key: <token>' -d @turn.json $BASE/v1/messages"
cat > "$WORK/turn.json" <<'JSON'
{"model":"deepseek-v4.1-flash[1m]","max_tokens":1024,
 "system":[{"type":"text","text":"You are a Firstmate lane worker.","cache_control":{"type":"ephemeral"}}],
 "tools":[{"name":"Bash","description":"Run a shell command","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}],
 "messages":[{"role":"user","content":"Use the Bash tool to run: cat sample.txt"}]}
JSON
curl -sS --max-time 20 -H "x-api-key: $TOKEN" -H 'content-type: application/json' \
  -d @"$WORK/turn.json" "$BASE/v1/messages" | python3 -m json.tool | redact

note "   What the provider actually received - the model id is the ONLY field rewritten;"
note "   tools and cache_control markers passed through, and the key went upstream (never to the log)."
say "cat upstream-requests.log   # recorded by the fake provider"
tail -1 "$WORK/upstream-requests.log" | python3 -m json.tool | redact

note "7. Streaming is relayed frame by frame (what an interactive lane sees)."
say "curl -N -H 'x-api-key: <token>' -d '{...\"stream\":true}' $BASE/v1/messages"
curl -sS -N --max-time 20 -H "x-api-key: $TOKEN" -H 'content-type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","max_tokens":64,"stream":true,"messages":[{"role":"user","content":"hi"}]}' \
  "$BASE/v1/messages" | redact

note "8. A model id this gateway never advertised is not forwarded upstream."
say "curl -H 'x-api-key: <token>' -d '{\"model\":\"deepseek-v4.1-flash-turbo\",...}' $BASE/v1/messages"
curl -sS --max-time 10 -o "$WORK/bad.json" -w 'HTTP %{http_code}\n' -H "x-api-key: $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"model":"deepseek-v4.1-flash-turbo","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
  "$BASE/v1/messages"
python3 -m json.tool < "$WORK/bad.json" | redact

note "9. The operator verbs: health (exit 0 only when the route and key resolve), logs, env."
say "bin/fm-deepseek-gateway.sh health --port $PORT"
gw health --port "$PORT" | redact; echo "exit=${PIPESTATUS[0]}"
say "bin/fm-deepseek-gateway.sh logs --lines 4"
gw logs --lines 4 | redact
say "bin/fm-deepseek-gateway.sh env --port $PORT"
gw env --port "$PORT" | redact

note "   No secret anywhere in the request log or the process output:"
say "grep -c '$FAKE_KEY' state/fm-deepseek-gateway.log state/fm-deepseek-gateway.out"
grep -c "$FAKE_KEY" "$STATE/fm-deepseek-gateway.log" "$STATE/fm-deepseek-gateway.out" || true

say "bin/fm-deepseek-gateway.sh stop"
gw stop; echo "exit=$?"
say "curl -o /dev/null -w '%{http_code}' $BASE/healthz   # after stop"
curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' "$BASE/healthz" 2>&1 || echo "(connection refused - the port is released)"
