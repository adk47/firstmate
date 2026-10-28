"""What is true for one verified user, read from core and hydra. Read-only.

Sources (node-8):
  core replica via Trino (scripts/trino-query.sh)  users, credit_requests (+ core delivery markers),
                                                   claiming, profile_merges
  hydra verify ledger (read-only)                  last hydra note, status-note holds
                                                   (/var/lib/hydra/credit-review/ledger.sqlite3)
  proof-on-file export                             a document of theirs awaits review; emailed support@
  the account gate's PUBLISHED hold set              /opt/firstmate/fraud-lens/out/account_holds.jsonl
                                                   (read only: no verifier or gate process runs inside
                                                   Caroline's tools, captain 03:4xZ; hold = owes proof)
  Caroline's own ledger                            last approved line she offered (ledger.py)

Any source that cannot be read makes the whole read UNKNOWN (Facts.unknown): policy then offers no line.
"""

from __future__ import annotations

import csv
import io
import os
import re
import sqlite3
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Optional

IDP_HOLD_ARGV = ["kubectl", "-n", "muso-prod", "get", "deploy", "industry-proc-raw-v2", "-o",
                 'jsonpath={.spec.template.spec.containers[0].env[?(@.name=="IDP_CREDIT_HOLD_SUBMITTER_IDS")].value}']
ACCOUNT_HOLDS = os.environ.get("CAROLINE_ACTIONS_ACCOUNT_HOLDS", "/opt/firstmate/fraud-lens/out/account_holds.jsonl")
HOLDS_MAX_AGE_S = 72 * 3600


def account_hold_state(user_id: int, path: str = ACCOUNT_HOLDS, now: float | None = None) -> str:
    """'hold' when the gate's published hold set lists this account, else 'allow'; raises (-> unknown)
    when the set is missing, unreadable or older than 72 h. A file read only: Caroline's tools never
    run the gate or any verifier (captain 2026-10-28 03:4xZ)."""
    import json as _json
    import time as _time
    st = os.stat(path)
    if (now or _time.time()) - st.st_mtime > HOLDS_MAX_AGE_S:
        raise FactsError("account hold set is older than 72h")
    uid = str(int(user_id))
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and str(_json.loads(line).get("user_id")) == uid:
                return "hold"
    return "allow"


