#!/usr/bin/env python3
"""risk_reader.py: the ONE reader of the churn-risk file. Every paid-first queue
imports this (or shells out to `order`) instead of parsing the file itself.

What it answers (Fable report 2026-11-03 section 4 item 2, firstmate spec item 3):

    risk-first within paid, renews-soonest first

`sort_key(user_id)` returns a tuple that sorts that way when it is prepended to a
queue's own key, so a consumer change is one sort line and no consumer gains a
write. `order --file <list.json>` does the same for the JSON audience lists other
lanes build (they carry a top-level array of objects with a `user_id`).

Safety posture (this file is read by queues that SEND mail, so it fails open and
never fails loud):

  - the risk file missing, unreadable, malformed, STALE (older than
    thresholds.risk_max_age_hours) or disabled by /etc/hydra/churn-risk.disabled
    means NO override: every queue keeps its own order, which is always safe.
  - an unknown user is never risk. Nothing here can make a queue skip a user;
    the override only moves someone earlier.
  - the policy is re-read on every load, so a threshold move needs no deploy.

CLI:
    risk_reader.py stats                     counts by kind, and whether it applies
    risk_reader.py is-risk <user_id>         exit 0 when risk, 1 when not
    risk_reader.py sort-key <user_id>        the tuple, tab separated
    risk_reader.py json                      {str(user_id): row} as JSON
    risk_reader.py order --file L [--out O] [--array users] [--id-field user_id]
                                             rewrite a JSON audience list risk-first
    risk_reader.py print-config              what this process would read
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

DEFAULT_POLICY = str(Path(__file__).resolve().parents[2] / "policies" / "churn-risk.json")
DEFAULT_KILL = "/etc/hydra/churn-risk.disabled"
DEFAULT_RISK = "/var/lib/hydra/churn/risk.json"
FAR_FUTURE = 9_999_999_999.0
# a publisher's clock can run a few seconds ahead of ours; anything beyond this is a
# broken timestamp, and a future-dated file would otherwise never be called stale.
_FUTURE_TOLERANCE_S = 3600.0


def _shape_error(doc: dict[str, Any]) -> str:
    """"" when the document has the shape risk.py publishes, else why it does not."""
    for key in ("users", "churned"):
        rows = doc.get(key)
        if rows is None:
            continue
        if not isinstance(rows, list):
            return f"{key} is not a list"
        for row in rows:
            if not isinstance(row, dict):
                return f"{key} holds a non-object row"
            if row.get("user_id") in (None, ""):
                return f"a {key} row has no user_id"
    return ""


def _policy_path() -> str:
    return os.environ.get("CHURN_RISK_POLICY", DEFAULT_POLICY)


def load_policy(path: str | None = None) -> tuple[dict[str, Any], str]:
    """(policy, why-not) — an unreadable policy is `({}, reason)`, never an exception."""
    p = path or _policy_path()
    try:
        with open(p, encoding="utf-8") as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict):
            return {}, f"{p} is not a JSON object"
        return doc, ""
    except FileNotFoundError:
        return {}, f"{p} is missing"
    except (OSError, ValueError) as exc:
        return {}, f"{p} is unreadable: {exc}"[:200]


def _iso_ts(value: Any) -> float:
    if value in (None, ""):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value) / (1000.0 if value > 1e11 else 1.0)
    s = str(value).strip().replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return 0.0
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


class Risk:
    """The risk file, decoded, with the policy's thresholds applied."""

    def __init__(self, policy: dict[str, Any] | None = None, *, policy_why: str = "",
                 path: str | None = None, now: float | None = None):
        self.policy = policy
        self.now = now if now is not None else time.time()
        self.source = path or ((policy or {}).get("store") or {}).get("risk") or DEFAULT_RISK
        self.kill_file = (policy or {}).get("kill_file") or DEFAULT_KILL
        self.policy_why = policy_why
        self.enabled = bool(((policy or {}).get("priority") or {}).get("churn_risk", {}).get("enabled", True))
        thresholds = (policy or {}).get("thresholds") or {}
        try:
            self.max_age_h = float(thresholds.get("risk_max_age_hours", 36))
        except (TypeError, ValueError):
            self.max_age_h = 36.0
        try:
            self.churned_days = float(thresholds.get("churned_paid_priority_days", 30))
        except (TypeError, ValueError):
            self.churned_days = 30.0
        self.rows: dict[str, dict[str, Any]] = {}
        self.churned: dict[str, dict[str, Any]] = {}
        self.generated_at: float = 0.0
        self.counts: dict[str, Any] = {}
        self.why: str = ""            # why the override is NOT applied ("" = applied)
        self.load_error: str = ""
        self._load()

    # -- loading -----------------------------------------------------------
    def _load(self) -> None:
        if self.policy_why:
            self.why = f"policy unreadable ({self.policy_why})"
            return
        if not self.enabled:
            self.why = "priority.churn_risk.enabled is false in policies/churn-risk.json"
            return
        if os.path.exists(self.kill_file):
            self.why = f"kill file {self.kill_file} present"
            return
        try:
            with open(self.source, encoding="utf-8") as fh:
                doc = json.load(fh)
            if not isinstance(doc, dict):
                raise ValueError("not a JSON object")
        except FileNotFoundError:
            self.why = f"{self.source} is missing"
            return
        except (OSError, ValueError) as exc:
            self.load_error = f"{self.source} is unreadable: {exc}"[:200]
            self.why = self.load_error
            return
        # a row shape we do not recognise is malformed data, not an empty risk set: the
        # documented contract is that a bad file leaves every queue's order unchanged, so
        # validate BEFORE loading a single row rather than trusting whatever parses.
        shape = _shape_error(doc)
        if shape:
            self.load_error = f"{self.source} is malformed: {shape}"[:200]
            self.why = self.load_error
            return
        self.generated_at = _iso_ts(doc.get("generated_at"))
        if not self.generated_at:
            self.load_error = f"{self.source} has no usable generated_at"
            self.why = self.load_error
            return
        age_h = (self.now - self.generated_at) / 3600.0
        if age_h > self.max_age_h:
            self.why = f"{self.source} is stale ({age_h:.1f}h old, max {self.max_age_h:.0f}h)"
            return
        if age_h < -_FUTURE_TOLERANCE_S / 3600.0:
            self.why = f"{self.source} is dated in the future ({-age_h:.1f}h ahead)"
            return
        self.counts = doc.get("counts") or {}
        for row in doc.get("users") or []:
            self.rows[str(row["user_id"])] = row
        for row in doc.get("churned") or []:
            uid = row.get("user_id")
            if uid is None:
                continue
            self.churned[str(uid)] = row

    # -- queries -----------------------------------------------------------
    def applies(self) -> bool:
        return not self.why

    def is_risk(self, user_id: Any) -> bool:
        return str(user_id) in self.rows

    def row(self, user_id: Any) -> dict[str, Any] | None:
        return self.rows.get(str(user_id))

    def churned_row(self, user_id: Any) -> dict[str, Any] | None:
        r = self.churned.get(str(user_id))
        if not r:
            return None
        at = _iso_ts(r.get("churned_at"))
        if at and (self.now - at) / 86400.0 > self.churned_days:
            return None
        return r

    def paid_priority(self, user_id: Any) -> bool:
        """R4: a paying user with an open issue, and a churned-with-issue user for
        30 d after the cancel, are paid-priority in every queue."""
        return self.is_risk(user_id) or self.churned_row(user_id) is not None

    def renews_in_days(self, user_id: Any) -> float | None:
        row = self.row(user_id) or self.churned_row(user_id) or {}
        ts = _iso_ts(row.get("renews_at"))
        if not ts:
            return None
        return round((ts - self.now) / 86400.0, 2)

    def sort_key(self, user_id: Any) -> tuple[float, float, float]:
        """Prepend to a queue's own key.

        (0, renews_at, -mrr) for a risk user -> ahead of every non-risk user and,
        among them, renews-soonest first (a user with no known renewal date sorts
        after the ones that have one). A churned-with-open-issue user inside the
        30 d window falls back to their churned row, exactly like `lane()` and
        `renews_in_days()`, so R4's paid-priority is real through this API too.
        (1, 0, 0) otherwise, so the queue's own order is untouched and stable.
        """
        row = self.row(user_id) or self.churned_row(user_id)
        if row is None:
            return (1.0, 0.0, 0.0)
        renews = _iso_ts(row.get("renews_at")) or FAR_FUTURE
        try:
            mrr = float(row.get("mrr_list") or 0.0)
        except (TypeError, ValueError):
            mrr = 0.0
        return (0.0, renews, -mrr)

    def lane(self, user_id: Any) -> str | None:
        row = self.row(user_id) or self.churned_row(user_id) or {}
        return row.get("lane")

    def as_map(self) -> dict[str, dict[str, Any]]:
        return dict(self.rows)


