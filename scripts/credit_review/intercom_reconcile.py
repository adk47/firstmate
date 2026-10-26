"""Intercom external_id reconcile (Fable ruling-intercom-external-id-1026 Ruling A; captain
2026-10-26 ~00:40Z "fix all the issues now!").

The gate's identity rule stays exactly as it is (intercom-verify-request.sh: the Intercom user for
the account email must carry the account's users.neptuneProfessionalId, or its Auth0 subject, as
external_id; exactly one when several share the email). This job fixes the DATA the gate reads, for
the users the gate refused on identity, with an audited, reversible write. It never messages anyone.

Population: every user the verify ledger holds or refused on identity (external_id mismatch, no
external_id, several Intercom users for the email, none) or whose note Intercom rejected with
action_forbidden, restricted to --segment paid (an active/trialing subscription on the account or on
the workspace of one of its open credit requests).

Classes (per Intercom user contact for the account email, then per account):
  A1  the contact's external_id is empty                         -> fix: set it to the professional id
  A2  the external_id is an orphan (matches no Muso account's     -> fix, but only when every
      professional id, Auth0 subject or users.id)                    WRITE CONDITION holds; else A3
  A3  the external_id is another Muso account's (or any contact   -> refused, no write, no message;
      with this email is), or A2 failed a condition                  listed for cs (both account ids)
  A4  2+ Intercom users for the email, none matching: A1/A2 per    -> fix exactly one, else refused
      contact; exactly one may become the match                      and listed for cs
  A5  Intercom answered action_forbidden (archived / blocked)     -> held for cs (owner's choice per the
                                                                     ruling: no email from this job)
  plus NONE (no Intercom user for the email: reported), OK (already matches: the hold is stale,
  reported), and holds that are not identity cases.

WRITE CONDITIONS (firstmate spec: every A1 / A2 / A4 write, not only A2): the account email is
confirmed (users.emailconfirmed); the account is >= MIN_ACCOUNT_DAYS old; no other Muso account
holds the email now, none was ever given it by an admin create / email change (action_log, which
starts 2026-09-01: core keeps no older email history), and no Intercom contact with this email names
another account; the account is paid; the professional id is on no other Intercom contact; and the
fraud lens does not hold the user (fraud_lens.py: such a user is fraud_hold, never written).

--mode dry-run (default) reads only: the ledger is opened read-only, Intercom and the replica are
only read. It writes the table (account id, Intercom contact id, old external_id, class, decision,
why; never an email: an external_id that is not id-shaped is shown as a short hash) to --out.
--mode apply --approved <dry-run json>: only rows that were `fix` in that approved dry run AND are
still `fix` now, for the same contact and old external_id. Right before each write the account is
classified again from scratch (replica facts, paid, fraud lens, Intercom by email and by professional
id: every WRITE CONDITION) and must still be that same `fix`; the contact is re-read (still a user
with this email and this old external_id) and an intercom_identity_fix ledger row is
written (account, contact, old and new external_id, class, run id, status pending); then
PUT /contacts/{id}; then the contact is re-read to confirm. FIRST_RUN_CAP (50) writes on the first
apply run ever, --max-users after that. A confirmed fix lifts that account's 7-day identity refusal
hold (verify_refusal_holds next_recheck_at -> now; the count and a cs flag are left alone), and the
old value is kept on the ledger row.
--revert <run_id> [--mode apply]: for each row of that run (including one a crashed revert left
`reverting`), re-read the contact; when it still carries the new id AND still has the email and role
it had when fixed (hashed on the row as contact_owner), write `reverting` to the ledger, PUT the old
external_id back, re-read and record reverted / revert_failed; then put the lifted refusal holds
back. A contact whose id, email or role changed since the fix is revert_refused, never overwritten. NOTE: an A1 row's old external_id
is empty, and Intercom does not document clearing an external_id: such a revert is attempted with
null, confirmed by the re-read, and reported revert_failed for a human when Intercom keeps the id.
Kill switch: /etc/hydra/intercom-identity-reconcile.disabled.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterable

from . import fraud_lens, verify_ledger, verify_notify

Query = verify_notify.Query
Api = Callable[[str, str, Any], "tuple[int, dict[str, Any]]"]

KILL_SWITCH = Path(os.environ.get("INTERCOM_RECONCILE_KILL_SWITCH", "/etc/hydra/intercom-identity-reconcile.disabled"))
FIRST_RUN_CAP = 50
MIN_ACCOUNT_DAYS = 30
API = "https://api.intercom.io"
API_VERSION = "2.11"
EXT_RE = re.compile(r"^[A-Za-z0-9._|-]{1,128}$")
EMAIL_RE = re.compile(r"^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$")
RID_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
CONTACT_RE = re.compile(r"^[A-Za-z0-9]{1,40}$")
_EMAIL_ANY = re.compile(r"[^\s@<>\"']+@[^\s@<>\"']+")

# The gate's refusal / rejection reasons (intercom-verify-request.sh), by kind.
REASONS = (
    ("mismatch", re.compile(r"external_id mismatch")),
    ("no_external_id", re.compile(r"has no external_id")),
    ("several_contacts", re.compile(r"matches ([2-9]|\d{2,}) Intercom users")),
    ("no_contact", re.compile(r"matches 0 Intercom users")),
    ("action_forbidden", re.compile(r"action_forbidden")),
)
IDENTITY_KINDS = ("mismatch", "no_external_id", "several_contacts", "no_contact")
FIX, REFUSE_CS, HOLD_CS, FRAUD_HOLD, NO_CONTACT, ALREADY_OK, NO_PRO_ID = (
    "fix", "refuse_cs", "hold_cs", "fraud_hold", "no_contact", "already_ok", "no_professional_id")
CS_DECISIONS = (REFUSE_CS, HOLD_CS)

SCHEMA = """
CREATE TABLE IF NOT EXISTS intercom_identity_runs (
  run_id TEXT PRIMARY KEY,
  mode TEXT NOT NULL,                -- apply | revert
  started_at TEXT NOT NULL,
  finished_at TEXT,
  cap INTEGER,
  approved_from TEXT,                -- the dry-run file the apply was bound to
  summary_json TEXT
);
CREATE TABLE IF NOT EXISTS intercom_identity_fix (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  account_id TEXT NOT NULL,          -- Muso user id
  contact_id TEXT NOT NULL,          -- Intercom contact id
  old_external_id TEXT NOT NULL,     -- '' for A1
  new_external_id TEXT NOT NULL,     -- the account's professional id
  class TEXT NOT NULL,               -- A1 | A2 | A4
  status TEXT NOT NULL,              -- pending | applied | unverified | failed | skipped | reverting | reverted | revert_failed | revert_refused
  error TEXT,
  holds_json TEXT,                   -- [{campaign, user_key, old_next_recheck_at, cleared_to}] lifted by this fix
  contact_owner TEXT,                -- sha256 of the contact's lower-cased email + '|' + role when fixed (never the email)
  at TEXT NOT NULL,                  -- written BEFORE the Intercom write
  updated_at TEXT NOT NULL,
  reverted_at TEXT,
  revert_run TEXT
);
CREATE INDEX IF NOT EXISTS intercom_identity_fix_run ON intercom_identity_fix(run_id);
CREATE INDEX IF NOT EXISTS intercom_identity_fix_contact ON intercom_identity_fix(contact_id);
"""


def stamp(now: datetime | None = None) -> str:
    return verify_ledger.stamp(now)


def reason_kind(reason: str) -> str:
    for kind, rx in REASONS:
        if rx.search(reason or ""):
            return kind
    return ""


def _scrub(s: Any) -> str:
    return _EMAIL_ANY.sub("<email>", str(s or ""))[:300]


# -- Intercom ------------------------------------------------------------------------------

def intercom_api(token: str | None = None, pace: float = 0.2) -> Api:
    """A minimal Intercom REST client. MUSOAI_INTERCOM_TOKEN is required (from /etc/openclaw/main.env)."""
    tok = token or os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if not tok:
        raise RuntimeError("MUSOAI_INTERCOM_TOKEN is not set: set -a; . /etc/openclaw/main.env; set +a")

    def call(method: str, path: str, body: Any = None) -> tuple[int, dict[str, Any]]:
        if pace:
            time.sleep(pace)
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(API + path, data=data, method=method, headers={
            "Authorization": f"Bearer {tok}", "Accept": "application/json", "Content-Type": "application/json",
            "Intercom-Version": API_VERSION})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read().decode() or "{}"
                return resp.status, json.loads(raw)
        except urllib.error.HTTPError as exc:
            try:
                return exc.code, json.loads(exc.read().decode() or "{}")
            except ValueError:
                return exc.code, {}
    return call


def search_contacts(api: Api, field_name: str, value: str, max_pages: int = 5) -> list[dict[str, Any]]:
    """Every contact (any role) with field == value. A failed read raises: nothing is decided on it."""
    out: list[dict[str, Any]] = []
    cursor = None
    for _ in range(max_pages):
        body: dict[str, Any] = {"query": {"field": field_name, "operator": "=", "value": value},
                                "pagination": {"per_page": 50}}
        if cursor:
            body["pagination"]["starting_after"] = cursor
        status, res = api("POST", "/contacts/search", body)
        if status != 200 or not isinstance(res.get("data"), list):
            raise RuntimeError(f"Intercom contact search failed (HTTP {status}): {_scrub(res)[:200]}")
        out.extend(c for c in res["data"] if isinstance(c, dict))
        cursor = ((res.get("pages") or {}).get("next") or {}).get("starting_after")
        if not cursor:
            return out
    raise RuntimeError(f"Intercom contact search returned more than {max_pages} pages")


def get_contact(api: Api, contact_id: str) -> dict[str, Any]:
    if not CONTACT_RE.match(contact_id or ""):
        raise RuntimeError("malformed Intercom contact id")
    status, res = api("GET", f"/contacts/{contact_id}", None)
    if status != 200 or res.get("type") != "contact" or str(res.get("id")) != contact_id:
        raise RuntimeError(f"Intercom contact read failed (HTTP {status})")
    return res


def owner_key(contact: dict[str, Any]) -> str:
    """Who the contact is (its email and role), hashed: a revert refuses a contact that moved."""
    email = str(contact.get("email") or "").strip().lower()
    return hashlib.sha256(f"{email}|{contact.get('role') or ''}".encode()).hexdigest()


def ext_of(contact: dict[str, Any]) -> str:
    v = contact.get("external_id")
    return "" if v is None else str(v).strip()


# -- facts -----------------------------------------------------------------------------------

@dataclass
class Account:
    user_id: int
    email: str = ""
    email_confirmed: bool = False
    created_at: datetime | None = None
    professional_id: str = ""
    auth_id: str = ""
    paid: bool = False
    other_holders: list[str] = field(default_factory=list)      # other users rows with this email
    admin_history: list[str] = field(default_factory=list)      # action_log admin create / email change to this email, another account
    sources: list[str] = field(default_factory=list)            # "<campaign>:<reason kind>"

    def is_account(self, ext: str) -> bool:
        """The gate's ext_is_account: the professional id or the Auth0 subject (with or without auth0|)."""
        if not ext:
            return False
        return (bool(self.professional_id) and ext == self.professional_id) or \
            (bool(self.auth_id) and ext in (self.auth_id, "auth0|" + self.auth_id))


