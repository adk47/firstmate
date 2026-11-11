"""SA_HOME resolution and canonical JSON helpers (SA-01).

The single owner of two contracts from design.md:

* ``SA_HOME`` is the only writable root. It is ``$SA_HOME`` when set, else
  ``<repo>/sa/var``. Nothing in ``sa/`` writes anywhere else.
* Canonical JSON is ``json.dumps(obj, sort_keys=True, separators=(",", ":"),
  ensure_ascii=False)``. Every persisted byte and every printed state uses it,
  which is what makes "byte-identical replay" a real test.

Python 3 stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

#: ISO-8601 UTC seconds, the only accepted ``at`` shape.
AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def repo_root() -> Path:
    """Return the repository root (``sa/lib/sa_paths.py`` -> ``sa`` -> repo)."""
    return Path(__file__).resolve().parents[2]


def sa_home() -> Path:
    """Return the writable SA root: ``$SA_HOME`` if set, else ``<repo>/sa/var``."""
    env = os.environ.get("SA_HOME")
    if env:
        return Path(env).expanduser().resolve()
    return repo_root() / "sa" / "var"


def events_path(home: Path | None = None) -> Path:
    """Return the event log path inside ``home`` (default: :func:`sa_home`)."""
    return (home or sa_home()) / "events.jsonl"


def canonical(obj) -> str:
    """Serialize ``obj`` to canonical JSON (the one true byte form)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def canonical_bytes(obj) -> bytes:
    """Return the canonical JSON of ``obj`` as UTF-8 bytes."""
    return canonical(obj).encode("utf-8")


def sha256_of(obj) -> str:
    """Return the sha256 hex digest of the canonical JSON of ``obj``."""
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


def utc_now() -> str:
    """Return the current UTC time as ISO-8601 seconds."""
    return datetime.now(timezone.utc).strftime(AT_FORMAT)


def parse_at(value: str) -> str:
    """Normalize a caller-supplied timestamp to ISO-8601 UTC seconds.

    Accepts ``2026-11-05T02:10:00Z`` and any ISO-8601 form carrying an offset
    (``+00:00``, ``-05:00``). Raises ``ValueError`` for anything else, so a bad
    timestamp never reaches the log.
    """
    if not isinstance(value, str) or not value.strip():
        raise ValueError("at must be a non-empty ISO-8601 string")
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError(f"at is not ISO-8601: {value!r}") from exc
    if parsed.tzinfo is None:
        raise ValueError(f"at must carry a UTC offset: {value!r}")
    return parsed.astimezone(timezone.utc).strftime(AT_FORMAT)
