#!/usr/bin/env python3
"""Coded proof review: a "review the proof" ask answered by code, every time.

Jan's ask (census 2026-10-21..11-04: 35 proof asks, 23 top-level, 10 with no verdict
in thread, median 31 min to verdict) reached a human, or worse an OpenClaw agent
turn that judged credits itself. This module answers it from evidence, once, in
the same shape every time: one verdict per credit request, one next step, one
reply card. It decides NOTHING by itself about approving: `SUFFICIENT` means the
evidence is sufficient, and today the only action it can take for it is to wait
for an approval route (policies/proof-review-route.json, mode off).

Design and operator view: docs/credit-verification/proof-review-coded.md.

# What it reads (all read-only)

  proof.sqlite            H3: `proof_intake` (the documents on file for the
                          account, their conversation, arrival time), `forensics`
                          F2 (a document another account already sent) and F5a
                          (document kind), `stage2_shadow` (the per request x
                          role verdict built from H3 + the catalog when the
                          account was on the decider's proof-on-file hold).
  doc-verify.sqlite       `dv_outcomes`: the latest per-document read
                          (verified | contradicted | forged | unverifiable |
                          unknown), the `need` code and its reason.
  dsp-verify.sqlite       `dsp_verdicts.anchor`: whether a same-run Spotify AND
                          Tidal by-id anchor was confirmed for the request.
  fraud lens              credit_review.fraud_lens (the messaging holds and the
                          velocity band), measured once per run.
  decider ledger          `decisions.claimed_roles` (the request's own claim, latest
                          row per request): completeness is measured against it,
                          never against the rows a judge happened to write.
  injection watch         lib.injection_watch ledger rows recorded against a
                          document's extracted text (detection only).

# The verdict, per credit request x role, in this precedence

  1. HOLD                 the fraud lens holds the account, or a document on
                          file is one ANOTHER account already sent (H3 F2 at
                          HARD severity), or doc-verify read a document as
                          forged, or stage 2 recorded reject_hold (a likely
                          forgery), review (forensic doubt) or human
                          (org-affiliated, big track, an account hold).
                          Nothing goes to the user; the ask row is persisted
                          `held` and the router pages a person to decide it.
  2. DECLINE-RECOMMENDED  a document CONTRADICTS the claim (doc-verify
                          `contradicted`). Nothing goes to the user: the ask
                          row is persisted `held` and a named human is paged.
  3. SUFFICIENT           every claimed role is supported by a document of
                          record AND the DSP anchor is `both`.
  4. SUFFICIENT-ON-MERITS-NO-ROUTE
                          every claimed role is supported, but there is no DSP
                          anchor: the 2026-11-04 "El Guero" state. Nothing to
                          send beyond the existing on-file status; the ask
                          waits for a route.
  5. GAP-ASK              the evidence is there but does not cover the claim
                          (`need_more`, or `unverifiable` with a named gap):
                          intercom-verify-request.sh --campaign gap-ask.
  6. UVN-STATUS           nothing readable on file for it: no document at all,
                          `no_document`, unreadable in two runs (the stage-2
                          rule), or only screenshots of a dashboard / a DAW
                          session / a pro or distributor portal. The approved
                          uvn-status ask.

  Anything else is UNKNOWN: a first unreadable read, a request with no
  verdict from either judge, or a supporting read that names a document which
  is not on file for the account (a judge row is not a document). UNKNOWN asks
  nothing and approves nothing (the standing rule, and stage 2's own "when in
  doubt, no ask").

Per role a later doc-verify read may PROMOTE an unapproved role and never
DEMOTE one stage 2 already approved. The only downgrade a newer read can
produce is `unverifiable`/`unknown` ("we could not read it"), which is already
a non-approval, so it buys no safety - while it is customer-facing, because an
unsupported role routes into the gap ask. The real safety signals fire from
their own arms whatever that rule returns: `forged` -> HOLD, `contradicted` ->
DECLINE-RECOMMENDED, `reject_hold`/`review`/`human` -> HOLD. A document whose
extracted text carries an instruction pattern can neither approve nor deny a
claim: its doc-verify read counts as `unverifiable` and the hit is named in the
why. A stage-2 `approve` of that same document supports nothing either - the
judges read the same text, so a tainted document never makes a role covered
(`forged` stays a HOLD). A ledger that cannot be read is not a quiet day: no document is evidence
and every request holds.

The latest stage-2 row under the CURRENT `analyzer_version` is the read: stage
2's own load filters on it, so a new analyzer version re-judges every request
and a later row under a new version - `approve` or `need_more` - can replace an
earlier `reject_hold`/`review`/`human` and clear that HOLD arm. No HOLD here is
permanent against a re-read under a new analyzer version; lifting a real hold is
a human's decision, not a re-read's, which is why this module never clears one
itself - it only reads what the latest row says. The two judges' other signals
follow their own latest-read rules too: a later `verified` read of the same role
clears an earlier doc-verify `forged`, and a re-analysis under a new
`analyzer_version` clears an H3 hard-F2 reuse row.

The deny/route half of the intent is satisfied: an insufficient proof always
becomes a coded ask and a sufficient proof never approves; the approval half is
blocked on the captain's approval route and this lane does not implement it.

# The next coded step

Only three actions exist, and only for the two ask verdicts:

  GAP-ASK / UVN-STATUS  -> the armed sender (credit_review.uvn_status with
                           campaign gap-ask|uvn-status, --from-stage2), which
                           owns the copy, the identity gate, the 20-day
                           idempotency, the fraud holds and the ledger. This
                           module never writes a customer message itself and
                           never renders one: it names the campaign, and the
                           sender refuses if its own stage-2 release disagrees.
  SUFFICIENT*           -> no customer message: the review state is
                           waiting_route, and the router keeps the ask row OPEN
                           (`ask`, chased by the overdue-ask tick) rather than
                           closing it `answered`, since no decision was taken.
                           The approval route is OFF
                           (policies/proof-review-route.json); `on` does not
                           approve either - there is no approval writer in this
                           lane, and adding one is a captain decision.
  HOLD / DECLINE         -> nothing to the user; the ask row is `held` (not
                           `answered`) and the router pages a person.
  UNKNOWN (every role)  -> nothing is asked and nothing approved YET: the ask
                           row stays OPEN (`ask`) naming the uvn-status campaign,
                           whose "we could not read your document, please send a
                           clear copy or a link" line is approved and unlocked
                           (UVN_STATUS_COPY_APPROVED=1 since 2026-10-29), so it can
                           send as soon as run() runs in apply mode - subject only
                           to the sender's own population/placeholder/identity
                           gates (gap-ask's copy lock, GAP_ASK_COPY_APPROVED=0, is
                           the one still closed) - and doc-verify's next read
                           decides the ask.

# The reply card (one line, Slack mrkdwn, no account names)

  proof-review <ask> <account hash> <N> requests: k sufficient / g gap-ask /
  u uvn-status / h hold / c contradicted  documents: <sha8>(<reuse flag>), ...
  sent: <campaign|none> (<gate reason>)  ledger <ref|none>

The words "approved" / "approval" never appear unless a decision ledger row
exists for one of the requests (never, today): a proof review is evidence, not
a decision.

# What this module never does

  - never changes a credit request, never writes to core, never sends to a user
    on its own path (the single sender does), never calls a model (the document
    judges already ran: H3 forensics + doc-verify; a document's text is data);
  - never reads a name from a document as an instruction, and never lets text
    inside a document choose an account, a request or a verdict rule - the
    account comes from the H3 filing (matched by a verified handle), the
    requests from core, the verdict from the precedence above;
  - never approves.

CLI (read-only unless --mode apply):

  proof_review.py review --conversation <id> [--mode apply] [--asked-at TS] [--json]
  proof_review.py review --request-ids <uuid,...> --user-id <id> [...]
  proof_review.py board                      # today's cards, one line each
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import sqlite3
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# ── verdicts ─────────────────────────────────────────────────────────────────
SUFFICIENT = "sufficient"
SUFFICIENT_ON_MERITS = "sufficient-on-merits-no-route"
GAP_ASK = "gap-ask"
UVN_STATUS = "uvn-status"
HOLD = "hold"
DECLINE = "declined-recommended"
UNKNOWN = "unknown"

VERDICTS = (SUFFICIENT, SUFFICIENT_ON_MERITS, GAP_ASK, UVN_STATUS, HOLD, DECLINE, UNKNOWN)
# The two verdicts that name a campaign the single sender owns.
CAMPAIGN = {GAP_ASK: "gap-ask", UVN_STATUS: "uvn-status"}
# The card's five buckets (the contract from j2) plus the ones that need their own count.
BUCKETS = (SUFFICIENT, GAP_ASK, UVN_STATUS, HOLD, DECLINE, UNKNOWN)

# ── evidence vocabulary ──────────────────────────────────────────────────────
# stage2_shadow.outcome (credit_verify/proof/stage2.py)
S2_APPROVE, S2_REJECT, S2_HUMAN, S2_REVIEW = "approve", "reject_hold", "human", "review"
S2_NEED_MORE, S2_NO_DOCUMENT, S2_UNDETERMINED = "need_more", "no_document", "undetermined"
# dv_outcomes.outcome (credit_verify/docverify/gate.py)
DV_VERIFIED, DV_CONTRADICTED, DV_FORGED = "verified", "contradicted", "forged"
DV_UNVERIFIABLE, DV_UNKNOWN = "unverifiable", "unknown"

# H3 F2 (credit_verify/proof/store.py cross_account): which cross-account signals HOLD the ask.
# HARD is a stolen/relabelled document. The two `claimant_undetermined` / `role_undetermined` signals
# are INFO by severity but say the same thing the 2026-11-04 17:42Z human reviewer read as "reused
# document": another account sent this file and it does not say whose it is, so we cannot tell. Asking
# its sender for MORE proof is the one thing not to do. Every other F2 name is a co-writer case
# (shared_split_sheet, shared_multi_track_document, shared_public_page = POSITIVE), a template family
# (not reuse), or this account's own re-upload: reported on the card, left to the judges.
REUSE_HARD = "hard"
REUSE_HOLD_NAMES = frozenset({"reused_by_another_account", "reused_by_another_account_same_claim",
                              "reused_on_another_track", "impersonation_suspected",
                              "shared_document_claimant_undetermined", "shared_document_role_undetermined"})
# F2 signal names that are about THIS account's own re-upload, never reuse by somebody else.
REUSE_OWN = frozenset({"reupload_same_account"})

# A dashboard / catalog panel / DAW-session screenshot is not a document of record: a credit claim needs
# a document that names the claimant and the track (credit_verify/docverify/gate.py RECORD_DOC_TYPES).
# These are H3's F5a kinds - the brief's own three examples (SongDNA panel, dashboard, Pro Tools session).
# `distributor_portal` and `pro_portal` are deliberately NOT here: H3's kind is a keyword count, so a real
# contract naming DistroKid three times reads `distributor_portal` (gate.py's own warning, QA #1476).
# A kind of `unknown` (the F5a default, most documents) carries no information and is never a screenshot.
SCREENSHOT_KINDS = frozenset({"catalog_page", "dsp_for_artists", "daw_session"})
# Unreadable this many times is `no_document` (stage2_verdicts.UNDETERMINED_RERUNS / the doc-verify
# store's own retry rule): a document we cannot read twice is not in the file.
UNREADABLE_RERUNS = 2
# The injection window starts at the oldest document under review; this margin absorbs a filing
# timestamp written a moment after the hit. No parseable filing time means no bound: read the lot.
INJECTION_WINDOW_MARGIN_HOURS = 1
INJECTION_WINDOW_UNKNOWN_FILING_HOURS = 24 * 365 * 50
INJECTION_LEDGER = os.environ.get("INJECTION_WATCH_LEDGER", "/var/lib/hydra/injection-watch/ledger.jsonl")
PROOF_DB = os.environ.get("CREDIT_PROOF_STORE", "/var/lib/hydra-credit-verify/proof.sqlite")
DV_DB = os.environ.get("CREDIT_DOC_VERIFY_STORE", "/var/lib/hydra-credit-verify/doc-verify.sqlite")
DSP_DB = os.environ.get("CREDIT_DSP_VERIFY_STORE", "/var/lib/hydra-credit-verify/dsp-verify.sqlite")
STATE_DIR = os.environ.get("PROOF_REVIEW_STATE_DIR", "/var/lib/hydra-credit-verify")
STORE = os.environ.get("PROOF_REVIEW_STORE", os.path.join(STATE_DIR, "proof-review.sqlite"))
KILL_SWITCH = os.environ.get("CREDIT_VERIFY_KILL_SWITCH", "/etc/hydra/credit-verify.disabled")
# The approval route (captain decision, off): off | log | on. Missing or malformed reads as off -
# a broken file must never look like a lifted gate.
ROUTE_POLICY = os.environ.get("PROOF_REVIEW_ROUTE",
                              str(Path(__file__).resolve().parents[2] / "policies" / "proof-review-route.json"))
DECIDE_LEDGER = os.environ.get("CREDIT_TRUST_DECIDE_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
# At most this many cards per account per UTC day (a burst of re-sends must not page the lane 20 times).
CARDS_PER_ACCOUNT_DAY = 3
# The card is due inside 15 min of the ask; past 30 is an escalation to the intake lane, never a
# reason to hold the card back.
SLA_MINUTES, LATE_MINUTES = 15, 30


class ProofReviewError(RuntimeError):
    """The review could not be computed (an unreadable store). Nothing is decided and nothing sent."""


# ── the facts, as the loaders hand them over ─────────────────────────────────
@dataclass(frozen=True)
class Reuse:
    name: str
    severity: str

    @property
    def hard(self) -> bool:
        """Does this signal mean another account sent this document?"""
        return self.severity == REUSE_HARD or self.name in REUSE_HOLD_NAMES


@dataclass(frozen=True)
class Document:
    """One document on file (H3 `proof_intake`), with what H3 said about it."""
    proof_id: str
    doc_kind: str = ""
    reuse: tuple[Reuse, ...] = ()
    injection: str = ""          # the highest injection-watch severity recorded against its text
    conversation_id: str = ""    # provenance only: the verdict reads every document the account filed
    filed_at: str = ""           # when the customer sent it: the injection window starts here

    @property
    def sha8(self) -> str:
        return self.proof_id[:8]

    @property
    def screenshot_only(self) -> bool:
        return self.doc_kind in SCREENSHOT_KINDS

    @property
    def holding_reuse(self) -> Reuse | None:
        for r in self.reuse:
            if r.hard:
                return r
        return None

    @property
    def reuse_flag(self) -> str:
        """The card's short reuse flag ('' when the document triggered no F2 signal): the signal that
        holds first, then the worst severity, because 'reupload_same_account' is never the news."""
        if not self.reuse:
            return ""
        worst = max(self.reuse, key=lambda r: (r.hard, {"hard": 3, "soft": 2, "info": 1}.get(r.severity, 0)))
        return f"{worst.name}/{worst.severity}"


@dataclass(frozen=True)
class RoleProof:
    """One claimed role of a request, as the two judges last read it."""
    role: str
    stage2: str = ""             # approve|reject_hold|human|review|need_more|no_document|undetermined|""
    dv: str = ""                 # verified|contradicted|forged|unverifiable|unknown|""
    dv_need: str = ""
    proof_id: str = ""           # the document the doc-verify read is about
    stage2_proof_id: str = ""    # the document the stage-2 read is about (kept apart from proof_id: a later
                                 # doc-verify read of another document must not hide a tainted approval)
    undetermined_runs: int = 0    # consecutive stage-2 runs judging it undetermined
    unknown_runs: int = 0         # consecutive doc-verify runs returning `unknown`
    stage2_at: str = ""           # when stage 2 recorded its read (judged_at)
    dv_at: str = ""               # when doc-verify recorded its read (at)


@dataclass(frozen=True)
class RequestProof:
    request_id: str
    user_id: int | None
    roles: tuple[RoleProof, ...] = ()
    dsp_anchor: str = "none"      # both | single | none
    claimed_roles: tuple[str, ...] = ()   # the claim the decider recorded; () = never recorded

    @property
    def anchor_both(self) -> bool:
        return self.dsp_anchor == "both"


@dataclass(frozen=True)
class Ask:
    """One proof-review ask: the account, its documents and its requests."""
    ask_id: str
    conversation_id: str = ""
    account_h: str = ""
    user_ids: tuple[int, ...] = ()
    asked_at: str = ""
    documents: tuple[Document, ...] = ()
    requests: tuple[RequestProof, ...] = ()
    fraud_held: tuple[str, ...] = ()   # the fraud lens's reasons, [] when it does not hold
    fraud_watch: tuple[str, ...] = ()  # reported, never a hold
    injection_unchecked: str = ""      # why the injection check could not run; every request then HOLDS
    route: str = "off"                 # off | log | on

    @property
    def account(self) -> str:
        """The account hash the card carries: H3's contact hash, never a name or an email."""
        h = (self.account_h or "").strip().lower()
        if len(h) >= 8 and all(c in "0123456789abcdef" for c in h):
            return h[:8]
        return "unknown"