@dataclass
class Row:
    account_id: int
    cls: str
    decision: str
    why: str = ""
    contact_id: str = ""
    old_external_id: str = ""
    new_external_id: str = ""
    other_account_ids: list[str] = field(default_factory=list)
    contacts: int = 0
    sources: list[str] = field(default_factory=list)


def _chunks(xs: list[Any], n: int) -> Iterable[list[Any]]:
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def _ts(raw: Any) -> datetime | None:
    s = str(raw or "").strip()
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})", s)
    if not m:
        return None
    return datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}+00:00")


def _q(xs: Iterable[str]) -> str:
    return ",".join(f"'{x}'" for x in xs)


def population(ledger_path: str, query: Query) -> dict[int, list[str]]:
    """{Muso user id: ["<campaign>:<kind>", ...]} for every identity refusal or action_forbidden
    rejection in the verify ledger (read-only). Rows without a user id are resolved by their request
    ids on the replica, else by the account email when exactly one account has it."""
    db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    found: dict[int, set[str]] = {}
    by_rids: list[tuple[list[str], str]] = []
    by_email: list[tuple[str, str]] = []
    try:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        items: list[tuple[str, str, str, str, str]] = []
        if "verify_refusal_holds" in tables:
            items += [(str(r["campaign"]), str(r["reason"] or ""), str(r["user_id"] or ""), str(r["user_key"] or ""), "[]")
                      for r in db.execute("SELECT campaign, reason, user_id, user_key FROM verify_refusal_holds")]
        if "verify_messages" in tables:
            items += [(str(r["campaign"]), str(r["reason"] or ""), str(r["account_id"] or ""), str(r["user_key"] or ""),
                       str(r["request_ids_json"] or "[]"))
                      for r in db.execute("SELECT campaign, reason, account_id, user_key, request_ids_json FROM verify_messages "
                                          "WHERE status IN ('refused','rejected')")]
    finally:
        db.close()
    for campaign, reason, uid, key, rids_json in items:
        kind = reason_kind(reason)
        if not kind:
            continue
        src = f"{campaign}:{kind}"
        if uid.strip().isdigit():
            found.setdefault(int(uid), set()).add(src)
            continue
        try:
            rids = [str(r) for r in json.loads(rids_json) if RID_RE.match(str(r))]
        except ValueError:
            rids = []
        if rids:
            by_rids.append((rids, src))
        elif EMAIL_RE.match(key.strip().lower()):
            by_email.append((key.strip().lower(), src))
    all_rids = sorted({r for rids, _ in by_rids for r in rids})
    owner: dict[str, int] = {}
    for chunk in _chunks(all_rids, 400):
        for rid, uid in query("SELECT CAST(id AS varchar), CAST(userid AS varchar) FROM postgresql_core.public.credit_requests "
                              f"WHERE CAST(id AS varchar) IN ({_q(chunk)})"):
            if str(uid).isdigit():
                owner[str(rid)] = int(uid)
    for rids, src in by_rids:
        users = {owner[r] for r in rids if r in owner}
        if len(users) == 1:
            found.setdefault(users.pop(), set()).add(src)
    emails = sorted({e for e, _ in by_email})
    holders: dict[str, set[int]] = {}
    for chunk in _chunks(emails, 200):
        for uid, email in query("SELECT CAST(id AS varchar), lower(email) FROM postgresql_core.public.users "
                                f"WHERE lower(email) IN ({_q(chunk)})"):
            holders.setdefault(str(email), set()).add(int(uid))
    for email, src in by_email:
        if len(holders.get(email, set())) == 1:
            found.setdefault(next(iter(holders[email])), set()).add(src)
    return {u: sorted(s) for u, s in found.items()}


