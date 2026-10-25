"""Provisional-credit tracker + the day-N close (L7) + watchdog ``backup_ask_undelivered``.

Captain 2026-10-23 20:03Z / 20:04Z / 20:07Z (Fable backup-threshold-ruling-1023.md §6): every
PROVISIONAL credit gets **7 days from the DELIVERED backup ask** to send documents, else it goes to
removal through the removal gate. "Keep track of these somewhere": the tracker is the credit row
itself (core ``metadata.approval``: provisional, anchor kind, proofDueAt, ...) plus this daily read.

Read-only. Inputs:
  * core replica (Trino): every APPROVED credit request whose ``metadata.approval.provisional`` is
    true (id, user, profile, track, title, popularity, approval record);
  * hydra's verify ledger (``verify_messages``, status=sent): the first DELIVERED note listing the
    request starts its clock (``created_at`` of that send);
  * proof-on-file (``/var/lib/credit-trust/proof-on-file.json``): a document for that request (or a
    whole-user entry) = backup on file.

Per row it computes ``state``:
  backup_on_file   a document for THIS request   -> day-N outcome: plain approve (a core write, not here)
  user_documented  a whole-user document only    -> never asked (documented user); day N = the stage-2
                                                    document checker decides, not this clock
  no_ask_yet       no delivered ask              -> watchdog backup_ask_undelivered after 48 h
  clock_running    delivered, due in N days      -> board "due in N days"
  due              day N reached, no docs        -> day-N close: live Spotify AND Tidal check first
                                                    (DSP credits them = backup, keep), else the
                                                    REMOVAL GATE (held_for_ops until the live readers
                                                    and the core gate exist). This module never writes.
It also reports core's stored proofDueAt where it differs from delivered + N days (core stamps
approval + 30 d today; the clock must start at the delivered ask).
"""
from __future__ import annotations

import csv
import io
import json
import os
import sqlite3
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

TRINO = "/opt/hydra/scripts/trino-query.sh"
WINDOW_DAYS = 7                 # captain 2026-10-23 20:07Z ("i think 30 is too long")
UNDELIVERED_AFTER_H = 48        # Fable §6: watchdog class backup_ask_undelivered
DUE_SOON_DAYS = 2
REMINDER_DAY = 4                # Fable §7: one ask on delivery + one reminder on day 4, no other notice
# Only a note that ASKS for backup on an approved credit starts its clock. Status notes ("we got
# your document", "your request is under review") and pre-approval UVN reminders do not.
ASK_CAMPAIGNS = ("backup-ask", "verify-live")

Query = Callable[[str], str]


def trino_csv(sql: str) -> str:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=600, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"trino rc={p.returncode}: {p.stderr.strip()[-200:]}")
    return p.stdout


def _ts(s: Any) -> datetime | None:
    s = str(s or "").replace(" UTC", "").replace("Z", "").replace("T", " ").strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s[:26]).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def provisional_rows(query: Query = trino_csv) -> list[dict[str, Any]]:
    text = query(
        "SELECT cast(id AS varchar), cast(userid AS varchar), cast(profileid AS varchar), cast(trackid AS varchar), "
        "coalesce(spotifytracktitle, ''), coalesce(cast(spotifypopularity AS varchar), ''), "
        "json_format(json_extract(metadata, '$.approval')) FROM postgresql_core.public.credit_requests "
        "WHERE deletedat IS NULL AND status = 'approved' "
        "AND json_extract_scalar(metadata, '$.approval.provisional') = 'true'")
    out = []
    for r in csv.reader(io.StringIO(text)):
        if len(r) != 7 or len(r[0]) != 36:
            continue
        try:
            appr = json.loads(r[6]) if r[6] else {}
        except ValueError:
            appr = {}
        out.append({"request_id": r[0].lower(), "user_id": int(r[1]) if r[1].isdigit() else None,
                    "profile_id": r[2], "track_id": r[3], "title": r[4],
                    "popularity": int(r[5]) if r[5].lstrip("-").isdigit() else None, "approval": appr})
    return out