@dataclass(frozen=True)
class RequestVerdict:
    request_id: str
    verdict: str
    why: str
    documents: tuple[str, ...] = ()      # sha8 of the documents this verdict rests on


@dataclass
class Review:
    ask: Ask
    verdicts: tuple[RequestVerdict, ...] = ()
    counts: dict[str, int] = field(default_factory=dict)
    state: str = ""                      # waiting_route | ask | asked | hold | declined | unknown | unfiled
    campaign: str = ""                   # the campaign the next step names ('' none)
    sent: str = "none"                   # none | the campaign, after the sender ran
    gate_reason: str = ""
    ledger: str = "none"                 # this card's own ledger row (card:<id>) once recorded
    decision: str = "none"               # the decider's row for these requests, or none
    card: str = ""
    at: str = ""
    sla_minutes: int | None = None


# ── the precedence (pure) ────────────────────────────────────────────────────
def _role_unknown(r: RoleProof) -> bool:
    return (not r.stage2 and not r.dv) or r.dv == DV_UNKNOWN or r.stage2 == S2_UNDETERMINED


def _supporting_proof(r: RoleProof) -> str | None:
    """The document the read that supports this role rests on: a stage-2 approval is about
    `stage2_proof_id`, a doc-verify verification about the document it read (`proof_id`). None when no
    read supports the role at all, so nothing about it is being approved."""
    if r.stage2 == S2_APPROVE:
        return r.stage2_proof_id
    if r.dv == DV_VERIFIED:
        return r.proof_id
    return None