def account_facts(user_ids: list[int], query: Query) -> dict[int, Account]:
    """Everything the write conditions need, from the core replica (read-only)."""
    accts: dict[int, Account] = {}
    for chunk in _chunks(sorted(user_ids), 400):
        ids = ",".join(str(u) for u in chunk)
        for uid, email, confirmed, created, pro, auth in query(
                "SELECT CAST(id AS varchar), lower(email), CAST(emailconfirmed AS varchar), CAST(createdat AS varchar), "
                f"neptuneprofessionalid, auth0userid FROM postgresql_core.public.users WHERE id IN ({ids})"):
            accts[int(uid)] = Account(user_id=int(uid), email=(email or "").strip(),
                                      email_confirmed=str(confirmed).lower() == "true", created_at=_ts(created),
                                      professional_id=verify_notify.professional_id(pro),
                                      auth_id=verify_notify.auth_subject(auth))
        for (uid,) in query(
                "SELECT DISTINCT CAST(userid AS varchar) FROM postgresql_core.public.subscriptions "
                f"WHERE status IN ('active','trialing') AND userid IN ({ids}) UNION "
                "SELECT DISTINCT CAST(userid AS varchar) FROM postgresql_core.public.credit_requests "
                f"WHERE deletedat IS NULL AND status NOT IN ('approved','rejected') AND userid IN ({ids}) "
                f"AND workspaceid IN {fraud_lens.PAID_TEAMS}"):
            if int(uid) in accts:
                accts[int(uid)].paid = True
    by_email: dict[str, list[Account]] = {}
    for a in accts.values():
        if EMAIL_RE.match(a.email):
            by_email.setdefault(a.email, []).append(a)
    emails = sorted(by_email)
    for chunk in _chunks(emails, 200):
        for uid, email in query("SELECT CAST(id AS varchar), lower(email) FROM postgresql_core.public.users "
                                f"WHERE lower(email) IN ({_q(chunk)})"):
            for a in by_email.get(str(email), []):
                if int(uid) != a.user_id:
                    a.other_holders.append(str(uid))
        for route, method, email in query(
                "SELECT route, requestmethod, lower(json_extract_scalar(requestdata, '$.body.email')) "
                "FROM postgresql_core.public.action_log "
                f"WHERE lower(json_extract_scalar(requestdata, '$.body.email')) IN ({_q(chunk)}) "
                "AND ((requestmethod = 'PUT' AND regexp_like(route, '/admin/user/[0-9]+$')) "
                "OR (requestmethod = 'POST' AND regexp_like(route, '/admin/user$')))"):
            m = re.search(r"/admin/user/(\d+)$", str(route or ""))
            for a in by_email.get(str(email), []):
                if not m or int(m.group(1)) != a.user_id:
                    a.admin_history.append(f"{method} {re.sub(r'/[0-9]+$', '/:id', str(route))}"
                                           + (f" (account {m.group(1)})" if m else " (account create)"))
    return accts


