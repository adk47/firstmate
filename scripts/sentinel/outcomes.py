"""The 7-day outcome join behind every demotion trigger (§2.3, §2.6, addendum 10-30).

Six sources, joined per capability over a trailing window:

  reverts_7d        ACTION-AUDIT `action_ledger` rows that were REVERTED  (action-audit-ledger-a1)
  manipulated_7d    the same ledger's watcher verdicts == `manipulated`   (action-audit-ledger-a1)
  contradicted_7d   `contra_appr`: decider rows a later trusted source (or a validator decline)
                    contradicted (fraud-lens ARS input)                   (credit_review + A1)
  complaints_7d     Intercom conversations tagged as complaints on that capability's threads
  audit_fails_7d    spot-audit (Fable 2-hourly sample) failures
  overdue_pct       `waiting_on=us` evaluation rows past `due_at`, as % of the day's rows (§2.5)

Two rules this module exists to keep:

1. **A missing source is `unknown`, never zero.** "We could not measure it" is a third
   state (AGENTS.md, codex-quota doctrine). Every adapter returns its own status and
   the digest prints it, so a source that quietly stopped writing cannot look healthy.
2. **Unknown never demotes and never excuses.** A trigger whose source is `unknown`
   cannot fire (we have no evidence), so the row is reported as `UNMEASURED`, not as
   passing. Promotion (report.py:parity) refuses on it.

Read-only by construction: every SQLite handle is opened `mode=ro`, every JSONL is read
with plain open(). This module writes nothing, anywhere.
"""
from __future__ import annotations

import json
import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

WINDOW_DAYS = 7
DAY_HOURS = 24

# Names are the registry's `demotion` keys where the registry names them (§2.3).
COUNTERS = (
    "reverts_7d",
    "manipulated_7d",
    "contradicted_7d",
    "complaints_7d",
    "audit_fails_7d",
)
RATE_COUNTERS = ("overdue_pct",)

# A revert is itself an action row (A1: "reverts are revertible"), so counting every
# row with reverted_at set and not excluding revert rows would let one reverted
# approve + its revert count twice.
REVERT_ACTION_TYPES = {"revert", "action.revert", "credit.revert", "audit.revert", "action_audit.revert"}

DEFAULT_PATHS = {
    "action_ledger_db": "/var/lib/hydra/action-audit/ledger.sqlite",
    "contra_store": "/var/lib/hydra/sentinel/contra-appr.jsonl",
    "decisions_db": "/var/lib/hydra/credit-review/ledger.sqlite3",
    "complaints_store": "/var/lib/hydra/sentinel/complaints.jsonl",
    "spot_audit_store": "/var/lib/hydra/sentinel/spot-audit.jsonl",
    "evaluations_db": "/var/lib/hydra/sentinel/evaluations.sqlite",
}