TRINO = os.environ.get("CAROLINE_ACTIONS_TRINO", "/opt/hydra/scripts/trino-query.sh")
VERIFY_LEDGER = os.environ.get("CAROLINE_ACTIONS_VERIFY_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
STATUS_NOTE_CAMPAIGNS = ("status-doc-received", "status-team-review")
OPEN_STATUSES = ("pending", "processing", "unverified", "user_verification_needed")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class FactsError(RuntimeError):
    """A source could not be read: the answer is UNKNOWN, never 'nothing'."""


def parse_ts(v: Any) -> Optional[datetime]:
    if not isinstance(v, str) or not v.strip():
        return None
    s = v.strip().replace(" UTC", "+00:00").replace("Z", "+00:00")
    if " " in s and "T" not in s:
        s = s.replace(" ", "T", 1)
    try:
        t = datetime.fromisoformat(s)
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


@dataclass
class Request:
    id: str
    status: str
    title: str = ""
    updated_at: Optional[datetime] = None
    proof_notice_at: Optional[datetime] = None      # metadata.proofRequest.noticeSentAt
    info_request_at: Optional[datetime] = None      # metadata.infoRequest.at
    approved_notice_at: Optional[datetime] = None   # metadata.approvedNotice.noticeSentAt
    review_hold: bool = False                       # IDP review_* fired: the user owes proof
    reject_rule: bool = False                       # validator reject_*: decided, not closed

    @property
    def open(self) -> bool:
        return self.status in OPEN_STATUSES


@dataclass
class Claim:
    id: str
    status: str
    profile_id: str = ""
    updated_at: Optional[datetime] = None
    has_links: bool = False


@dataclass
class Merge:
    id: str
    status: str
    survivor: str = ""
    loser: str = ""
    updated_at: Optional[datetime] = None


@dataclass
class Facts:
    user_id: Optional[int] = None
    full_name: str = ""
    requests: list[Request] = field(default_factory=list)
    claims: list[Claim] = field(default_factory=list)
    merges: list[Merge] = field(default_factory=list)
    last_hydra_note_at: Optional[datetime] = None
    status_note_hold: bool = False
    support_contact: bool = False
    doc_pending: Optional[bool] = None          # None = proof-on-file unreadable
    gate: str = "unknown"                       # allow | hold | unknown
    idp_hold: Optional[bool] = None             # on IDP's submitter hold list (None = could not read)
    last_caroline_line_at: Optional[datetime] = None
    profile_names: dict[str, str] = field(default_factory=dict)
    unknown: list[str] = field(default_factory=list)   # sources that could not be read
    identity: str = "unresolved"                # resolved | no_account | ambiguous | unconfirmed | bad_email

    def as_dict(self) -> dict[str, Any]:
        """PII-free summary for the ledger and the tool result (no email, no name)."""
        def ts(t: Optional[datetime]) -> Optional[str]:
            return t.strftime("%Y-%m-%dT%H:%M:%SZ") if t else None
        return {
            "user_id": self.user_id, "identity": self.identity, "unknown": list(self.unknown),
            "requests": [{"id": r.id, "status": r.status, "updated_at": ts(r.updated_at),
                          "proof_notice_at": ts(r.proof_notice_at), "info_request_at": ts(r.info_request_at),
                          "approved_notice_at": ts(r.approved_notice_at), "review_hold": r.review_hold,
                          "reject_rule": r.reject_rule} for r in self.requests],
            "claims": [{"id": c.id, "status": c.status, "profile_id": c.profile_id, "updated_at": ts(c.updated_at),
                        "has_links": c.has_links} for c in self.claims],
            "merges": [{"id": m.id, "status": m.status, "survivor": m.survivor, "loser": m.loser,
                        "updated_at": ts(m.updated_at)} for m in self.merges],
            "last_hydra_note_at": ts(self.last_hydra_note_at), "status_note_hold": self.status_note_hold,
            "support_contact": self.support_contact, "doc_pending": self.doc_pending, "gate": self.gate, "idp_hold": self.idp_hold,
            "last_caroline_line_at": ts(self.last_caroline_line_at),
        }


# ---------------------------------------------------------------------------------------------- core

TrinoFn = Callable[[str], list[list[str]]]


def trino(sql: str) -> list[list[str]]:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise FactsError(f"replica query failed (exit {p.returncode})")
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


def sql_email(email: str) -> str:
    e = (email or "").strip().lower()
    if not EMAIL_RE.match(e):
        raise ValueError("not an email")
    return e.replace("'", "''")


def q_user(email: str) -> str:
    return ("SELECT CAST(id AS varchar), coalesce(fullname, ''), CAST(coalesce(emailconfirmed, false) AS varchar) "
            f"FROM postgresql_core.public.users WHERE lower(email) = '{sql_email(email)}'")


def q_requests(uid: int) -> str:
    return (
        "SELECT CAST(c.id AS varchar), c.status, coalesce(c.spotifytracktitle, ''), "
        "coalesce(to_iso8601(c.updatedat), ''), "
        "coalesce(json_extract_scalar(c.metadata, '$.proofRequest.noticeSentAt'), ''), "
        "coalesce(json_extract_scalar(c.metadata, '$.infoRequest.at'), ''), "
        "coalesce(json_extract_scalar(c.metadata, '$.approvedNotice.noticeSentAt'), ''), "
        "CAST(regexp_like(coalesce(json_format(json_extract(c.verificationdata, '$.rule_risk_percent')), ''), "
        "'\"review_[a-z_]+\":\\s*[1-9]') AS varchar), "
        "CAST(regexp_like(coalesce(json_format(json_extract(c.verificationdata, '$.rule_risk_percent')), ''), "
        "'\"reject_[a-z_]+\":\\s*[1-9]') AS varchar) "
        "FROM postgresql_core.public.credit_requests c WHERE c.deletedat IS NULL "
        f"AND c.userid = {int(uid)} AND (c.status IN ('pending', 'processing', 'unverified', "
        "'user_verification_needed') OR c.updatedat > now() - INTERVAL '7' DAY) "
        "ORDER BY c.createdat")


def q_claims(uid: int) -> str:
    return ("SELECT CAST(id AS varchar), status, coalesce(profileid, ''), coalesce(to_iso8601(updatedat), ''), "
            "CAST(coalesce(json_array_length(verificationlinks), 0) > 0 AS varchar) "
            f"FROM postgresql_core.public.claiming WHERE deletedat IS NULL AND userid = {int(uid)} "
            "AND (status = 'pending' OR updatedat > now() - INTERVAL '7' DAY) ORDER BY createdat")


def q_merges(uid: int) -> str:
    owned = (f"SELECT profileid FROM postgresql_core.public.claiming WHERE deletedat IS NULL AND userid = {int(uid)} "
             "AND status = 'processed'")
    return ("SELECT CAST(m.id AS varchar), m.status, CAST(m.survivor_profile_id AS varchar), "
            "CAST(m.loser_profile_id AS varchar), coalesce(to_iso8601(m.updated_at), '') "
            "FROM postgresql_core.public.profile_merges m "
            f"WHERE CAST(m.survivor_profile_id AS varchar) IN ({owned}) "
            f"OR CAST(m.loser_profile_id AS varchar) IN ({owned}) ORDER BY m.created_at")


def _bool(v: str) -> bool:
    return str(v).strip().lower() == "true"


def load_core(f: Facts, email: str, run: TrinoFn) -> None:
    try:
        rows = run(q_user(email))
    except ValueError:
        f.identity = "bad_email"
        return
    if not rows:
        f.identity = "no_account"
        return
    if len(rows) > 1:
        f.identity = "ambiguous"
        return
    uid, full, confirmed = rows[0][:3]
    if not _bool(confirmed):
        f.identity = "unconfirmed"
        return
    f.user_id, f.full_name, f.identity = int(uid), full, "resolved"
    for r in run(q_requests(f.user_id)):
        rid, st, title, upd, pn, ir, an, rev, rej = (r + [""] * 9)[:9]
        f.requests.append(Request(rid, st, title, parse_ts(upd), parse_ts(pn), parse_ts(ir), parse_ts(an),
                                  _bool(rev), _bool(rej)))
    for r in run(q_claims(f.user_id)):
        cid, st, pid, upd, links = (r + [""] * 5)[:5]
        f.claims.append(Claim(cid, st, pid, parse_ts(upd), _bool(links)))
    for r in run(q_merges(f.user_id)):
        mid, st, sv, lo, upd = (r + [""] * 5)[:5]
        f.merges.append(Merge(mid, st, sv, lo, parse_ts(upd)))


def idp_hold_ids() -> set[str]:
    """IDP's submitter hold list (the deploy env IDP_CREDIT_HOLD_SUBMITTER_IDS), read live. An empty
    answer is an error, never "nobody is held": the list has carried 20+ accounts since 10-26."""
    p = subprocess.run(IDP_HOLD_ARGV, capture_output=True, text=True, timeout=30)
    ids = {x.strip() for x in (p.stdout or "").split(",") if x.strip().isdigit()}
    if p.returncode != 0 or not ids:
        raise FactsError(f"IDP hold list unreadable (exit {p.returncode})")
    return ids


# ---------------------------------------------------------------------------------------------- hydra

def load_verify_ledger(f: Facts, email: str, path: str = VERIFY_LEDGER) -> None:
    """Last hydra note (any campaign, sent or in flight) and the status-note holds. Read-only."""
    key = (email or "").strip().lower()
    uid = str(f.user_id or "")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        row = db.execute("SELECT max(coalesce(sent_at, created_at)) FROM verify_messages "
                         "WHERE status IN ('sent', 'attempted') AND (account_id = ? OR user_key = ?)",
                         (uid, key)).fetchone()
        f.last_hydra_note_at = parse_ts(row[0]) if row and row[0] else None
        marks = ",".join("?" * len(STATUS_NOTE_CAMPAIGNS))
        held = db.execute(f"SELECT 1 FROM verify_refusal_holds WHERE flagged_at IS NOT NULL AND campaign IN ({marks}) "
                          "AND (user_id = ? OR user_key = ? OR user_key = ?) LIMIT 1",
                          (*STATUS_NOTE_CAMPAIGNS, uid, key, f"user:{uid}")).fetchone()
        f.status_note_hold = bool(held)
    finally:
        db.close()


def load_proof_on_file(f: Facts, loader: Callable[[], Any]) -> None:
    """doc_pending: a document of theirs (or of one of these requests) awaits review."""
    pof = loader()
    uid = str(f.user_id or "")
    entries = pof.get(uid, []) if hasattr(pof, "get") else []
    f.doc_pending = any(kind == "pending_doc" for _rid, kind in entries)
    f.support_contact = uid in getattr(pof, "support_contacts", frozenset())


def load(email: str, *, run: TrinoFn | None = None, verify_ledger: str | None = None,
         proof_loader: Callable[[], Any] | None = None, gate: Callable[[int], Any] | None = None,
         caroline_last_line: Callable[[int], Optional[datetime]] | None = None,
         profile_name: Callable[[str], Optional[str]] | None = None,
         idp_ids: Callable[[], set[str]] | None = None) -> Facts:
    """Every source, each failure recorded in Facts.unknown. Never raises for a source failure."""
    f = Facts()
    try:
        load_core(f, email, run or trino)
    except Exception as exc:  # noqa: BLE001 - UNKNOWN, never an empty answer
        f.unknown.append(f"core: {type(exc).__name__}")
        return f
    if f.identity != "resolved":
        return f
    try:
        load_verify_ledger(f, email, verify_ledger or VERIFY_LEDGER)
    except Exception as exc:  # noqa: BLE001
        f.unknown.append(f"verify_ledger: {type(exc).__name__}")
    try:
        if proof_loader is None:
            from credit_review.verify_notify import load_proof_on_file as _pof
            proof_loader = _pof
        load_proof_on_file(f, proof_loader)
    except Exception as exc:  # noqa: BLE001
        f.doc_pending = None
        f.unknown.append(f"proof_on_file: {type(exc).__name__}")
    try:
        if gate is None:
            f.gate = account_hold_state(f.user_id)
        else:
            g = gate(f.user_id)
            f.gate = g if isinstance(g, str) else getattr(g, "decision", "unknown")
    except Exception as exc:  # noqa: BLE001
        f.gate = "unknown"
        f.unknown.append(f"account_holds: {type(exc).__name__}")
    try:
        f.idp_hold = str(f.user_id) in (idp_ids or idp_hold_ids)()
    except Exception as exc:  # noqa: BLE001
        f.idp_hold = None
        f.unknown.append(f"idp_hold: {type(exc).__name__}")
    if caroline_last_line is not None:
        try:
            f.last_caroline_line_at = caroline_last_line(f.user_id)
        except Exception as exc:  # noqa: BLE001
            f.unknown.append(f"caroline_ledger: {type(exc).__name__}")
    if profile_name is not None:
        for c in f.claims:
            if c.status == "pending" and c.profile_id and UUID_RE.match(c.profile_id):
                try:
                    name = profile_name(c.profile_id)
                except Exception:  # noqa: BLE001 - no name, no claim line (policy refuses)
                    name = None
                if name:
                    f.profile_names[c.profile_id] = name
    return f