def ext_owners(exts: Iterable[str], query: Query) -> dict[str, set[str]]:
    """{external_id: Muso user ids whose users.id, professional id or Auth0 subject it is}. Every
    Muso account counts (core has no soft delete on users)."""
    vals = sorted({x for x in exts if x and EXT_RE.match(x)})
    out: dict[str, set[str]] = {x: set() for x in vals}
    for chunk in _chunks(vals, 150):
        auth = sorted(set(chunk) | {"auth0|" + x for x in chunk if not x.startswith("auth0|")}
                      | {x[6:] for x in chunk if x.startswith("auth0|") and len(x) > 6})
        nums = [x for x in chunk if x.isdigit() and len(x) <= 18]
        cond = f"neptuneprofessionalid IN ({_q(chunk)}) OR auth0userid IN ({_q(auth)})"
        if nums:
            cond += f" OR id IN ({','.join(nums)})"
        for uid, pro, sub in query("SELECT CAST(id AS varchar), neptuneprofessionalid, auth0userid "
                                   f"FROM postgresql_core.public.users WHERE {cond}"):
            sub_bare = re.sub(r"^auth0\|", "", str(sub or ""))
            for x in chunk:
                if x in (str(uid), str(pro or ""), str(sub or ""), sub_bare) or (x.startswith("auth0|") and x[6:] == sub_bare):
                    out[x].add(str(uid))
    return out


# -- classifier (pure) -------------------------------------------------------------------------

def contact_class(a: Account, ext: str, owners: dict[str, set[str]]) -> tuple[str, list[str]]:
    """One Intercom contact against the account: (A1 | MATCH | A3 | OWN_LEGACY | UNCHECKABLE | A2, other ids)."""
    if not ext:
        return "A1", []
    if a.is_account(ext):
        return "MATCH", []
    if not EXT_RE.match(ext) or ext not in owners:
        return "UNCHECKABLE", []
    others = sorted(owners[ext] - {str(a.user_id)})
    if others:
        return "A3", others
    if owners[ext]:
        return "OWN_LEGACY", []   # e.g. the account's bare numeric id: not the gate's identity, not covered by the ruling
    return "A2", []


def write_blockers(a: Account, *, now: datetime, other_contact_accounts: list[str], pro_elsewhere: bool,
                   uncheckable: int = 0) -> list[str]:
    """Every failed WRITE CONDITION (empty = the write may go)."""
    out = []
    if uncheckable:
        out.append(f"{uncheckable} Intercom contact(s) with this email carry an external_id that could not be checked")
    if not a.email_confirmed:
        out.append("account email not confirmed")
    if a.created_at is None or now - a.created_at < timedelta(days=MIN_ACCOUNT_DAYS):
        out.append(f"account younger than {MIN_ACCOUNT_DAYS} days (or no creation date)")
    if not EMAIL_RE.match(a.email):
        out.append("account email not checkable")
    if a.other_holders:
        out.append("another Muso account holds this email (" + ",".join(sorted(a.other_holders)) + ")")
    if a.admin_history:
        out.append("an admin gave this email to another account: " + "; ".join(sorted(set(a.admin_history))[:3]))
    if other_contact_accounts:
        out.append("an Intercom contact with this email names another Muso account ("
                   + ",".join(sorted(set(other_contact_accounts))) + ")")
    if not a.paid:
        out.append("account not paid (no active/trialing subscription)")
    if pro_elsewhere:
        out.append("the professional id is already the external_id of another Intercom contact")
    return out