def delivered_asks(db: sqlite3.Connection) -> dict[str, tuple[str, str]]:
    """{request id (lower): (first delivered send time, campaign)} from verify_messages (status sent).
    QA @1349: the clock starts at the actual send, never the claim. ``sent_at`` is the immutable time
    the note was finalized 'sent'; a row sent before that column existed falls back to updated_at,
    which is never earlier than its send (finalize stamps it; later touches only move it later), so a
    clock can start late but never early."""
    cols = {r[1] for r in db.execute("PRAGMA table_info(verify_messages)")}
    when = "COALESCE(sent_at, updated_at)" if "sent_at" in cols else "updated_at"
    out: dict[str, tuple[str, str]] = {}
    for created, campaign, ids in db.execute(
            f"SELECT {when}, campaign, request_ids_json FROM verify_messages WHERE status = 'sent' "
            f"AND campaign IN ({','.join(repr(c) for c in ASK_CAMPAIGNS)}) ORDER BY 1"):
        try:
            rids = json.loads(ids or "[]")
        except ValueError:
            continue
        for rid in rids if isinstance(rids, list) else []:
            out.setdefault(str(rid).lower(), (created, campaign))
    return out


def documents(path: str, now: datetime | None = None) -> tuple[set[str], set[int]]:
    """(request ids with a document, user ids with a whole-user document entry), read through the
    shared proof-on-file contract (verify_notify.load_proof_on_file: freshness, every required part
    present and fresh, every entry well-formed). QA @1349: a stale or partial export would otherwise
    read as 'no backup' and publish a day-7 removal route for a credit whose backup is on file, so a
    non-authoritative export raises (the tracker reports an error, never a due list)."""
    from .verify_notify import ProofFileError, load_proof_on_file
    try:
        pof = load_proof_on_file(path, now=now)
    except ProofFileError as exc:
        raise ValueError(str(exc)) from exc
    rids, users = set(), set()
    for uid, entries in pof.items():
        for rid, _kind in entries:
            if rid:
                rids.add(str(rid).lower())
            elif str(uid).isdigit():
                users.add(int(uid))
    return rids, users


def bucket(state: str, delivered: datetime | None, due: datetime | None, now: datetime) -> str | None:
    """Fable §7 daily list buckets: due_in_7 / due_in_3 / due_today / overdue (by whole days left)."""
    if state not in ("clock_running", "due") or due is None:
        return None
    left = (due - now).total_seconds() / 86400
    if left < 0:
        return "overdue" if left <= -1 else "due_today"
    if left < 1:
        return "due_today"
    if left <= 3:
        return "due_in_3"
    return "due_in_7"


# node-8 is not in-cluster: the public board host (in-cluster: http://credit-trust-board.monitoring.svc/...)
BOARD_URL = os.environ.get("CREDIT_TRUST_BOARD_INGEST_URL", "https://credit-trust.ak.muso.ai/api/ingest/provisional")
BOARD_ENV = "/etc/hydra/credit-trust-board.env"   # INGEST_TOKEN= (Vault secret/k8s/monitoring/credit-trust-board ingest_token)
BOARD_BUCKETS = ("overdue", "today", "d1_3", "d4_7", "later", "no_due")


def _board_bucket(r: dict, now: datetime) -> str:
    if not r.get("due_at"):
        return "no_due"
    left = (_ts(r["due_at"]) - now).total_seconds() / 86400
    if left < 0:
        return "overdue" if left <= -1 else "today"
    if left < 1:
        return "today"
    if left <= 3:
        return "d1_3"
    if left <= 7:
        return "d4_7"
    return "later"


