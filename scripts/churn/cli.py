"""Shared plumbing for the three campaign stages: policy, paths, logging, run artifacts.

Kept in one place so the three entry scripts (``scripts/route_fix.py``,
``scripts/fix_readback.py``, ``scripts/winback_fix_send.py``) can be read as the story of the
campaign - route, prove, tell - instead of three copies of argument parsing.

Two conventions matter operationally:

* **stdout is the machine channel.** Human logs go to stderr, so a cron/journal reader can take
  stdout as JSON without filtering. Nothing here prints customer PII to stdout.
* **every run writes an artifact** under ``<state>/reports/`` with the counts that justified it.
  A campaign that cannot show what it did on a given day is indistinguishable from one that did
  nothing, which is exactly the failure this campaign exists to fix.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Mapping

REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_DEFAULT = REPO_ROOT / "policies" / "winback-fix.json"
STATE_DIR_DEFAULT = Path("/var/lib/hydra/churn")


def log(msg: str) -> None:
    print(f"[churn] {msg}", file=sys.stderr, flush=True)


def load_policy(path: str | Path | None = None) -> dict[str, Any]:
    """Read policies/winback-fix.json. A missing or malformed policy is fatal, never defaulted."""
    p = Path(path) if path else POLICY_DEFAULT
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"policy not found: {p}") from exc
    except (OSError, ValueError) as exc:
        raise SystemExit(f"policy unreadable: {p}: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("campaign") != "wb_fix_1":
        raise SystemExit(f"policy {p} is not the wb_fix_1 policy (campaign field mismatch)")
    return doc


def path_from(policy: Mapping[str, Any], key: str, override: str | Path | None = None) -> Path:
    """A policy path: explicit flag/env first, then the policy default."""
    if override:
        return Path(override)
    spec = ((policy.get("paths") or {}).get(key) or {})
    env_name = "WINBACK_FIX_" + key.upper()
    if os.environ.get(env_name):
        return Path(os.environ[env_name])
    return Path(str(spec.get("default") or ""))


def state_dir(policy: Mapping[str, Any], override: str | Path | None = None) -> Path:
    d = path_from(policy, "state_dir", override)
    if not str(d):
        raise SystemExit("policy paths.state_dir has no default and no --state-dir was given")
    return d


def live_flag(policy: Mapping[str, Any], override: str | Path | None = None) -> Path:
    return path_from(policy, "live_flag", override)


def write_private_json(path: Path, doc: Mapping[str, Any], *, indent: int = 1,
                       sort_keys: bool = True, newline: bool = True) -> Path:
    """Write a run artifact atomically, 0600, inside a 0700 directory.

    These files are not just counts: the read-back artifact carries the staff reply we would
    quote verbatim, so the file must never exist with umask-derived permissions - not even
    between create and chmod - and the directory that holds it must not be world-traversable.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if str(path.parent) not in ("", "."):
        os.chmod(path.parent, 0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    payload = json.dumps(dict(doc), indent=indent, sort_keys=sort_keys)
    if newline:
        payload += "\n"
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(payload)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


def write_report(doc: Mapping[str, Any], *, state: Path, name: str, day: str | None = None) -> Path:
    """Write ``<state>/reports/<name>-<UTC day>.json`` atomically and return the path."""
    out = state / "reports" / f"{name}-{day or time.strftime('%Y-%m-%d', time.gmtime())}.json"
    return write_private_json(out, doc)


def emit(doc: Mapping[str, Any]) -> None:
    """The machine channel: one JSON document on stdout."""
    print(json.dumps(dict(doc), indent=1, sort_keys=True))


def add_common(parser: argparse.ArgumentParser, *, source: bool = False) -> argparse.ArgumentParser:
    parser.add_argument("--policy", default=None, help="policies/winback-fix.json (default: repo copy)")
    parser.add_argument("--state-dir", default=None, help="state dir (default: /var/lib/hydra/churn)")
    if source:
        parser.add_argument("--source", choices=("sqlite", "json"), default="sqlite",
                            help="read the support-state store (default) or the measured baseline artifact")
        parser.add_argument("--state", default=None, help="support-state.sqlite path")
        parser.add_argument("--candidates", default=None, help="winback-candidates.json (with --source json)")
        parser.add_argument("--churn-days", type=int, default=None, help="window (default: policy windows.churn_days)")
        parser.add_argument("--as-of", type=float, default=None, help="anchor epoch for the window (default: the snapshot's own time)")
    return parser


def readback_config(policy: Mapping[str, Any]) -> dict[str, Any]:
    """``policy.readback``: the attempt budget and the per-run ceiling. Fatal when unusable.

    The schedule lives in the policy file, never as a constant here: the two numbers that decide
    how often a stuck ticket is re-read and how much work an hourly run takes are operational
    dials, and a code literal would read as enforcement while being un-editable.
    """
    cfg = policy.get("readback") or {}
    raw = cfg.get("backoff_hours")
    if not isinstance(raw, list) or not raw:
        raise SystemExit("policy readback.backoff_hours must be a non-empty list of hours per attempt")
    try:
        hours = tuple(float(h) for h in raw)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"policy readback.backoff_hours is not a list of numbers: {exc}") from exc
    if any(h <= 0 for h in hours):
        raise SystemExit("policy readback.backoff_hours must be positive: a zero interval re-reads forever")
    try:
        limit = int(cfg.get("max_per_run") or 0)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"policy readback.max_per_run is not a count: {exc}") from exc
    if limit <= 0:
        raise SystemExit("policy readback.max_per_run must be a positive per-run limit")
    return {"backoff_hours": hours, "max_per_run": limit}


def churn_days(policy: Mapping[str, Any], override: int | None) -> int:
    return int(override or (policy.get("windows") or {}).get("churn_days") or 60)
