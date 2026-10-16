"""Admin API transports for credit-retro.

Two transports, on purpose:

* ``SessionApi`` (reads AND writes): a named human's own login session.
  core-backend #10310 lets the admin credit DELETE route run only for an
  interactive login of a NAMED_HUMAN_APPROVER_ACCOUNTS user (nick@ / jan@)
  signed in after CREDIT_GUARD_SESSION_CUTOFF; any agent or API token gets
  403 ``credit_removal_agent_refused``. The token comes from an interactive
  sign-in at run time (``--login``: email + password prompted, never stored)
  or from a 0600 file the human wrote. It is never logged, never written to
  the ledger, and never passed on argv.
* ``WrapperReadApi`` (GET only): the deployed muso-admin-api.sh wrapper with
  hydra's agent credentials, so a crewmate can run the dry-run plan and
  prepare the waves without any human token. It refuses every non-GET.
"""

from __future__ import annotations

import base64
import getpass
import json
import os
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Protocol
from urllib.parse import urlencode

DEFAULT_API_URL = "https://api.muso.ai/api/v3"
SERVICE = "credit-retro-r1"
# core-backend agentApprovalGuard NAMED_HUMAN_APPROVER_ACCOUNTS. The server is
# the authority; this copy only lets us fail before touching anything.
NAMED_HUMANS = frozenset({"jan@muso.ai", "nick@muso.ai"})
# Header values the server logs (requireRemovalAuthority caps them at 255).
HEADER_MAX = 255
# core-backend #10597: stage a removal set any admin token may write; a named human approves it.
STAGE_PATH = "/admin/credit-removals"
# Refuse a token that would expire mid-run.
MIN_TOKEN_LIFETIME_S = 300


class ApiError(RuntimeError):
    def __init__(self, message: str, status: int | None = None, body: Any = None):
        super().__init__(message)
        self.status = status
        self.body = body


class ReadApi(Protocol):
    def get(self, path: str, params: dict[str, Any] | None = None) -> Any: ...


def _unwrap(body: Any) -> Any:
    if isinstance(body, dict) and "data" in body:
        return body["data"]
    return body


def header_value(text: str) -> str:
    """ASCII-only, single line, capped: safe as an HTTP header value."""
    flat = " ".join(str(text or "").split())
    return flat.encode("ascii", "replace").decode("ascii")[:HEADER_MAX]