def _role_supported(r: RoleProof, filed: frozenset[str]) -> bool:
    """A document of record covers this role, which takes TWO things: a read that supports it, and that
    read naming a document actually ON FILE for the account (`filed`). A judge row is not a document - the
    store records the proof id it read, and a read of a document nobody in scope filed (a stale id, a
    wrong account's filing, or no id at all) cannot support "a document of record", so it approves
    nothing. A later doc-verify read may PROMOTE an unapproved role and never DEMOTE one stage 2 already
    approved: the only downgrade a newer read can produce is `unverifiable`/`unknown` ("we could not read
    it"), which is already a non-approval, so it buys no safety - while it is customer-facing, because an
    unsupported role routes into the gap ask. The real safety signals fire from their own arms whatever
    this returns (`forged` -> HOLD, `contradicted` -> DECLINE-RECOMMENDED, `reject_hold`/`review`/`human`
    -> HOLD). When the two timestamps cannot order the reads, stage 2 is the read."""
    proof = _supporting_proof(r)
    if proof is None or proof not in filed:
        return False
    if r.stage2 == S2_APPROVE or not r.stage2:
        return True
    return bool(r.stage2_at and r.dv_at and r.dv_at > r.stage2_at)


def _tainted(r: RoleProof, tainted: frozenset[str]) -> RoleProof:
    """A document whose extracted text carries an instruction pattern can neither approve nor deny a claim:
    its doc-verify read counts as unverifiable (the gap ask, never a hold, never a decline), and the hit is
    named in the why. That includes the stage-2 approval of the SAME document - the judges read the same
    text, so a tainted document never supports a role, whichever arm it reached. A `forged` read is left
    alone - it is already a HOLD, and neutralizing it would weaken a fail-closed signal."""
    ids = {p[:8] for p in (r.proof_id, r.stage2_proof_id) if p}
    if not (ids & tainted) or r.dv == DV_FORGED:
        return r
    if r.dv not in (DV_VERIFIED, DV_CONTRADICTED) and r.stage2 != S2_APPROVE:
        return r
    return dataclasses.replace(r, dv=DV_UNVERIFIABLE, dv_need="injection_hit",
                              stage2="" if r.stage2 == S2_APPROVE else r.stage2)


def _role_key(role: str) -> str:
    return " ".join(str(role or "").split()).casefold()


def _unread_claim(req: RequestProof, roles: Sequence[RoleProof]) -> tuple[str, ...] | None:
    """The claimed roles no judge has read, or None when the claim itself was never recorded.

    The judges' role list is not the claim: stage 2 writes one row per claimed role and doc-verify reads
    the role it is given, so a request whose Producer row was never written has exactly the same judged
    roles as a request that claims Composer alone. `all(...)` over that list is therefore never evidence
    that EVERY claimed role is covered - the request's own role list is, and it is the decider's
    `decisions.claimed_roles`. An unrecorded or partly read claim approves nothing (UNKNOWN)."""
    claimed = {_role_key(r): " ".join(str(r).split()) for r in req.claimed_roles if _role_key(r)}
    if not claimed:
        return None
    return tuple(sorted(claimed[k] for k in set(claimed) - {_role_key(r.role) for r in roles}))


def _role_no_document(r: RoleProof) -> bool:
    """Nothing readable is on file for this role: no_document, or unreadable in two runs."""
    if r.stage2 == S2_NO_DOCUMENT:
        return True
    if r.stage2 == S2_UNDETERMINED and r.undetermined_runs >= UNREADABLE_RERUNS:
        return True
    if r.dv == DV_UNKNOWN and r.unknown_runs >= UNREADABLE_RERUNS:
        return True
    # need_more is a gap (the document is there and does not cover the claim), never "nothing on file".
    # A stage-2 `human`/`review`/`reject_hold` is decided earlier, by the HOLD arms.
    return False


def request_verdict(req: RequestProof, documents: Sequence[Document], *, fraud_held: Sequence[str] = ()) \
        -> RequestVerdict:
    """The coded verdict for one credit request, in the documented precedence."""
    shas = tuple(sorted({d.sha8 for d in documents}))
    tainted = frozenset(d.sha8 for d in documents if d.injection)
    # The documents that can support a claim: a screenshot of a dashboard / a DAW is not a document of
    # record (arm 5), so it never covers a role either.
    filed = frozenset(d.proof_id for d in documents if not d.screenshot_only)
    roles = tuple(_tainted(r, tainted) for r in req.roles)
    # 1. HOLD: the account is fraud-held, or a document on file is another account's.
    if fraud_held:
        return RequestVerdict(req.request_id, HOLD, "fraud lens holds the account: " + "; ".join(fraud_held)[:200],
                              shas)
    stolen = [(d.sha8, r.name) for d in documents for r in d.reuse if r.hard]
    if stolen:
        where, name = stolen[0]
        return RequestVerdict(req.request_id, HOLD, f"a document on file ({where}) is one another account already "
                                                    f"sent ({name})", (where,))
    if not roles:
        return RequestVerdict(req.request_id, UNKNOWN, "no judge has recorded a verdict for this request", shas)
    # 1b. HOLD: a document on file is likely forged (doc-verify `forged`) - the same family as reuse.
    for r in roles:
        if r.dv == DV_FORGED:
            return RequestVerdict(req.request_id, HOLD,
                                  f"{r.role}: the document on file is likely forged",
                                  (r.proof_id[:8],) if r.proof_id else shas)
    # 2. HOLD: a document with forensic doubts, a likely forgery, or an account-level hold. This arm
    # runs BEFORE the decline arm: a contradicted document with an applicable stage-2 hold must HOLD,
    # not decline - a row that should pause for a human is never refused to the customer.
    for r in roles:
        if r.stage2 in (S2_REJECT, S2_REVIEW, S2_HUMAN):
            return RequestVerdict(req.request_id, HOLD, f"{r.role}: stage 2 recorded {r.stage2}", shas)
    # 3. DECLINE-RECOMMENDED: a document contradicts the claim.
    for r in roles:
        if r.dv == DV_CONTRADICTED:
            return RequestVerdict(req.request_id, DECLINE,
                                  f"{r.role}: the document contradicts the claim ({r.dv_need or r.dv}); a named human "
                                  "is the first 20", (r.proof_id[:8],) if r.proof_id else shas)
    # 4. SUFFICIENT / SUFFICIENT-ON-MERITS: every CLAIMED role covered by a document of record. The
    # judged rows alone can be a subset of the claim, so a partial read approves nothing.
    if all(_role_supported(r, filed) for r in roles):
        unread = _unread_claim(req, roles)
        if unread is None:
            return RequestVerdict(req.request_id, UNKNOWN,
                                  "the request's claimed roles are not recorded, so a read of "
                                  f"{', '.join(sorted(r.role for r in roles))} cannot be every claimed role", shas)
        if unread:
            return RequestVerdict(req.request_id, UNKNOWN,
                                  f"a judge has not read every claimed role (not read: {', '.join(unread)})", shas)
        if req.anchor_both:
            return RequestVerdict(req.request_id, SUFFICIENT,
                                  f"every claimed role ({', '.join(sorted(r.role for r in roles))}) is covered by a "
                                  "document of record, and a same-run Spotify and Tidal anchor confirms the credit", shas)
        return RequestVerdict(req.request_id, SUFFICIENT_ON_MERITS,
                              "every claimed role is covered by a document of record, but there is no same-run DSP "
                              "anchor: sufficient on the merits, no route", shas)
    # 5. UVN-STATUS: nothing of record on file. A screenshot of a catalog panel / DAW session is not
    # a document at all, so it reads as "nothing on file" BEFORE the gap arm: the approved uvn-status
    # ask is the honest one, and the gap ask would name a gap in a document that is not one.
    if documents and all(d.screenshot_only for d in documents):
        kinds = ", ".join(sorted({d.doc_kind for d in documents}))
        return RequestVerdict(req.request_id, UVN_STATUS,
                              f"the only documents on file are screenshots ({kinds}): not a document of record", shas)
    # 6. GAP-ASK: the evidence is there but does not cover the claim.
    gaps = [r for r in roles if r.stage2 == S2_NEED_MORE or r.dv == DV_UNVERIFIABLE]
    if gaps:
        needs = sorted({r.dv_need for r in gaps if r.dv_need})
        return RequestVerdict(req.request_id, GAP_ASK,
                              f"{', '.join(r.role for r in gaps)}: the document on file does not cover the claim"
                              + (f" ({', '.join(needs)})" if needs else ""), shas)
    # 7. UVN-STATUS: nothing readable for the claim.
    if all(_role_no_document(r) for r in roles):
        return RequestVerdict(req.request_id, UVN_STATUS, "nothing readable is on file for this request", shas)
    # 8. UNKNOWN: a role reads as supported by a document that is NOT on file for this account (or by no
    # document at all - no proof id recorded). The read cannot be tied to a filing, so "a document of
    # record supports this role" is unmeasured: nothing asked, nothing approved. It sits after the gap
    # arm, so a role that is a gap is still asked for the document it needs.
    untied = sorted({r.role for r in roles
                     if (p := _supporting_proof(r)) is not None and p not in filed})
    if untied:
        return RequestVerdict(req.request_id, UNKNOWN,
                              f"a judge supports {', '.join(untied)} with a document that is not on file for "
                              "this account: nothing asked, nothing approved", shas)
    if any(_role_unknown(r) for r in roles):
        return RequestVerdict(req.request_id, UNKNOWN,
                              "a judge has not finished reading this request (one unreadable read)", shas)
    # A role supported, another with nothing on file: the missing role is asked for.
    return RequestVerdict(req.request_id, UVN_STATUS, "part of the claim has nothing readable on file", shas)


