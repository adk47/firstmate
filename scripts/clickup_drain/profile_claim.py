#!/usr/bin/env python3
"""Drain the `action:profile-claim` queue: read the claim in core, tag the outcome.

THE QUEUE
---------
Measured 2026-11-03 23:4xZ on the live board (901000600160): 238 OPEN
`action:profile-claim` tickets ("I want to claim this profile"). `outcomeChannelFor
("profile-claim")` is `app_notification` — the claim lane's own message reaches
the customer in the app and by email, NOT as an Intercom reply — so this queue
is the one whose customer-visible outcome already has an owner, and the ticket
only has to record it.

WHAT IT DOES (per ticket, read-only, then at most ONE tag)
----------------------------------------------------------
  LINK     identity from the #417 fields: User Email -> core user id, Profile
           ID, Intercom link. Nothing else is guessed.
  RESOLVE  the claim rows for that account+profile out of `postgresql_core
           .public.claiming` (not deleted, created on/after the ticket's
           creation minus one day — a claim older than the ask is not the claim
           this ticket is about). A claim on that SAME profile by that SAME
           account that predates the window is still kept, because the pair is
           the identity key: measured 2026-11-03, 68 of the 80 such tickets had
           that pair already `processed`, i.e. the profile was theirs before they
           asked and the ask is already satisfied. Only an APPROVED predated
           claim closes anything; a pending or rejected one is reported.
  DECIDE   one of the four terminal determinations, from core status only:
             `processed`  the claim was APPROVED. -> `customer-outcome:complete`
             `rejected`   by the claim executor (its audit row for this claim
                          id says outcome=written, after=rejected) -> `complete`
                          as well: core's `profile_claim_rejected` fan-out is the
                          outcome the customer was told, and the executor only
                          moves a row after reading the rejection back.
             `pending`/`reverted` with a coded contradiction class that has not
                          been executed -> a `claim_executor` TRAY ROW carrying
                          the coded ruling id. The ticket stays `waiting-on-us`
                          (no tag) until the executor's own read-back says
                          `rejected`; the next run then tags it complete.
             `pending`/`reverted` still awaiting identity proof (no submitted
                          link and no domain email on the claim) -> `customer-
                          outcome:verification-required`, and ONLY when
                          `claim_proof_ask` recorded an ask for that claim.
             no claim row at all -> `drain:awaiting-user-submission`: the
                          customer never started the claim in the app, so the
                          ask campaign (`claim-proof-ask`) is what talks to
                          them. On the live board this is the LARGEST bucket,
                          and saying so is the deliverable. (The first measured
                          run put it at 164 of 238; the runbook carries the
                          current numbers — do not read this line as today's
                          queue count.)

Every other shape is REPORTED and never written: a rejection by a human in
Retool (no executor audit row), a `closed` claim, a claim older than the window,
several claims for one ticket with no profile id to disambiguate, an email that
resolves to no account. "Not in the four determinations" is not permission.

WHAT IT MUST NOT DO — AND DOES NOT
----------------------------------
* **Never approves a claim.** `POST /admin/claiming/:id/verify` writes catalog
  identity and hydra has never used it; `scripts/check-credit-approval-
  automation.sh` would also have to register anything that could. Approval stays
  with the existing human/verification flow. `tests/test_clickup_drain_profile_
  claim.py` fails if the word `/verify` ever appears next to the admin path.
* **Never writes a reject itself.** A contradiction is handed to
  `claim_executor` as a tray row; `credit-fable-execute.py` is on that gate's
  NEVER_SCHEDULED list, so this drainer writes the tray and prints the command
  instead of running it.
* **Never sends customer copy, never writes a ClickUp status.** The tag is the
  output. `resolve-notify.py` (profile-claim IS in its ALLOWLIST) sends the one
  approved line; `clickup-reconcile.py` owns the `resolved` status;
  `close-resolved-conversations.py` closes the conversation when we spoke last.
  For an `app_notification` class the Intercom close may legitimately not fire
  because we never replied in-thread — the digest reports that instead of
  writing a reply to make the close fit.

SAFETY
------
`--dry-run` is the default; `--apply` writes. Cap: 100 tag writes per run
(`--max-writes`, first live batch run at 20). Kill file
`/etc/hydra/clickup-drain-profile-claim.disabled`. Shared write lock with
`claim_executor` (`/var/lib/hydra/credit-status-writes.lock`) — both touch the
claim tray. Ledger `/var/lib/hydra/clickup-drain/profile-claim.jsonl`, written
BEFORE each network call; `--revert <ledger>` deletes exactly the tags it added.
Stops on the first surprise (a read-back that does not show the tag, a non-2xx,
an unreadable core read): a drainer that writes past a surprise is how a tag
lands on the wrong ticket.

USAGE
  ./profile_claim.py                          # dry run: counts + every would-close ticket
  ./profile_claim.py --json                   # the same, machine-readable
  ./profile_claim.py --apply --max-writes 20  # the first live batch
  ./profile_claim.py --revert /var/lib/hydra/clickup-drain/profile-claim.jsonl --apply

ENV
  CLICKUP_API_KEY / MUSOAI_CLICKUP_API_KEY   board token (required)
  CLICKUP_DRAIN_LIST                         list id (default 901000600160)
  CLICKUP_DRAIN_STATE                        state dir (default /var/lib/hydra/clickup-drain)
  CLICKUP_DRAIN_PROFILE_CLAIM_KILL           kill file
  CLICKUP_DRAIN_PROFILE_CLAIM_LEDGER         ledger path (default <state>/profile-claim.jsonl)
  CLICKUP_DRAIN_EXECUTOR_AUDIT               claim_executor audit
                                             (default /var/lib/hydra/credit-review/fable-decider-audit.jsonl)
  CLICKUP_DRAIN_CLAIM_ASKED                  claim_proof_ask's asked export
                                             (default /var/lib/hydra/credit-review/claim-proof-asked.jsonl)
  CLICKUP_DRAIN_TRINO                        read-only Trino runner (default /opt/hydra/scripts/trino-query.sh)
  CLICKUP_DRAIN_WRITE_LOCK                   shared lock (default /var/lib/hydra/credit-status-writes.lock)
"""
from __future__ import annotations