def classify(a: Account, contacts: list[dict[str, Any]], owners: dict[str, set[str]], *, now: datetime,
             pro_contacts: list[dict[str, Any]] | None = None, verdict: fraud_lens.Verdict | None = None) -> Row:
    """The ruling's A1-A5 table for one account. `contacts`: every Intercom contact (any role) whose
    email is the account email; `pro_contacts`: every contact whose external_id is the professional id."""
    row = Row(account_id=a.user_id, cls="", decision="", sources=list(a.sources), new_external_id=a.professional_id)
    kinds = {s.split(":", 1)[1] for s in a.sources if ":" in s}
    if "action_forbidden" in kinds and not kinds & set(IDENTITY_KINDS):
        row.cls, row.decision, row.why = "A5", HOLD_CS, "Intercom refuses this contact (action_forbidden); held for cs"
        return row
    if not a.professional_id:
        row.cls, row.decision, row.why = "NONE", NO_PRO_ID, "the account has no professional id"
        return row
    mine = [c for c in contacts if str(c.get("email") or "").strip().lower() == a.email]
    users = [c for c in mine if c.get("role") == "user"]
    row.contacts = len(users)
    other_accounts: list[str] = []
    per: list[tuple[dict[str, Any], str]] = []
    for c in mine:
        cls, others = contact_class(a, ext_of(c), owners)
        other_accounts += others
        if c.get("role") == "user":
            per.append((c, cls))
    if not users:
        row.cls, row.decision, row.why = "NONE", NO_CONTACT, "no Intercom user for the account email"
        return row
    matches = [c for c, k in per if k == "MATCH"]
    if len(matches) == 1:
        row.cls, row.decision, row.why = "OK", ALREADY_OK, "the Intercom user already carries this account's id"
        row.contact_id = str(matches[0].get("id") or "")
        return row
    row.other_account_ids = sorted(set(other_accounts))
    if len(users) == 1:
        c, k = per[0]
        row.contact_id, row.old_external_id = str(c.get("id") or ""), ext_of(c)
        if k == "A3":
            row.cls, row.decision, row.why = "A3", REFUSE_CS, "the external_id is another Muso account's"
            return row
        if k in ("UNCHECKABLE", "OWN_LEGACY"):
            row.cls, row.decision = "A3", REFUSE_CS
            row.why = ("the external_id is this account's bare numeric id or legacy id (not covered by the ruling)"
                       if k == "OWN_LEGACY" else "the external_id could not be checked against the Muso accounts")
            return row
        row.cls = k
    else:
        row.cls = "A4"
        if matches:
            row.decision, row.why = REFUSE_CS, "several Intercom users already carry this account's id"
            return row
        fixable = [c for c, k in per if k in ("A1", "A2")]
        if len(fixable) != 1:
            row.decision = REFUSE_CS
            row.why = f"{len(users)} Intercom users for the email, {len(fixable)} would become the match (need exactly 1)"
            return row
        row.contact_id, row.old_external_id = str(fixable[0].get("id") or ""), ext_of(fixable[0])
    if not CONTACT_RE.match(row.contact_id):
        row.decision, row.why = REFUSE_CS, "malformed Intercom contact id"
        return row
    pro_elsewhere = any(str(c.get("id")) != row.contact_id for c in (pro_contacts or []))
    uncheckable = sum(1 for c in mine if contact_class(a, ext_of(c), owners)[0] == "UNCHECKABLE")
    blockers = write_blockers(a, now=now, other_contact_accounts=other_accounts, pro_elsewhere=pro_elsewhere,
                              uncheckable=uncheckable)
    if verdict is None or verdict.held:
        row.decision = FRAUD_HOLD
        row.why = "fraud lens: " + ("; ".join(verdict.held) if verdict else "no verdict")
        return row
    if blockers:
        if row.cls == "A2":
            row.cls = "A3"       # the ruling: an orphan that fails a condition is handled as A3
        row.decision, row.why = REFUSE_CS, "write condition failed: " + "; ".join(blockers)
        return row
    row.decision = FIX
    row.why = {"A1": "empty external_id", "A2": "orphan external_id (no Muso account)",
               "A4": "exactly one of several Intercom users becomes the match"}.get(row.cls, "")
    return row


# -- run ---------------------------------------------------------------------------------------

@dataclass
class Result:
    run_id: str
    mode: str
    rows: list[Row] = field(default_factory=list)
    applied: int = 0
    failed: int = 0
    skipped: int = 0
    unverified: int = 0
    holds_cleared: int = 0
    cap: int = 0
    over_cap: int = 0
    not_in_segment: int = 0
    errors: list[str] = field(default_factory=list)
    halted: str = ""
    emails: dict[int, str] = field(default_factory=dict, repr=False)   # in memory only: never written out

    def table(self) -> dict[str, dict[str, int]]:
        t: dict[str, dict[str, int]] = {}
        for r in self.rows:
            t.setdefault(r.cls, {})
            t[r.cls][r.decision] = t[r.cls].get(r.decision, 0) + 1
        return t


def new_run_id(prefix: str, now: datetime | None = None) -> str:
    return f"{prefix}-{(now or verify_ledger.utcnow()).strftime('%Y%m%dT%H%M%SZ')}-{secrets.token_hex(3)}"


def classify_all(*, ledger_path: str, query: Query, api: Api, lens: fraud_lens.LensFn, now: datetime,
                 segment: str = "paid", result: Result) -> list[Row]:
    pop = population(ledger_path, query)
    accts = account_facts(sorted(pop), query)
    for uid, srcs in pop.items():
        if uid in accts:
            accts[uid].sources = srcs
    if segment == "paid":
        result.not_in_segment = sum(1 for u in pop if u not in accts or not accts[u].paid)
        accts = {u: a for u, a in accts.items() if a.paid}
    result.emails = {u: a.email for u, a in accts.items()}
    return classify_accounts(accts, query=query, api=api, lens=lens, now=now)


def classify_accounts(accts: dict[int, Account], *, query: Query, api: Api, lens: fraud_lens.LensFn,
                      now: datetime) -> list[Row]:
    """classify() for these accounts on FRESH reads: the lens, Intercom (by email and by professional
    id) and the owners of every external_id seen."""
    verdicts = lens(sorted(accts)) if accts else {}
    contacts: dict[int, list[dict[str, Any]]] = {}
    pro_contacts: dict[int, list[dict[str, Any]]] = {}
    for uid, a in sorted(accts.items()):
        if not EMAIL_RE.match(a.email) or not a.professional_id:
            contacts[uid], pro_contacts[uid] = [], []
            continue
        contacts[uid] = search_contacts(api, "email", a.email)
        pro_contacts[uid] = search_contacts(api, "external_id", a.professional_id)
    owners = ext_owners({ext_of(c) for cs in contacts.values() for c in cs}, query)
    return [classify(a, contacts[uid], owners, now=now, pro_contacts=pro_contacts[uid], verdict=verdicts.get(uid))
            for uid, a in sorted(accts.items())]


def reclassify(r: Row, *, query: Query, api: Api, lens: fraud_lens.LensFn, now: datetime,
               segment: str = "paid") -> Row | None:
    """This account's row re-derived from scratch (replica facts, paid, lens, Intercom), for the check
    right before its write (QA @28ddcca: a condition can change while earlier rows are written).
    None when the account is gone or no longer in the segment."""
    accts = account_facts([r.account_id], query)
    a = accts.get(r.account_id)
    if a is None or (segment == "paid" and not a.paid):
        return None
    a.sources = list(r.sources)
    return classify_accounts({r.account_id: a}, query=query, api=api, lens=lens, now=now)[0]


def _connect(path: str) -> sqlite3.Connection:
    db = verify_ledger.connect(path)
    db.executescript(SCHEMA)
    return db