def review(ask: Ask) -> Review:
    """Every request's verdict, the counts, the next coded step and the card. Pure."""
    if len(ask.user_ids) > 1:
        # One ask, one account. The documents are loaded for the ask as a whole, so a verdict rendered
        # across two accounts could call a request covered by a document that belongs to somebody else,
        # and the card carries a single account hash. Nothing is decided: a person splits the ask (the
        # sender also takes exactly one account).
        rev = Review(ask=ask, at=utcnow(), state="unknown")
        rev.gate_reason = (f"the ask covers {len(ask.user_ids)} accounts: a person must split it into one ask "
                           "per account before any verdict is rendered. An approved customer line is on file, "
                           "but the sender campaign that renders it does not exist yet ("
                           "SPLIT_ACCOUNT_COPY_APPROVED=0), so nothing is sent.")
        rev.sla_minutes = _sla(ask.asked_at, rev.at)
        rev.card = ""
        return rev
    if ask.injection_unchecked:
        # "We could not check these documents for injection" is a system fault, not a gap in the
        # customer's proof: hold, never ask them for more. No document on file is evidence.
        why = (f"the injection check could not run ({ask.injection_unchecked}): no document on file can be read "
               "as evidence")
        verdicts = tuple(RequestVerdict(r.request_id, HOLD, why,
                                        tuple(sorted({d.sha8 for d in ask.documents})))
                         for r in ask.requests)
    else:
        verdicts = tuple(request_verdict(r, ask.documents, fraud_held=ask.fraud_held) for r in ask.requests)
    counts = {v: 0 for v in BUCKETS}
    for rv in verdicts:
        counts[rv.verdict] = counts.get(rv.verdict, 0) + 1
    counts[SUFFICIENT] += counts.pop(SUFFICIENT_ON_MERITS, 0)   # the card's "sufficient" bucket
    rev = Review(ask=ask, verdicts=verdicts, counts=counts, at=utcnow())
    rev.state, rev.campaign = _next_step(verdicts)
    if not ask.documents and not ask.requests:
        # Nothing is filed anywhere for this ask: the resolver's first step has not run for it, and
        # this module never reads an Intercom conversation itself. Say so instead of a silent zero.
        rev.state = "unfiled"
        rev.gate_reason = "nothing is filed for this ask: run credit-proof.py file --apply for the conversation first"
    rev.sla_minutes = _sla(ask.asked_at, rev.at)
    rev.ledger, rev.decision = "none", "none"
    rev.card = render_card(rev)
    return rev


def _next_step(verdicts: Sequence[RequestVerdict]) -> tuple[str, str]:
    """(ask row state, campaign the sender owns). The only three actions there are.

    A HOLD or a DECLINE anywhere in the ask stops every message: an account with a forensic hold or a
    contradicted claim is never sent an ask (the single sender's own account-hold rule), and the card
    pages a human instead. An all-UNKNOWN ask is nothing to ask about YET: no judge has finished reading
    it (`unknown` asks nothing, approves nothing), so it stays open as `ask` and names the uvn-status
    campaign - the "we could not read your document, please send a clear copy or a link" line - to be
    decided by doc-verify's next read. In a MIXED ask one unread-once request does not silence the asks
    the rest of the ask needs: the sender's stage-2 release never includes a request no judge released.
    """
    got = {v.verdict for v in verdicts}
    if not verdicts:
        return "unknown", ""
    if HOLD in got:
        return "hold", ""
    if DECLINE in got:
        return "declined", ""
    if got == {UNKNOWN}:
        return "ask", CAMPAIGN[UVN_STATUS]
    if got <= {SUFFICIENT, SUFFICIENT_ON_MERITS}:
        # No customer message beyond the existing on-file status, whatever the route says: the
        # approval writer is not built (a captain decision), so the ask waits.
        return "waiting_route", ""
    # Both asks can be due at once and §3 names ONE campaign per run: ask for the gap (which names
    # what is missing) first; the rest is counted on the board and picked up by the next review.
    wanted = [CAMPAIGN[v] for v in (GAP_ASK, UVN_STATUS) if v in got]
    if wanted:
        return "asked", wanted[0]
    return "unknown", ""