def board_payload(t: "Tracker", now: datetime, source: str = "hydra credit-review provisional-tracker") -> dict:
    """The board's POST /api/ingest/provisional contract (credit-trust-board-t03, firstmate 200): one entry
    per user (earliest due wins), every bucket key present. Documented users are 'received'; a request-level
    document is 'received' too until the stage-2 checker marks it genuine ('verified' is not ours to say)."""
    order = {b: i for i, b in enumerate(BOARD_BUCKETS)}
    users: dict = {}
    for r in t.rows:
        # QA @1349: only OUTSTANDING credits (clock running or due) carry a due bucket; a resolved one
        # (backup on file / documented user) never makes its user look overdue.
        outstanding = r["state"] in ("clock_running", "due")
        b = _board_bucket(r, now) if outstanding else "no_due"
        u = users.setdefault(r["user_id"], {"user_id": r["user_id"], "paid": bool(r["paid"]), "credits": 0,
                                           "bucket": b, "earliest_due": None, "ask_delivered_at": None,
                                           "documents": "none", "live_check": "not_run", "reasons": []})
        u["credits"] += 1
        if order[b] < order[u["bucket"]]:
            u["bucket"] = b
        if outstanding and r.get("due_at") and (u["earliest_due"] is None or r["due_at"] < u["earliest_due"]):
            u["earliest_due"] = r["due_at"]
        if r.get("ask_delivered_at") and (u["ask_delivered_at"] is None or r["ask_delivered_at"] < u["ask_delivered_at"]):
            u["ask_delivered_at"] = r["ask_delivered_at"]
        if r["state"] in ("backup_on_file", "user_documented"):
            u["documents"] = "received"
        reason = r.get("provisional_by")
        if reason and reason not in u["reasons"]:
            u["reasons"].append(str(reason)[:80])
    lst = sorted(users.values(), key=lambda u: (not u["paid"], order[u["bucket"]], u["earliest_due"] or "~"))[:5000]
    counts = {b: 0 for b in BOARD_BUCKETS}
    for u in lst:
        counts[u["bucket"]] += 1
    return {"as_of": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "source": source, "window_days": t.window_days,
            "buckets": counts, "users": lst}


def post_board(payload: dict, token: str, url: str = BOARD_URL, opener=None,
               gate_token: str | None = None) -> tuple[bool, str]:
    """The public host sits behind the board's agent gate (X-Credit-Trust-Token, the digest's agent
    token); the ingest route then checks its own X-Credit-Trust-Ingest-Token."""
    import urllib.request
    import urllib.error
    headers = {"Content-Type": "application/json", "X-Credit-Trust-Ingest-Token": token}
    if gate_token:
        headers["X-Credit-Trust-Token"] = gate_token
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST", headers=headers)
    try:
        with (opener or urllib.request.urlopen)(req, timeout=30) as resp:
            return 200 <= resp.status < 300, f"HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:  # noqa: BLE001 - a delivery failure is reported, never raised
        return False, type(e).__name__


def board_token(path: str = BOARD_ENV, key: str = "INGEST_TOKEN") -> str | None:
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if line.strip().startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'") or None
    except OSError:
        return None
    return None


@dataclass
class Tracker:
    at: str
    window_days: int
    rows: list = field(default_factory=list)
    error: str | None = None

    def counts(self) -> dict[str, int]:
        c: dict[str, int] = {}
        for r in self.rows:
            c[r["state"]] = c.get(r["state"], 0) + 1
        return c

    def undelivered(self) -> list[dict]:
        return [r for r in self.rows if r["state"] == "no_ask_yet" and r["hours_since_approval"] is not None
                and r["hours_since_approval"] > UNDELIVERED_AFTER_H]

    def findings(self) -> list[str]:
        if self.error:
            return [f"provisional tracker could not run ({self.error})"]
        c = self.counts()
        out = [f"PROVISIONAL CREDITS {len(self.rows)}: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items()))
               + f" ({self.window_days}-day window from the delivered ask)"]
        due = [r for r in self.rows if r["state"] == "due"]
        soon = [r for r in self.rows if r["state"] == "clock_running" and r["days_left"] <= DUE_SOON_DAYS]
        if due:
            out.append(f"DUE (day {self.window_days} reached, no backup): {len(due)} -> live Spotify+Tidal check, "
                       "else removal gate (nothing is removed until the live readers + gate exist)")
        if soon:
            out.append(f"due within {DUE_SOON_DAYS} days: {len(soon)}")
        und = self.undelivered()
        if und:
            out.append(f"backup_ask_undelivered: {len(und)} provisional credits ({len({r['user_id'] for r in und})} "
                       f"users) have no delivered ask after {UNDELIVERED_AFTER_H} h")
        b: dict[str, int] = {}
        for r in self.rows:
            if r.get("bucket"):
                b[r["bucket"]] = b.get(r["bucket"], 0) + 1
        if b:
            out.append("buckets: " + ", ".join(f"{k} {b[k]}" for k in ("due_in_7", "due_in_3", "due_today", "overdue") if k in b))
        rem = sum(1 for r in self.rows if r.get("reminder_due"))
        if rem:
            out.append(f"day-{REMINDER_DAY} reminder due: {rem} credits")
        mism = sum(1 for r in self.rows if r.get("core_due_mismatch"))
        if mism:
            out.append(f"core proofDueAt differs from delivered + {self.window_days} d on {mism} rows (core stamps from approval)")
        return out


