"""Shared ClickUp client: 429-aware, throttled, stdlib only.

ClickUp allows 100 requests/min per token and every hydra job (plus the agents)
shares one key. A bare urlopen turns the first 429 into a dead unit, so every
Python ClickUp caller that scans a list goes through here instead.

* Throttle: a sliding 60 s window, `max_per_min` requests per client. Build ONE
  client per process (`shared()`) so the window covers every call of a run.
* 429: wait until X-RateLimit-Reset (epoch seconds), else Retry-After, else 60 s,
  clamped to [1, 65] s, at most `attempts` tries, then raise ClickUpRateLimited.
  ClickUp refuses a 429 before acting, so retrying POST/DELETE is safe.
* URLError / socket.timeout: retried with the old 2*(a+1) backoff.
* Any other HTTPError propagates untouched.
* list_tasks never returns a partial scan: a bad page or too many pages raises.
"""
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLICKUP_API = "https://api.clickup.com/api/v2"
WINDOW_SEC = 60
MIN_WAIT, MAX_WAIT, DEFAULT_WAIT = 1, 65, 60


class ClickUpRateLimited(RuntimeError):
    """ClickUp answered 429 on every attempt."""


class ClickUp:
    def __init__(self, key, *, max_per_min=80, attempts=5, sleep=time.sleep,
                 clock=time.time, urlopen=urllib.request.urlopen, base=CLICKUP_API):
        self.base = base
        self.key, self.max_per_min, self.attempts = key, max_per_min, attempts
        self._sleep, self._clock, self._urlopen = sleep, clock, urlopen
        self._sent = []  # send times inside the sliding window

    def _throttle(self):
        now = self._clock()
        self._sent = [t for t in self._sent if now - t < WINDOW_SEC]
        if len(self._sent) >= self.max_per_min:
            self._sleep(max(self._sent[0] + WINDOW_SEC - now, 0))
            now = self._clock()
            self._sent = [t for t in self._sent if now - t < WINDOW_SEC]
        self._sent.append(now)

    def _wait_for(self, err):
        hdr = err.headers.get if err.headers is not None else (lambda _k: None)
        wait = DEFAULT_WAIT
        try:
            if hdr("X-RateLimit-Reset"):
                wait = float(hdr("X-RateLimit-Reset")) - self._clock()
            elif hdr("Retry-After"):
                wait = float(hdr("Retry-After"))
        except ValueError:
            wait = DEFAULT_WAIT
        return min(max(wait, MIN_WAIT), MAX_WAIT)

    def request(self, method, url_or_path, body=None, timeout=60):
        url = url_or_path if url_or_path.startswith("http") else self.base + url_or_path
        path = urllib.parse.urlsplit(url).path
        data = json.dumps(body).encode() if body is not None else None
        for a in range(self.attempts):
            self._throttle()
            req = urllib.request.Request(url, data=data, method=method,
                                         headers={"Authorization": self.key})
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with self._urlopen(req, timeout=timeout) as r:
                    return r.status, json.loads(r.read() or b"null")
            except urllib.error.HTTPError as e:
                if e.code != 429:
                    raise
                if a == self.attempts - 1:
                    raise ClickUpRateLimited(
                        f"clickup: 429 on {method} {path} after {self.attempts} attempts") from e
                wait = self._wait_for(e)
                print(f"clickup: 429 on {method} {path}; sleeping {wait:g}s "
                      f"(attempt {a + 1}/{self.attempts})", file=sys.stderr)
                self._sleep(wait)
            except (urllib.error.URLError, socket.timeout) as e:
                if a == self.attempts - 1:
                    raise RuntimeError(f"{method} {path} failed after {self.attempts}: {e}")
                self._sleep(2 * (a + 1))

    def list_tasks(self, list_id, params, max_pages):
        """Every task of `params` on a list, deduped by id; raises rather than
        return a partial scan (bad page, or no last_page within max_pages)."""
        out, seen = [], set()
        for page in range(max_pages):
            q = urllib.parse.urlencode([*params, ("page", str(page))])
            s, body = self.request("GET", f"/list/{list_id}/task?{q}")
            if s != 200 or not isinstance(body, dict) or not isinstance(body.get("tasks"), list):
                raise RuntimeError(f"clickup list page {page} -> {s}: "
                                   f"{body.get('err') if isinstance(body, dict) else body}")
            for t in body["tasks"]:
                if t.get("id") not in seen:
                    seen.add(t.get("id"))
                    out.append(t)
            if body.get("last_page") or not body["tasks"]:
                return out
        raise RuntimeError(f"clickup list {list_id}: no last_page after {max_pages} pages; "
                           f"refusing a partial scan")


_shared = {}


def shared(key, base=CLICKUP_API):
    """One client per key per process, so the throttle covers the whole run."""
    if (key, base) not in _shared:
        _shared[(key, base)] = ClickUp(key, base=base)
    return _shared[(key, base)]