def utc(ts: Optional[datetime] = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(s: str) -> datetime:
    s = str(s).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


# ── source status ──────────────────────────────────────────────────────────────
@dataclass
class SourceStatus:
    """One source's outcome. `status` is ok | absent | unknown, never a bare number."""

    name: str
    status: str
    detail: str
    path: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {"name": self.name, "status": self.status, "detail": self.detail, "path": self.path}


@dataclass
class Counters:
    """Everything the demote engine may act on, plus what it could not measure."""

    window_start: str
    window_end: str
    per_cap: Dict[str, Dict[str, float]] = field(default_factory=dict)
    unattributed: Dict[str, float] = field(default_factory=dict)
    sources: List[SourceStatus] = field(default_factory=list)
    # capability -> counter -> why it is not measurable
    blind: Dict[str, Dict[str, str]] = field(default_factory=dict)

    def bump(self, cap: Optional[str], counter: str, n: float = 1) -> None:
        if n == 0:
            return
        if cap is None:
            self.unattributed[counter] = self.unattributed.get(counter, 0) + n
            return
        row = self.per_cap.setdefault(cap, {})
        row[counter] = row.get(counter, 0) + n

    def set_value(self, cap: Optional[str], counter: str, v: float) -> None:
        if cap is None:
            self.unattributed[counter] = v
        else:
            self.per_cap.setdefault(cap, {})[counter] = v

    def of(self, cap: str) -> Dict[str, float]:
        return self.per_cap.get(cap, {})

    def source(self, name: str) -> Optional[SourceStatus]:
        for s in self.sources:
            if s.name == name:
                return s
        return None

    def status(self, name: str) -> str:
        s = self.source(name)
        return s.status if s else "unknown"

    def blind_for(self, cap: str) -> Dict[str, str]:
        return self.blind.get(cap, {})


# ── helpers ────────────────────────────────────────────────────────────────────
def _ro(path: str) -> Optional[sqlite3.Connection]:
    if not path or not os.path.exists(path):
        return None
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        conn.row_factory = sqlite3.Row
        return conn
    except sqlite3.Error:
        return None


def _cols(conn: sqlite3.Connection, table: str) -> List[str]:
    try:
        return [str(r[1]) for r in conn.execute(f"PRAGMA table_info({table})")]
    except sqlite3.Error:
        return []


def _tables(conn: sqlite3.Connection) -> List[str]:
    try:
        return [str(r[0]) for r in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")]
    except sqlite3.Error:
        return []


def _pick(cols: Iterable[str], *names: str) -> Optional[str]:
    have = {c.lower(): c for c in cols}
    for n in names:
        if n.lower() in have:
            return have[n.lower()]
    return None


def _within(value: Any, start: datetime, end: datetime) -> bool:
    """Window membership that survives the three timestamp shapes we actually store."""
    if value is None:
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            dt = datetime.fromtimestamp(float(value), timezone.utc)
        except (OverflowError, OSError, ValueError):
            return False
        return start <= dt <= end
    text = str(value).strip()
    if not text:
        return False
    try:
        return start <= parse_utc(text) <= end
    except ValueError:
        return False


def _is_timestamp(value: Any) -> bool:
    """Whether a reversal column holds a TIME rather than a boolean/actor marker."""
    if isinstance(value, bool) or value is None:
        return False
    if isinstance(value, (int, float)):
        return value > 1e8  # a unix timestamp, not a 0/1 flag
    text = str(value).strip()
    if not text:
        return False
    try:
        parse_utc(text)
        return True
    except ValueError:
        return False


def _read_jsonl(path: str) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    """(rows, error). A missing file is the caller's `absent`, not an error.

    A malformed line is an ERROR, not a skipped line. Dropping bad JSON used to turn a
    corrupted `spot-audit.jsonl` failure row into `([], None)`, i.e. a source that is
    `ok` with ZERO failures — so `audit_fail_any` did not demote and promotion saw no
    blind trigger. "I could not read the evidence" must never render as "the evidence
    says fine": that is the one direction this whole system must not fail in.

    The single tolerated case is a TORN FINAL LINE: a writer appending without a
    trailing newline can leave a partial record, and that record was never durably
    written. It is tolerated only when it is the last line AND the file does not end
    with a newline; anything else is corruption and is reported.
    """
    p = Path(path)
    if not p.exists():
        return [], None
    rows: List[Dict[str, Any]] = []
    bad: List[int] = []
    try:
        with p.open("r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        return [], f"{exc}"
    lines = raw.split("\n")
    torn_tail = bool(lines) and lines[-1] != "" and not raw.endswith("\n")
    for ln, line in enumerate(lines, 1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            if torn_tail and ln == len(lines):
                continue  # partial final write, never durably committed
            bad.append(ln)
            continue
        if isinstance(obj, dict):
            rows.append(obj)
        else:
            bad.append(ln)
    if bad:
        shown = ", ".join(str(n) for n in bad[:5]) + (" …" if len(bad) > 5 else "")
        return [], (f"{len(bad)} malformed record(s) at line(s) {shown} — refusing to report "
                    "this source as healthy with the unreadable rows dropped")
    return rows, None


# ── source 1+2: ACTION-AUDIT ledger (reverts) and its watcher verdicts ─────────
def action_ledger(c: Counters, path: str, attribution: Dict[str, List[str]],
                  start: datetime, end: datetime) -> None:
    """Both sources that live in the ACTION-AUDIT store: reverts, and watcher verdicts.

    They are collected INDEPENDENTLY. The revert ledger used to return early when the
    `action_ledger` table was absent or lacked a time/reverted column, which also skipped
    `_watcher_verdicts` — so a store carrying a fresh `manipulated` verdict in
    `audit_verdicts` but no usable ledger recorded no `manipulated_7d` at all, and the
    strongest manipulation signal could not demote anything. A missing revert table is a
    fact about reverts, never about verdicts.
    """
    try:
        _revert_ledger(c, path, attribution, start, end)
    finally:
        _watcher_verdicts(c, path, attribution, start, end)


def _revert_ledger(c: Counters, path: str, attribution: Dict[str, List[str]],
                   start: datetime, end: datetime) -> None:
    name = "action_ledger"
    conn = _ro(path)
    if conn is None:
        c.sources.append(SourceStatus(name, "absent", "ACTION-AUDIT ledger not present (action-audit-ledger-a1 not deployed)", path))
        return
    try:
        tables = _tables(conn)
        if "action_ledger" not in tables:
            c.sources.append(SourceStatus(name, "unknown", f"ledger db has no action_ledger table (has: {', '.join(sorted(tables)) or 'nothing'})", path))
            return
        cols = _cols(conn, "action_ledger")
        at_c = _pick(cols, "at", "created_at", "ts", "timestamp", "occurred_at")
        rev_c = _pick(cols, "reverted_at", "reverted_by", "reverted")
        typ_c = _pick(cols, "action_type", "type", "action")
        cap_c = _pick(cols, "capability_id", "capability")
        if at_c is None or rev_c is None:
            c.sources.append(SourceStatus(name, "unknown", f"action_ledger lacks a time/reverted column (has: {', '.join(cols)})", path))
            return
        select = f"SELECT {at_c} AS at, {rev_c} AS reverted, {typ_c + ' AS action_type' if typ_c else 'NULL AS action_type'}, {cap_c + ' AS capability_id' if cap_c else 'NULL AS capability_id'} FROM action_ledger"
        reverts: Dict[Optional[str], int] = {}
        for row in conn.execute(select):
            if row["reverted"] in (None, "", 0, False):
                continue
            # Window on WHEN IT WAS REVERTED, not when the action was created. An action
            # from 30 days ago reverted yesterday is a revert this week; filtering on
            # `at` dropped it, so a capability could revert every day and read as zero.
            # A reversal column that holds a flag/actor name (not a time) can only be
            # windowed on creation.
            when = row["reverted"] if _is_timestamp(row["reverted"]) else row["at"]
            if not _within(when, start, end):
                continue
            cap = str(row["capability_id"]) if row["capability_id"] else None
            kind = str(row["action_type"] or "").strip().lower()
            # A revert row is the OTHER half of a reverted action, so counting it doubles
            # every revert (and a reverted revert triples it) — enough to demote a healthy
            # capability on a threshold. Excluded whether or not it carries an attribution.
            if kind in REVERT_ACTION_TYPES:
                continue
            if not cap and kind:
                claimants = attribution.get(kind) or []
                cap = claimants[0] if len(claimants) == 1 else None
            reverts[cap] = reverts.get(cap, 0) + 1
        for cap, n in reverts.items():
            c.bump(cap, "reverts_7d", n)
        c.sources.append(SourceStatus(name, "ok", f"{sum(reverts.values())} reverted action rows in window", path))
    finally:
        conn.close()


def _watcher_verdicts(c: Counters, path: str, attribution: Dict[str, List[str]],
                      start: datetime, end: datetime) -> None:
    name = "watcher_verdicts"
    conn = _ro(path)
    if conn is None:
        c.sources.append(SourceStatus(name, "absent", "no ACTION-AUDIT store for watcher verdicts", path))
        return
    try:
        tables = _tables(conn)
        hits: Dict[Optional[str], int] = {}
        found = False
        if "audit_verdicts" in tables:
            cols = _cols(conn, "audit_verdicts")
            at_c = _pick(cols, "at", "created_at", "ts")
            ver_c = _pick(cols, "verdict")
            cap_c = _pick(cols, "capability_id", "capability")
            typ_c = _pick(cols, "action_type", "type", "action")
            if at_c and ver_c:
                found = True
                sql = f"SELECT {at_c} AS at, {ver_c} AS verdict, {cap_c + ' AS capability_id' if cap_c else 'NULL AS capability_id'}, {typ_c + ' AS action_type' if typ_c else 'NULL AS action_type'} FROM audit_verdicts"
                for row in conn.execute(sql):
                    if not _within(row["at"], start, end):
                        continue
                    if str(row["verdict"] or "").strip().lower() != "manipulated":
                        continue
                    cap = str(row["capability_id"]) if row["capability_id"] else None
                    if not cap:
                        claimants = attribution.get(str(row["action_type"] or "").strip().lower()) or []
                        cap = claimants[0] if len(claimants) == 1 else None
                    hits[cap] = hits.get(cap, 0) + 1
        elif "action_ledger" in tables:
            cols = _cols(conn, "action_ledger")
            at_c = _pick(cols, "at", "created_at", "ts")
            ver_c = _pick(cols, "watcher_verdict", "verdict")
            cap_c = _pick(cols, "capability_id", "capability")
            typ_c = _pick(cols, "action_type", "type", "action")
            if at_c and ver_c:
                found = True
                sql = f"SELECT {at_c} AS at, {ver_c} AS verdict, {cap_c + ' AS capability_id' if cap_c else 'NULL AS capability_id'}, {typ_c + ' AS action_type' if typ_c else 'NULL AS action_type'} FROM action_ledger"
                for row in conn.execute(sql):
                    if not _within(row["at"], start, end):
                        continue
                    if str(row["verdict"] or "").strip().lower() != "manipulated":
                        continue
                    cap = str(row["capability_id"]) if row["capability_id"] else None
                    if not cap:
                        claimants = attribution.get(str(row["action_type"] or "").strip().lower()) or []
                        cap = claimants[0] if len(claimants) == 1 else None
                    hits[cap] = hits.get(cap, 0) + 1
        if not found:
            c.sources.append(SourceStatus(name, "unknown", "no audit_verdicts table and no verdict column on action_ledger", path))
            return
        for cap, n in hits.items():
            c.bump(cap, "manipulated_7d", n)
        c.sources.append(SourceStatus(name, "ok", f"{sum(hits.values())} manipulated verdicts in window", path))
    finally:
        conn.close()


# ── source 3: contradicted decider rows (contra_appr) ──────────────────────────
def contradicted(c: Counters, contra_store: str, decisions_db: str,
                 attribution: Dict[str, List[str]], start: datetime, end: datetime) -> None:
    name = "contra_appr"
    rows, err = _read_jsonl(contra_store)
    if err is not None:
        c.sources.append(SourceStatus(name, "unknown", f"unreadable contra store: {err}", contra_store))
        return
    if Path(contra_store).exists():
        hits: Dict[Optional[str], int] = {}
        for row in rows:
            if not _within(row.get("at") or row.get("ts"), start, end):
                continue
            cap = row.get("capability_id")
            cap = str(cap) if cap else None
            if not cap:
                for key in ("action_type", "intercom_tag"):
                    claimants = attribution.get(str(row.get(key) or "").strip().lower()) or []
                    if len(claimants) == 1:
                        cap = claimants[0]
                        break
            hits[cap] = hits.get(cap, 0) + 1
        for cap, n in hits.items():
            c.bump(cap, "contradicted_7d", n)
        c.sources.append(SourceStatus(name, "ok", f"{sum(hits.values())} contradicted rows in window", contra_store))
        return
    # No dedicated store: derive it from the decider ledger we DO have, and say so.
    conn = _ro(decisions_db)
    if conn is None:
        c.sources.append(SourceStatus(name, "absent", "no contra_appr store and no decisions ledger", contra_store))
        return
    try:
        tables = _tables(conn)
        if "decisions" not in tables:
            c.sources.append(SourceStatus(name, "unknown", "decisions ledger has no decisions table", decisions_db))
            return
        cols = _cols(conn, "decisions")
        at_c = _pick(cols, "decided_at", "at")
        dec_c = _pick(cols, "decision")
        n1_c = _pick(cols, "n1")
        if not (at_c and dec_c and n1_c):
            c.sources.append(SourceStatus(name, "unknown", f"decisions lacks decided_at/decision/n1 (has: {', '.join(cols)})", decisions_db))
            return
        n = 0
        for row in conn.execute(f"SELECT {at_c} AS at, {dec_c} AS decision, {n1_c} AS n1 FROM decisions"):
            if not _within(row["at"], start, end):
                continue
            if str(row["decision"] or "").lower() not in ("approve", "support"):
                continue
            if int(row["n1"] or 0) < 1:
                continue
            n += 1
        # Calls we acted on and a trusted source later contradicted: attributed by
        # the registry row that CLAIMS the credit-approve action type, never guessed.
        cap = None
        for key in ("credit.approve", "credit.approve.decide"):
            claimants = attribution.get(key) or []
            if len(claimants) == 1:
                cap = claimants[0]
                break
        c.bump(cap, "contradicted_7d", n)
        declines = 0
        if "decision_outcomes" in tables:
            ocols = _cols(conn, "decision_outcomes")
            oat = _pick(ocols, "at", "created_at")
            oout = _pick(ocols, "outcome", "result")
            if oat and oout:
                for row in conn.execute(f"SELECT {oat} AS at, {oout} AS outcome FROM decision_outcomes"):
                    if not _within(row["at"], start, end):
                        continue
                    if "declin" in str(row["outcome"] or "").lower():
                        declines += 1
                c.bump(cap, "contradicted_7d", declines)
        detail = f"{n} contradicted approvals (n1>=1) + {declines} validator declines; derived from {decisions_db} (no contra_appr store)"
        c.sources.append(SourceStatus(name, "ok", detail, decisions_db))
    finally:
        conn.close()


# ── source 4: Intercom complaints ──────────────────────────────────────────────
def complaints(c: Counters, path: str, attribution: Dict[str, List[str]],
               start: datetime, end: datetime) -> None:
    name = "complaints"
    rows, err = _read_jsonl(path)
    if err is not None:
        c.sources.append(SourceStatus(name, "unknown", f"unreadable complaints store: {err}", path))
        return
    if not Path(path).exists():
        c.sources.append(SourceStatus(name, "absent", "no complaint store; complaint trigger cannot fire", path))
        return
    seen: set = set()
    hits: Dict[Optional[str], int] = {}
    for row in rows:
        if not _within(row.get("at") or row.get("ts") or row.get("tagged_at"), start, end):
            continue
        conv = row.get("conv_id") or row.get("conversation_id") or row.get("id")
        dedupe = f"{conv}:{row.get('reason') or ''}"
        if conv and dedupe in seen:
            continue
        seen.add(dedupe)
        cap = row.get("capability_id")
        cap = str(cap) if cap else None
        if not cap:
            for key in ("intercom_tag", "tag", "action_type"):
                claimants = attribution.get(str(row.get(key) or "").strip().lower()) or []
                if len(claimants) == 1:
                    cap = claimants[0]
                    break
        hits[cap] = hits.get(cap, 0) + 1
    for cap, n in hits.items():
        c.bump(cap, "complaints_7d", n)
    c.sources.append(SourceStatus(name, "ok", f"{sum(hits.values())} complaint rows in window", path))


# ── source 5: spot-audit (Fable 2-hourly sample) ───────────────────────────────
def spot_audit(c: Counters, path: str, attribution: Dict[str, List[str]],
               start: datetime, end: datetime) -> None:
    name = "spot_audit"
    rows, err = _read_jsonl(path)
    if err is not None:
        c.sources.append(SourceStatus(name, "unknown", f"unreadable spot-audit store: {err}", path))
        return
    if not Path(path).exists():
        c.sources.append(SourceStatus(name, "absent", "no spot-audit store; sample trigger cannot fire", path))
        return
    hits: Dict[Optional[str], int] = {}
    sampled = 0
    for row in rows:
        if not _within(row.get("at") or row.get("ts"), start, end):
            continue
        sampled += 1
        if row.get("ok") is not False and str(row.get("verdict") or "").lower() not in ("fail", "failed", "mismatch"):
            continue
        cap = row.get("capability_id")
        cap = str(cap) if cap else None
        if not cap:
            claimants = attribution.get(str(row.get("action_type") or "").strip().lower()) or []
            cap = claimants[0] if len(claimants) == 1 else None
        hits[cap] = hits.get(cap, 0) + 1
    for cap, n in hits.items():
        c.bump(cap, "audit_fails_7d", n)
    c.sources.append(SourceStatus(name, "ok", f"{sum(hits.values())} fails of {sampled} sampled rows", path))


# ── source 6: waiting_on=us past due_at (§2.5, addendum 10-30) ─────────────────
def overdue(c: Counters, path: str, now: datetime) -> None:
    name = "evaluations"
    conn = _ro(path)
    if conn is None:
        c.sources.append(SourceStatus(name, "absent", "no sentinel evaluation store (sentinel-core-s0 not deployed)", path))
        return
    try:
        tables = _tables(conn)
        table = "sentinel_evaluations" if "sentinel_evaluations" in tables else ("evaluations" if "evaluations" in tables else None)
        if table is None:
            c.sources.append(SourceStatus(name, "unknown", f"no evaluations table (has: {', '.join(sorted(tables)) or 'nothing'})", path))
            return
        cols = _cols(conn, table)
        at_c = _pick(cols, "at", "created_at", "ts")
        wo_c = _pick(cols, "waiting_on")
        due_c = _pick(cols, "due_at")
        cap_c = _pick(cols, "capability_id", "capability")
        if at_c is None or wo_c is None or due_c is None:
            c.sources.append(SourceStatus(name, "unknown", f"{table} lacks at/waiting_on/due_at (has: {', '.join(cols)})", path))
            return
        if cap_c is None:
            # Without a capability column an overdue row cannot be attributed to anybody,
            # so every capability's `overdue_pct` trigger is unable to fire. Reporting
            # "ok" here would render an unmeasurable trigger as a measured, quiet one.
            c.sources.append(SourceStatus(
                name, "unknown",
                f"{table} has no capability_id/capability column, so an overdue row cannot "
                f"be attributed: overdue_pct is UNMEASURED, not zero (has: {', '.join(cols)})",
                path))
            return
        day_start = now - timedelta(hours=DAY_HOURS)
        totals: Dict[Optional[str], int] = {}
        late: Dict[Optional[str], int] = {}
        sql = f"SELECT {at_c} AS at, {wo_c} AS waiting_on, {due_c} AS due_at, {cap_c + ' AS capability_id' if cap_c else 'NULL AS capability_id'} FROM {table}"
        for row in conn.execute(sql):
            if not _within(row["at"], day_start, now):
                continue
            if str(row["waiting_on"] or "").strip().lower() != "us":
                cap = (str(row["capability_id"]) if row["capability_id"] else None)
                if cap:
                    totals[cap] = totals.get(cap, 0) + 1
                continue
            cap = (str(row["capability_id"]) if row["capability_id"] else None)
            totals[cap] = totals.get(cap, 0) + 1
            if row["due_at"] is None:
                continue
            if _within(row["due_at"], datetime(1970, 1, 1, tzinfo=timezone.utc), now):
                late[cap] = late.get(cap, 0) + 1
        for cap, total in totals.items():
            n_late = late.get(cap, 0)
            c.set_value(cap, "overdue_rows", float(n_late))
            c.set_value(cap, "day_rows", float(total))
        c.sources.append(SourceStatus(
            name, "ok",
            f"{sum(late.values())} of {sum(totals.values())} us-waiting evaluations past due_at in the last 24h",
            path,
        ))
    finally:
        conn.close()


# ── the join ───────────────────────────────────────────────────────────────────
def collect(*, paths: Optional[Dict[str, str]] = None,
            attribution: Optional[Dict[str, List[str]]] = None,
            now: Optional[datetime] = None,
            window_days: int = WINDOW_DAYS) -> Counters:
    """Join every source over the trailing window. Never raises on a bad source."""
    now = now or datetime.now(timezone.utc)
    start = now - timedelta(days=window_days)
    p = dict(DEFAULT_PATHS)
    for k, v in dict(paths or {}).items():
        if v is None:
            p.pop(k, None)
        else:
            p[k] = v
    c = Counters(window_start=utc(start), window_end=utc(now))
    attr = attribution or {}

    def guard(name: str, fn, *args, **kwargs) -> None:
        """A source that raises is `unknown`, with the exception text kept — a dead
        source must never take the whole tick (and every other trigger) down."""
        try:
            fn(*args, **kwargs)
        except Exception as exc:  # noqa: BLE001 — deliberately broad, see docstring
            c.sources.append(SourceStatus(name, "unknown", f"{type(exc).__name__}: {exc}"))

    if "action_ledger_db" in p:
        guard("action_ledger", action_ledger, c, p["action_ledger_db"], attr, start, now)
    if "contra_store" in p or "decisions_db" in p:
        guard("contra_appr", contradicted, c, p.get("contra_store", ""), p.get("decisions_db", ""), attr, start, now)
    if "complaints_store" in p:
        guard("complaints", complaints, c, p["complaints_store"], attr, start, now)
    if "spot_audit_store" in p:
        guard("spot_audit", spot_audit, c, p["spot_audit_store"], attr, start, now)
    if "evaluations_db" in p:
        guard("evaluations", overdue, c, p["evaluations_db"], now)
    return c


def blind_counters(rows: Iterable[Dict[str, Any]], counters: Counters) -> None:
    """Record, per capability, which of ITS OWN declared triggers could not be measured.

    A trigger the row does not declare is not "blind" — it simply cannot fire. This
    is what the digest prints as UNMEASURED and what promotion refuses on.
    """
    # Mirrors _rule_hits in demote.py EXACTLY: a rule that can fire must be the rule
    # that is reported unmeasured. A rule the row does not declare is not blind — it
    # simply cannot fire.
    wanted = {
        "reverts_7d": ("action_ledger",),
        "manipulated_7d": ("watcher_verdicts",),
        "contradicted_7d": ("contra_appr",),
        "complaints_7d": ("complaints",),
        "audit_fails_7d": ("spot_audit",),
        "audit_fail_any": ("watcher_verdicts", "spot_audit"),
        "overdue_pct": ("evaluations",),
    }
    for row in rows:
        cap = str(row["id"])
        demotion = row.get("demotion") or {}
        for rule, sources in wanted.items():
            if rule not in demotion:
                continue
            for src in sources:
                st = counters.status(src)
                if st != "ok":
                    detail = (counters.source(src).detail if counters.source(src) else "never collected")
                    counters.blind.setdefault(cap, {})[f"{rule}:{src}"] = f"{rule} needs {src} → {st}: {detail}"
                    break