def run(query: Query = trino_csv, *, ledger: sqlite3.Connection, proof_path: str,
        paying: set[int] | None = None, now: datetime | None = None, window_days: int = WINDOW_DAYS) -> Tracker:
    now = now or datetime.now(timezone.utc)
    t = Tracker(at=now.strftime("%Y-%m-%dT%H:%MZ"), window_days=window_days)
    try:
        rows = provisional_rows(query)
        asks = delivered_asks(ledger)
        doc_rids, doc_users = documents(proof_path, now=now)
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError, sqlite3.Error) as exc:
        t.error = str(exc)[:200]
        return t
    for r in rows:
        appr = r.pop("approval")
        approved_at = _ts(appr.get("provisionalAt") or appr.get("at"))
        ask = asks.get(r["request_id"])
        delivered = _ts(ask[0]) if ask else None
        due = delivered + timedelta(days=window_days) if delivered else None
        core_due = _ts(appr.get("proofDueAt"))
        if r["request_id"] in doc_rids:
            state = "backup_on_file"
        elif r["user_id"] in doc_users:
            state = "user_documented"
        elif delivered is None:
            state = "no_ask_yet"
        elif now >= due:
            state = "due"
        else:
            state = "clock_running"
        r.update({
            "state": state, "paid": bool(paying and r["user_id"] in paying),
            "anchor_kind": appr.get("anchor_kind") or appr.get("anchorKind"),
            "provisional_by": appr.get("provisionalBy") or appr.get("automationId") or appr.get("via"),
            "approved_at": approved_at.strftime("%Y-%m-%dT%H:%MZ") if approved_at else None,
            "hours_since_approval": round((now - approved_at).total_seconds() / 3600, 1) if approved_at else None,
            "ask_delivered_at": delivered.strftime("%Y-%m-%dT%H:%MZ") if delivered else None,
            "ask_campaign": ask[1] if ask else None,
            "due_at": due.strftime("%Y-%m-%dT%H:%MZ") if due else None,
            "days_left": (due - now).days if due and now < due else (0 if due else None),
            "core_proof_due_at": core_due.strftime("%Y-%m-%dT%H:%MZ") if core_due else None,
            "core_due_mismatch": bool(core_due and (due is None or abs((core_due - due).total_seconds()) > 3600)),
            "bucket": bucket(state, delivered, due, now),
            "reminder_due": bool(delivered and state == "clock_running"
                                 and now >= delivered + timedelta(days=REMINDER_DAY)),
            "day_n_route": {"backup_on_file": "plain_approve", "user_documented": "stage2_document_check",
                            "due": "live_dsp_check_then_removal_gate"}.get(state),
        })
        t.rows.append(r)
    t.rows.sort(key=lambda x: (not x["paid"], x["state"] != "due", x["days_left"] if x["days_left"] is not None else 99))
    return t
