"""Cross-process pacing for the doc-verify reader (proof-loop lead 2026-10-28: parallel readers,
with MusicBrainz at 1 request/s and Intercom/admin GETs at 1/s TOTAL, whatever the number of
workers).

One small file per API under PACE_DIR holds the wall-clock time of the last call. `wait()` takes
an exclusive flock on it, sleeps until `min_interval` has passed since that time, writes the new
time and releases: every process on the host that paces through the same name is serialised,
and the stamp survives a process restart. An unusable pace file (no directory, unwritable):
  * strict (a parallel worker): PaceError - the call is NOT made, because per-process pacing in
    N workers would be N calls/s on the host (QA #1433);
  * not strict (the single reader): pacing inside this process only, said once.
"""

from __future__ import annotations

import fcntl
import os
import threading
import time
from typing import Callable, TypeVar

PACE_DIR = os.environ.get("CREDIT_DOC_VERIFY_PACE_DIR",
                          os.path.join(os.environ.get("CREDIT_VERIFY_STATE_DIR", "/var/lib/hydra-credit-verify"),
                                       "pace"))
T = TypeVar("T")


class PaceError(RuntimeError):
    """The host-wide pace file cannot be used and the pacer is strict."""


def usable(directory: str | None = None) -> str | None:
    """None when pace files can be created and locked under `directory`, else why not."""
    d = directory or PACE_DIR
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        fd = os.open(os.path.join(d, ".probe.pace"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
    except OSError as exc:
        return f"{d}: {type(exc).__name__}"
    return None


class Pacer:
    def __init__(self, name: str, min_interval: float, directory: str | None = None,
                 log: Callable[[str], None] = lambda m: None, strict: bool = False):
        if not name.replace("-", "").isalnum():
            raise ValueError("pacer name must be alphanumeric")
        self.name, self.min_interval, self.log, self.strict = name, float(min_interval), log, strict
        self.path = os.path.join(directory or PACE_DIR, f"{name}.pace")
        self._local = threading.Lock()
        self._last = 0.0
        self._warned = False

    def wait(self) -> None:
        with self._local:                     # threads of this process queue here first
            try:
                os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
                fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
            except OSError as exc:
                if self.strict:
                    raise PaceError(f"pace {self.name}: {self.path} unusable ({type(exc).__name__}); "
                                    "a parallel worker never calls the API unpaced") from exc
                if not self._warned:
                    self.log(f"pace {self.name}: {type(exc).__name__}; pacing inside this process only")
                    self._warned = True
                self._sleep_until(self._last + self.min_interval)
                self._last = time.time()
                return
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                raw = os.pread(fd, 64, 0).decode("ascii", "ignore").strip()
                try:
                    last = float(raw) if raw else 0.0
                except ValueError:
                    last = 0.0
                self._sleep_until(max(last, self._last) + self.min_interval)
                now = time.time()
                os.ftruncate(fd, 0)
                os.pwrite(fd, f"{now:.6f}".encode(), 0)
                self._last = now
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    @staticmethod
    def _sleep_until(t: float) -> None:
        d = t - time.time()
        if 0 < d < 60:                         # a clock jump never stalls a run for long
            time.sleep(d)

    def paced(self, fn: Callable[..., T]) -> Callable[..., T]:
        def call(*a, **kw) -> T:
            self.wait()
            return fn(*a, **kw)
        return call


def shard_of(proof_id: str, n: int) -> int:
    """The worker that owns a document: its sha256 (hex) modulo the worker count. Two filings
    of the same bytes (two accounts) land on the same worker, so a document is never read by
    two workers at once."""
    try:
        return int(str(proof_id)[:12], 16) % max(1, n)
    except ValueError:
        return sum(map(ord, str(proof_id))) % max(1, n)