def _sla(asked_at: str, now: str) -> int | None:
    try:
        a = datetime.strptime(asked_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        n = datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None
    return max(0, int((n - a).total_seconds() // 60))


# ── the reply card ───────────────────────────────────────────────────────────
def _restamp(rev: Review) -> None:
    if rev.card:
        rev.card = render_card(rev)


def render_card(rev: Review) -> str:
    """One Slack line, the contract from j2. No account names, no 'approved' without a ledger row."""
    c = rev.counts
    n = len(rev.verdicts)
    parts = [f"proof-review {rev.ask.ask_id}", f"acct {rev.ask.account}",
             f"{n} request{'s' if n != 1 else ''}: "
             f"{c.get(SUFFICIENT, 0)} sufficient / {c.get(GAP_ASK, 0)} gap-ask / {c.get(UVN_STATUS, 0)} uvn-status / "
             f"{c.get(HOLD, 0)} hold / {c.get(DECLINE, 0)} contradicted"]
    if c.get(UNKNOWN):
        parts.append(f"{c[UNKNOWN]} unknown")
    docs = ", ".join(f"{d.sha8}" + (f"({d.reuse_flag})" if d.reuse_flag else "")
                     + ("(screenshot)" if d.screenshot_only else "")
                     + (f"(injection:{d.injection})" if d.injection else "")
                     for d in rev.ask.documents[:8]) or "none"
    if len(rev.ask.documents) > 8:
        docs += f" (+{len(rev.ask.documents) - 8})"
    parts.append(f"documents: {docs}")
    sent = rev.sent if rev.sent != "none" else "none"
    parts.append(f"sent: {sent}" + (f" ({rev.gate_reason})" if rev.gate_reason else ""))
    parts.append(f"ledger {rev.decision if rev.decision != 'none' else rev.ledger}")
    if rev.sla_minutes is not None:
        parts.append(f"sla {rev.sla_minutes}m" + (" LATE" if rev.sla_minutes > LATE_MINUTES else ""))
    card = " · ".join(parts)
    if rev.decision == "none":
        # Never the word: a proof review is evidence, and only a decision ledger row is a decision.
        for word in ("approv", "Approved", "APPROVED"):
            if word in card:
                raise ProofReviewError(f"refusing to render a card carrying {word!r} without a decision ledger row")
    return " ".join(card.split())


# ── the stores, read-only ────────────────────────────────────────────────────
def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ro(path: str) -> sqlite3.Connection:
    if not os.path.exists(path):
        raise ProofReviewError(f"store missing: {path}")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
        db.row_factory = sqlite3.Row
        return db
    except sqlite3.Error as exc:            # pragma: no cover - unreadable file
        raise ProofReviewError(f"store unreadable: {path}: {exc}") from exc


def _exec(db: sqlite3.Connection, sql: str, params: Sequence[Any] = (), *, what: str) -> list[sqlite3.Row]:
    """The rows of one read, with a query the store cannot answer turned into this module's own
    error: a store that is there and unreadable is a broken reader, never a quiet absence of
    evidence, and every caller of this module already handles `ProofReviewError`."""
    try:
        return db.execute(sql, params).fetchall()
    except sqlite3.Error as exc:
        raise ProofReviewError(f"{what} unreadable: {type(exc).__name__}: {exc}") from exc


def load_documents(user_ids: Sequence[int], *, proof_db: str | None = None,
                   kinds: dict[str, str] | None = None, reuse: dict[str, tuple[Reuse, ...]] | None = None,
                   injections: dict[str, str] | None = None,
                   version: str | None = None) -> tuple[Document, ...]:
    """Every document H3 filed for these accounts, whatever conversation it arrived in, with H3's
    reuse F2 and kind F5a under the current analyzer version.

    The verdict's other inputs (stage 2, doc-verify, the H3 filings, the fraud lens) are per REQUEST
    and not conversation-scoped, so narrowing the documents to one conversation would make the two
    halves disagree and ask a user for proof that is already on file. `conversation_id` rides on each
    Document as provenance for reuse and forensics."""
    if not user_ids:
        return ()
    db = _ro(proof_db or PROOF_DB)
    try:
        where, params = _in_clause("user_id", user_ids)
        rows = _exec(db, f"SELECT DISTINCT file_sha256, user_id, conversation_id, received_at "
                         f"FROM proof_intake WHERE {where}", params, what="the proof filings")
        # One Document per sha: the same document filed in two conversations (or by two accounts in
        # scope) is one document on file, and the card must not list it twice. The first conversation
        # by id is the provenance and the earliest filing is the stamp, so a later duplicate cannot
        # shorten the injection window; reuse, kind and the injection hit are keyed by sha, so they
        # survive.
        convs: dict[str, str] = {}
        filed: dict[str, str] = {}
        undated: set[str] = set()
        for r in sorted(rows, key=lambda r: (str(r["conversation_id"] or ""), str(r["received_at"] or ""))):
            sha = str(r["file_sha256"])
            convs.setdefault(sha, str(r["conversation_id"] or ""))
            stamp = str(r["received_at"] or "")
            if not stamp:
                undated.add(sha)          # any undated filing makes the filing time unknown, not the dated one
            elif not filed.get(sha) or stamp < filed[sha]:
                filed[sha] = stamp
        shas = sorted(convs)
        if not shas:
            return ()
        kind = dict(kinds or {})
        reus = dict(reuse or {})
        missing = [s for s in shas if s not in kind or s not in reus]
        if missing:
            k2, r2 = _h3_flags(db, missing, version or _forensics_version())
            k2.update(kind)
            r2.update(reus)
            kind, reus = k2, r2
    finally:
        db.close()
    return tuple(Document(proof_id=s, doc_kind=kind.get(s, ""), reuse=reus.get(s, ()),
                          injection=(injections or {}).get(s, ""), conversation_id=convs.get(s, ""),
                          filed_at="" if s in undated else filed.get(s, ""))
                 for s in shas)


def _in_clause(col: str, vals: Sequence[Any]) -> tuple[str, list[Any]]:
    return f"{col} IN ({','.join('?' * len(vals))})", list(vals)


def _forensics_version() -> str:
    """The analyzer version whose rows are the current read (credit_verify.proof.FORENSICS_VERSION).
    `forensics` is append-only and versioned, so a row of another version is a stale judgement."""
    try:
        from credit_verify.proof import FORENSICS_VERSION
    except Exception as exc:               # noqa: BLE001 - no version, no way to tell a stale signal from a live one
        raise ProofReviewError(f"cannot read the analyzer version: {type(exc).__name__}: {exc}") from exc
    return FORENSICS_VERSION


def _h3_flags(db: sqlite3.Connection, proof_ids: Sequence[str], version: str) \
        -> tuple[dict[str, str], dict[str, tuple[Reuse, ...]]]:
    """({proof id: F5a kind}, {proof id: F2 signals from another account}) for these documents, under
    the current analyzer version only: a re-analysis that cleared an older signal is the read."""
    kinds: dict[str, str] = {}
    reuse: dict[str, list[Reuse]] = {}
    for i in range(0, len(proof_ids), 400):
        chunk = list(proof_ids[i:i + 400])
        where, params = _in_clause("proof_id", chunk)
        for r in _exec(db, f"SELECT proof_id, name, severity, value_json FROM forensics WHERE check_id = 'F5a' "
                           f"AND name = 'document_kind' AND analyzer_version = ? AND {where} ORDER BY id",
                       [version, *params], what="the H3 forensics"):
            try:
                v = json.loads(r["value_json"] or "{}")
            except ValueError:
                continue
            if isinstance(v, dict) and isinstance(v.get("kind"), str) and v["kind"] != "unknown":
                kinds[str(r["proof_id"])] = v["kind"]        # the latest kind wins; `unknown` says nothing
        for r in _exec(db, f"SELECT DISTINCT proof_id, name, severity FROM forensics WHERE check_id = 'F2' "
                           f"AND analyzer_version = ? AND {where}", [version, *params],
                       what="the H3 forensics"):
            if r["name"] in REUSE_OWN:
                continue
            reuse.setdefault(str(r["proof_id"]), []).append(Reuse(name=str(r["name"]),
                                                                  severity=str(r["severity"] or "")))
    return kinds, {k: tuple(v) for k, v in reuse.items()}


def load_stage2(request_ids: Sequence[str], *, proof_db: str | None = None) -> dict[str, dict[str, RoleProof]]:
    """{request id: {role: the latest stage-2 read}} under the current analyzer version, with the
    consecutive-undetermined count (an unreadable twice rule).

    A store that is not there at all, or one stage 2 has never written to, is no evidence (a warning
    on stderr, then {}); a store that is there and unreadable is a broken reader and raises. The
    difference matters: no stage-2 view leaves every role to doc-verify alone, while a half-read
    store would drop a recorded reject_hold/review/human and let the request read SUFFICIENT."""
    if not request_ids:
        return {}
    path = proof_db or PROOF_DB
    if not os.path.exists(path):
        print(f"[proof-review] proof store not found ({path}): no stage-2 verdicts this run", file=sys.stderr)
        return {}
    db = _ro(path)
    try:
        have = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='stage2_shadow'").fetchone()
    except sqlite3.Error as exc:
        raise ProofReviewError(f"stage-2 store unreadable: {path}: {exc}") from exc
    finally:
        db.close()
    if have is None:
        print(f"[proof-review] no stage2_shadow table in {path}: stage 2 has not judged anything yet",
              file=sys.stderr)
        return {}
    try:
        from credit_review import stage2_verdicts
        got = stage2_verdicts.load(path, request_ids=list(request_ids))
    except Exception as exc:               # noqa: BLE001 - a store that is there and unreadable is a broken reader
        raise ProofReviewError(f"stage-2 store unreadable: {path}: {type(exc).__name__}: {exc}") from exc
    return {rid: {role: RoleProof(role=role, stage2=v.outcome, proof_id=str(v.proof_id or ""),
                                  stage2_proof_id=str(v.proof_id or ""),
                                  undetermined_runs=v.undetermined_runs, stage2_at=str(v.judged_at or ""))
                  for role, v in roles.items()} for rid, roles in got.items()}


def load_doc_verify(request_ids: Sequence[str], *, dv_db: str | None = None) \
        -> dict[str, dict[str, RoleProof]]:
    """{request id: {role: the LATEST doc-verify read}} (any document of the request) plus the
    consecutive-`unknown` count. A request with no read at all is absent.

    A store that is not there at all is no evidence (a warning on stderr, then {}); a store that is
    there and unreadable is a broken reader and raises. The difference matters: no evidence makes
    every role UNKNOWN (nothing is asked and nothing approved), while a half-read store would let a
    silent subset look like the whole answer."""
    ids = [str(r).strip().lower() for r in request_ids if str(r).strip()]
    if not ids:
        return {}
    path = dv_db or DV_DB
    if not os.path.exists(path):
        print(f"[proof-review] doc-verify store not found ({path}): no document verdicts this run", file=sys.stderr)
        return {}
    db = _ro(path)
    out: dict[str, dict[str, tuple[sqlite3.Row, int]]] = {}
    try:
        for i in range(0, len(ids), 200):
            chunk = ids[i:i + 200]
            where, params = _in_clause("lower(request_id)", chunk)
            rows = _exec(db, f"SELECT id, at, lower(request_id) rid, role, outcome, need, proof_id FROM dv_outcomes "
                             f"WHERE {where} ORDER BY id", params, what="the doc-verify store")
            unknown: dict[tuple[str, str], int] = {}
            latest: dict[tuple[str, str], sqlite3.Row] = {}
            for r in rows:
                key = (str(r["rid"]), str(r["role"]))
                latest[key] = r
                if r["outcome"] == DV_UNKNOWN:
                    unknown[key] = unknown.get(key, 0) + 1
                else:
                    unknown[key] = 0
            for key, r in latest.items():
                out.setdefault(key[0], {})[key[1]] = (r, unknown.get(key, 0))
    finally:
        db.close()
    return {rid: {role: RoleProof(role=role, dv=str(r["outcome"] or ""), dv_need=str(r["need"] or ""),
                                  proof_id=str(r["proof_id"] or ""), unknown_runs=n,
                                  dv_at=str(r["at"] or ""))
                  for role, (r, n) in roles.items()} for rid, roles in out.items()}


def load_dsp_anchor(request_ids: Sequence[str], *, dsp_db: str | None = None) -> dict[str, str]:
    """{request id: the latest dsp_verdicts anchor} (both | single | none). No store = no anchors."""
    ids = [str(r).strip().lower() for r in request_ids if str(r).strip()]
    if not ids:
        return {}
    try:
        db = _ro(dsp_db or DSP_DB)
    except ProofReviewError:
        return {}
    out: dict[str, str] = {}
    try:
        for i in range(0, len(ids), 200):
            chunk = ids[i:i + 200]
            where, params = _in_clause("lower(request_id)", chunk)
            for r in _exec(db, f"SELECT lower(request_id) rid, anchor FROM dsp_verdicts WHERE {where} "
                               f"AND id IN (SELECT MAX(id) FROM dsp_verdicts WHERE {where} GROUP BY "
                               f"lower(request_id))", params + params, what="the DSP store"):
                out[str(r["rid"])] = str(r["anchor"] or "none")
    finally:
        db.close()
    return out


def load_fraud_lens(user_ids: Sequence[int], lens: "LensFn | None" = None) -> dict[int, tuple[tuple[str, ...], tuple[str, ...]]]:
    """{user id: (held reasons, watch reasons)} from the fraud lens. No lens available = everyone
    held: a review that cannot measure the fraud lens must not act on the account (the send gate
    measures it again anyway, and this module sends nothing itself)."""
    ids = sorted({int(u) for u in user_ids})
    if not ids:
        return {}
    if lens is None:
        return {u: (("fraud lens not measured (no replica on this host)",), ()) for u in ids}
    try:
        got = lens(ids)
    except Exception as exc:               # noqa: BLE001 - a lens that cannot answer holds everybody
        print(f"[proof-review] fraud lens FAILED ({type(exc).__name__}: {exc}): holding every account on this ask",
              file=sys.stderr)
        return {u: ((f"fraud lens unavailable ({type(exc).__name__})",), ()) for u in ids}
    # An account the lens did not answer for is unmeasured, never clean: every requested id is present.
    out: dict[int, tuple[tuple[str, ...], tuple[str, ...]]] = {}
    for u in ids:
        v = got.get(u)
        out[u] = (tuple(v.held), tuple(v.watch)) if v is not None \
            else (("fraud lens did not answer for this account",), ())
    return out


def collision_owner(user_id: int, conversation_id: str) -> tuple[bool, str]:
    """Is this account the one the Intercom conversation belongs to? H3's filings are the evidence:
    a conversation filed under another account is a refusal (never review somebody else's proof for
    a different asker). Read-only; unknown is a refusal."""
    if not conversation_id:
        return True, ""
    db = _ro(PROOF_DB)
    try:
        rows = _exec(db, "SELECT DISTINCT user_id FROM proof_intake WHERE conversation_id = ?",
                     (str(conversation_id),), what="the conversation's filings")
    finally:
        db.close()
    owners = {int(r["user_id"]) for r in rows}
    if not owners:
        return True, ""                     # nothing filed: the resolver's own account stands
    if int(user_id) in owners:
        return True, ""
    return False, "the conversation is filed under another account"


def _hours_since(iso: str, now: str) -> int | None:
    try:
        then = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        at = datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None
    return max(0, int((at - then).total_seconds() // 3600))


def _injection_window(documents: Sequence[Document], now: str) -> int:
    """Hours back to read the injection ledger: from the OLDEST document under review, so a hit
    recorded at any point while the document has been on file counts. A fixed window would hide a
    hit older than it while the document it taints is still being judged. A document whose filing
    time cannot be read means no bound at all: the window is unknown, not the youngest readable
    document's age."""
    ages = [_hours_since(d.filed_at, now) for d in documents]
    if not ages or any(h is None for h in ages):
        return INJECTION_WINDOW_UNKNOWN_FILING_HOURS
    return max(h for h in ages if h is not None) + INJECTION_WINDOW_MARGIN_HOURS


def injection_hits(documents: Sequence[Document], *, hours: int | None = None, ledger: str | Path | None = None,
                   now: str | None = None) -> dict[str, str]:
    """{proof id: the highest injection-watch severity} for documents whose extracted text matched a
    rule. Detection only: `lib.injection_watch` records nothing about the review and the verdict reads
    the hit as "this text is data, and it can neither approve nor deny a claim".

    A ledger that cannot be read raises: `recent_hits` answers an empty list for a failed read unless
    it is told to raise, and an empty list is indistinguishable from a quiet day."""
    if not documents:
        return {}
    if hours is None:
        hours = _injection_window(documents, now or utcnow())
    try:
        from lib import injection_watch
        hits = injection_watch.recent_hits(ledger or INJECTION_LEDGER, hours=hours, on_error="raise")
    except Exception as exc:               # noqa: BLE001 - no ledger read, no taint set: refuse, never guess
        raise ProofReviewError(f"the injection ledger could not be read: {type(exc).__name__}: {exc}") from exc
    want = {d.proof_id for d in documents}
    out: dict[str, str] = {}
    rank = {"low": 1, "medium": 2, "high": 3}
    for row in hits:
        ref = str(row.get("ref") or "")
        if ref not in want:
            continue
        sev = str(row.get("severity") or "")
        if rank.get(sev, 0) >= rank.get(out.get(ref, ""), 0):
            out[ref] = sev
    return out


def load_claimed_roles(request_ids: Sequence[str], *, ledger: str | None = None) \
        -> dict[str, tuple[str, ...]]:
    """{request id: the claimed roles the decider recorded for it} from its own `decisions.claimed_roles`
    (comma-joined, append-only), the LATEST row per request.

    A missing ledger, a ledger without the table, or a request it never decided is absent: a claim nobody
    recorded approves nothing (a partial read must never look like the whole answer). Read-only."""
    ids = {str(r).strip().lower() for r in request_ids if str(r).strip()}
    path = ledger or DECIDE_LEDGER
    if not ids or not os.path.exists(path):
        return {}
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
        try:
            rows = db.execute("SELECT d.request_id, d.claimed_roles FROM decisions d JOIN "
                              "(SELECT request_id, MAX(id) id FROM decisions GROUP BY request_id) last "
                              "ON d.id = last.id").fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return {}
    out: dict[str, tuple[str, ...]] = {}
    for rid, roles in rows:
        key = str(rid or "").strip().lower()
        if key not in ids:
            continue
        got = tuple(str(x).strip() for x in str(roles or "").split(",") if str(x).strip())
        if got:
            out[key] = got
    return out


# ── the ask, assembled ───────────────────────────────────────────────────────
def build_ask(*, ask_id: str, conversation_id: str = "", user_ids: Sequence[int] = (),
              request_ids: Sequence[str] = (), asked_at: str = "", account_h: str = "",
              proof_db: str | None = None, dv_db: str | None = None, dsp_db: str | None = None,
              lens: "LensFn | None" = None, route: str | None = None) -> Ask:
    """Resolve the facts for one ask from the stores. Read-only.

    `request_ids` without `user_ids` derives the account from the H3 filings; a request the account
    never filed a document for still gets a verdict (UVN-STATUS / UNKNOWN), never an assumption.
    """
    users = sorted({int(u) for u in user_ids})
    if not users and conversation_id:
        users = _filed_accounts(conversation_id, proof_db) or []
    docs = load_documents(users, proof_db=proof_db) if users else ()
    unchecked = ""
    if docs:
        try:
            hits = injection_hits(docs)
        except ProofReviewError as exc:
            hits, unchecked = {}, str(exc)
        if hits:
            docs = tuple(Document(proof_id=d.proof_id, doc_kind=d.doc_kind, reuse=d.reuse,
                                  injection=hits.get(d.proof_id, ""),
                                  conversation_id=d.conversation_id, filed_at=d.filed_at) for d in docs)
    if not account_h:
        account_h = _contact_h(users, conversation_id, proof_db) or _account_h(users)
    reqs = [str(r).strip().lower() for r in request_ids if str(r).strip()]
    if not reqs:
        reqs = _candidates(users, conversation_id, proof_db)
    stage2 = load_stage2(reqs, proof_db=proof_db)
    dv = load_doc_verify(reqs, dv_db=dv_db)
    anchors = load_dsp_anchor(reqs, dsp_db=dsp_db)
    claimed = load_claimed_roles(reqs)
    proofs: list[RequestProof] = []
    for rid in reqs:
        roles = dict((stage2.get(rid) or {}))
        for role, rp in (dv.get(rid) or {}).items():
            if role in roles:
                roles[role] = RoleProof(role=role, stage2=roles[role].stage2, dv=rp.dv, dv_need=rp.dv_need,
                                        proof_id=rp.proof_id or roles[role].proof_id,
                                        stage2_proof_id=roles[role].stage2_proof_id,
                                        undetermined_runs=roles[role].undetermined_runs,
                                        unknown_runs=rp.unknown_runs,
                                        stage2_at=roles[role].stage2_at, dv_at=rp.dv_at)
            else:
                roles[role] = rp
        owner = users[0] if len(users) == 1 else None
        proofs.append(RequestProof(request_id=rid, user_id=owner, roles=tuple(roles.values()),
                                   dsp_anchor=anchors.get(rid, "none"),
                                   claimed_roles=claimed.get(rid, ())))
    fraud = load_fraud_lens(users, lens)
    held = tuple(sorted({why for u in users for why in (fraud.get(int(u)) or ((), ()))[0]}))
    watch = tuple(sorted({why for u in users for why in (fraud.get(int(u)) or ((), ()))[1]}))
    return Ask(ask_id=ask_id, conversation_id=conversation_id, account_h=account_h, user_ids=tuple(users),
               asked_at=asked_at, documents=docs, requests=tuple(proofs), fraud_held=held, fraud_watch=watch,
               injection_unchecked=unchecked,
               route=route if route is not None else route_mode())


def _filed_accounts(conversation_id: str, proof_db: str | None = None) -> list[int]:
    db = _ro(proof_db or PROOF_DB)
    try:
        return sorted({int(r["user_id"]) for r in
                       _exec(db, "SELECT DISTINCT user_id FROM proof_intake WHERE conversation_id = ?",
                             (str(conversation_id),), what="the conversation's filings")})
    finally:
        db.close()


def _contact_h(users: Sequence[int], conversation_id: str, proof_db: str | None = None) -> str:
    if not users:
        return ""
    db = _ro(proof_db or PROOF_DB)
    try:
        where, params = _in_clause("user_id", users)
        sql = f"SELECT contact_h FROM proof_intake WHERE {where} AND contact_h IS NOT NULL"
        if conversation_id:
            sql += " AND conversation_id = ?"
            params.append(str(conversation_id))
        rows = _exec(db, sql + " LIMIT 1", params, what="the proof filings")
        return str(rows[0]["contact_h"]) if rows else ""
    finally:
        db.close()


def _account_h(users: Sequence[int]) -> str:
    """A stable, non-identifying account handle when H3 has no contact hash: a hash of the numeric
    account id (never a name, an email or a professional id)."""
    return hashlib.sha256(",".join(str(int(u)) for u in users).encode()).hexdigest()[:16] if users else ""


def _candidates(users: Sequence[int], conversation_id: str, proof_db: str | None = None) -> list[str]:
    """The account's candidate requests, as H3 filed them (the resolver's list: the open
    user_verification_needed / unverified rows at filing time). Sorted, deduped, lowercase."""
    if not users:
        return []
    db = _ro(proof_db or PROOF_DB)
    out: set[str] = set()
    try:
        where, params = _in_clause("user_id", users)
        sql = f"SELECT candidate_request_ids_json FROM proof_intake WHERE {where}"
        if conversation_id:
            sql += " AND conversation_id = ?"
            params.append(str(conversation_id))
        for r in _exec(db, sql, params, what="the proof filings"):
            listed = r["candidate_request_ids_json"]
            try:
                decoded = json.loads(listed or "[]")
            except ValueError as exc:
                raise ProofReviewError(
                    "the proof filings' candidate requests are unreadable: "
                    f"{type(exc).__name__}: {exc}") from exc
            if not isinstance(decoded, list):
                raise ProofReviewError(
                    "the proof filings' candidate requests are not a list: "
                    f"{type(decoded).__name__}")
            out.update(str(x).strip().lower() for x in decoded)
    finally:
        db.close()
    return sorted(x for x in out if x)


# ── the approval route (a captain decision that is OFF) ──────────────────────
def route_mode(path: str | None = None) -> str:
    """off | log | on. Missing, unreadable or malformed reads OFF: a broken policy file must never
    look like a lifted gate. Only `on` could ever reach an approval writer, and this lane has none."""
    try:
        doc = json.loads(Path(path or ROUTE_POLICY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "off"
    route = (doc or {}).get("approval_route") if isinstance(doc, dict) else None
    mode = route.get("mode") if isinstance(route, dict) else None
    return mode if mode in ("off", "log", "on") else "off"


def ledger_row(request_ids: Sequence[str], *, ledger: str | None = None) -> str:
    """The decision ledger ref for these requests, or '' when no approval of theirs still stands.
    Read-only; a missing ledger is '' (no approval), never a reason to fail the review.

    `decision_outcomes` is append-only, so the standing decision is the LAST row per request: an
    approval a later `revert` took back (the server's `unverified`) no longer licenses the word.
    A revert the server refused (`skipped:<reason>`) leaves the approval standing."""
    ids = {str(r).strip().lower() for r in request_ids}
    path = ledger or DECIDE_LEDGER
    if not ids or not os.path.exists(path):
        return ""
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
        try:
            rows = db.execute("SELECT request_id, action, outcome, at FROM decision_outcomes "
                              "WHERE action IN ('approve', 'revert') ORDER BY id").fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return ""
    standing: dict[str, str] = {}
    for rid, action, outcome, at in rows:
        key = str(rid or "").strip().lower()
        if key not in ids:
            continue
        if action == "approve" and outcome == "approved":
            standing[key] = f"{str(rid)[:8]}@{at}"
        elif action == "revert" and outcome == "unverified":
            standing.pop(key, None)
    for rid in sorted(ids):
        if rid in standing:
            return standing[rid]
    return ""


# ── the sender (the single sender owns every customer message) ───────────────
Runner = Callable[[list[str]], "tuple[int, str]"]
LensFn = Callable[[list[int]], "dict[int, Any]"]


def send_campaign(campaign: str, user_id: int, segment: str, *, runner: Runner | None = None,
                  max_users: int = 1) -> tuple[str, str]:
    """Ask the single sender for this account's released asks. Returns (sent campaign | 'none', why).

    The sender is `credit-review.py uvn-status --campaign <c> --from-stage2`, which owns the copy, the
    identity gate, the 20-day idempotency, the fraud holds, the daily caps and the verify ledger. It
    is asked for ONE user by naming that user in `--only-users` (the sender's own positive narrowing),
    so no other account can be reached by this call: the sender filters the population it reads at
    send time, so a user who became eligible after our own read cannot take the page ahead of ours.
    A refusal is reported as `none` with the sender's own words: this module never falls back to a
    message it builds itself.

    A send is reported only on positive evidence: the sender's own `--outcomes-json` record names the
    users it sent to, and an empty `sent` list is `none` - the sender exits 0 when it offers nobody
    (wrong segment, everyone already asked, a document already on file, a gate refusal). A record
    naming any account but ours is `none` too: nothing was sent to the account that was asked.
    """
    if campaign not in CAMPAIGN.values():
        raise ProofReviewError(f"{campaign!r} is not one of the ask campaigns this lane may name")
    runner = runner or _run_cli
    try:
        only = _only_user(user_id)
    except Exception as exc:               # noqa: BLE001 - no scope file, no run: refuse, never guess
        return "none", f"sender scope unwritable ({type(exc).__name__}), nothing sent"
    try:
        outcomes = _outcomes_path(user_id)
    except Exception as exc:               # noqa: BLE001 - no record of the run, no run: refuse, never guess
        return "none", f"sender state dir unusable ({type(exc).__name__}), nothing sent"
    argv = [sys.executable, str(Path(__file__).resolve().parents[1] / "credit-review.py"), "uvn-status",
            "--campaign", campaign, "--from-stage2", "--segment", segment, "--mode", "apply",
            "--max-users", str(max_users), "--only-users", only, "--outcomes-json", outcomes]
    try:
        rc, out = runner(argv)
        sent = _sent_users(outcomes) if rc == 0 else ()
    finally:
        for path in (only, outcomes):
            try:
                os.unlink(path)
            except OSError:
                pass
    others = tuple(u for u in sent if u != str(int(user_id)))
    if others:
        return "none", f"sender reported another account ({', '.join(others[:3])}), not {int(user_id)}"
    return (campaign, _first_line(out)) if sent else ("none", _first_line(out))


def _outcomes_path(user_id: int) -> str:
    """The sender's own machine-readable record of this run (`--outcomes-json`), under the state dir."""
    return str(_state_dir() / f"proof-review-outcomes-{int(user_id)}-{os.getpid()}.json")


def _sent_users(path: str) -> tuple[str, ...]:
    """The users the sender's own run recorded as sent, never an inference from its exit code."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return ()
    return tuple(str(s.get("user")) for s in (data.get("sent") or ()) if isinstance(s, dict))


def _segment_for(campaign: str, user_id: int) -> tuple[str | None, str]:
    """The sender's own population filter is `bool(u["paid"]) is want_paid`, so the segment is the
    account's own paid flag - never a default that would offer nobody and still exit 0."""
    from credit_review import stage2_verdicts
    try:
        users = stage2_verdicts.population(stage2_verdicts.RELEASES[campaign])
    except Exception as exc:               # noqa: BLE001 - no population read, no segment: refuse, never guess
        return None, f"sender population unreadable ({type(exc).__name__})"
    for u in users:
        if str(u["user_id"]) == str(int(user_id)):
            return ("paid" if u.get("paid") else "free"), ""
    return None, f"account {int(user_id)} is not in the {campaign} population"


def _only_user(user_id: int) -> str:
    """A temp file naming the ONE user this run may message, so the sender scopes the population it
    reads at send time positively. Written 0600 under the state dir and removed by the CLI."""
    p = _state_dir() / f"proof-review-only-{int(user_id)}-{os.getpid()}.txt"
    p.write_text(f"{int(user_id)}\n", encoding="utf-8")
    os.chmod(p, 0o600)
    return str(p)


def _state_dir() -> Path:
    """The state dir this lane writes its temp files into. It never creates the tree above it: on a
    host that is not node-8 there is no /var/lib/hydra-credit-verify, and a review that cannot keep
    a temp file must fail loudly rather than make a directory it has no business making."""
    d = Path(STATE_DIR)
    if not d.parent.exists():
        raise ProofReviewError(f"state dir parent missing: {d.parent} (nothing is written outside it)")
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def _run_cli(argv: list[str]) -> tuple[int, str]:        # pragma: no cover - subprocess boundary
    import subprocess
    r = subprocess.run(argv, capture_output=True, text=True, timeout=1800)
    return r.returncode, (r.stdout or r.stderr or "").strip()


def _first_line(text: str) -> str:
    line = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    return " ".join(line.split())[:240].replace("&", "and").replace("<", "(").replace(">", ")")


# ── its own store (the ask row + one ledger row per card) ────────────────────
SCHEMA = """
CREATE TABLE IF NOT EXISTS asks (
  ask_id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL DEFAULT '',
  account_h TEXT NOT NULL DEFAULT '',
  user_ids TEXT NOT NULL DEFAULT '[]',
  first_seen TEXT NOT NULL,
  last_card TEXT
);
CREATE TABLE IF NOT EXISTS cards (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ask_id TEXT NOT NULL,
  account_h TEXT NOT NULL DEFAULT '',
  at TEXT NOT NULL,
  day TEXT NOT NULL,
  state TEXT NOT NULL,
  counts_json TEXT NOT NULL,
  sent TEXT NOT NULL DEFAULT 'none',
  gate_reason TEXT NOT NULL DEFAULT '',
  ledger TEXT NOT NULL DEFAULT 'none',
  campaign TEXT NOT NULL DEFAULT '',
  card TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS cards_account_day ON cards(account_h, day);
"""


class ReviewStore:
    """This lane's own store: the ask rows and every card, so a re-run is idempotent and the board
    can be read without the stores (never a decision store: no verdict here approves anything)."""

    def __init__(self, path: str | None = None):
        self.path = path or STORE
        d = os.path.dirname(self.path)
        if d:
            os.makedirs(d, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.path, timeout=60)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.commit()

    def seen(self, rev: Review) -> None:
        self.db.execute("INSERT INTO asks (ask_id, conversation_id, account_h, user_ids, first_seen, last_card) "
                        "VALUES (?,?,?,?,?,?) ON CONFLICT(ask_id) DO UPDATE SET last_card=excluded.last_card",
                        (rev.ask.ask_id, rev.ask.conversation_id, rev.ask.account, json.dumps(list(rev.ask.user_ids)),
                         rev.at, rev.at))
        self.db.commit()

    def cards_today(self, account_h: str, day: str | None = None) -> int:
        day = day or rev_day()
        return int(self.db.execute("SELECT count(*) FROM cards WHERE account_h=? AND day=?",
                                   (account_h, day)).fetchone()[0])

    def record(self, rev: Review, *, day: str | None = None) -> int:
        cur = self.db.execute(
            "INSERT INTO cards (ask_id, account_h, at, day, state, counts_json, sent, gate_reason, ledger, campaign, "
            "card) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (rev.ask.ask_id, rev.ask.account, rev.at, day or rev_day(), rev.state,
             json.dumps(rev.counts, sort_keys=True), rev.sent, rev.gate_reason, rev.ledger, rev.campaign, rev.card))
        rev.ledger = f"card:{cur.lastrowid}"
        _restamp(rev)
        self.db.execute("UPDATE cards SET card=?, ledger=? WHERE id=?", (rev.card, rev.ledger, cur.lastrowid))
        self.db.commit()
        return int(cur.lastrowid)

    def board(self, day: str | None = None) -> list[dict[str, Any]]:
        day = day or rev_day()
        return [dict(r) for r in self.db.execute(
            "SELECT at, ask_id, account_h, state, counts_json, sent, campaign, ledger FROM cards WHERE day=? "
            "ORDER BY id", (day,))]

    def close(self) -> None:
        self.db.close()


def rev_day() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


# ── run one ask end to end ───────────────────────────────────────────────────
def run(ask: Ask, *, store: ReviewStore | None = None, mode: str = "dry-run", segment: str | None = None,
        sender: Callable[[str, int, str], tuple[str, str]] | None = None,
        cap: int = CARDS_PER_ACCOUNT_DAY) -> Review:
    """Review one ask and (in apply mode) take its one coded next step.

    dry-run is the default and touches nothing: no send, no card row. apply sends through the single
    sender when the next step names a campaign, and records one card. Never more than `cap` cards per
    account per UTC day: a burst of re-sends must not page the lane repeatedly.
    """
    if mode not in ("dry-run", "apply"):
        raise ProofReviewError(f"mode must be dry-run or apply (got {mode!r})")
    rev = review(ask)
    rev.decision = ledger_row([r.request_id for r in ask.requests]) or "none"
    _restamp(rev)
    if mode == "dry-run":
        return rev
    if os.path.exists(KILL_SWITCH):
        rev.gate_reason = f"kill switch present ({KILL_SWITCH})"
        rev.campaign, rev.sent = "", "none"
        _restamp(rev)
        return rev
    own = store or ReviewStore()
    if own.cards_today(rev.ask.account) >= cap:
        rev.gate_reason = f"{cap} cards for this account today"
        rev.campaign, rev.sent = "", "none"
        _restamp(rev)
        own.seen(rev)
        return rev
    if rev.campaign and ask.user_ids:
        uid = int(ask.user_ids[0])
        try:
            ok, refuse = collision_owner(uid, ask.conversation_id)
        except ProofReviewError as exc:
            ok, refuse = False, f"the proof store cannot say which account owns the conversation: {exc}"
        seg, why = (segment, "") if segment else _segment_for(rev.campaign, uid)
        if not ok:
            rev.sent, rev.gate_reason = "none", refuse
        elif seg is None:
            rev.sent, rev.gate_reason = "none", why
        else:
            fn = sender or (lambda c, u, s: send_campaign(c, u, s))
            sent, why = fn(rev.campaign, uid, seg)
            rev.sent, rev.gate_reason = sent, why if sent == "none" else ""
    elif rev.campaign:
        # A campaign is due but no account is attached to the ask: never guess a recipient.
        rev.gate_reason = "no account on this ask: the sender needs one"
    own.record(rev)
    own.seen(rev)
    return rev


# ── CLI ──────────────────────────────────────────────────────────────────────
def file_conversation(conversation_id: str, *, runner: Runner | None = None) -> tuple[bool, str]:
    """File every attachment of one conversation into H3 (`credit-proof.py file --apply`), so a
    document the edge cache never kept is still on file when the review reads it (2026-11-02 16:42Z:
    attachment #28 was a 504 at the edge and reached H3 only through this path).

    Filing is not a judgement: no model runs, no credit changes, and the filer records the account
    and the candidate requests. doc-verify's read is NOT triggered here - that is a metered model
    call with a daily cap and its own cron (doc-verify-build-b1 owns it), so a brand-new document is
    UNKNOWN (nothing asked, nothing approved) until that cron reads it.
    """
    runner = runner or _run_cli
    d = _state_dir()
    listing = d / f"proof-review-conv-{os.getpid()}.txt"
    listing.write_text(str(conversation_id).strip() + "\n", encoding="utf-8")
    os.chmod(listing, 0o600)
    argv = [sys.executable, str(Path(__file__).resolve().parents[1] / "credit-proof.py"), "file",
            "--conversations", str(listing), "--apply"]
    try:
        rc, out = runner(argv)
    finally:
        try:
            os.unlink(listing)
        except OSError:
            pass
    return rc == 0, _first_line(out)


def cmd_review(args: argparse.Namespace) -> int:
    if args.file and args.conversation:
        ok, why = file_conversation(args.conversation)
        print(f"[proof-review] filing {args.conversation}: {'ok' if ok else 'FAILED'} {why}", file=sys.stderr)
    reqs = [x for x in (args.request_ids or "").split(",") if x.strip()]
    ask = build_ask(ask_id=args.ask_id or args.conversation or ",".join(reqs[:1]) or "unknown",
                    conversation_id=args.conversation or "", user_ids=[int(u) for u in (args.user_id or [])],
                    request_ids=reqs, asked_at=args.asked_at or "", account_h=args.account or "",
                    route=args.route, lens=None if args.no_lens else _real_lens())
    if args.no_lens:
        # Offline / fixture review: no HOLD is inferred from a lens nobody measured, and the card
        # says nothing about it (a guessed hold is as wrong as a guessed all-clear).
        ask = dataclasses.replace(ask, fraud_held=(), fraud_watch=())
    if args.conversation and ask.user_ids:
        ok, why = collision_owner(ask.user_ids[0], args.conversation)
        if not ok:
            print(json.dumps({"ask_id": ask.ask_id, "refused": why}) if args.json else f"REFUSED: {why}")
            return 3
    rev = run(ask, mode=args.mode, segment=args.segment)
    if args.json:
        print(json.dumps({"ask_id": rev.ask.ask_id, "account": rev.ask.account, "state": rev.state,
                          "route": rev.ask.route,
                          "counts": rev.counts, "campaign": rev.campaign, "sent": rev.sent,
                          "gate_reason": rev.gate_reason,
                          "ledger": rev.decision if rev.decision != "none" else rev.ledger,
                          "sla_minutes": rev.sla_minutes,
                          "verdicts": [{"request_id": v.request_id, "verdict": v.verdict, "why": v.why}
                                       for v in rev.verdicts],
                          "documents": [{"sha8": d.sha8, "kind": d.doc_kind, "reuse": d.reuse_flag,
                                         "injection": d.injection} for d in rev.ask.documents],
                          "card": rev.card}, indent=1, ensure_ascii=False))
    else:
        print(rev.card)
    if rev.sla_minutes is not None and rev.sla_minutes > LATE_MINUTES:
        print(f"[proof-review] SLA: {rev.sla_minutes} min past the ask (> {LATE_MINUTES}): escalate to the intake "
              "lane (j-w1)", file=sys.stderr)
    return 0


def cmd_board(args: argparse.Namespace) -> int:
    store = ReviewStore(args.store)
    try:
        rows = store.board(args.day)
    finally:
        store.close()
    if args.json:
        print(json.dumps(rows, indent=1))
        return 0
    for r in rows:
        print(f"{r['at']} {r['ask_id']} acct {str(r['account_h'])[:8]} {r['state']} sent={r['sent']} "
              f"{r['counts_json']} ledger={r['ledger']}")
    return 0


def _real_lens() -> LensFn:
    """The fraud lens, built on first use: `default_lens` eagerly loads the watchlist and the holds
    and raises on a missing or malformed file, and `load_fraud_lens` is the one place that turns a
    lens that cannot answer into a HOLD. Constructing it here would raise past that guard."""
    def lens(ids: list[int]) -> dict[int, Any]:
        from credit_review import fraud_lens, verify_notify
        return fraud_lens.default_lens(verify_notify.trino)(ids)
    return lens


def real_lens() -> LensFn:
    """The production fraud lens, fail-closed: a lens that cannot be built holds every account."""
    return _real_lens()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="coded proof review for a 'review the proof' ask (read-only unless "
                                            "--mode apply)")
    sub = p.add_subparsers(dest="op", required=True)
    rv = sub.add_parser("review", help="review one ask and render its card")
    rv.add_argument("--conversation", help="the Intercom conversation the proof arrived in")
    rv.add_argument("--request-ids", help="comma separated credit request ids")
    rv.add_argument("--user-id", action="append", help="the Muso account (repeatable)")
    rv.add_argument("--ask-id", help="the ask's own id (default: the conversation / first request)")
    rv.add_argument("--account", help="the account hash the card carries (default: H3's contact hash)")
    rv.add_argument("--asked-at", help="when the ask arrived (YYYY-MM-DDTHH:MM:SSZ) for the SLA")
    rv.add_argument("--segment", choices=["paid", "free"], default=None,
                    help="override the segment; by default it is the account's own paid flag")
    rv.add_argument("--route", choices=["off", "log", "on"], help="override the approval route (default: policy)")
    rv.add_argument("--file", action="store_true",
                    help="first file this conversation's attachments into H3 (credit-proof.py file --apply): "
                         "no model call, no judgement. doc-verify's read stays with its own cron")
    rv.add_argument("--no-lens", action="store_true",
                    help="do not measure the fraud lens (offline review): no HOLD is inferred from it. The "
                         "default measures it, and a lens that fails to answer holds every account on the ask")
    rv.add_argument("--mode", choices=["dry-run", "apply"], default="dry-run")
    rv.add_argument("--json", action="store_true")
    rv.set_defaults(fn=cmd_review)
    bd = sub.add_parser("board", help="today's cards")
    bd.add_argument("--day", help="YYYY-MM-DD (default: today, UTC)")
    bd.add_argument("--store", default=None)
    bd.add_argument("--json", action="store_true")
    bd.set_defaults(fn=cmd_board)
    a = p.parse_args(argv)
    try:
        return int(a.fn(a))
    except ProofReviewError as exc:
        print(f"proof-review: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
