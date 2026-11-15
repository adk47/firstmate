#!/usr/bin/env python3
"""The proof reviewer: the AI writer of `verify_proof_reviews`.

A note is "under review" once `verify_messages.proof_tagged_at` is set (`proof_marker.py`, or the Intercom tag
sweep's `verify_ledger.mark_tagged`). Until 2026-11-13 the only thing that could then write a verdict was a person
typing `credit-review.py --proof-review`, and nobody did: `verify_proof_reviews` had zero rows, ever, while
doc-verify had already read the documents. This module is the reviewer. No person is part of it.

What it reads (read-only): the doc-verify store (`dv_outcomes`, the outcome doc-verify's gate reached from the
model's extraction plus forensics and independent cross-checks; `dv_intake_keys`/`dv_intake_unmatched`, the claim
keys doc-verify committed to read for a filing and the ones its fan-out cut did not match, falling back to the
newest `dv_steps` `intake_keys` row when the table has none; `dv_llm_calls`, the model
that extracted) and `proof_intake` (which documents are on file for which request). It calls no model itself: the
model's part ended at the extraction, the gate's predicates decided, and this module turns that recorded outcome into
the ledger's per-credit verdict through `verify_ledger.record_proof_review`.

Every credit gets one of two verdicts. There is no third state and no queue for a person:

  accepted   every role this credit claims on the filing has a `verified` read of its own and nothing on the
             request reads forged or contradicted. A verified credit is accepted even when doc-verify holds the
             ACCOUNT (another document of that account was forged or contradicted): the hold governs what we send,
             not whether this document is true. Never removal-due.
  rejected   anything else doc-verify read, with an internal `reason` from `verify_ledger.REJECTION_REASONS`
             (never shown to a customer) AND a specific ask: the need code naming what would satisfy the request,
             taken from the gate that failed. `other_track` is only for a credit doc-verify finished with the filing
             and found no claim for - a key its fan-out cut marked not matched, or another document of the
             account's read and naming nothing of this credit: the verified roles genuinely belong to a different
             act.

The only thing that is not a verdict is `wait_reader`, and that one is our reader's, not the user's: a document on
file that doc-verify has not read, has read only as `unknown`, keyed a role of the credit and neither read nor cut
it (the per-run claim cap), or whose keying was never recorded, gets no verdict at all - not a rejection, not an
ask - however long the reader takes. A role one document proved is never carried by another role, and a role the
reader never recorded is never assumed to be absent from the claim. No clock charges the user for our reader's
backlog. Every run writes
`{"at", "wait_reader", "oldest_days"}` to `--waiting-file` (and prints the same numbers as `wait_reader` and
`wait_reader_oldest_days`), so our backlog is a number someone can read; the queue report that carries it is a
separate change, and until then the file itself is the report. A verdict returns only once a read is `verified`, `unverifiable`, `contradicted` or `forged`.

The ask a customer receives is never written here. `ask_need` is one of the codes the send gate renders
(`intercom-verify-request.sh` `proof_need_line`, campaign `proof-need-ask`, driven by `need_asks.py`: the ONE
reviewed ask path). `ask_route` says whether that path can carry it today: `proof-need-ask`, or `blocked:<cause>`
when the send gate's own rules stop it (counted in every run's output, never silent). A blocked route records NO
ask - `ask_need` and `ask` stay empty, because nothing can send them - so a row never claims a customer was asked
when the message could not leave. The reason-free decline is the `decline` campaign's and is not sent from here
either.

It approves nothing in core, calls no admin API and sends nothing: it writes `verify_proof_reviews` (through
`record_proof_review`) and one `proof_review_decisions` audit row per credit. `revert --run-id RUN` removes the
verdicts a run wrote that nothing has changed since and puts the notes back under review.

Backlog: the same `apply`, bounded by `--max-notes`; a credit that already has a verdict is skipped, so a re-run
decides nothing twice. A rejected credit is decided again only when a new document re-tags its note, which is
`proof_marker.py`'s job.

Kill file: /etc/hydra/proof-reviewer.disabled (exit 0, nothing read or written).

Exit codes: 0 the run's record adds up; 2 a store could not be read (nothing written); 70 (`EX_NO_ROWS`) an
`apply` reached verdicts and not one of them is on file in `verify_proof_reviews` when the ledger is read back
(`unwritten`). The last one is never a quiet success: `verify_proof_reviews` stood at zero rows for as long as it
did because every run that wrote nothing exited 0. A run where every credit waits on our reader reached no
verdict, so it owes no row and exits 0 with its `wait_reader` count: that backlog is the reader's, and the
reader has its own guard (`credit-doc-verify.py` `EX_NO_TRACE`).
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import verify_ledger as vl  # noqa: E402
from credit_verify.docverify import VERSION as DV_VERSION  # noqa: E402

RULE = "pr-1"
LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
DV_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"
KILL = "/etc/hydra/proof-reviewer.disabled"
WAITING = os.environ.get("CREDIT_REVIEW_WAITING", "/var/lib/hydra/credit-review/proof-reader-waiting.json")
MAX_NOTES = 200
EX_NO_ROWS = 70              # EX_SOFTWARE: the run reached verdicts and the ledger holds none of them (unwritten)

# The need codes the send gate renders (intercom-verify-request.sh proof_need_line). A test pins this list to it.
NEED_READABLE = "readable_document"
NEED_COUNTERPARTY = "counterparty_signed_or_registered"
NEED_DASHBOARD = "distributor_dashboard_with_code"
NEED_ISSUER = "issuer_email_from_official_domain"
ASK_NEEDS = (NEED_READABLE, NEED_COUNTERPARTY, NEED_DASHBOARD, NEED_ISSUER)
# What each need asks for, in words for the audit row and the run report. The bytes a customer reads are the send
# gate's approved copy for the same code; nothing here is sent. No line may carry a rejection reason.
ASK_LINES = {
    NEED_READABLE: "the same document as a PDF or a clear photo of the whole page",
    NEED_COUNTERPARTY: "a split sheet or agreement signed by the artist or label, a PRO registration that lists "
                       "you in your role, or a royalty statement that names the track",
    NEED_DASHBOARD: "one screenshot of your distributor dashboard that shows the release and the code we send you",
    NEED_ISSUER: "one line from the issuer's own address confirming your role on the track, or their original "
                 "email with its headers",
}
# need_asks.SENDABLE: the needs the reviewed ask path sends today (a test pins the two equal).
SENDABLE = (NEED_READABLE, NEED_COUNTERPARTY, NEED_DASHBOARD)
ROUTE_ASK = "proof-need-ask"
BLOCKED_HOLD = "blocked:account_on_hold"            # a held account is never messaged (doc-verify hold: forged/contradicted too)
BLOCKED_VERIFY_AT = "blocked:verify_at_off"         # the issuer-email ask is locked (VERIFY_AT_ENABLED=0)
BLOCKED_NO_READ = "blocked:no_unverifiable_read"    # the send gate asks only on an `unverifiable` doc-verify read

DECISIVE = ("forged", "forged_positive", "contradicted")

# Not part of verify_ledger.SCHEMA on purpose (see proof_marker.MARKS): created here, by the only code that reads it.
DECISIONS = """
CREATE TABLE IF NOT EXISTS proof_review_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  rule TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  message_row INTEGER NOT NULL,      -- verify_messages.id of the tagged row the review was recorded against
  family INTEGER NOT NULL,           -- verify_messages.id of the credit's own note
  request_id TEXT NOT NULL,
  account_id TEXT,
  outcome TEXT NOT NULL,             -- accepted | rejected
  reason TEXT,                       -- INTERNAL: one of verify_ledger.REJECTION_REASONS
  ask_need TEXT,                     -- rejected: the need code naming what would satisfy the request
  ask TEXT,                          -- rejected: that need in words (ASK_LINES)
  ask_route TEXT,                    -- rejected: proof-need-ask | blocked:<cause>
  dv_reason TEXT,                    -- INTERNAL: the doc-verify gate's own reason for the row the verdict rests on
  basis_json TEXT NOT NULL,          -- the doc-verify rows read: [{dv_id, proof_id, role, outcome, need}]
  reviewer TEXT NOT NULL,            -- the AI and the model that decided; never a person
  result TEXT NOT NULL,              -- record_proof_review's result: ok | not_on_note | not_tagged | no_message
  cleared_tags_json TEXT NOT NULL DEFAULT '[]',   -- [[verify_messages.id, proof_tagged_at]] this review cleared
  reverted_at TEXT
);
CREATE INDEX IF NOT EXISTS proof_review_decisions_run ON proof_review_decisions(run_id);
"""


class Unreadable(RuntimeError):
    """A store could not be read. Never the same thing as 'no evidence'."""


def _ts(value: Any) -> datetime | None:
    try:
        d = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _stamp(d: datetime) -> str:
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _step_keys(detail_json: Any) -> set[str] | None:
    """The complete claim-key list a `dv_steps` `intake_keys` row records, or None when the row cannot prove one.

    The runner writes `{"candidates": int, "keys": int, "first_keys": keys[:20]}` and, when keying failed,
    `{"error": ...}`: `keys` is a count and `first_keys` is cut at 20, so neither is the list unless the count
    says nothing was cut. A partial list would silently drop a claim key, which is the role-carried-by-another
    defect the keyed-role rule exists to stop."""
    try:
        detail = json.loads(detail_json or "{}")
    except (TypeError, ValueError):
        return None
    if not isinstance(detail, dict):
        return None
    recorded, first = detail.get("keys"), detail.get("first_keys")
    if isinstance(recorded, list) and recorded and all(isinstance(k, str) for k in recorded):
        return set(recorded)
    if isinstance(recorded, int) and not isinstance(recorded, bool) and isinstance(first, list) \
            and len(first) == recorded and all(isinstance(k, str) for k in first):
        return set(first)
    return None


def _ids(raw: Any) -> list[str]:
    try:
        got = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return []
    return [str(x) for x in got] if isinstance(got, list) else []


def _ro(path: str) -> sqlite3.Connection:
    if not Path(path).is_file():
        raise Unreadable(f"{path} does not exist")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    except sqlite3.Error as exc:
        raise Unreadable(f"{path}: {exc}") from exc
    db.row_factory = sqlite3.Row
    return db


@dataclass
class Evidence:
    """What doc-verify recorded, keyed for one credit at a time."""
    rows: dict[str, list[dict[str, Any]]] = field(default_factory=dict)   # request id -> latest row per (doc, role)
    read_files: set[str] = field(default_factory=set)                     # file sha256 doc-verify has an outcome for
    first_read: dict[str, datetime] = field(default_factory=dict)         # file sha256 -> its first outcome's time
    held: set[str] = field(default_factory=set)                           # accounts on a document hold
    models: dict[str, str] = field(default_factory=dict)                  # file sha256 -> the model that extracted it
    docs: dict[str, list[dict[str, Any]]] = field(default_factory=dict)   # account -> its documents on file
    intake: dict[str, dict[str, set[str]]] = field(default_factory=dict)  # intake id -> its claim keys, cut keys


def read_evidence(dv_store: str, proof_store: str) -> Evidence:
    ev = Evidence()
    try:
        with _ro(dv_store) as db:
            for r in db.execute(
                    "SELECT o.id, o.at, o.proof_id, o.request_id, o.role, o.user_id, o.outcome, o.reason, o.need, "
                    "o.account_hold FROM dv_outcomes o JOIN (SELECT MAX(id) id FROM dv_outcomes WHERE version=? "
                    "GROUP BY proof_id, request_id, role) l USING(id)", (DV_VERSION,)):
                ev.rows.setdefault(str(r["request_id"]).lower(), []).append(dict(r))
            for sha, at in db.execute("SELECT proof_id, MIN(at) FROM dv_outcomes WHERE version=? GROUP BY proof_id",
                                      (DV_VERSION,)):
                ev.read_files.add(str(sha))
                first = _ts(at)
                if first is not None:
                    ev.first_read[str(sha)] = first
            ev.held = {str(u) for (u,) in db.execute(
                "SELECT DISTINCT user_id FROM dv_outcomes WHERE account_hold=1 AND user_id IS NOT NULL")}
            for sha, model in db.execute(
                    "SELECT proof_id, model FROM dv_llm_calls WHERE model IS NOT NULL AND model != '' "
                    "AND proof_id IS NOT NULL ORDER BY (outcome IN ('ok','cached')), id"):
                ev.models[str(sha)] = str(model)            # the last row wins: the newest call that answered
            for table, slot in (("dv_intake_keys", "keys"), ("dv_intake_unmatched", "unmatched")):
                for intake_id, keys_json in db.execute(
                        f"SELECT intake_id, keys_json FROM {table} WHERE version=?", (DV_VERSION,)):
                    rec = ev.intake.setdefault(str(intake_id), {"keys": set(), "unmatched": set()})
                    rec[slot] |= {str(k) for k in _ids(keys_json)}
            keyed_from_table = set(ev.intake)
            newest_step: set[str] = set()
            for request_id, detail_json in db.execute(
                    "SELECT request_id, detail_json FROM dv_steps WHERE step='intake_keys' AND version=? "
                    "ORDER BY id DESC", (DV_VERSION,)):
                intake_id = str(request_id)
                if intake_id.startswith("intake:"):
                    intake_id = intake_id[len("intake:"):]
                if intake_id in keyed_from_table or intake_id in newest_step:
                    continue
                newest_step.add(intake_id)     # the newest step decides, as DocVerifyStore.intake_keys_recorded reads it
                keys = _step_keys(detail_json)
                if keys is None:
                    continue
                ev.intake[intake_id] = {"keys": keys, "unmatched": set()}
    except sqlite3.Error as exc:
        raise Unreadable(f"doc-verify store unreadable: {exc}") from exc
    try:
        with _ro(proof_store) as db:
            for r in db.execute("SELECT intake_id, user_id, file_sha256, received_at, candidate_request_ids_json "
                                "FROM proof_intake"):
                ev.docs.setdefault(str(r["user_id"]), []).append(
                    {"intake_id": str(r["intake_id"]), "sha": str(r["file_sha256"]), "at": _ts(r["received_at"]),
                     "account": str(r["user_id"]), "requests": {x.lower() for x in _ids(r["candidate_request_ids_json"])}})
    except sqlite3.Error as exc:
        raise Unreadable(f"proof_intake unreadable: {exc}") from exc
    return ev


@dataclass
class Verdict:
    outcome: str                       # accepted | rejected
    reason: str = ""                   # INTERNAL (REJECTION_REASONS)
    ask_need: str = ""
    ask: str = ""
    ask_route: str = ""
    dv_reason: str = ""                # INTERNAL
    basis: list[dict[str, Any]] = field(default_factory=list)
    model: str = ""

    @property
    def reviewer(self) -> str:
        return reviewer_name(self.model)

    def public(self) -> dict[str, Any]:
        """What may leave this module toward a customer-facing path: the ask, never a reason."""
        return {"outcome": self.outcome, "ask_need": self.ask_need, "ask": self.ask, "ask_route": self.ask_route}


def reviewer_name(model: str) -> str:
    """The AI that decided and the model whose extraction it decided on. Never a person's name."""
    return f"ai:proof-reviewer/{RULE} doc-verify/{DV_VERSION} model={model or 'none-recorded'}"