_CACHE: dict[str, Any] = {"at": 0.0, "risk": None, "key": None}


def default(*, max_age_s: float = 300.0, policy: dict[str, Any] | None = None,
            path: str | None = None) -> Risk:
    """Process-wide cached reader (a sort of 5,000 rows must not re-read the file).

    The cache lives `max_age_s` (5 min by default): a long-lived process picks up a
    policy change or a fresh file without a restart, and a hot loop does not stat
    the kill file per row.

    A caller that already loaded a policy passes it here (`policy`/`path`): the reader
    must read the SAME file the caller's other paths came from. The 2026-11-04 canary
    caught the alternative - cancel_alert.py loaded its policy, then called
    default() with no arguments, so it read the process default risk path and silently
    ran with "risk file missing, no override" while its own policy named the file.
    """
    now = time.time()
    key = (_src_key(policy), path)
    cached = _CACHE.get("risk")
    if (cached is not None and now - _CACHE["at"] <= max_age_s
            and _CACHE.get("key") == key):
        return cached
    if policy is not None:
        risk = Risk(policy, path=path, policy_why="", now=now)
    else:
        loaded, why = load_policy()
        risk = Risk(loaded, path=path, policy_why=why, now=now)
    _CACHE["risk"], _CACHE["at"], _CACHE["key"] = risk, now, key
    return risk