def _lift_holds(db: sqlite3.Connection, a_email: str, account_id: str, now: datetime) -> list[dict[str, str]]:
    """Lift this account's live identity refusal holds (next_recheck_at -> now). The refusal count
    and a cs flag stay. Returns what was lifted, for the ledger row and a revert."""
    ts = stamp(now)
    cond, params = verify_ledger._hold_of(a_email, account_id)
    lifted = []
    for r in db.execute(f"SELECT campaign, user_key, reason, next_recheck_at FROM verify_refusal_holds "
                        f"WHERE {cond} AND flagged_at IS NULL AND next_recheck_at > ?", (*params, ts)).fetchall():
        if reason_kind(str(r["reason"] or "")) not in IDENTITY_KINDS:
            continue
        n = db.execute("UPDATE verify_refusal_holds SET next_recheck_at=?, updated_at=? WHERE campaign=? AND user_key=? "
                       "AND next_recheck_at=? AND flagged_at IS NULL",
                       (ts, ts, r["campaign"], r["user_key"], r["next_recheck_at"])).rowcount
        if n:
            lifted.append({"campaign": str(r["campaign"]), "user_key": str(r["user_key"]),
                           "old_next_recheck_at": str(r["next_recheck_at"]), "cleared_to": ts})
    return lifted


def _approved_rows(path: str) -> dict[tuple[int, str, str], str]:
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or doc.get("mode") != "dry-run" or not isinstance(doc.get("rows"), list):
        raise ValueError(f"{path} is not an intercom-reconcile dry-run file")
    return {(int(r["account_id"]), str(r["contact_id"]), str(r["old_external_id"])): str(r["new_external_id"])
            for r in doc["rows"] if r.get("decision") == FIX}


def run(*, mode: str = "dry-run", ledger_path: str | None = None, query: Query = verify_notify.trino,
        api: Api | None = None, lens: fraud_lens.LensFn | None = None, max_users: int = FIRST_RUN_CAP,
        approved: str | None = None, classes: tuple[str, ...] = ("A1", "A2", "A4"), segment: str = "paid",
        now: datetime | None = None) -> Result:
    now = now or verify_ledger.utcnow()
    path = ledger_path or verify_ledger.DEFAULT_PATH
    res = Result(run_id=new_run_id("irc" if mode == "apply" else "irc-dry", now), mode=mode)
    if mode not in ("dry-run", "apply"):
        raise ValueError(f"unknown mode {mode!r}")
    allowed: dict[tuple[int, str, str], str] = {}
    if mode == "apply":
        if not approved:
            res.halted = "apply needs --approved <the dry-run json firstmate approved>; nothing written"
            return res
        try:
            allowed = _approved_rows(approved)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            res.halted = f"approved dry-run unreadable: {exc}; nothing written"
            return res
    if lens is None:
        try:
            lens = fraud_lens.default_lens(query)
        except ValueError as exc:
            res.halted = f"fraud lens unavailable ({exc}); nothing written"
            return res
    try:
        api = api or intercom_api()
    except RuntimeError as exc:
        res.halted = f"{exc}; nothing written"
        return res
    res.rows = classify_all(ledger_path=path, query=query, api=api, lens=lens, now=now, segment=segment, result=res)
    if mode != "apply":
        res.cap = min(max_users, FIRST_RUN_CAP) if _prior_fixes(path) == 0 else max_users
        return res
    lock = open(f"{path}.intercom-reconcile.lock", "a+")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        res.halted = "another intercom-reconcile run is in progress; nothing written"
        return res
    db = _connect(path)
    try:
        first = db.execute(f"SELECT count(*) FROM intercom_identity_fix WHERE status IN {LIVE_STATUSES}").fetchone()[0] == 0
        res.cap = min(max_users, FIRST_RUN_CAP) if first else max_users
        db.execute("INSERT INTO intercom_identity_runs (run_id, mode, started_at, cap, approved_from) VALUES (?,?,?,?,?)",
                   (res.run_id, "apply", stamp(now), res.cap, str(approved)))
        todo = [r for r in res.rows if r.decision == FIX and r.cls in classes
                and allowed.get((r.account_id, r.contact_id, r.old_external_id)) == r.new_external_id]
        for r in todo:
            if res.applied + res.unverified + res.failed >= res.cap:
                res.over_cap += 1
                continue
            fresh = reclassify(r, query=query, api=api, lens=lens, now=now, segment=segment)
            if fresh is None or (fresh.decision, fresh.contact_id, fresh.old_external_id, fresh.new_external_id) != \
                    (FIX, r.contact_id, r.old_external_id, r.new_external_id):
                res.skipped += 1
                res.errors.append(f"{r.account_id}: no longer a fix right before the write ("
                                  + (f"{fresh.cls} {fresh.decision}: {fresh.why}" if fresh else "not in the segment")
                                  + "); not written")
                continue
            _apply_one(db, api, r, res, now)
        db.execute("UPDATE intercom_identity_runs SET finished_at=?, summary_json=? WHERE run_id=?",
                   (stamp(), json.dumps(summary(res)), res.run_id))
    finally:
        db.close()
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()
    return res


LIVE_STATUSES = "('pending','applied','unverified','reverting','reverted','revert_failed','revert_refused')"


def _prior_fixes(path: str) -> int:
    """Writes ever attempted (read-only): 0 means the next apply is the first run (FIRST_RUN_CAP)."""
    if not Path(path).exists():
        return 0
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='intercom_identity_fix'").fetchone():
            return 0
        return int(db.execute(f"SELECT count(*) FROM intercom_identity_fix WHERE status IN {LIVE_STATUSES}").fetchone()[0])
    finally:
        db.close()


