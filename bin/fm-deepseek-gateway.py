#!/usr/bin/env python3
"""fm-deepseek-gateway.py - the second local Anthropic-compatible gateway.

Owned by bin/fm-deepseek-gateway.sh, which starts, stops, and probes it; the
home's own supervisor keeps it alive across a reboot, and
docs/deepseek-lane-gateway.md carries a launchctl recipe for a macOS home that
wants one. Read that script's header for the operator surface and the doc for
the mechanism and the proof sequence.

WHY A GATEWAY AT ALL: Claude Code 2.x gates every model id through its compiled
catalog before any request leaves the machine, so pointing ANTHROPIC_BASE_URL
straight at OpenRouter or Fireworks is refused client-side. What works is the
shape the fleet already uses for the Claude account pool: a gateway that
advertises the model on GET /v1/models, which Claude Code itself fetches and
caches, after which `/model <advertised-id>` is accepted and sent.

WHAT THIS SERVES (and nothing else - every other path is a 404):
  GET  /healthz                liveness, the resolved route, and counters.
                               Unauthenticated it carries a route_ok boolean
                               only; WITH the token it also carries the route
                               picker's own message. No request rows on either:
                               $STATE/fm-deepseek-gateway.log is the one place
                               those live, and `logs` is what reads them.
  GET  /v1/models[?limit=N]    the advertised model list Claude Code discovers
  POST /v1/messages            the proxied Anthropic Messages call
  POST /v1/messages/count_tokens  a local token estimate

ROUTING: the upstream provider, model id, base URL, and key are resolved
PER REQUEST by running the captain's ~/.config/llm-route/pick.py, never once at
startup, so a long-running lane that crosses DeepSeek's UTC peak window is
routed to Fireworks at peak and OpenRouter off peak
(~/.config/llm-route/README.md owns that rule). The key comes from the very
`api_key_cmd` pick.py names, so this file never learns where a secret lives.
Secrets are never logged, never echoed in an error, and never printed by any
subcommand.

AUTH: every request except /healthz needs the local bearer token in the token
file (created mode 0600 on first run). The token gates THIS port, not the
providers; it is what stops any other local process from spending the
captain's provider cash through an open loopback port.

NO AUTOMATIC FAILOVER: an upstream 429/5xx is returned as-is, because routing
is pick.py's decision and silently switching providers behind it would hide
both the failure and the cost. A lane that needs the other provider is
switched by the clock, not by this process.

NOT THIS GATEWAY: 127.0.0.1:8080 is the shared Claude account-pool gateway
(better-ccflare) serving the whole fleet. This file must never be pointed at
that port and bin/fm-deepseek-gateway.sh refuses it.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEMA = "fm-deepseek-gateway.v1"
DEFAULT_PORT = 8799
DEFAULT_KIND = "deepseek"
DEFAULT_PICK = "~/.config/llm-route/pick.py"
SHARED_POOL_PORT = 8080
ANTHROPIC_VERSION_DEFAULT = "2023-06-01"
MAX_ERROR_CHARS = 400
LOG_MAX_BYTES_DEFAULT = 5 * 1024 * 1024

# The exact model ids this gateway advertises. Claude Code discovers these from
# GET /v1/models and then accepts `/model <id>`; the `[1m]` row is the same
# model with Claude Code's 1M context marker, which the client strips or keeps
# depending on the surface, so the wire id is normalized before routing.
ADVERTISED_MODELS = (
    ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash (routed)"),
    ("deepseek-v4.1-flash[1m]", "DeepSeek V4.1 Flash (1M context)"),
)
CANONICAL_MODEL = ADVERTISED_MODELS[0][0]


class RouteError(Exception):
    """The upstream route or its key could not be resolved."""


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def canonical_model_id(requested: str) -> str:
    """Return the routed model id for an exactly advertised id, or ''.

    Claude Code may send the bare id or the `[1m]`-suffixed form, and both are
    advertised on GET /v1/models. Only those two exact spellings are served:
    an id this gateway never advertised is not ours to forward upstream.
    """
    name = (requested or "").strip()
    for advertised, _display in ADVERTISED_MODELS:
        if name == advertised:
            return CANONICAL_MODEL
    return ""


class Config:
    def __init__(self, args: argparse.Namespace) -> None:
        self.host = args.host
        self.port = int(args.port)
        self.pick = os.path.expanduser(args.pick)
        self.kind = args.kind
        self.state = os.path.expanduser(args.state)
        self.token_file = os.path.expanduser(args.token_file) if args.token_file else os.path.join(self.state, "fm-deepseek-gateway.token")
        self.log_file = os.path.expanduser(args.log) if args.log else os.path.join(self.state, "fm-deepseek-gateway.log")
        self.upstream_timeout = float(args.upstream_timeout)
        self.log_max_bytes = int(args.log_max_bytes)
        self.token = ""
        self.started_at = utc_now()
        self.lock = threading.Lock()
        self.requests = 0
        self.errors = 0

    def ensure_token(self) -> str:
        path = self.token_file
        parent = os.path.dirname(path) or "."
        os.makedirs(parent, exist_ok=True)
        if not os.path.exists(path):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write(secrets.token_hex(16) + "\n")
        else:
            mode = os.stat(path).st_mode & 0o777
            if mode & 0o077:
                os.chmod(path, 0o600)
        with open(path, "r") as handle:
            token = handle.read().strip()
        if not token:
            raise RouteError("gateway token file is empty: %s" % path)
        self.token = token
        return token


def run_pick(cfg: Config) -> dict:
    """Resolve the current route by running the captain's pick.py. No caching."""
    if not os.path.exists(cfg.pick):
        raise RouteError("route picker is missing: %s" % cfg.pick)
    try:
        proc = subprocess.run(
            [sys.executable, cfg.pick, cfg.kind, "--json"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RouteError("route picker could not run: %s" % exc)
    if proc.returncode != 0:
        raise RouteError("route picker failed: %s" % (proc.stderr.strip()[:MAX_ERROR_CHARS] or "no diagnostics"))
    try:
        route = json.loads(proc.stdout)
    except ValueError as exc:
        raise RouteError("route picker returned invalid JSON: %s" % exc)
    missing = [key for key in ("provider", "model", "base_url", "api_key_cmd", "slot") if key not in route]
    if missing:
        raise RouteError("route picker returned no %s" % ",".join(missing))
    return route


def read_api_key(api_key_cmd: str) -> str:
    """Read the provider key through the command pick.py itself names.

    The command is pick.py's own data, so this file never hardcodes where a
    secret lives and a captain who moves a key file changes one place.
    """
    if not api_key_cmd:
        raise RouteError("route picker returned no api_key_cmd")
    try:
        proc = subprocess.run(["/bin/sh", "-c", api_key_cmd], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RouteError("provider key could not be read: %s" % exc)
    key = proc.stdout.strip()
    if proc.returncode != 0 or not key:
        raise RouteError("provider key is unavailable (the route's api_key_cmd produced nothing)")
    return key


def redact(text: str, secret: str) -> str:
    if not text:
        return ""
    if secret:
        text = text.replace(secret, "[redacted]")
    return text[:MAX_ERROR_CHARS]


def usage_from(payload: dict) -> dict:
    """Usage in the Anthropic Messages names, the only surface this gateway calls.

    Both routes are Anthropic Messages endpoints, so these are the names that
    actually arrive. No OpenAI spelling is accepted: `prompt_tokens` INCLUDES
    the cached prefix while `input_tokens` excludes it, so reading one as the
    other would silently over-report both the token row and estimate_cost.
    """
    usage = payload.get("usage") if isinstance(payload, dict) else None
    if not isinstance(usage, dict):
        return {}
    out = {}
    for name in (
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    ):
        value = usage.get(name)
        if isinstance(value, (int, float)):
            out[name] = value
    return out


def estimate_cost(route: dict, usage: dict) -> float:
    """A list-price estimate for one call.

    Cache reads are billed at one tenth of the input rate: that is the
    measured behaviour recorded in the fleet's DeepSeek offload report, and it
    is why a cache-heavy lane costs a fraction of its token count. The number
    is an estimate for operator accounting only; the provider's own billing is
    authoritative.
    """
    if not usage:
        return 0.0
    try:
        price_in = float(route.get("list_in", 0) or 0)
        price_out = float(route.get("list_out", 0) or 0)
    except (TypeError, ValueError):
        return 0.0
    plain_in = float(usage.get("input_tokens", 0) or 0)
    cache_read = float(usage.get("cache_read_input_tokens", 0) or 0)
    cache_write = float(usage.get("cache_creation_input_tokens", 0) or 0)
    out = float(usage.get("output_tokens", 0) or 0)
    return round(
        (plain_in * price_in + cache_read * price_in / 10 + cache_write * price_in * 1.25 + out * price_out) / 1_000_000,
        6,
    )


class Gateway:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    # --- logging ---------------------------------------------------------
    def log(self, record: dict) -> None:
        record = {"schema": SCHEMA, "at": utc_now(), **record}
        line = json.dumps(record, sort_keys=True) + "\n"
        try:
            path = self.cfg.log_file
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            if os.path.exists(path) and os.path.getsize(path) > self.cfg.log_max_bytes:
                os.replace(path, path + ".1")
                os.chmod(path + ".1", 0o600)
            # 0600, not the umask: these rows are the ones /healthz refuses to
            # show, because a failed one carries the provider's own error body.
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a") as handle:
                handle.write(line)
        except OSError:
            pass  # A gateway that cannot log still serves; it must not fail a request.

    def note(self, record: dict) -> None:
        """Count one request and write its durable row.

        Counting and recording are one act on purpose: the request log is the
        only reader of rows, so a path that counts a failure without writing it
        would leave a moved counter an operator cannot explain.
        """
        with self.cfg.lock:
            self.cfg.requests += 1
            if record.get("outcome") != "ok":
                self.cfg.errors += 1
        self.log(record)

    def health(self, include_error: bool = False) -> dict:
        route = {}
        key_present = False
        error = None
        try:
            route = run_pick(self.cfg)
            key_present = bool(read_api_key(route["api_key_cmd"]))
        except RouteError as exc:
            error = str(exc)
        with self.cfg.lock:
            requests = self.cfg.requests
            errors = self.cfg.errors
        # No request row here, and no picker text unless the caller proved the
        # token: a recorded row carries the provider's own error body and the
        # picker's message is an unowned third-party script's stderr, neither of
        # which belongs on a surface any local process can read. The rows live
        # in the request log; `route_ok` is what an unauthenticated caller gets.
        body = {
            "schema": SCHEMA,
            "status": "ok" if key_present else "degraded",
            "pid": os.getpid(),
            "started_at": self.cfg.started_at,
            "model": CANONICAL_MODEL,
            "models": [model for model, _display in ADVERTISED_MODELS],
            "provider": route.get("provider", ""),
            "slot": route.get("slot", ""),
            "upstream_model": route.get("model", ""),
            "base_url": route.get("base_url", ""),
            "key_present": key_present,
            "requests_served": requests,
            "errors": errors,
            "route_ok": error is None,
        }
        if error and include_error:
            body["route_error"] = redact(error, "")
        return body

    # --- upstream --------------------------------------------------------
    def forward(self, body: bytes, model: str, stream: bool, headers) -> tuple:
        """Send one request upstream. Returns (status, response_headers, reader).

        The reader is a file-like object the caller streams from; it is closed
        by the caller. Raises RouteError before any upstream call when the
        route or key cannot be resolved.
        """
        route = run_pick(self.cfg)
        key = read_api_key(route["api_key_cmd"])
        payload = json.loads(body.decode("utf-8"))
        payload["model"] = route["model"]
        data = json.dumps(payload).encode("utf-8")
        upstream_headers = {
            "authorization": "Bearer %s" % key,
            "content-type": "application/json",
            "accept": "text/event-stream" if stream else "application/json",
            "anthropic-version": headers.get("anthropic-version") or ANTHROPIC_VERSION_DEFAULT,
            # Never gzip: the response body is relayed byte for byte.
            "accept-encoding": "identity",
            "user-agent": "fm-deepseek-gateway/%s" % SCHEMA,
        }
        beta = headers.get("anthropic-beta")
        if beta:
            upstream_headers["anthropic-beta"] = beta
        url = route["base_url"].rstrip("/") + "/messages"
        request = urllib.request.Request(url, data=data, headers=upstream_headers, method="POST")
        try:
            response = urllib.request.urlopen(request, timeout=self.cfg.upstream_timeout)
        except urllib.error.HTTPError as exc:
            detail = redact(exc.read().decode("utf-8", "replace"), key)
            raise UpstreamError(exc.code, detail, route)
        except urllib.error.URLError as exc:
            raise UpstreamError(502, redact("upstream unreachable: %s" % exc.reason, key), route)
        except OSError as exc:
            raise UpstreamError(502, redact("upstream transport failed: %s" % exc, key), route)
        return response.status, response.headers, response, route, key


class UpstreamError(Exception):
    def __init__(self, status: int, detail: str, route: dict) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail
        self.route = route


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fm-deepseek-gateway"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: A003 - silence the default stderr log
        return

    # --- helpers ---------------------------------------------------------
    @property
    def gateway(self) -> Gateway:
        return self.server.gateway  # type: ignore[attr-defined]

    def _authorized(self) -> bool:
        token = self.headers.get("x-api-key") or ""
        if not token:
            auth = self.headers.get("authorization") or ""
            if auth.lower().startswith("bearer "):
                token = auth[7:].strip()
        return bool(token) and hmac.compare_digest(token, self.gateway.cfg.token)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8") + b"\n"
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, status: int, error_type: str, message: str) -> None:
        self._send_json(status, {"type": "error", "error": {"type": error_type, "message": message}})

    def _discard_body(self) -> None:
        """Drain the request body before an error that never reads it.

        This is HTTP/1.1 with keep-alive, so an unread body would be parsed as
        the next request line and answered with a bogus 400 - a lane holding a
        stale token would see alternating 401s and malformed responses instead
        of the plain auth failure it actually has.
        """
        try:
            size = int(self.headers.get("content-length") or 0)
        except ValueError:
            self.close_connection = True
            return
        if size < 0 or size > 64 * 1024 * 1024:
            self.close_connection = True
            return
        while size > 0:
            chunk = self.rfile.read(min(size, 65536))
            if not chunk:
                self.close_connection = True
                return
            size -= len(chunk)

    def _read_body(self) -> bytes:
        length = self.headers.get("content-length")
        if not length:
            raise ValueError("missing content-length")
        try:
            size = int(length)
        except ValueError:
            raise ValueError("invalid content-length")
        if size < 0 or size > 64 * 1024 * 1024:
            raise ValueError("content-length out of range")
        return self.rfile.read(size)

    # --- routes ----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path == "/healthz":
            # One path, one surface: the token only widens what it carries.
            self._send_json(200, self.gateway.health(include_error=self._authorized()))
            return
        if not self._authorized():
            self._send_error_json(401, "authentication_error", "missing or invalid gateway token")
            return
        if path == "/v1/models":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                limit = int(query.get("limit", ["1000"])[0])
            except ValueError:
                limit = 1000
            models = [
                {
                    "type": "model",
                    "id": model,
                    "display_name": display,
                    "created_at": self.gateway.cfg.started_at,
                    "object": "model",
                    "owned_by": "fm-deepseek-gateway",
                }
                for model, display in ADVERTISED_MODELS
            ][: max(limit, 0)]
            # Discovery is logged on purpose: it is the one event that proves a
            # client actually read this gateway's model list, and without a
            # record of it an operator cannot tell a discovered model from a
            # silently accepted one.
            self.gateway.log({
                "outcome": "models",
                "models": [model for model, _display in ADVERTISED_MODELS],
                "limit": limit,
                "user_agent": (self.headers.get("user-agent") or "")[:120],
            })
            self._send_json(200, {
                "data": models,
                "has_more": False,
                "first_id": models[0]["id"] if models else None,
                "last_id": models[-1]["id"] if models else None,
            })
            return
        self._send_error_json(404, "not_found_error", "no such endpoint: %s" % path)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.rstrip("/") or "/"
        if not self._authorized():
            self._discard_body()
            self._send_error_json(401, "authentication_error", "missing or invalid gateway token")
            return
        if path == "/v1/messages/count_tokens":
            self._count_tokens()
            return
        if path != "/v1/messages":
            self._discard_body()
            self._send_error_json(404, "not_found_error", "no such endpoint: %s" % path)
            return
        self._messages()

    def _count_tokens(self) -> None:
        try:
            body = self._read_body()
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            self._send_error_json(400, "invalid_request_error", "unreadable request body: %s" % exc)
            return
        text = json.dumps(payload.get("messages", [])) + json.dumps(payload.get("system", ""))
        # A local estimate, deliberately not a provider call: the providers do
        # not all expose a count endpoint, and Claude Code only needs a bound.
        estimate = max(1, len(text) // 4)
        self._send_json(200, {"input_tokens": estimate})

    def _messages(self) -> None:
        started = time.time()
        try:
            body = self._read_body()
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            self.gateway.note({"outcome": "bad-request", "error": str(exc)})
            self._send_error_json(400, "invalid_request_error", "unreadable request body: %s" % exc)
            return
        requested = payload.get("model", "")
        model = canonical_model_id(requested)
        if not model:
            self.gateway.note({"outcome": "unknown-model", "requested_model": requested})
            self._send_error_json(
                404, "not_found_error",
                "%s is not served by this gateway; it advertises %s"
                % (requested or "(no model)", ", ".join(m for m, _d in ADVERTISED_MODELS)),
            )
            return
        stream = bool(payload.get("stream"))
        try:
            status, upstream_headers, reader, route, key = self.gateway.forward(body, model, stream, self.headers)
        except RouteError as exc:
            self.gateway.note({"outcome": "route-error", "model": model, "error": str(exc)})
            self._send_error_json(503, "api_error", str(exc))
            return
        except UpstreamError as exc:
            self.gateway.note({
                "outcome": "upstream-error", "model": model, "upstream_status": exc.status,
                "provider": exc.route.get("provider", ""), "slot": exc.route.get("slot", ""),
                "error": exc.detail, "duration_ms": int((time.time() - started) * 1000),
            })
            self._send_error_json(exc.status if 400 <= exc.status < 600 else 502, "api_error", exc.detail)
            return
        record = {
            "model": model,
            "upstream_model": route["model"],
            "provider": route["provider"],
            "slot": route["slot"],
            "stream": stream,
            "upstream_status": status,
            "duration_ms": int((time.time() - started) * 1000),
        }
        try:
            if stream:
                self._relay_stream(reader, route, record)
            else:
                self._relay_once(reader, route, record)
        except (BrokenPipeError, ConnectionResetError):
            record["outcome"] = "client-disconnected"
            record["duration_ms"] = int((time.time() - started) * 1000)
            self.gateway.note(record)
            return
        except Exception as exc:
            # An upstream that stalls past the timeout or drops mid-response
            # fails HERE, after the headers are already out, so there is no
            # error response left to send. The row is what the operator reads
            # instead: without it the only trace is a traceback in the .out
            # file and the counters never move.
            record["outcome"] = "relay-failed"
            record["error"] = redact("%s: %s" % (type(exc).__name__, exc), key)
            record["duration_ms"] = int((time.time() - started) * 1000)
            self.gateway.note(record)
            raise
        finally:
            reader.close()

    def _relay_once(self, reader, route: dict, record: dict) -> None:
        raw = reader.read()
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            payload = {}
        usage = usage_from(payload)
        record["usage"] = usage
        record["cost_usd"] = estimate_cost(route, usage)
        record["outcome"] = "ok"
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.gateway.note(record)

    def _relay_stream(self, reader, route: dict, record: dict) -> None:
        """Relay Server-Sent Events frame by frame, never buffering the run."""
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        usage = {}
        while True:
            line = reader.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace")
            if text.startswith("data:"):
                try:
                    event = json.loads(text[5:].strip())
                except ValueError:
                    event = None
                if isinstance(event, dict):
                    found = usage_from(event)
                    if found:
                        # Merge, never replace: providers split the counts
                        # across message_start (input/cache) and message_delta
                        # (output), so the last event alone under-reports.
                        usage.update(found)
                    message = event.get("message")
                    if isinstance(message, dict):
                        found = usage_from(message)
                        if found:
                            usage.update(found)
            chunk = line
            self.wfile.write(b"%x\r\n" % len(chunk))
            self.wfile.write(chunk)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        record["usage"] = usage
        record["cost_usd"] = estimate_cost(route, usage)
        record["outcome"] = "ok"
        self.gateway.note(record)


def parse_args(argv) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="fm-deepseek-gateway.py",
        description="Second local Anthropic-compatible gateway for DeepSeek V4.1 Flash.",
        add_help=True,
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--pick", default=DEFAULT_PICK, help="route picker (default %s)" % DEFAULT_PICK)
    parser.add_argument("--kind", default=DEFAULT_KIND, help="route kind passed to the picker")
    parser.add_argument("--state", default=os.path.expanduser("~/.local/state/fm-deepseek-gateway"))
    parser.add_argument("--token-file", default="")
    parser.add_argument("--log", default="")
    parser.add_argument("--upstream-timeout", default="900")
    parser.add_argument("--log-max-bytes", default=str(LOG_MAX_BYTES_DEFAULT))
    parser.add_argument(
        "--print-model", action="store_true",
        help="print the advertised model id and exit (the one owner of that id)",
    )
    return parser.parse_args(argv)


def main(argv) -> int:
    args = parse_args(argv)
    if args.print_model:
        print(CANONICAL_MODEL)
        return 0
    cfg = Config(args)
    if cfg.port == SHARED_POOL_PORT:
        print(
            "error: port %d is the shared Claude account-pool gateway; this gateway refuses it"
            % SHARED_POOL_PORT,
            file=sys.stderr,
        )
        return 2
    try:
        cfg.ensure_token()
    except (OSError, RouteError) as exc:
        print("error: gateway token could not be prepared: %s" % exc, file=sys.stderr)
        return 1
    gateway = Gateway(cfg)
    try:
        server = ThreadingHTTPServer((cfg.host, cfg.port), Handler)
    except OSError as exc:
        print("error: cannot bind %s:%d (%s)" % (cfg.host, cfg.port, exc), file=sys.stderr)
        return 1
    server.daemon_threads = True
    server.gateway = gateway  # type: ignore[attr-defined]

    def shutdown(_signum=None, _frame=None):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print("ready: http://%s:%d model=%s" % (cfg.host, cfg.port, CANONICAL_MODEL), flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