def _src_key(policy: dict[str, Any] | None) -> Any:
    """A cache key for the policy a caller handed us (identity is enough: callers load once)."""
    return None if policy is None else id(policy)


def reset_cache() -> None:
    _CACHE["risk"], _CACHE["at"], _CACHE["key"] = None, 0.0, None


def order_rows(rows: Iterable[Any], *, id_of=lambda r: r.get("user_id"),
               risk: Risk | None = None) -> list[Any]:
    """Stable risk-first order for any row iterable (rows keep their own order otherwise)."""
    r = risk if risk is not None else default()
    # materialize BEFORE sorting: `sorted()` drains a one-pass iterable, so a key that
    # raises mid-sort would leave the fail-open branch with an empty tail and drop the
    # whole queue (reproduced: three rows in, zero out).
    rows = list(rows)
    try:
        return sorted(rows, key=lambda row: r.sort_key(id_of(row)))
    except Exception:  # noqa: BLE001 - an ordering bug must never drop a queue
        return rows


# -- the audience-list reorder (bash consumers, other lanes' list builders) ----
def _find_array(doc: dict[str, Any], array: str | None) -> tuple[str, list[Any]] | None:
    if array and isinstance(doc.get(array), list):
        return array, doc[array]
    for key, value in doc.items():
        if isinstance(value, list) and value and isinstance(value[0], dict) \
                and ("user_id" in value[0] or "userId" in value[0]):
            return key, value
    return None