def reason_for(row: dict[str, Any] | None) -> str:
    """The internal rejection code for the doc-verify row a rejection rests on (REJECTION_REASONS only)."""
    if row is None:
        return "unreadable"
    outcome, need, why = str(row.get("outcome") or ""), str(row.get("need") or ""), str(row.get("reason") or "")
    if outcome == "unknown" or need == NEED_READABLE or "claims not extracted" in why \
            or "sender address unreadable" in why:
        return "unreadable"
    if "credits the claimant on other tracks" in why:
        return "other_track"
    if "does not name the claimant" in why or outcome == "contradicted":
        return "doesnt_name_you"
    # forged, a panel or screenshot that is not a document of record, or a document nothing outside confirms
    return "not_a_document"


def ask_for(row: dict[str, Any] | None, reason: str, held: bool) -> tuple[str, str]:
    """(need code, route) of the specific ask: the failing gate's own need when it names one."""
    outcome = str((row or {}).get("outcome") or "")
    given = str((row or {}).get("need") or "")
    need = given if given in ASK_NEEDS else (NEED_READABLE if reason == "unreadable" else NEED_COUNTERPARTY)
    if held or outcome in DECISIVE:
        # doc-verify holds the account on a forged or contradicted read (gate.py NEED_ACCOUNT): never messaged
        return need, BLOCKED_HOLD
    if need == NEED_ISSUER:
        return need, BLOCKED_VERIFY_AT
    if outcome == "unverifiable" and need in SENDABLE and need == given:
        return need, ROUTE_ASK
    return need, BLOCKED_NO_READ