import argparse
import collections
import csv
import dataclasses
import datetime as dt
import io
import json
import os
import pathlib
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SCRIPTS_DIR = SCRIPT_DIR.parent
for _p in (str(SCRIPTS_DIR), str(SCRIPT_DIR)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from lib import clickup_client  # noqa: E402
from clickup_drain import common  # noqa: E402
from clickup_drain.common import Surprise, CapReached, LockHeld  # noqa: E402

# The coded decline rules and their facts. Imported, never re-implemented: the
# ruling ids are per-item decisions produced by code (captain 2026-10-29), and a
# second copy here would drift from what the executor re-runs.
from claim_verify import decline_rules  # noqa: E402
from credit_review import account_gate  # noqa: E402
from credit_review import claim_executor as cx  # noqa: E402
from credit_review import fable_executor as fx  # noqa: E402

DRAIN_TAG = "drain:awaiting-user-submission"
OUTCOME_COMPLETE = "customer-outcome:complete"
OUTCOME_VERIFICATION = "customer-outcome:verification-required"

ACTION = "profile-claim"
# A claim must have been created on/after the ticket minus this slack: the ticket
# and the in-app claim are minutes apart at worst, and a claim from last month is
# not the one this ticket is about.
WINDOW_SLACK_S = 86_400

MAX_TAG_WRITES = 100
DEFAULT_MAX_GATE_CALLS = 25

STATE_DIR = os.environ.get("CLICKUP_DRAIN_STATE", "/var/lib/hydra/clickup-drain")
LEDGER_PATH = os.environ.get("CLICKUP_DRAIN_PROFILE_CLAIM_LEDGER",
                             os.path.join(STATE_DIR, "profile-claim.jsonl"))
TRAY_DIR = os.path.join(STATE_DIR, "profile-claim", "trays")
KILL_FILE = os.environ.get("CLICKUP_DRAIN_PROFILE_CLAIM_KILL",
                           "/etc/hydra/clickup-drain-profile-claim.disabled")
EXECUTOR_AUDIT = os.environ.get("CLICKUP_DRAIN_EXECUTOR_AUDIT",
                                "/var/lib/hydra/credit-review/fable-decider-audit.jsonl")
CLAIM_ASKED = os.environ.get("CLICKUP_DRAIN_CLAIM_ASKED",
                             "/var/lib/hydra/credit-review/claim-proof-asked.jsonl")
TRINO = os.environ.get("CLICKUP_DRAIN_TRINO", "/opt/hydra/scripts/trino-query.sh")
WRITE_LOCK = os.environ.get("CLICKUP_DRAIN_WRITE_LOCK",
                            "/var/lib/hydra/credit-status-writes.lock")
# The executor's kill switch is a TUPLE of paths, not one: `fable_executor`
# honours both the current name and the legacy one so a host rename or a rollback
# never silently re-enables the executor. Read it from the module rather than
# restating the paths here, so a rename upstream cannot leave this note lying
# about which file a human has to remove. `CLICKUP_DRAIN_EXECUTOR_KILL` still
# overrides the whole set (one path) for tests and for a host that moved it.
EXECUTOR_KILL = ((os.environ["CLICKUP_DRAIN_EXECUTOR_KILL"],)
                 if os.environ.get("CLICKUP_DRAIN_EXECUTOR_KILL") else tuple(fx.KILL_FILES))

# Core's successful-claim status is `processed` (services/claiming/statusTransitions
# .js; KNOWN_STATUSES in plugins/support-tools/src/tools/profile-claim-status.ts).
# There is no `verified` status on `claiming` — a spec that says "verified" means
# this one, and the wrong spelling would silently match nothing.
CLAIM_APPROVED = frozenset({"processed"})
CLAIM_REJECTED = frozenset({"rejected"})
CLAIM_CLOSED = frozenset({"closed"})

# Buckets. Only the first three write a tag; everything below is reported.
B_COMPLETE = "complete"
B_VERIFICATION = "verification-required"
B_AWAITING = "awaiting-user-submission"
B_CONTRADICTION = "contradiction-queued"
B_HELD = "held-for-human"
B_AWAITING_REVIEW = "awaiting-review"
B_PROOF_NO_ASK = "awaiting-proof-no-ask"
B_REJECTED_OUTSIDE = "rejected-outside-executor"
B_CLAIM_CLOSED = "claim-closed"
B_OUTSIDE_WINDOW = "claim-outside-window"
B_AMBIGUOUS = "ambiguous-claims"
B_UNDATED = "ticket-undated"
B_NEEDS_IDENTITY = "needs-identity"

TAG_OF_BUCKET = {B_COMPLETE: OUTCOME_COMPLETE,
                 B_VERIFICATION: OUTCOME_VERIFICATION,
                 B_AWAITING: DRAIN_TAG}
# The cap spends oldest-first, on the buckets that actually close a ticket.
BUCKET_ORDER = (B_COMPLETE, B_VERIFICATION, B_AWAITING)


# ───────────────────────── data shapes ─────────────────────────


@dataclass(frozen=True)
class Ticket:
    id: str
    status: str
    created_s: int | None
    email: str | None
    profile_id: str | None
    conversation: str | None
    user_id: int | None = None
    tags: tuple = ()

    @classmethod
    def of(cls, task: dict) -> "Ticket":
        ident = common.identity_of(task)
        return cls(id=str(task.get("id")), status=common.status_of(task),
                   created_s=common.created_s(task), email=ident["email"],
                   profile_id=ident["profile_id"],
                   conversation=ident["intercom_conversation"],
                   tags=tuple(common.tag_names(task)))


@dataclass(frozen=True)
class Claim:
    id: int
    user_id: int
    profile_id: str
    profile_type: str
    status: str
    created_s: int
    links: dict
    reason: str

    @property
    def has_identity_proof(self) -> bool:
        """Something the customer submitted that can prove identity (E1/E2).

        `verificationLinks` carries the submitted surfaces (`weblinks`, `email`,
        socials) — a claim with only null socials and no link/email has submitted
        nothing yet, which is the state `claim_proof_ask` writes to.
        """
        return any(str(self.links.get(k) or "").strip() for k in ("weblinks", "email"))


@dataclass
class Decision:
    ticket: Ticket
    bucket: str
    evidence: str
    claims: tuple = ()
    tray_row: dict | None = None
    note: str = ""
    # The claim id(s) the bucket RESTS ON. A tag written for this decision is only
    # still true if THESE claims still say so — accepting any qualifying claim on
    # the account would let an unrelated processed claim vouch for this ticket's
    # (QA finding, PR #1712).
    basis: tuple = ()

    @property
    def tag(self):
        return TAG_OF_BUCKET.get(self.bucket)

    @property
    def closes(self) -> bool:
        return self.bucket == B_COMPLETE

    @property
    def already_tagged(self) -> bool:
        return bool(self.tag) and self.tag in self.ticket.tags


@dataclass
class RuleVerdict:
    """The coded rule's answer for one pending claim."""
    kind: str                 # decline | held | none
    contradiction: str | None = None
    ruling_id: str = ""
    evidence: str = ""
    snapshot: dict | None = None


# ───────────────────────── core reads (read-only) ─────────────────────────


def trino_text(sql: str, cmd: str | None = None) -> str:
    """Raw CSV from the read-only replica runner. Raises: an unreadable read is never 'empty'."""
    p = subprocess.run([cmd or TRINO], input=sql, capture_output=True, text=True, timeout=900, check=False)
    if p.returncode:
        raise Surprise(f"replica read failed rc={p.returncode}: {p.stderr.strip()[-300:]}")
    return p.stdout


def _rows(text: str) -> list[list[str]]:
    return list(csv.reader(io.StringIO("\n".join(l for l in text.splitlines() if l.startswith('"')))))


def _quote(value) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _chunks(values, size):
    values = list(values)
    for i in range(0, len(values), size):
        yield values[i:i + size]


def resolve_users(emails, run=trino_text) -> dict[str, int]:
    """email -> core user id, for exactly these addresses."""
    out: dict[str, int] = {}
    emails = sorted({e for e in emails if e})
    for chunk in _chunks(emails, 400):
        sql = ("select cast(id as varchar), lower(email) from postgresql_core.public.users "
               f"where lower(email) in ({','.join(_quote(e) for e in chunk)})")
        for rec in _rows(run(sql)):
            if len(rec) != 2 or not rec[0].isdigit():
                # A row we cannot read is NOT an absent account: skipping it turns
                # a replica/schema change into "this email has no Muso account".
                raise Surprise(f"users read answered a row the drainer cannot parse: {rec!r:.200}")
            out[rec[1].strip().lower()] = int(rec[0])
    return out


def fetch_claims(user_ids, run=trino_text) -> dict[int, list[Claim]]:
    """user id -> EVERY not-deleted claim that account ever made. No date cutoff.

    The cutoff is applied per ticket in `match_claims`, and it must NOT be applied
    here: a claim approved before the oldest open ticket's window is exactly the
    case that closes a ticket, so a global `createdat >= min(ticket) - 1d` makes
    the historical lookup silently incomplete and the run reports "this account
    never claimed anything" about a profile it already owns (QA finding, PR #1712;
    `tests/...::test_a_claim_outside_the_oldest_ticket_window_still_closes` keeps
    a fake replica that HONOURS a timestamp predicate, so re-introducing one fails).
    """
    out: dict[int, list[Claim]] = collections.defaultdict(list)
    for chunk in _chunks(sorted({u for u in user_ids if u}), 400):
        sql = ("select cast(c.id as varchar), cast(c.userid as varchar), lower(c.profileid), c.profiletype, "
               "c.status, coalesce(to_iso8601(c.createdat), ''), "
               "coalesce(json_format(c.verificationlinks), '{}'), coalesce(c.reason, '') "
               "from postgresql_core.public.claiming c "
               f"where c.deletedat is null and c.userid in ({','.join(str(int(u)) for u in chunk)})")
        for rec in _rows(run(sql)):
            # FAIL CLOSED on anything we cannot read. A skipped row makes the
            # account look like it never claimed, which is exactly the tag
            # `drain:awaiting-user-submission`; a malformed links blob reads as "no
            # identity proof", which is `verification-required`. Both are tags
            # asserting a fact the read did not establish (QA finding, PR #1712).
            if len(rec) != 8:
                raise Surprise(f"claim read answered a {len(rec)}-column row, expected 8: "
                               f"{rec!r:.200}")
            if not rec[0].isdigit() or not rec[1].isdigit():
                raise Surprise(f"claim read answered a non-numeric id: {rec!r:.200}")
            if (rec[2] or "").strip() and not rec[2].strip().lower():
                raise Surprise(f"claim read answered a malformed profile id: {rec!r:.200}")
            try:
                links = json.loads(rec[6] or "{}")
            except ValueError as exc:
                raise Surprise(f"claim {rec[0]} has unreadable verificationlinks JSON "
                               f"({exc}): identity proof cannot be inferred") from exc
            if not isinstance(links, dict):
                raise Surprise(f"claim {rec[0]} verificationlinks is not an object: {rec[6]!r:.120}")
            out[int(rec[1])].append(Claim(
                id=int(rec[0]), user_id=int(rec[1]), profile_id=(rec[2] or "").lower(),
                profile_type=rec[3], status=(rec[4] or "").strip().lower(),
                created_s=_epoch(rec[5]), links=links if isinstance(links, dict) else {},
                reason=rec[7] or ""))
    return dict(out)


def _epoch(ts: str) -> int:
    """An empty timestamp is legitimately 0; an UNREADABLE one is a Surprise.

    `created_s` decides the per-ticket window, so quietly treating a bad timestamp
    as the epoch moves a claim outside the window and changes the outcome.
    """
    text = str(ts or "").strip().replace(" UTC", "").replace(" ", "T")
    if not text:
        return 0
    try:
        return int(dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp())
    except ValueError as exc:
        raise Surprise(f"claim read answered an unreadable timestamp {ts!r:.80}") from exc


# ───────────────────────── the lanes' own ledgers ─────────────────────────


def executor_rejections(path=EXECUTOR_AUDIT) -> set[int]:
    """Claim ids `claim_executor` itself moved to `rejected` (its audit read-back).

    Only `outcome=written` counts: that row is emitted after the executor read the
    claim back as `rejected`, so the customer-visible `profile_claim_rejected`
    fan-out has already been gated on it. A `reserved` or `not_moved` row is an
    attempt, not an outcome.
    """
    out: set[int] = set()
    for rec in common.read_jsonl(path):
        if rec.get("kind") != "claim_decline" or rec.get("outcome") != "written":
            continue
        if str(rec.get("after") or "").strip().lower() != "rejected":
            continue
        try:
            out.add(int(rec["claim_id"]))
        except (KeyError, TypeError, ValueError):
            continue
    return out


def asked_claims(path=CLAIM_ASKED) -> dict[int, dict]:
    """claim id -> its `claim_proof_ask` record (the ask that actually went out)."""
    out: dict[int, dict] = {}
    for rec in common.read_jsonl(path):
        try:
            out[int(rec["id"])] = rec
        except (KeyError, TypeError, ValueError):
            continue
    return out


# ───────────────────────── matching ─────────────────────────


def match_claims(ticket: Ticket, claims_by_user: dict, *, slack_s: int = WINDOW_SLACK_S):
    """-> (rows, mode, why_not).

    `mode` is how the rows were attributed: "profile+user" (claim inside the
    window), "profile+user-predates" (the account's claim on THIS profile is
    older than the ticket), "user-window" (no Profile ID, exactly one claim in
    the window), or "user" (nothing at all).

    The window is not decorative: it keeps an unrelated claim from being read as
    this ticket's one. But the (account, profile) PAIR is itself the identity key
    — measured 2026-11-03, 68 of the 80 tickets whose claim predates the window
    had that exact pair `processed`, i.e. the profile was already approved to
    that person and the ask was satisfied before the ticket was filed. So a
    predated claim is returned for a decision instead of being thrown away, and
    only an APPROVED one closes anything (see `classify`).

    A ticket with no Profile ID is matched only when the window holds exactly ONE
    claim, because closing a ticket on a claim for another profile is the
    wrong-account failure this pipeline exists to avoid.
    """
    if not ticket.user_id:
        return [], None, "needs-identity"
    if ticket.created_s is None:
        # No readable `date_created` means no window: `cutoff` would be -86400, so
        # EVERY historical claim would qualify. For a profile-less ticket that
        # attributes one unrelated old claim to this request and can tag it
        # `complete` for the wrong person (QA finding, PR #1712). Nothing on the
        # ticket dates it, so nothing can be attributed to it.
        return [], None, B_UNDATED
    rows = list(claims_by_user.get(ticket.user_id) or ())
    cutoff = (ticket.created_s or 0) - slack_s
    if ticket.profile_id:
        same = [c for c in rows if c.profile_id == ticket.profile_id]
        windowed = [c for c in same if c.created_s >= cutoff]
        if windowed:
            return windowed, "profile+user", None
        if same:
            return same, "profile+user-predates", None
        return [], "profile+user", None
    windowed = [c for c in rows if c.created_s >= cutoff]
    if len(windowed) == 1:
        return windowed, "user-window", None
    if windowed:
        return [], None, B_AMBIGUOUS
    if rows:
        # No Profile ID and only claims OLDER than the window: we cannot say which
        # profile this ticket is about, and it is certainly NOT "the customer never
        # started a claim" — the account has one (possibly `processed`). Report it.
        return [], None, B_AMBIGUOUS
    return [], "user", None


def _statuses(claims) -> set[str]:
    return {c.status for c in claims}


def classify(ticket: Ticket, claims, *, mode, why_not, asked: dict,
             executor: set[int], rule) -> Decision:
    """One ticket -> one Decision. First match wins; the ladder is the spec's.

    `rule` is `rule_verdict(claim)`; it is only consulted for a pending claim, so
    a ticket that is already decided never pays for a facts read or a gate call.
    """
    if why_not == "needs-identity":
        return Decision(ticket, B_NEEDS_IDENTITY,
                        "the ticket's email resolves to no Muso account" if ticket.email
                        else "no User Email on the ticket: the claim cannot be attributed")
    if why_not == B_UNDATED:
        return Decision(ticket, B_UNDATED,
                        "the ticket has no readable `date_created`, so no claim can be "
                        "attributed to it: reported, never written")
    if why_not == B_AMBIGUOUS:
        return Decision(ticket, B_AMBIGUOUS,
                        "no Profile ID on the ticket and this account's claims do not identify "
                        "one unambiguously (several in the window, or only ones older than it): "
                        "reported, never written")
    if not claims:
        return Decision(ticket, B_AWAITING,
                        "no claim row in core for this account+profile: the customer never "
                        "started the claim in the app", note=mode or "")

    statuses = _statuses(claims)
    approved = [c for c in claims if c.status in CLAIM_APPROVED]
    if approved:
        c = sorted(approved, key=lambda c: c.created_s)[-1]
        where = ("" if c.created_s >= (ticket.created_s or 0) - WINDOW_SLACK_S
                 else " — approved BEFORE this ticket was filed, so the ask was already satisfied")
        return Decision(ticket, B_COMPLETE,
                        f"claim {c.id} is `processed` in core (the claim was approved; the "
                        f"app notification is the channel){where}", claims=tuple(claims),
                        basis=(c.id,))

    if mode == "profile+user-predates":
        # Same (account, profile) pair, older than the ticket, not approved: the
        # ask is genuinely in flight from a previous attempt. Never close it on a
        # pending/rejected row — that would tell the customer "done" about the
        # claim they just filed.
        return Decision(ticket, B_OUTSIDE_WINDOW,
                        f"this account's claim on the profile predates the ticket by more than "
                        f"{WINDOW_SLACK_S // 3600}h and is `{sorted(statuses)}`: reported, never written",
                        claims=tuple(claims))

    rejected_by_executor = [c for c in claims if c.status in CLAIM_REJECTED and c.id in executor]
    if rejected_by_executor:
        c = rejected_by_executor[0]
        return Decision(ticket, B_COMPLETE,
                        f"claim {c.id} is `rejected` and claim_executor's audit row proves it "
                        f"moved it and read the rejection back (core's profile_claim_rejected "
                        f"fan-out is what the customer was told)", claims=tuple(claims),
                        basis=(c.id,))

    pending = [c for c in claims if c.status in cx.OPEN_STATUSES]
    if pending:
        verdicts = [(c, rule(c)) for c in sorted(pending, key=lambda c: c.created_s)]
        declined = [(c, v) for c, v in verdicts if v.kind == "decline"]
        if declined:
            c, v = declined[0]
            return Decision(ticket, B_CONTRADICTION,
                            f"claim {c.id} is `{c.status}` and the coded rule "
                            f"{v.ruling_id} ({v.contradiction}) fires on fresh facts: hand it "
                            f"to claim_executor, never write the reject here",
                            claims=tuple(claims),
                            tray_row=_tray_row(c, v))
        held = [(c, v) for c, v in verdicts if v.kind == "held"]
        if held:
            c, v = held[0]
            return Decision(ticket, B_HELD,
                            f"claim {c.id} contradicts ({v.contradiction}) but the account is not "
                            f"cleanly allowed ({v.evidence}): a human tray, never a decline",
                            claims=tuple(claims))
        asks = [(c, asked[c.id]) for c in pending if c.id in asked]
        if asks:
            c, rec = asks[0]
            unproven = all(not x.has_identity_proof for x in pending)
            if unproven:
                return Decision(ticket, B_VERIFICATION,
                                f"claim {c.id} is `{c.status}` with nothing submitted that can prove "
                                f"identity, and claim_proof_ask recorded the ask at "
                                f"{rec.get('askedAt')}: the next move is the customer's",
                                claims=tuple(claims), basis=(c.id,))
            return Decision(ticket, B_AWAITING_REVIEW,
                            f"claim {c.id} is `{c.status}`, identity proof was submitted, and an ask "
                            f"went out at {rec.get('askedAt')}: it is in review, not with the customer",
                            claims=tuple(claims))
        if all(not c.has_identity_proof for c in pending):
            first = pending[0]
            return Decision(ticket, B_PROOF_NO_ASK,
                            f"claim {first.id} is `{first.status}` with no identity proof submitted and "
                            f"NO recorded ask: nothing has been said to the customer, so nothing is "
                            f"tagged", claims=tuple(claims))
        return Decision(ticket, B_AWAITING_REVIEW,
                        f"claim {pending[0].id} is `{pending[0].status}` with identity proof "
                        f"submitted and no ask outstanding: ours to move, not the customer's",
                        claims=tuple(claims))

    if any(c.status in CLAIM_REJECTED for c in claims):
        c = [x for x in claims if x.status in CLAIM_REJECTED][0]
        return Decision(ticket, B_REJECTED_OUTSIDE,
                        f"claim {c.id} is `rejected` with no claim_executor audit row: the reject came "
                        f"from somewhere this run cannot vouch for, so the outcome is not inferred",
                        claims=tuple(claims))
    if statuses & CLAIM_CLOSED:
        return Decision(ticket, B_CLAIM_CLOSED,
                        f"claim {[c.id for c in claims if c.status in CLAIM_CLOSED]} is `closed` in "
                        f"core: neither approved nor rejected, so there is no outcome to record",
                        claims=tuple(claims))
    return Decision(ticket, B_AWAITING_REVIEW,
                    f"claim status {sorted(statuses) or ['unknown']} is none of the four "
                    f"determinations: reported, never written", claims=tuple(claims))


def _tray_row(claim: Claim, verdict: RuleVerdict) -> dict:
    return {"claim_id": claim.id, "user_id": claim.user_id, "profile_id": claim.profile_id,
            "profile_type": claim.profile_type, "ruling_id": verdict.ruling_id,
            "contradiction": verdict.contradiction, "evidence": verdict.evidence,
            "audit_reason": f"coded rule {verdict.ruling_id} (no per-item ruling)",
            "facts": verdict.snapshot}


def rule_verdict(claim: Claim, snapshot: dict | None, *, gate=account_gate.check) -> RuleVerdict:
    """The coded contradiction class for one pending claim, on FRESH facts.

    `decline_rules.reproduce` is the executor's own provenance check, so a
    `decline` here is exactly a decline the executor will accept. It runs with a
    synthetic allow gate; the account gate is asked separately (and remembered)
    because a held or watchlisted account must never be handed to a decline tray.
    """
    if not snapshot:
        return RuleVerdict("none", evidence="the coded rule's facts could not be read for this claim")
    try:
        ruled = decline_rules.reproduce(snapshot)
    except Exception as exc:  # noqa: BLE001 - unreadable facts are a refusal, never a pass
        return RuleVerdict("none", evidence=f"the coded rule does not run here ({type(exc).__name__})")
    if ruled.decision == "hold":           # the facts' own watchlist / held-account class
        return RuleVerdict("held", ruled.contradiction, ruled.rule_id, ruled.evidence)
    if ruled.decision != "decline":
        return RuleVerdict("none", ruling_id=ruled.rule_id, evidence=ruled.evidence)
    try:
        result = gate(claim.user_id)
    except Exception as exc:  # noqa: BLE001 - a gate that cannot answer is not an allow
        return RuleVerdict("held", ruled.contradiction, ruled.rule_id,
                           f"the account gate did not answer ({type(exc).__name__})")
    if result is None:
        return RuleVerdict("held", ruled.contradiction, ruled.rule_id,
                           "the run's account-gate budget was spent before this claim")
    reasons = tuple(getattr(result, "reasons", ()) or ())
    payload = getattr(result, "payload", {}) or {}
    watchlisted = bool(payload.get("watch")) or any(
        "watchlist" in r.lower() or "deny" in r.lower() for r in reasons)
    if not getattr(result, "allowed", False) or watchlisted:
        why = "watchlisted" if watchlisted else f"gate {getattr(result, 'decision', 'unknown')}"
        return RuleVerdict("held", ruled.contradiction, ruled.rule_id,
                           f"account not cleanly allowed ({why})")
    return RuleVerdict("decline", ruled.contradiction, ruled.rule_id, ruled.evidence, snapshot)


# ───────────────────────── trays ─────────────────────────


def build_tray(declined: list[Decision], *, run_id: str, now: dt.datetime) -> dict:
    """The `claim_executor` tray document for this run's coded contradictions."""
    claims_map, snapshots, decisions = {}, {}, []
    for d in declined:
        row = d.tray_row
        snap = row["facts"]
        claims_map[row["claim_id"]] = {
            "id": row["claim_id"], "userId": row["user_id"], "profileId": row["profile_id"],
            "profileType": row["profile_type"], "reason": snap["claim"].get("reason"),
            "status": snap["claim"].get("status")}
        snapshots[row["claim_id"]] = snap
        decisions.append(decline_rules.Decision(
            claim_id=row["claim_id"], decision="decline", contradiction=row["contradiction"],
            rule_id=row["ruling_id"], evidence=row["evidence"]))
    tray = decline_rules.build_tray(decisions, claims_map, daily_cap=fx.DAILY_CAP,
                                   snapshots=snapshots)
    tray["generated_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    tray["generated_by"] = f"clickup-drain/profile-claim run {run_id}"
    return tray


def write_tray(tray: dict, *, run_id: str, tray_dir=TRAY_DIR) -> str:
    path = pathlib.Path(tray_dir) / f"profile-claim-{run_id}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise Surprise(f"tray {path} already exists; refusing to overwrite a claim tray")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(tray, fh, separators=(",", ":"), sort_keys=True)
    return str(path)


def executor_command(tray_path: str) -> str:
    return (f"python3 {SCRIPTS_DIR / 'credit-fable-execute.py'} {tray_path} --apply --claims")


# ───────────────────────── the run ─────────────────────────


@dataclass
class Report:
    now: dt.datetime
    dry_run: bool
    mode: str = "apply"
    tickets: int = 0
    buckets: collections.Counter = field(default_factory=collections.Counter)
    decisions: list = field(default_factory=list)
    planned: list = field(default_factory=list)
    written: int = 0
    already_present: int = 0
    skipped_stale: int = 0
    cap: int = MAX_TAG_WRITES
    trays: list = field(default_factory=list)
    surprises: list = field(default_factory=list)
    notes: list = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "ts": common.now_iso(self.now), "mode": self.mode, "dry_run": self.dry_run,
            "tickets": self.tickets, "buckets": dict(sorted(self.buckets.items())),
            "planned_writes": len(self.planned), "written": self.written,
            "already_present": self.already_present,
            "skipped_stale": self.skipped_stale,
            "trays": self.trays, "surprises": self.surprises, "notes": self.notes,
            "would_close": [
                {"ticket_id": d.ticket.id, "claim_ids": [c.id for c in d.claims],
                 "core_status": sorted({c.status for c in d.claims}),
                 "conversation": d.ticket.conversation, "evidence": d.evidence}
                for d in self.decisions if d.closes],
        }


def _snapshot_batch(claim_ids, run=trino_text) -> dict[int, dict]:
    """Fresh, trusted facts per pending claim (the executor rebuilds these anyway).

    The deceased policy is resolved the same way `decline_rules.main` does — an
    absent policy file means no deceased class rather than a crash, and it can
    only ever REMOVE a decline, never invent one.
    """
    if not claim_ids:
        return {}
    policy = decline_rules.DEFAULT_DECEASED_POLICY
    deceased = decline_rules.load_deceased(str(policy)) if policy.exists() else frozenset()
    return decline_rules.live_snapshots(sorted(claim_ids), run, deceased=deceased)


def collect(*, client, now: dt.datetime, run=trino_text, gate=account_gate.check,
            ask_path=CLAIM_ASKED, executor_path=EXECUTOR_AUDIT,
            max_gate_calls: int = DEFAULT_MAX_GATE_CALLS) -> Report:
    """Read the board and core and decide every open ticket. Writes nothing."""
    report = Report(now=now, dry_run=True)
    tasks = common.fetch_queue(client, ACTION)
    tickets = [Ticket.of(t) for t in tasks]
    report.tickets = len(tickets)
    if not tickets:
        return report

    users = resolve_users({t.email for t in tickets if t.email}, run=run)
    tickets = [_with_user(t, users.get(t.email) if t.email else None) for t in tickets]
    report.notes.append(f"accounts resolved from email: {sum(1 for t in tickets if t.user_id)}/{len(tickets)}")

    claims_by_user = fetch_claims({t.user_id for t in tickets if t.user_id}, run=run)
    asked = asked_claims(ask_path)
    executor = executor_rejections(executor_path)

    matched: list[tuple[Ticket, list, str, str | None]] = []
    for t in tickets:
        rows, mode, why = match_claims(t, claims_by_user)
        matched.append((t, rows, mode, why))

    pending_ids = [c.id for _, rows, _, _ in matched for c in rows if c.status in cx.OPEN_STATUSES]
    snapshots = _snapshot_batch(sorted(set(pending_ids)), run=run)
    report.notes.append(f"coded-rule facts read for {len(snapshots)}/{len(set(pending_ids))} pending claims")

    gate_cache: dict[int, object] = {}

    def _gate(user_id):
        if user_id not in gate_cache:
            if len(gate_cache) >= max_gate_calls:
                # Fail safe, not loud: a spent budget means MORE contradicted claims
                # than a drainer plans for, so they go to a human rather than to a
                # decline tray nobody checked.
                return None
            gate_cache[user_id] = gate(user_id)
        return gate_cache[user_id]

    for t, rows, mode, why in matched:
        decision = classify(t, rows, mode=mode, why_not=why, asked=asked, executor=executor,
                            rule=lambda c: rule_verdict(c, snapshots.get(c.id), gate=_gate))
        report.decisions.append(decision)
        report.buckets[decision.bucket] += 1
    if len(gate_cache) >= max_gate_calls:
        report.notes.append(f"account-gate budget {max_gate_calls} spent: any further contradiction is "
                            f"reported as held-for-human, not queued")
    report.decisions.sort(key=lambda d: (BUCKET_ORDER.index(d.bucket)
                                         if d.bucket in BUCKET_ORDER else len(BUCKET_ORDER),
                                         d.ticket.created_s or 0))
    return report


def _with_user(ticket: Ticket, user_id) -> Ticket:
    return dataclasses.replace(ticket, user_id=user_id)


# Buckets whose tag is a claim about CORE state, so core is re-read before the write.
RECHECKED_BUCKETS = (B_COMPLETE, B_VERIFICATION, B_AWAITING)
# Seconds of core-read time one run may spend revalidating before it stops writing
# and leaves the rest for the next tick. A single-user claim read costs ~4s on
# node-8, so this bounds a run at ~80 tagged tickets even though the write cap is
# 100 — freshness is per write, and the budget is what keeps the run inside the
# unit's timeout.
RECHECK_BUDGET_S = 300.0


def _pending_for(ticket, fresh) -> list:
    """This ticket's open claims, attributed exactly the way the scan attributed them."""
    rows, _mode, why_not = match_claims(ticket, {ticket.user_id: list(fresh)})
    if why_not:
        return []
    return [c for c in rows if c.status in cx.OPEN_STATUSES]


def _bucket_still_holds(decision, fresh, asked: dict, executor: set) -> str | None:
    """Re-decide one bucket from fresh claims. A reason string means "do not tag".

    The scan and the write are minutes apart, and a claim can move between them in
    both directions: `processed` can be reverted, proof can be submitted, a new
    claim can be filed. Every tag we write is a statement about core, so the
    statement is re-checked against core right before it is written (QA finding,
    PR #1712).

    The check is on the claim(s) the decision RESTS ON (`decision.basis`), not on
    "any claim on this account that happens to qualify": an unrelated processed
    claim on another profile must not vouch for this ticket.

    Deliberately NOT a full re-classification: the pending-claim branch runs
    `decline_rules` against fresh facts, which costs a snapshot read and an
    account-gate call per claim. What is checked here is exactly the fact the tag
    asserts.
    """
    if decision.bucket == B_VERIFICATION:
        # The scan required ALL of this ticket's pending claims to lack proof, so
        # re-checking only the claim the ask named is not the same predicate: a
        # SECOND pending claim that gains proof makes `verification-required` a lie
        # while the named claim still passes (QA finding, PR #1712).
        pending = _pending_for(decision.ticket, fresh)
        if not pending:
            return "no open claim is left for this ticket: `verification-required` would be false"
        proven = [c for c in pending if c.has_identity_proof]
        if proven:
            ids = ",".join(str(c.id) for c in proven[:3])
            return (f"claim(s) {ids} have identity proof now: `verification-required` "
                    f"would be false")
        if not any(c.id in asked for c in pending):
            return "no recorded ask covers the open claims: `verification-required` would be false"
        return None
    by_id = {c.id: c for c in fresh}
    statuses = sorted({c.status for c in fresh}) or ["none"]
    if decision.bucket == B_AWAITING:
        # The ticket's claim, not just any claim: same profile, when the ticket
        # names one. (Over-strict is safe here — it only skips a write.)
        want = (decision.ticket.profile_id or "").lower() or None
        appeared = [c for c in fresh if want is None or c.profile_id == want]
        if appeared:
            ids = ",".join(str(c.id) for c in appeared[:3])
            return f"a claim appeared after the scan ({ids}); the no-claim tag would be false"
        return None
    if not decision.basis:
        return f"{decision.bucket} decision carries no claim basis: nothing to re-check"
    for cid in decision.basis:
        c = by_id.get(cid)
        if c is None:
            return f"claim {cid} is no longer in core ({statuses}); the tag would be stale"
        if c.status in CLAIM_APPROVED:
            continue
        if c.status in CLAIM_REJECTED and c.id in executor:
            continue
        return (f"claim {cid} is `{c.status}` now, not approved or executor-rejected: "
                f"`complete` would be false")
    return None


class RecheckMeter:
    """How much of the run's core-read budget is spent."""

    def __init__(self, budget_s: float = RECHECK_BUDGET_S, clock=None):
        self.budget_s = budget_s
        self.clock = clock or time.monotonic
        self.spent = 0.0

    def exhausted(self) -> bool:
        return self.spent > self.budget_s

    def timed(self, fn):
        started = self.clock()
        try:
            return fn()
        finally:
            self.spent += self.clock() - started


def _live_claim_check(decision, claims_recheck, ask_path, executor_path, meter):
    """A revalidator for `TagWriter.add`, run IMMEDIATELY before that POST.

    Per write, not per batch: a claim can be reverted between two writes in the
    same run, and a batch-level read would then still stamp that ticket
    `complete` (QA finding, PR #1712). The staleness window is now the POST itself.
    """
    ticket = decision.ticket

    def check():
        fresh = meter.timed(lambda: claims_recheck({ticket.user_id}).get(ticket.user_id, []))
        return _bucket_still_holds(decision, fresh, asked_claims(ask_path),
                                   executor_rejections(executor_path))
    return check


def apply_plan(report: Report, *, client, ledger: common.Ledger, run_id: str,
               max_writes: int, now_iso=common.now_iso, tray_dir=TRAY_DIR,
               claims_recheck=None, ask_path=CLAIM_ASKED,
               executor_path=EXECUTOR_AUDIT,
               recheck_budget_s: float = RECHECK_BUDGET_S, clock=None) -> Report:
    """Tag what the ladder decided, capped, stopping on the first surprise."""
    writer = common.TagWriter(client, ledger, max_writes=max_writes, run_id=run_id, now=now_iso)
    report.dry_run = False
    report.mode = "apply"
    report.cap = max_writes

    # Every tag is a statement about core, and core moves. The read happens inside
    # `writer.add`, immediately before that POST (`claims_recheck`), and the time it
    # costs is metered so a big batch cannot overrun the unit's timeout.
    meter = RecheckMeter(recheck_budget_s, clock)

    declined = [d for d in report.decisions if d.bucket == B_CONTRADICTION and d.tray_row]
    if declined:
        try:
            tray = build_tray(declined, run_id=run_id, now=report.now)
            path = write_tray(tray, run_id=run_id, tray_dir=tray_dir)
            report.trays.append({"path": path, "rows": len(tray["rows"]),
                                 "claim_ids": [r["claim_id"] for r in tray["rows"]],
                                 "executor_command": executor_command(path)})
            for d in declined:
                ledger.write({"ts": now_iso(), "run_id": run_id, "action": "enqueue-tray",
                              "ticket_id": d.ticket.id, "claim_id": d.tray_row["claim_id"],
                              "ruling_id": d.tray_row["ruling_id"], "tray": path,
                              "result": "written"})
        except Surprise:
            raise
        except Exception as exc:  # noqa: BLE001 - a tray that cannot be written must stop the run
            raise Surprise(f"claim tray not written: {type(exc).__name__}: {str(exc)[:200]}") from exc

    for d in report.decisions:
        tag = d.tag
        if not tag:
            continue
        if d.already_tagged:      # a previous run (or a human) already said it
            report.already_present += 1
            continue
        if writer.remaining() <= 0:
            report.notes.append(f"cap {max_writes} reached; the remaining tag decisions wait for the "
                                f"next tick")
            break
        report.planned.append({"ticket_id": d.ticket.id, "tag": tag, "bucket": d.bucket})
        revalidate = None
        if claims_recheck is not None and d.bucket in RECHECKED_BUCKETS:
            if meter.exhausted():
                report.notes.append(
                    f"claim recheck budget {recheck_budget_s:.0f}s spent after "
                    f"{report.written} writes; the remaining tag decisions wait for the next tick")
                break
            revalidate = _live_claim_check(d, claims_recheck, ask_path, executor_path, meter)
        result = writer.add(d.ticket.id, tag, bucket=d.bucket, evidence=d.evidence,
                            claims=tuple(c.id for c in d.claims),
                            extra={"profile_id": d.ticket.profile_id,
                                   "email": d.ticket.email,
                                   "queue": ACTION,
                                   "conversation": d.ticket.conversation},
                            revalidate=revalidate)
        if result == "written":
            report.written += 1
        elif result == "stale":
            report.skipped_stale += 1
            report.notes.append(f"{d.ticket.id}: skipped, the ticket moved under the scan")
        else:
            report.already_present += 1
    return report


# ───────────────────────── digest ─────────────────────────

BUCKET_MEANING = {
    B_COMPLETE: f"tag {OUTCOME_COMPLETE} (claim approved or executor-rejected; the customer was told in-app)",
    B_VERIFICATION: f"tag {OUTCOME_VERIFICATION} (awaiting identity proof and the ask went out)",
    B_AWAITING: f"tag {DRAIN_TAG} (no claim row in core: the ask campaign talks to them)",
    B_CONTRADICTION: "coded contradiction -> claim_executor tray row, ticket stays waiting-on-us",
    B_HELD: "contradiction on an account the gate does not allow: a human tray, never a decline",
    B_AWAITING_REVIEW: "pending, ours or in review: reported, never written",
    B_PROOF_NO_ASK: "pending, nothing submitted, no ask recorded: reported, never written",
    B_REJECTED_OUTSIDE: "rejected with no claim_executor audit row: reported, never written",
    B_CLAIM_CLOSED: "claim `closed` in core: no outcome to record",
    B_OUTSIDE_WINDOW: "the account's claim predates the ticket window: reported",
    B_AMBIGUOUS: "no Profile ID, claims do not name one: reported (never \"unclaimed\")",
    B_NEEDS_IDENTITY: "no email/account to resolve: reported, never touched",
    B_UNDATED: "no readable ticket date, so no claim is attributable: reported",
}


def digest(report: Report, *, max_close: int = 60) -> str:
    head = "DRY RUN" if report.dry_run and not report.written else "APPLIED"
    lines = [f"profile-claim drain — {head} — {common.now_iso(report.now)}",
             f"board {common.LIST_ID} · queue action:{ACTION} · open tickets {report.tickets}"]
    for bucket, count in sorted(report.buckets.items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append(f"  {bucket:<24} {count:>4}   {BUCKET_MEANING.get(bucket, '')}")
    if report.written or report.already_present or report.skipped_stale:
        lines.append(f"  tag writes: {report.written} written, {report.already_present} already present, "
                     f"{report.skipped_stale} skipped as stale, cap {report.cap}")
    for note in report.notes:
        lines.append(f"note: {note}")
    for tray in report.trays:
        lines.append(f"tray: {tray['path']} ({tray['rows']} rows: claims "
                     f"{', '.join(str(c) for c in tray['claim_ids'])})")
        lines.append(f"      run it: {tray['executor_command']}")
    tagged = [d for d in report.decisions if d.already_tagged]
    if tagged:
        lines.append(f"already tagged by an earlier run: {len(tagged)} "
                     f"(nothing re-posted; a re-run is a no-op)")
    closing = [d for d in report.decisions if d.closes and not d.already_tagged]
    if closing:
        without_conv = [d for d in closing if not d.ticket.conversation]
        if without_conv:
            lines.append(f"note: {len(without_conv)} of the would-close tickets carry no Intercom link, "
                         f"so resolve-notify has no conversation to tell (the in-app message is still "
                         f"the outcome)")
        lines.append(f"would-close ({len(closing)}), each with the claim id and core status:")
        for d in closing[:max_close]:
            claims = ", ".join(f"{c.id}={c.status}" for c in d.claims) or "none"
            lines.append(f"  {d.ticket.id}  claims {claims}  conv {d.ticket.conversation or '-'}")
        if len(closing) > max_close:
            lines.append(f"  … {len(closing) - max_close} more")
    for surprise in report.surprises:
        lines.append(f"SURPRISE: {surprise}")
    return "\n".join(lines)


# ───────────────────────── CLI ─────────────────────────


def _positive(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"not an integer: {value}") from exc
    if number < 1:
        raise argparse.ArgumentTypeError("must be >= 1")
    return number


def revert_with_lock(ledger_path, client, *, apply: bool, run_id: str,
                     lock_path=None):
    """Run the rollback under the SAME write lock the hourly writer takes.

    `--revert --apply` used to call `revert_ledger` holding no lock while the
    normal `--apply` path held `shared_write_lock(WRITE_LOCK)`. Started while the
    timer was mid-batch, the rollback read a ledger that was still being appended
    to: it removed the tags it had seen, returned `errors: []`, and left the tags
    the writer added afterwards live — a rollback that reports complete and is
    not. A kill file or a stopped timer cannot cancel a run that already holds
    the lock, so the lock is the only serialization that actually holds
    (QA finding, PR #1712).

    A dry run takes no lock: it mutates nothing, and blocking a read behind the
    hourly writer would make the one check an operator runs before an apply
    unavailable exactly when it matters.
    """
    def undo():
        return common.revert_ledger(
            ledger_path, client,
            writer=revert_writer(client, ledger_path, run_id=run_id), dry_run=not apply)

    if not apply:
        return undo()
    with common.shared_write_lock(lock_path or WRITE_LOCK):
        return undo()


def revert_writer(client, ledger_path, *, run_id: str):
    """The writer a `--revert` uses. Its rows go into the SOURCE ledger.

    They must not go into a sidecar: the next `--revert` decides what we still
    own by reading that one file, so a removal recorded anywhere else leaves the
    original verified add standing. If a human later restores the tag, the second
    revert would then delete THEIR tag and report it as our own undo (QA finding,
    PR #1712). Appending is safe — `revert_ledger` reads every row before the
    first removal.
    """
    return common.TagWriter(client, common.Ledger(ledger_path),
                            max_writes=MAX_TAG_WRITES, run_id=run_id)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="write the tags (default: dry run, nothing written)")
    ap.add_argument("--json", action="store_true", help="machine-readable report on stdout")
    ap.add_argument("--max-writes", type=_positive, default=MAX_TAG_WRITES,
                    help=f"tag writes this run (default and hard ceiling {MAX_TAG_WRITES})")
    ap.add_argument("--revert", metavar="LEDGER",
                    help="delete the tags a ledger's add-tag rows put on tickets")
    ap.add_argument("--no-tray", action="store_true",
                    help="decide contradicted claims but write no claim_executor tray")
    ap.add_argument("--recheck-budget", type=float, default=RECHECK_BUDGET_S,
                    metavar="SECONDS",
                    help=f"core-read time to spend revalidating before the run stops writing "
                         f"(default {RECHECK_BUDGET_S:.0f}s; a single-user claim read is ~4s)")
    ap.add_argument("--max-gate-calls", type=_positive, default=DEFAULT_MAX_GATE_CALLS,
                    help="account-gate subprocess budget (a drainer never gate-storms)")
    args = ap.parse_args(argv)

    if args.max_writes > MAX_TAG_WRITES:
        ap.error(f"--max-writes cannot exceed the {MAX_TAG_WRITES}/run cap in the spec; "
                 f"raise the constant in a reviewed change")

    now = dt.datetime.now(dt.UTC)
    run_id = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:6]}"
    try:
        token = common.clickup_token()
        client = clickup_client.shared(token, common.CLICKUP_API)
    except Surprise as exc:
        print(f"profile-claim drain: {exc}", file=sys.stderr)
        return 2

    ledger = common.Ledger(LEDGER_PATH)

    if args.revert:
        try:
            result = revert_with_lock(args.revert, client, apply=args.apply, run_id=run_id)
        except LockHeld as exc:
            print(f"profile-claim drain: {exc} — a run holds the write lock, so the rollback "
                  f"did NOT run; re-run it when the run finishes", file=sys.stderr)
            return 2
        print(json.dumps({**result,
                          "cannot_undo": "trays are files no surface executes; nothing else was written"},
                         indent=2, sort_keys=True))
        return 0 if not result["errors"] else 1

    if args.apply and common.kill_file_present(KILL_FILE):
        print(f"profile-claim drain: kill file {KILL_FILE} present", file=sys.stderr)
        return 2

    try:
        report = collect(client=client, now=now, max_gate_calls=args.max_gate_calls)
        if args.apply:
            if args.no_tray:
                for d in report.decisions:
                    if d.bucket == B_CONTRADICTION:
                        d.bucket = B_AWAITING_REVIEW
                        d.note = "tray writing disabled (--no-tray)"
                        report.buckets[B_CONTRADICTION] -= 1
                        report.buckets[B_AWAITING_REVIEW] += 1
            with common.shared_write_lock(WRITE_LOCK):
                report = apply_plan(
                    report, client=client, ledger=ledger, run_id=run_id,
                    max_writes=args.max_writes,
                    claims_recheck=lambda ids: fetch_claims(ids, run=trino_text),
                    recheck_budget_s=args.recheck_budget)
        else:
            report.dry_run = True
    except LockHeld as exc:
        print(f"profile-claim drain: {exc} — another writer is running; nothing written", file=sys.stderr)
        return 0
    except CapReached as exc:
        print(f"profile-claim drain: {exc}", file=sys.stderr)
        return 1
    except Surprise as exc:
        print(f"profile-claim drain: stopped on a surprise: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(report.as_dict(), indent=2, sort_keys=True))
    else:
        print(digest(report))
    for path in EXECUTOR_KILL:
        if report.trays and common.kill_file_present(path):
            print(f"NOTE: {path} is present — the executor will refuse this tray until it is "
                  f"removed by a human", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