def order_document(doc: dict[str, Any], risk: Risk | None = None,
                   array: str | None = None) -> tuple[dict[str, Any], int, str]:
    """Return (new document, n_moved, note). The document's other keys are untouched:
    the audience builders' signing headers hash a SORTED list of per-user facts, so
    a reorder cannot invalidate them (verified for need-asks/owing; see docs)."""
    r = risk if risk is not None else default()
    found = _find_array(doc, array)
    if found is None:
        return doc, 0, "no audience array found; left as built"
    key, rows = found
    if not r.applies():
        return doc, 0, f"no override ({r.why or 'not applicable'})"
    def uid(row: dict[str, Any]) -> Any:
        return row.get("user_id", row.get("userId"))
    ordered = sorted(rows, key=lambda row: r.sort_key(uid(row)))
    moved = sum(1 for a, b in zip(rows, ordered) if a is not b)
    out = dict(doc)
    out[key] = ordered
    return out, moved, f"{moved} entries moved; head={uid(ordered[0]) if ordered else '-'}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="the churn-risk file's one reader")
    ap.add_argument("--policy", default=None, help="policy path (default: the repo's policies/churn-risk.json)")
    ap.add_argument("--risk", default=None, help="risk file path (default: the policy's store.risk)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("stats")
    sub.add_parser("json")
    sub.add_parser("print-config")
    p = sub.add_parser("is-risk"); p.add_argument("user_id")
    p = sub.add_parser("sort-key"); p.add_argument("user_id")
    p = sub.add_parser("order")
    p.add_argument("--file", required=True)
    p.add_argument("--out", default=None, help="write here (default: rewrite --file)")
    p.add_argument("--array", default=None, help="top-level array key (default: auto-detect)")
    args = ap.parse_args(argv)

    policy_path = args.policy or _policy_path()
    policy, why = load_policy(policy_path)
    risk = Risk(policy, policy_why=why, path=args.risk)

    if args.cmd == "stats":
        kinds: dict[str, int] = {}
        for row in risk.rows.values():
            for k in row.get("kind") or []:
                kinds[k] = kinds.get(k, 0) + 1
        print(json.dumps({"applies": risk.applies(), "why": risk.why, "source": risk.source,
                          "generated_at": risk.generated_at, "risk_users": len(risk.rows),
                          "churned": len(risk.churned), "by_kind": kinds,
                          "counts": risk.counts}, indent=1, sort_keys=True))
        return 0
    if args.cmd == "print-config":
        print(json.dumps({"policy": policy_path, "risk": risk.source, "kill_file": risk.kill_file,
                          "applies": risk.applies(), "why": risk.why}, indent=1))
        return 0
    if args.cmd == "json":
        print(json.dumps(risk.as_map(), sort_keys=True))
        return 0
    if args.cmd == "is-risk":
        return 0 if risk.applies() and risk.is_risk(args.user_id) else 1
    if args.cmd == "sort-key":
        print("\t".join(str(x) for x in risk.sort_key(args.user_id)))
        return 0
    if args.cmd == "order":
        try:
            with open(args.file, encoding="utf-8") as fh:
                doc = json.load(fh)
            if not isinstance(doc, dict):
                raise ValueError("not a JSON object")
        except (OSError, ValueError) as exc:
            print(f"risk_reader: cannot order {args.file}: {exc} (left as built)", file=sys.stderr)
            if args.out and args.out != args.file:
                try:
                    with open(args.file, "rb") as src, open(args.out, "wb") as dst:
                        dst.write(src.read())
                except OSError:
                    return 0
            return 0
        out, moved, note = order_document(doc, risk, args.array)
        target = args.out or args.file
        try:
            tmp = target + f".tmp.{os.getpid()}"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(out, fh, separators=(",", ":"))
            os.replace(tmp, target)
        except OSError as exc:
            print(f"risk_reader: cannot write {target}: {exc}", file=sys.stderr)
            return 0
        print(f"risk_reader: {note} -> {target}")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