def _apply_one(db: sqlite3.Connection, api: Api, r: Row, res: Result, now: datetime) -> None:
    try:
        c = get_contact(api, r.contact_id)
    except RuntimeError as exc:
        res.skipped += 1
        res.errors.append(f"{r.account_id}: {exc}")
        return
    acct_email = res.emails.get(r.account_id, "")
    if (c.get("role") != "user" or ext_of(c) != r.old_external_id or not EMAIL_RE.match(acct_email)
            or str(c.get("email") or "").strip().lower() != acct_email):
        res.skipped += 1
        res.errors.append(f"{r.account_id}: contact {r.contact_id} changed since it was classified; not written")
        return
    ts = stamp(now)
    # The ledger row (with the old id) BEFORE the write.
    fid = db.execute("INSERT INTO intercom_identity_fix (run_id, account_id, contact_id, old_external_id, new_external_id, "
                     "class, status, contact_owner, at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                     (res.run_id, str(r.account_id), r.contact_id, r.old_external_id, r.new_external_id, r.cls,
                      "pending", owner_key(c), ts, ts)).lastrowid
    status, body = api("PUT", f"/contacts/{r.contact_id}", {"external_id": r.new_external_id})
    if status != 200:
        res.failed += 1
        err = f"HTTP {status}: {_scrub(json.dumps(body.get('errors') or body))}"
        res.errors.append(f"{r.account_id}: write failed, {err}")
        db.execute("UPDATE intercom_identity_fix SET status='failed', error=?, updated_at=? WHERE id=?", (err, stamp(), fid))
        return
    try:
        after = ext_of(get_contact(api, r.contact_id))
    except RuntimeError:
        after = ""
    if after != r.new_external_id:
        res.unverified += 1
        db.execute("UPDATE intercom_identity_fix SET status='unverified', error=?, updated_at=? WHERE id=?",
                   ("the re-read does not show the new external_id", stamp(), fid))
        return
    lifted = _lift_holds(db, acct_email, str(r.account_id), now)
    res.applied += 1
    res.holds_cleared += len(lifted)
    db.execute("UPDATE intercom_identity_fix SET status='applied', holds_json=?, updated_at=? WHERE id=?",
               (json.dumps(lifted), stamp(), fid))


@dataclass
class RevertResult:
    run_id: str
    mode: str
    rows: list[dict[str, str]] = field(default_factory=list)
    reverted: int = 0
    failed: int = 0
    refused: int = 0
    holds_restored: int = 0
    halted: str = ""


def revert(target_run: str, *, mode: str = "dry-run", ledger_path: str | None = None, api: Api | None = None,
           now: datetime | None = None) -> RevertResult:
    """Put back the old external_id of every contact the run changed (see the module docstring)."""
    now = now or verify_ledger.utcnow()
    path = ledger_path or verify_ledger.DEFAULT_PATH
    out = RevertResult(run_id=new_run_id("irc-revert", now), mode=mode)
    if mode == "apply":
        db = _connect(path)
    else:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
    try:
        has = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='intercom_identity_fix'").fetchone()
        rows = db.execute("SELECT * FROM intercom_identity_fix WHERE run_id=? AND status IN "
                          "('pending','applied','unverified','reverting','revert_failed') ORDER BY id",
                          (target_run,)).fetchall() if has else []
        if not rows:
            out.halted = f"run {target_run} has nothing to revert"
            return out
        api = api or intercom_api()
        if mode == "apply":
            db.execute("INSERT INTO intercom_identity_runs (run_id, mode, started_at, approved_from) VALUES (?,?,?,?)",
                       (out.run_id, "revert", stamp(now), target_run))
        for r in rows:
            old, new = str(r["old_external_id"]), str(r["new_external_id"])
            entry = {"account_id": str(r["account_id"]), "contact_id": str(r["contact_id"]), "old_external_id": old,
                     "class": str(r["class"])}
            try:
                now_c = get_contact(api, str(r["contact_id"]))
                cur = ext_of(now_c)
            except RuntimeError as exc:
                out.failed += 1
                entry["result"] = f"contact unreadable: {exc}"
                out.rows.append(entry)
                continue
            if cur == old:
                entry["result"] = "already the old value"
                if mode == "apply":
                    out.holds_restored += _restore_holds(db, r)
                    _mark(db, r["id"], "reverted", out.run_id)
                out.reverted += 1
            elif cur != new:
                out.refused += 1
                entry["result"] = "the contact changed since the fix; not reverted"
                if mode == "apply":
                    _mark(db, r["id"], "revert_refused", out.run_id, "external_id changed since the fix")
            elif not r["contact_owner"] or owner_key(now_c) != r["contact_owner"]:
                # QA @214ea86: the contact now has another email or role; the old (orphan / empty) id
                # must not be written onto whoever it belongs to now.
                out.refused += 1
                entry["result"] = "the contact's email or role changed since the fix; not reverted"
                if mode == "apply":
                    _mark(db, r["id"], "revert_refused", out.run_id, "contact email or role changed since the fix")
            elif mode != "apply":
                entry["result"] = "would restore the old external_id"
                out.reverted += 1
            else:
                _mark(db, r["id"], "reverting", out.run_id)   # BEFORE the write
                status, body = api("PUT", f"/contacts/{r['contact_id']}", {"external_id": old or None})
                try:
                    after = ext_of(get_contact(api, str(r["contact_id"])))
                except RuntimeError:
                    after = new
                if status == 200 and after == old:
                    out.reverted += 1
                    out.holds_restored += _restore_holds(db, r)
                    _mark(db, r["id"], "reverted", out.run_id)
                    entry["result"] = "reverted"
                else:
                    out.failed += 1
                    why = (f"HTTP {status}: {_scrub(json.dumps(body.get('errors') or body))}" if status != 200 else
                           "Intercom kept the new external_id" + (" (it may not allow clearing one: a human must "
                                                                  "restore this A1 contact)" if not old else ""))
                    _mark(db, r["id"], "revert_failed", out.run_id, why)
                    entry["result"] = "revert failed: " + why
            out.rows.append(entry)
        if mode == "apply":
            db.execute("UPDATE intercom_identity_runs SET finished_at=?, summary_json=? WHERE run_id=?",
                       (stamp(), json.dumps({"reverted": out.reverted, "failed": out.failed, "refused": out.refused,
                                             "holds_restored": out.holds_restored}), out.run_id))
    finally:
        db.close()
    return out