def _filing_claims(ev: Evidence, doc: dict[str, Any], rid: str) -> tuple[set[str], set[str]] | None:
    """(the roles doc-verify keyed for this credit on the filing, the roles its fan-out cut did not match),
    or None when the filing's keying was never recorded: the claimed roles are then not knowable."""
    rec = ev.intake.get(str(doc["intake_id"]))
    if rec is None:
        return None
    def roles(slot: str) -> set[str]:
        return {k.rpartition("#")[2] for k in rec[slot] if k.rpartition("#")[0].strip().lower() == rid}
    return roles("keys"), roles("unmatched")


def _credit_docs(ev: Evidence, rid: str, account: str) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]] | None:
    """The filings that name this credit, and their documents by sha256: the note's own account's when the note
    carries one, otherwise every filing naming the credit - and None when filings of more than one account name it,
    because an account-less note cannot say which is its own."""
    if account:
        mine = ev.docs.get(account, [])
    else:
        mine = [d for ds in ev.docs.values() for d in ds]
        owners = {str(d.get("account") or "") for d in mine if rid in d["requests"]} - {""}
        if len(owners) > 1:
            return None
    return [d for d in mine if rid in d["requests"]], {d["sha"]: d for d in mine}


def judge(request_id: str, account: str, ev: Evidence, *, now: datetime) -> Verdict | None:
    """The verdict for one credit, or None while the credit still waits on the AI reader - a document on file it
    has not read, a read that came back `unknown`, or nothing read for the credit at all. Reads only. Never returns a
    state that waits for a person, and `unreadable` only follows a read doc-verify made and recorded as such.

    The wait is checked BEFORE acceptance: one verified read does not rule a credit while another document for it
    is unread or read `unknown`. Once every document is read, a verified read stands: an `unverifiable` read of
    the SAME role does not reopen it, and a role with no verified read of its own is never carried by another's.
    Acceptance is decided on the roles doc-verify KEYED for the credit on the filing (`dv_intake_keys`), not only on
    the rows it wrote: a keyed role with no row and no fan-out marker is still our reader's turn, and a filing whose
    keying was never recorded is not judged at all. A key the fan-out cut marked not matched is a read filing with
    no claim for the credit: `other_track`."""
    rid = str(request_id).lower()
    rows = [r for r in ev.rows.get(rid, [])
            if not account or r.get("user_id") is None or str(r["user_id"]) == account]
    filed = _credit_docs(ev, rid, account)
    if filed is None:
        return None                        # more than one account's filings name it: never a verdict on an assumption
    docs, by_sha = filed
    mine = ev.docs.get(account, []) if account else docs
    held = bool(account) and account in ev.held or any(int(r.get("account_hold") or 0) for r in rows)

    def arrived(sha: str) -> datetime | None:
        d = by_sha.get(sha)
        return (d["at"] if d and d["at"] else None) or ev.first_read.get(sha)

    basis = [{"dv_id": r["id"], "proof_id": r["proof_id"], "role": r["role"], "outcome": r["outcome"],
              "need": r.get("need")} for r in sorted(rows, key=lambda r: int(r["id"]))]
    model = next((ev.models[r["proof_id"]] for r in sorted(rows, key=lambda r: -int(r["id"]))
                  if r["proof_id"] in ev.models), "")
    roles = {str(r["role"]) for r in rows}
    proven = {str(r["role"]) for r in rows if r["outcome"] == "verified"}
    recorded = {str(r["role"]) for r in ev.rows.get(rid, [])}   # any read of the key, whatever user it named
    # what doc-verify COMMITTED to read for the credit, not just what it happened to record: a role it keyed and
    # neither read nor cut is still our reader's, and a filing whose keying we cannot see is never judged
    claimed: set[str] = set()
    cut: set[str] = set()
    unread = False
    for d in docs:
        got = _filing_claims(ev, d, rid)
        if got is None:
            return None                    # the claimed roles cannot be known: never a verdict on an assumption
        keyed, dropped = got
        claimed |= keyed
        cut |= dropped
        if d["sha"] not in ev.read_files and not (keyed and keyed <= dropped):
            unread = True                  # a document doc-verify has an outcome for nothing on, for this credit
    # the AI reader's turn first, with no clock on it: it owns the credit until every document has an answer
    if unread or claimed - recorded - cut or any(r["outcome"] == "unknown" for r in rows):
        return None
    if not claimed:
        claimed = roles                    # no filing on file for the credit: the roles doc-verify wrote are its claim
    if claimed and claimed <= proven and roles == proven and not any(r["outcome"] in DECISIVE for r in rows):
        # every role this credit claims on the filing has a verified read of its own: accepted, whether or not the
        # account is on hold, and whatever another document said about a role that is already proven
        return Verdict("accepted", basis=basis, model=model)
    failing = [r for r in rows if r["outcome"] != "verified"]
    row: dict[str, Any] | None = None
    if failing:
        # the decisive read first, then the newest document, a reader failure last
        def order(r: dict[str, Any]) -> tuple[int, float, int]:
            at = arrived(r["proof_id"])
            rank = 0 if r["outcome"] in DECISIVE else 2 if r["outcome"] == "unknown" else 1
            return rank, -(at.timestamp() if at else 0.0), -int(r["id"])
        row = sorted(failing, key=order)[0]
        reason = reason_for(row)
        if proven and row["outcome"] not in DECISIVE and reason != "unreadable":
            reason = "other_role"          # the document proves one of the request's roles and not this one
    elif cut or any(d["sha"] in ev.read_files for d in mine):
        reason = "other_track"             # the reader read the account's document and found no claim for this credit
    else:
        return None                        # nothing was read for this credit: our reader's, never a verdict on the user
    need, route = ask_for(row, reason, held)
    told = route != BLOCKED_NO_READ and not route.startswith("blocked:")
    return Verdict("rejected", reason=reason,
                   ask_need=need if told else "", ask=ASK_LINES[need] if told else "",
                   ask_route=route, dv_reason=str((row or {}).get("reason") or ""), basis=basis, model=model)