def jwt_claims(token: str) -> dict[str, Any]:
    """Decode (NOT verify) a JWT payload. Used only to fail early and to name
    the actor in the ledger; the server verifies the signature."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload.encode()).decode())
    except (IndexError, ValueError, UnicodeDecodeError) as exc:
        raise ApiError("the session token is not a JWT") from exc
    if not isinstance(data, dict):
        raise ApiError("the session token payload is not an object")
    return data


def check_session_claims(claims: dict[str, Any], *, now: float | None = None) -> str:
    """Return the actor email, or raise when the server would refuse anyway."""
    now = time.time() if now is None else now
    email = str(claims.get("email") or "").strip().lower()
    if claims.get("impersonatedBy"):
        raise ApiError("refusing an impersonated session: removals must come from the human's own login")
    if email not in NAMED_HUMANS:
        raise ApiError(f"session belongs to {email or '<no email>'}; only {sorted(NAMED_HUMANS)} may remove "
                       "credits (core-backend #10310)")
    if not claims.get("authTime"):
        raise ApiError("session carries no authTime (signed in before #10310): sign in again")
    exp = claims.get("exp")
    if isinstance(exp, (int, float)) and exp - now < MIN_TOKEN_LIFETIME_S:
        raise ApiError("session token expires within 5 minutes: sign in again")
    return email


def read_token_file(path: str) -> str:
    st = os.stat(path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise ApiError(f"{path} must be mode 0600 (it holds a login session)")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise ApiError(f"{path} must be owned by the user running this command")
    with open(path, encoding="utf-8") as fh:
        token = fh.read().strip()
    if not token:
        raise ApiError(f"{path} is empty")
    return token


Opener = Callable[[urllib.request.Request, float], Any]


def _default_opener(req: urllib.request.Request, timeout: float):
    return urllib.request.urlopen(req, timeout=timeout)  # noqa: S310 - fixed https base


def api_base(base: str | None = None) -> str:
    """The admin API base; https only, checked before any credential is asked for or sent."""
    url = (base or os.environ.get("MUSO_API_URL") or DEFAULT_API_URL).rstrip("/")
    if not url.startswith("https://"):
        raise ApiError(f"refusing non-https API base {url!r}")
    return url


class SessionApi:
    """Admin API over a named human's own login session."""

    def __init__(self, token: str, *, base: str | None = None, timeout: float = 60,
                 opener: Opener | None = None, now: float | None = None):
        self.base = api_base(base)
        self._token = token
        self.claims = jwt_claims(token)
        self.actor = check_session_claims(self.claims, now=now)
        self.timeout = timeout
        self._open = opener or _default_opener
        self.calls = 0

    @classmethod
    def login(cls, *, email: str | None = None, base: str | None = None,
              opener: Opener | None = None, prompt: Callable[[str], str] = getpass.getpass,
              ask: Callable[[str], str] = input) -> "SessionApi":
        """Interactive sign-in: the human types their own email + password."""
        base_url = api_base(base)
        email = (email or ask("Muso admin email (nick@ / jan@): ")).strip().lower()
        if email not in NAMED_HUMANS:
            raise ApiError(f"{email} is not a named human approver")
        password = prompt(f"Password for {email} (not stored): ")
        req = urllib.request.Request(
            f"{base_url}/admin/user/login",
            data=json.dumps({"email": email, "password": password}).encode(),
            headers={"Content-Type": "application/json", "Service": SERVICE},
            method="POST",
        )
        del password
        try:
            with (opener or _default_opener)(req, 60) as resp:
                body = json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as exc:
            raise ApiError(f"sign-in failed: HTTP {exc.code}", exc.code) from None
        data = _unwrap(body) if isinstance(body, dict) else {}
        token = ((data.get("authentication") or {}).get("accessToken")
                 or (data.get("user") or {}).get("accessToken")
                 or body.get("token") or "")
        if not token:
            raise ApiError("sign-in returned no token")
        return cls(token, base=base_url, opener=opener)

    def _request(self, method: str, path: str, body: Any = None,
                 headers: dict[str, str] | None = None) -> tuple[int, Any]:
        if not path.startswith("/admin/"):
            raise ApiError(f"refusing non-admin path {path!r}")
        hdrs = {
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json",
            "Service": SERVICE,
            "Requester": self.actor,
        }
        for k, v in (headers or {}).items():
            hdrs[k] = header_value(v)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}{path}", data=data, headers=hdrs, method=method)
        self.calls += 1
        try:
            with self._open(req, self.timeout) as resp:
                raw = resp.read().decode()
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode(errors="replace") if exc.fp else ""
            status = exc.code
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise ApiError(f"{method} {path}: transport error {exc}") from None
        try:
            parsed = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed = {"raw": raw[:500]}
        return status, parsed

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        if params:
            path = f"{path}?{urlencode(params)}"
        status, body = self._request("GET", path)
        if not 200 <= status < 300:
            raise ApiError(f"GET {path} returned HTTP {status}", status, body)
        return _unwrap(body)

    def write(self, method: str, path: str, body: Any, headers: dict[str, str] | None = None) -> tuple[int, Any]:
        """One write. Returns (status, body); never raises on an HTTP error
        status so the caller records a refusal exactly as the server sent it."""
        if method not in ("DELETE", "POST"):
            raise ApiError(f"credit-retro only issues DELETE/POST writes, not {method}")
        return self._request(method, path, body, headers)


class WrapperReadApi:
    """GET-only reads through the deployed muso-admin-api.sh (agent token)."""

    actor = "agent-read-only"

    def __init__(self, script: str | None = None):
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from credit_review.admin import AdminClient  # noqa: PLC0415 - sibling package
        self._client = AdminClient(script=script)

    @property
    def calls(self) -> int:
        return self._client.calls

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        from credit_review.admin import AdminError  # noqa: PLC0415
        try:
            return self._client.get(path, params)
        except AdminError as exc:
            raise ApiError(str(exc)) from None

    def write(self, method: str, path: str, body: Any, headers: dict[str, str] | None = None) -> tuple[int, Any]:
        """The ONLY write the agent may make: staging a credit-removal approval set
        (core-backend #10597: staging grants nothing; a named human approves it).
        Everything else needs a named human's session."""
        if method != "POST" or path != STAGE_PATH:
            raise ApiError("the wrapper transport only stages removal approvals; apply/revert need a named "
                           "human's session")
        argv = ["bash", self._client.script, "--requester", "credit-retro@hydra-ops", "call", "POST", path,
                json.dumps(body)]
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=120, check=False)
        if proc.returncode != 0:
            raise ApiError(f"stage POST failed rc={proc.returncode}: {proc.stderr.strip()[:300]}")
        try:
            env = json.loads(proc.stdout.strip().splitlines()[-1])
        except (json.JSONDecodeError, IndexError) as exc:
            raise ApiError("stage POST returned non-JSON") from exc
        return int(env.get("http_status") or 0), env.get("body")