def _mark(db: sqlite3.Connection, fid: int, status: str, revert_run: str, error: str | None = None) -> None:
    ts = stamp()
    db.execute("UPDATE intercom_identity_fix SET status=?, revert_run=?, error=COALESCE(?, error), updated_at=?, "
               "reverted_at=CASE WHEN ?='reverted' THEN ? ELSE reverted_at END WHERE id=?",
               (status, revert_run, error, ts, status, ts, fid))


def _restore_holds(db: sqlite3.Connection, r: sqlite3.Row) -> int:
    """Put back the holds a fix lifted, where nothing has touched them since (no send, no new refusal)."""
    n = 0
    for h in json.loads(r["holds_json"] or "[]"):
        n += db.execute("UPDATE verify_refusal_holds SET next_recheck_at=?, updated_at=? WHERE campaign=? AND user_key=? "
                        "AND next_recheck_at=? AND flagged_at IS NULL",
                        (h["old_next_recheck_at"], stamp(), h["campaign"], h["user_key"], h["cleared_to"])).rowcount
    return n


# -- output --------------------------------------------------------------------------------------

def summary(res: Result) -> dict[str, Any]:
    return {"run_id": res.run_id, "mode": res.mode, "accounts": len(res.rows), "not_in_segment": res.not_in_segment,
            "table": res.table(), "applied": res.applied, "unverified": res.unverified, "failed": res.failed,
            "skipped": res.skipped, "holds_cleared": res.holds_cleared, "cap": res.cap, "over_cap": res.over_cap,
            "halted": res.halted}


def shown_ext(x: str) -> str:
    """An external_id as the artifacts show it: an id-shaped value verbatim, anything else (e.g. an
    email someone typed into Intercom) as a short hash, so no output ever carries an email (QA @28ddcca)."""
    if not x or EXT_RE.match(x):
        return x
    return "<redacted sha256:" + hashlib.sha256(x.encode()).hexdigest()[:12] + ">"


def write_outputs(res: Result, out_dir: str) -> list[str]:
    """<run>.json (every row, ids only), <run>.md (the A1-A5 table + rows) and <run>-cs.json (the rows
    for cs-systemic-issues-lane-c1: A3, refused A4, A5; account ids, never an email). Mode 0700 dir."""
    d = Path(out_dir)
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    rows = [asdict(r) for r in res.rows]
    for r in rows:
        r["class"] = r.pop("cls")
        r["old_external_id"] = shown_ext(r["old_external_id"])
        r["why"] = _scrub(r["why"])
    base = d / res.run_id
    Path(f"{base}.json").write_text(json.dumps({"run_id": res.run_id, "mode": res.mode, "summary": summary(res),
                                                "rows": rows}, indent=1))
    cs = [{k: r[k] for k in ("account_id", "other_account_ids", "contact_id", "old_external_id", "class", "why", "sources")}
          for r in rows if r["decision"] in CS_DECISIONS]
    Path(f"{base}-cs.json").write_text(json.dumps({"run_id": res.run_id, "for": "cs-systemic-issues-lane-c1",
                                                   "note": "identity conflicts and held contacts: no message to anyone "
                                                           "until cs rules (Fable ruling A3/A4/A5)", "rows": cs}, indent=1))
    Path(f"{base}.md").write_text(render_markdown(res))
    return [f"{base}.json", f"{base}.md", f"{base}-cs.json"]


ORDER = ("A1", "A2", "A3", "A4", "A5", "NONE", "OK")


def render_markdown(res: Result) -> str:
    t = res.table()
    decisions = sorted({d for v in t.values() for d in v})
    lines = [f"# intercom-reconcile {res.run_id} ({res.mode})", "",
             "| class | " + " | ".join(decisions) + " | total |", "|---|" + "---|" * (len(decisions) + 1)]
    for cls in [c for c in ORDER if c in t] + sorted(c for c in t if c not in ORDER):
        v = t[cls]
        lines.append(f"| {cls} | " + " | ".join(str(v.get(d, 0)) for d in decisions) + f" | {sum(v.values())} |")
    lines += ["", f"accounts {len(res.rows)}; not in segment {res.not_in_segment}", "",
              "| account | contact | old external_id | class | decision | why |", "|---|---|---|---|---|---|"]
    for r in res.rows:
        lines.append(f"| {r.account_id} | {r.contact_id} | {shown_ext(r.old_external_id) or '(empty)'} | {r.cls} | {r.decision} | "
                     f"{_scrub(r.why).replace('|', '/')} |")
    return "\n".join(lines) + "\n"


def render(res: Result) -> str:
    if res.halted:
        return f"INTERCOM RECONCILE: NOTHING written: {res.halted}."
    t = res.table()
    parts = [f"INTERCOM RECONCILE ({res.mode}, run {res.run_id}): {len(res.rows)} accounts"]
    parts.append("; ".join(f"{c} " + ", ".join(f"{d} {n}" for d, n in sorted(t[c].items()))
                           for c in [c for c in ORDER if c in t] + sorted(c for c in t if c not in ORDER)))
    if res.mode == "apply":
        parts.append(f"written {res.applied} (cap {res.cap}), unverified {res.unverified}, failed {res.failed}, "
                     f"skipped {res.skipped}, over cap {res.over_cap}, refusal holds lifted {res.holds_cleared}")
    if res.errors:
        parts.append("errors: " + "; ".join(res.errors[:3]))
    return ". ".join(parts) + "."