def under_review(db: sqlite3.Connection) -> tuple[list[dict[str, Any]], Counter]:
    """Every sent credit note with a tagged proof no review has ruled on yet, oldest tag first. Reads only."""
    try:
        rows = db.execute(
            "SELECT id, message_id, campaign, account_id, parent_row, request_ids_json, proof_tagged_at "
            "FROM verify_messages WHERE status='sent' AND proof_tagged_at IS NOT NULL "
            "ORDER BY proof_tagged_at, id").fetchall()
        roots = sorted({int(r["parent_row"] or r["id"]) for r in rows})
        notes: dict[int, sqlite3.Row] = {}
        if roots:
            q = ",".join("?" * len(roots))
            notes = {int(r["id"]): r for r in db.execute(
                f"SELECT id, account_id, request_ids_json FROM verify_messages WHERE id IN ({q})", roots)}
        reviewed = {(int(f), str(r)) for f, r in db.execute(
            "SELECT family, request_id FROM verify_proof_reviews")}
        note_of = vl.note_index(db).get
    except sqlite3.Error as exc:
        raise Unreadable(f"verify ledger unreadable: {exc}") from exc
    n: Counter = Counter()
    out: list[dict[str, Any]] = []
    planned: set[tuple[int, str]] = set()
    for r in rows:
        if str(r["campaign"]) in vl.CLAIM_CAMPAIGNS:
            n["claim_notes_not_credits"] += 1             # a claim's document is the claim-doc ladder's
            continue
        root = int(r["parent_row"] or r["id"])
        note = notes.get(root)
        covered = list(dict.fromkeys((_ids(note["request_ids_json"]) if note is not None else [])
                                     + _ids(r["request_ids_json"])))
        todo, dup = [], 0
        for rid in covered:
            fam = note_of(rid) or root
            if (fam, rid) in reviewed:
                n["already_ruled"] += 1
                continue
            if (fam, rid) in planned:                     # one verdict per credit per run, whatever names it
                dup += 1
                continue
            planned.add((fam, rid))
            todo.append({"request_id": rid, "family": fam})
        if not todo:
            if not dup:
                n["notes_fully_reviewed"] += 1
            continue
        n["notes_under_review"] += 1
        n["credits_unreviewed"] += len(todo)
        out.append({"row": int(r["id"]), "message_id": r["message_id"], "root": root,
                    "account": str(r["account_id"] or (note["account_id"] if note is not None else "") or "").strip(),
                    "credits": todo})
    return out, n


def waiting_since(request_id: str, account: str, ev: Evidence) -> datetime | None:
    """When the credit's oldest unread or `unknown` document arrived: how long our reader has owed us an answer."""
    rid = str(request_id).lower()
    rows = [r for r in ev.rows.get(rid, [])
            if not account or r.get("user_id") is None or str(r["user_id"]) == account]
    unknown = {str(r["proof_id"]) for r in rows if str(r.get("outcome") or "") == "unknown"}
    filed = _credit_docs(ev, rid, account)
    if filed is None:
        return None
    when = []
    for d in filed[0]:
        if not d["at"]:
            continue
        got = _filing_claims(ev, d, rid)
        keyed, dropped = got if got is not None else (set(), set())
        read_roles = {str(r["role"]) for r in ev.rows.get(rid, []) if str(r.get("proof_id")) == d["sha"]}
        owed = keyed - read_roles - dropped
        if d["sha"] in unknown or owed or (got is None and d["sha"] not in ev.read_files) \
                or (d["sha"] not in ev.read_files and not (keyed and keyed <= dropped)):
            when.append(d["at"])
    return min(when) if when else None


def plan(db: sqlite3.Connection, ev: Evidence, *, now: datetime,
         max_notes: int = MAX_NOTES) -> tuple[list[dict[str, Any]], Counter]:
    """(the verdicts to record per note, counts). Reads only."""
    notes, n = under_review(db)
    out: list[dict[str, Any]] = []
    oldest: datetime | None = None
    for note in notes:
        decided = []
        for c in note["credits"]:
            v = judge(c["request_id"], note["account"], ev, now=now)
            if v is None:
                n["wait_reader"] += 1
                since = waiting_since(c["request_id"], note["account"], ev)
                if since is not None and (oldest is None or since < oldest):
                    oldest = since
                continue
            decided.append({**c, "verdict": v})
        if not decided:
            continue
        if len(out) >= max_notes:
            n["notes_left_for_next_run"] += 1
            continue
        for c in decided:
            v = c["verdict"]
            n[v.outcome] += 1
            if v.outcome == "rejected":
                n["reason:" + v.reason] += 1
                if v.ask_need:
                    n["ask:" + v.ask_need] += 1
                n["ask_route:" + (v.ask_route or "none")] += 1
        out.append({**note, "credits": decided})
    if oldest is not None:
        n["wait_reader_oldest_days"] = max(0, int((now - oldest).total_seconds() // 86400))
    return out, n


def apply(db: sqlite3.Connection, todo: list[dict[str, Any]], *, run_id: str, now: datetime) -> Counter:
    """Record each verdict through verify_ledger.record_proof_review, with one audit row per credit.

    The whole run is ONE transaction: every verdict, its audit row, the tags the run settles and the record of
    which tags it cleared land together or not at all. A run killed anywhere leaves the ledger as it found it,
    so there is never a verdict `revert --run-id` cannot see, nor a cleared tag no row remembers."""
    ts, n = _stamp(now), Counter()
    db.executescript(DECISIONS)
    db.execute("BEGIN IMMEDIATE")
    try:
        _apply(db, todo, run_id=run_id, ts=ts, now=now, n=n)
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise
    return n


def _apply(db: sqlite3.Connection, todo: list[dict[str, Any]], *, run_id: str, ts: str, now: datetime,
           n: Counter) -> None:
    """apply()'s writes, inside the transaction apply() holds: this function begins and commits nothing."""
    settles: list[dict[str, Any]] = []
    for note in todo:
        fams = sorted({c["family"] for c in note["credits"]} | {note["root"], note["row"]})
        marks = ",".join("?" * len(fams))
        tagged = [(int(i), str(t)) for i, t in db.execute(
            f"SELECT id, proof_tagged_at FROM verify_messages WHERE (id IN ({marks}) OR parent_row IN ({marks})) "
            "AND proof_tagged_at IS NOT NULL", (*fams, *fams))]
        covered: set[str] = {c["request_id"] for c in note["credits"]}
        for (ids_json,) in db.execute(
                f"SELECT request_ids_json FROM verify_messages WHERE id IN ({marks}) OR parent_row IN ({marks})",
                (*fams, *fams)):
            covered |= set(_ids(ids_json))
        written: list[int] = []
        groups: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
        for c in note["credits"]:
            v: Verdict = c["verdict"]
            groups.setdefault((v.outcome, v.reason, v.reviewer), []).append(c)
        for (outcome, reason, reviewer), credits in groups.items():
            got = vl.record_proof_review(db, message_id=str(note["message_id"] or ""), message_row=note["row"],
                                         request_ids=[c["request_id"] for c in credits], outcome=outcome,
                                         reviewer=reviewer, reason=reason, now=now, settle=False,
                                         transaction=False)
            n["record:" + str(got.get("result"))] += len(credits)
            for c in credits:
                v = c["verdict"]
                cur = db.execute(
                    "INSERT INTO proof_review_decisions (run_id, rule, decided_at, message_row, family, request_id, "
                    "account_id, outcome, reason, ask_need, ask, ask_route, dv_reason, basis_json, "
                    "reviewer, result) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (run_id, RULE, ts, note["row"], c["family"], c["request_id"], note["account"] or None, v.outcome,
                     v.reason or None, v.ask_need or None, v.ask or None, v.ask_route or None,
                     v.dv_reason or None, json.dumps(v.basis), reviewer, str(got.get("result"))))
                if got.get("result") == "ok":
                    written.append(int(cur.lastrowid))
                    n["recorded"] += 1
        if written:
            settles.append({"root": note["root"], "covered": sorted(covered), "written": written,
                            "tagged": tagged, "marks": marks, "fams": fams})
    for s in settles:
        vl.settle_proof_tags(db, root=s["root"], covered=s["covered"], now=now)
    for s in settles:
        marks, fams = s["marks"], s["fams"]
        still = {int(i) for (i,) in db.execute(
            f"SELECT id FROM verify_messages WHERE (id IN ({marks}) OR parent_row IN ({marks})) "
            "AND proof_tagged_at IS NOT NULL", (*fams, *fams))}
        cleared = [[i, t] for i, t in s["tagged"] if i not in still]
        if cleared:
            written = s["written"]
            db.execute(f"UPDATE proof_review_decisions SET cleared_tags_json=? WHERE id IN "
                       f"({','.join('?' * len(written))})", (json.dumps(cleared), *written))


def revert(db: sqlite3.Connection, *, run_id: str, now: datetime) -> dict[str, int]:
    """Remove the verdicts `run_id` wrote and put its notes back under review. A verdict something else has
    rewritten since is left and counted."""
    ts, out = _stamp(now), Counter()
    db.executescript(DECISIONS)
    db.execute("BEGIN IMMEDIATE")
    try:
        for d in db.execute("SELECT * FROM proof_review_decisions WHERE run_id=? AND reverted_at IS NULL "
                            "AND result='ok'", (run_id,)).fetchall():
            cur = db.execute("DELETE FROM verify_proof_reviews WHERE family=? AND request_id=? AND reviewed_by=? "
                             "AND reviewed_at=?", (d["family"], d["request_id"], d["reviewer"], d["decided_at"]))
            if cur.rowcount != 1:
                out["changed_since"] += 1
                continue
            for row, tagged_at in json.loads(d["cleared_tags_json"] or "[]"):
                db.execute("UPDATE verify_messages SET proof_tagged_at=?, updated_at=? WHERE id=? "
                           "AND proof_tagged_at IS NULL", (tagged_at, ts, row))
            db.execute("UPDATE proof_review_decisions SET reverted_at=? WHERE id=?", (ts, d["id"]))
            out["reverted"] += 1
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return {"reverted": out["reverted"], "changed_since": out["changed_since"]}


def unwritten(processed: int, written: int, run_id: str) -> str | None:
    """Why this `apply` failed although nothing raised, or None when its record adds up.

    `processed` is the credits the run reached a verdict for and handed to `record_proof_review` (within
    `--max-notes`); a credit waiting on our reader is not one of them, because the run reached nothing for it.
    `written` is the `verify_proof_reviews` rows found on file for this run (`on_file`), never the counter the run
    kept for itself. Verdicts reached and no row on file is a failure. Some rows on file is not: a credit the
    ledger refused (`record:not_tagged` and the like) is counted in the run's output and audited row by row."""
    if processed > 0 and written == 0:
        return (f"reached {processed} verdict(s) and wrote zero verify_proof_reviews rows under {run_id}: "
                "no credit on a tagged note was reviewed by this run")
    return None


def decision_floor(db: sqlite3.Connection) -> int:
    """The newest audit row before this run writes (0 when the table is not there yet): two runs inside one second
    share a `run_id`, and a run must never count another run's rows as its own."""
    there = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='proof_review_decisions'").fetchone()
    if there is None:
        return 0
    return int(db.execute("SELECT COALESCE(MAX(id), 0) FROM proof_review_decisions").fetchone()[0])


def on_file(path: str, run_id: str, floor: int) -> int:
    """The `verify_proof_reviews` rows this run left on file, read back on a connection of its own after the
    commit. A verdict is this run's when its audit row (newer than `floor`, `result` ok) names the row that is
    there now: the same match `revert` deletes on."""
    db = _ro(path)
    try:
        return int(db.execute(
            "SELECT COUNT(*) FROM proof_review_decisions d JOIN verify_proof_reviews v ON v.family=d.family "
            "AND v.request_id=d.request_id AND v.reviewed_by=d.reviewer AND v.reviewed_at=d.decided_at "
            "WHERE d.run_id=? AND d.id>? AND d.result='ok' AND d.reverted_at IS NULL", (run_id, floor)).fetchone()[0])
    finally:
        db.close()


def _rw(path: str) -> sqlite3.Connection:
    if not Path(path).is_file():
        raise Unreadable(f"{path} does not exist (the reviewer never creates a ledger)")
    db = vl.ledger_open().open_rw(path, opener="credit_review.proof_reviewer", timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def write_waiting(path: str, *, now: datetime, n: Counter) -> None:
    """Our own backlog, where the operator's report reads it: how many credits wait on the reader, how old."""
    body = {"at": _stamp(now), "wait_reader": int(n.get("wait_reader") or 0),
            "oldest_days": int(n.get("wait_reader_oldest_days") or 0)}
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(body))
    os.replace(tmp, p)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("op", choices=("plan", "apply", "revert"))
    p.add_argument("--ledger", default=LEDGER)
    p.add_argument("--dv-store", default=DV_STORE)
    p.add_argument("--store", default=PROOF_STORE, help="the proof store (proof_intake)")
    p.add_argument("--kill-file", default=KILL)
    p.add_argument("--waiting-file", default=WAITING,
                   help="where the run's reader backlog is written for the operator's report")
    p.add_argument("--max-notes", type=int, default=MAX_NOTES, help="notes decided per run (the backlog bound)")
    p.add_argument("--list", action="store_true", help="plan: print each verdict's ask (never a reason)")
    p.add_argument("--run-id", default=None, help="revert: the run to undo")
    a = p.parse_args(argv)
    if Path(a.kill_file).exists():
        print(json.dumps({"op": a.op, "killed": a.kill_file}))
        return 0
    if a.max_notes < 1:
        p.error("--max-notes must be >= 1")
    now = datetime.now(timezone.utc)
    try:
        if a.op == "revert":
            if not a.run_id:
                p.error("revert needs --run-id")
            print(json.dumps({"op": "revert", "run_id": a.run_id, **revert(_rw(a.ledger), run_id=a.run_id, now=now)}))
            return 0
        ev = read_evidence(a.dv_store, a.store)
        db = _rw(a.ledger) if a.op == "apply" else _ro(a.ledger)
        todo, n = plan(db, ev, now=now, max_notes=a.max_notes)
        out: dict[str, Any] = {"op": a.op, "rule": RULE, "doc_verify": DV_VERSION, **dict(sorted(n.items()))}
        silent: str | None = None
        if a.op == "apply":
            out["run_id"] = "pr-" + now.strftime("%Y%m%dT%H%M%SZ")
            floor = decision_floor(db)
            out.update(dict(sorted(apply(db, todo, run_id=out["run_id"], now=now).items())))
            processed = sum(len(note["credits"]) for note in todo)
            if processed:
                out["on_file"] = on_file(a.ledger, out["run_id"], floor)
                silent = unwritten(processed, out["on_file"], out["run_id"])
        elif a.list:
            out["verdicts"] = [{"request_id": c["request_id"], **c["verdict"].public()}
                               for note in todo for c in note["credits"]]
        write_waiting(a.waiting_file, now=now, n=n)
        if silent:
            # the run's counters are still printed: they say where the verdicts went (`record:<result>`)
            print(json.dumps({**out, "error": silent}))
            return EX_NO_ROWS
        print(json.dumps(out))
        return 0
    except (Unreadable, sqlite3.Error, OSError) as exc:
        print(json.dumps({"op": a.op, "error": str(exc)[:300]}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
