"""The claim document ladder: a returned claim document becomes ONE recorded decision per claim.

The claim twin of `credit_review/doc_approve.py`, in the same shape:

    extraction (fixed schema)  ->  predicates, in rank order  ->  a decision with a reason code

Before this, the claim side had no reader at all for a document. `claim_verify/decline_rules.py`
declines a claim on a coded contradiction and `claim-proof-check` reads a code on a bound page;
paperwork a claimant sent back landed in `proof_intake` and no rule ever looked at it.

WHO DECIDES. A model's part ends at the extraction: what the document says, in a fixed schema. It
never returns approve or refuse and nothing here asks it to. Every outcome below comes from a coded
predicate over that extraction and the claim's own facts, so a decision can be re-run from what is
stored (`reproduce`) and must come out the same.

THE PREDICATES, in rank order. The first one that fails is the reason:

  0. readable        there is an extraction and it says something. Not extracted, failed, degraded
                     or parsed-but-empty is `unreadable` - never `approved`.
  1. names claimant  a party the document names is the claimant, under the name rule every
                     credit reader already uses (`credit_review.roles.names_match`).
  2. names profile   the document names the profile: by page id under the ONE page-id rule
                     (`lib.page_identity`: equality or a truncated prefix of 8+ characters), or by
                     the profile's catalog name under the same name rule.
  3. document type   the type is one this claim class accepts (`policies/claim-doc-ladder.json`).
  4. contradiction   nothing coded contradicts the claim: the claim side's own contradiction rule
                     (`decline_rules`, re-run on its snapshot), another account already holding
                     the profile, another claim's code found on the profile's bound page, and the
                     releases the document names being none of the profile's.
  5. clean           the document is not forged, not contradicted, not filed by a second account;
                     the profile is not a big one; the account is not held.

Anything that does not pass is `needs_human_review` WITH the reason: an outcome a person can work
from, not a silent hold. `refused` is narrow on purpose: only a contradiction a document cannot
cure (policy `refuse_on_contradiction`). Unmeasured is never a pass: a fact that could not be read
is its own reason.

NO DOCUMENT, NO DECISION. `decide_claim` returns None for a claim with nothing on file. Absence
approves nothing and refuses nothing.

THIS MODULE WRITES ITS OWN STORE AND NOTHING ELSE. It calls no admin API, changes no claim's
status and sends no message. Acting on a recorded decision is a separate, captain-gated step
(docs/credit-verification/claim-doc-ladder.md). Revert, per field:
  claim_doc_decisions row   `release` marks it released (who, why); the claim may be decided again.
                            A pass retires the row of a claim it no longer decides (closed, or no
                            document on file); the row stands again when the claim is back
  claim_doc_extractions row never changed: it is the record of what was read, keyed by its hashes
  claim_doc_events row      never changed: append-only
  core `claiming.status`    not written by this module
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

_SCRIPTS = Path(__file__).resolve().parents[1]
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

from claim_verify import decline_rules  # noqa: E402
from credit_review import roles  # noqa: E402
from lib import page_identity  # noqa: E402

VERSION = "cdl-1"
DEFAULT_POLICY = _SCRIPTS.parent / "policies" / "claim-doc-ladder.json"
DEFAULT_STORE = "/var/lib/hydra/claim-doc-ladder/decisions.sqlite"
KILL_FILE = "/etc/hydra/claim-doc-ladder.disabled"

APPROVED, REFUSED, REVIEW, UNREADABLE = "approved", "refused", "needs_human_review", "unreadable"
OUTCOMES = (APPROVED, REFUSED, REVIEW, UNREADABLE)
TERMINAL = (APPROVED, REFUSED)
RETIRED = "retired"                        # a row's state, not an outcome: the claim left the population
RETIRED_BY = "claim-doc-ladder"
RETIRED_REASON = "claim_not_open_or_no_document"

# Every reason the ladder can give, and the ONE outcome it carries. `contradiction` is the only
# reason with two possible outcomes; which class refuses is the policy's `refuse_on_contradiction`.
REASONS: dict[str, str] = {
    "document_names_claimant_and_profile": APPROVED,
    # unreadable: nothing could be read, so nothing is decided about the claim
    "no_bytes_on_file": UNREADABLE,
    "not_extracted": UNREADABLE,
    "extraction_failed": UNREADABLE,
    "degraded_extraction": UNREADABLE,
    "empty_extraction": UNREADABLE,
    # a person decides, and this is why
    "claimant_name_unknown": REVIEW,
    "claimant_not_named": REVIEW,
    "catalog_unreadable": REVIEW,
    "profile_not_in_catalog": REVIEW,
    "profile_not_named": REVIEW,
    "claim_class_unknown": REVIEW,
    "doc_type_not_accepted": REVIEW,
    "contradiction": REVIEW,
    "profile_already_claimed": REVIEW,
    "bound_code_unmeasured": REVIEW,
    "bound_code_other_claim": REVIEW,
    "releases_unmeasured": REVIEW,
    "releases_not_on_profile": REVIEW,
    "no_release_named": REVIEW,
    "document_forged": REVIEW,
    "document_contradicted": REVIEW,
    "document_reused": REVIEW,
    "big_profile": REVIEW,
    "account_hold_unmeasured": REVIEW,
    "account_hold": REVIEW,
}
# A document carrying one of these stops every other document of the claim from approving it.
POISON = ("document_forged", "document_contradicted", "document_reused")
# dv-4's blocking verdicts (credit_review/doc_approve.BLOCKING_VERDICTS) and the reason each gives here.
BLOCKING = {"forged": "document_forged", "contradicted": "document_contradicted"}
HELD_PROFILE_STATUS = "processed"          # core `claiming.status` of a claim that was granted
PROFILE_URL = re.compile(r"muso\.ai/profile/([0-9a-f]{8}(?:-[0-9a-f]{1,12}){0,4})", re.I)


class PolicyError(RuntimeError):
    pass


def load_policy(path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """The reviewed policy file. Malformed is an error, never a default: a ladder that cannot read
    which types it accepts must not run on a guess."""
    p = Path(path or DEFAULT_POLICY)
    try:
        pol = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PolicyError(f"{p}: {type(exc).__name__}: {exc}") from exc
    return check_policy(pol)


def check_policy(pol: Any) -> dict[str, Any]:
    if not isinstance(pol, dict) or pol.get("version") != VERSION:
        raise PolicyError(f"policy version must be {VERSION!r}")
    conf = pol.get("min_confidence")
    if isinstance(conf, bool) or not isinstance(conf, (int, float)) or not 0 < conf <= 1:
        raise PolicyError("min_confidence must be a number in (0, 1]")
    types = pol.get("accepted_doc_types")
    if not isinstance(types, dict) or not types or not all(
            isinstance(v, list) and v and all(isinstance(t, str) and t for t in v) for v in types.values()):
        raise PolicyError("accepted_doc_types must map each claim class to a non-empty list of types")
    if not isinstance(pol.get("require_release_on_profile"), bool):
        raise PolicyError("require_release_on_profile must be true or false")
    refuse = pol.get("refuse_on_contradiction")
    if not isinstance(refuse, list) or not all(isinstance(c, str) and c for c in refuse):
        raise PolicyError("refuse_on_contradiction must be a list of contradiction classes")
    return pol


def canonical(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_of(obj: Any) -> str:
    return hashlib.sha256(canonical(obj).encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------------------------
# Extraction: the fixed schema the predicates read
# --------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Named:
    name: str
    where: str          # credit | signatory | issuer
    confidence: float


@dataclass(frozen=True)
class Extraction:
    """What one document says, in the only shape the predicates read. `source_sha256` is the
    document's bytes; `extraction_sha256` is the stored extraction it was normalised from. Together
    they name exactly what a decision stood on."""
    source_sha256: str
    extraction_sha256: str
    extractor: str
    ok: bool
    degraded: bool
    doc_type: str
    named: tuple[Named, ...]
    profile_refs: tuple[str, ...]
    tracks: int
    error: str

    @property
    def empty(self) -> bool:
        """Parsed, and it says nothing a predicate could read."""
        return not self.named and not self.profile_refs and not self.tracks


def _confidence(v: Any) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0.0
    f = float(v)
    return f if math.isfinite(f) and 0.0 <= f <= 1.0 else 0.0


def _text(v: Any) -> str:
    return v.strip() if isinstance(v, str) else ""


def _strings(v: Any) -> Iterable[str]:
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from _strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from _strings(x)


def normalise(raw: Any, source_sha256: str, extractor: str = "dv-4") -> Extraction:
    """A stored doc-verify extraction (`dv_steps` step `extract`) -> the fixed schema. Every field
    is re-typed here; nothing the model wrote is trusted for its shape."""
    digest = sha256_of(raw)
    if not isinstance(raw, dict):
        return Extraction(source_sha256, digest, extractor, False, True, "", (), (), 0, "extraction is not an object")
    named: list[Named] = []
    for c in raw.get("credits") if isinstance(raw.get("credits"), list) else []:
        if isinstance(c, dict) and _text(c.get("person")):
            named.append(Named(_text(c["person"]), "credit", _confidence(c.get("confidence"))))
    for where in ("signatory", "issuer"):
        part = raw.get(where)
        if isinstance(part, dict) and _text(part.get("name")):
            named.append(Named(_text(part["name"]), where, _confidence(part.get("confidence"))))
    refs = sorted({page_identity.norm(m) for s in _strings(raw) for m in PROFILE_URL.findall(s)})
    tracks = raw.get("tracks")
    n_tracks = sum(1 for t in tracks if isinstance(t, dict) and (_text(t.get("title")) or _text(t.get("isrc")))) \
        if isinstance(tracks, list) else 0
    return Extraction(source_sha256, digest, extractor, raw.get("ok") is True, raw.get("degraded") is True,
                      _text(raw.get("doc_type")), tuple(named), tuple(refs), n_tracks, _text(raw.get("error"))[:200])


# --------------------------------------------------------------------------------------------
# Facts: the claim and the documents on file for its claimant
# --------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class ClaimFacts:
    claim_id: int
    user_id: int
    profile_id: str
    profile_type: str
    status: str
    claimant_names: tuple[str, ...]
    account_hold: bool | None                     # None = the hold ledger could not be read
    code_found_other_claims: tuple[int, ...] | None   # None = the claim list could not be read
    decline_snapshot: dict[str, Any] | None       # decline_rules.snapshot(); None = catalog unreadable
    paid: bool | None = None
    profile_in_catalog: bool | None = None        # False = the catalog was read and has no such profile
    # document sha256 -> {"named": releases the document names, "on_profile": how many are the profile's};
    # None = the profile's catalog releases could not be read
    releases: dict[str, dict[str, int]] | None = None

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> "ClaimFacts":
        others = d.get("code_found_other_claims")
        snap = d.get("decline_snapshot")
        hold = d.get("account_hold")
        return cls(
            claim_id=int(d["claim_id"]), user_id=int(d["user_id"]),
            profile_id=page_identity.norm(d.get("profile_id")), profile_type=_text(d.get("profile_type")).lower(),
            status=_text(d.get("status")),
            claimant_names=tuple(n for n in (_text(x) for x in (d.get("claimant_names") or [])) if n),
            account_hold=hold if isinstance(hold, bool) else None,
            code_found_other_claims=tuple(int(x) for x in others) if isinstance(others, list) else None,
            decline_snapshot=snap if isinstance(snap, dict) else None,
            paid=d.get("paid") if isinstance(d.get("paid"), bool) else None,
            profile_in_catalog=d.get("profile_in_catalog") if isinstance(d.get("profile_in_catalog"), bool) else None,
            releases={str(k): {"named": int(v.get("named") or 0), "on_profile": int(v.get("on_profile") or 0)}
                      for k, v in d["releases"].items() if isinstance(v, dict)}
            if isinstance(d.get("releases"), dict) else None)

    @property
    def profile(self) -> Mapping[str, Any]:
        p = (self.decline_snapshot or {}).get("profile")
        return p if isinstance(p, dict) else {}

    @property
    def profile_name(self) -> str:
        return _text(self.profile.get("name"))


@dataclass(frozen=True)
class DocFacts:
    intake_id: str
    source_sha256: str
    received_at: str
    extract_status: str                    # "ok" | "error" | "" (doc-verify never read this document)
    extraction: Any                        # the stored extraction, verbatim; None when there is none
    extractor: str = "dv-4"
    blocking_verdicts: tuple[str, ...] = ()
    other_filers: int = 0
    has_bytes: bool = False
    subject: str = ""

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> "DocFacts":
        return cls(
            intake_id=_text(d.get("intake_id")), source_sha256=_text(d.get("source_sha256")).lower(),
            received_at=_text(d.get("received_at")), extract_status=_text(d.get("extract_status")),
            extraction=d.get("extraction"), extractor=_text(d.get("extractor")) or "dv-4",
            blocking_verdicts=tuple(sorted({_text(v) for v in (d.get("blocking_verdicts") or []) if _text(v)})),
            other_filers=int(d.get("other_filers") or 0), has_bytes=d.get("has_bytes") is True,
            subject=_text(d.get("subject")))

    def stored(self, extraction_sha256: str) -> dict[str, Any]:
        """This document as a decision records it: every fact but the extraction body, which lives
        once in claim_doc_extractions under its two hashes."""
        return {"intake_id": self.intake_id, "source_sha256": self.source_sha256, "received_at": self.received_at,
                "extract_status": self.extract_status, "extractor": self.extractor,
                "extraction_sha256": extraction_sha256, "has_extraction": self.extraction is not None,
                "blocking_verdicts": list(self.blocking_verdicts), "other_filers": self.other_filers,
                "has_bytes": self.has_bytes, "subject": self.subject}


# --------------------------------------------------------------------------------------------
# Predicates
# --------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Gate:
    name: str
    ok: bool
    reason: str = ""
    detail: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {"gate": self.name, "ok": self.ok, "reason": self.reason, "detail": self.detail}


def _pass(name: str, **detail: Any) -> Gate:
    return Gate(name, True, "", detail)


def _fail(name: str, reason: str, **detail: Any) -> Gate:
    if reason not in REASONS:
        raise ValueError(f"unregistered reason code {reason!r}")
    return Gate(name, False, reason, detail)


def _sure(ex: Extraction, policy: Mapping[str, Any]) -> list[Named]:
    return [n for n in ex.named if n.confidence >= float(policy["min_confidence"])]


def gate_readable(claim: ClaimFacts, doc: DocFacts, ex: Extraction | None, policy: Mapping[str, Any]) -> Gate:
    name = "readable"
    if ex is None:
        # two different gaps: bytes that were never stored cannot be read by anyone; bytes that
        # are on file and were never read are doc-verify's to read
        return _fail(name, "not_extracted" if doc.has_bytes else "no_bytes_on_file")
    if doc.extract_status != "ok" or not ex.ok:
        return _fail(name, "extraction_failed", status=doc.extract_status, error=ex.error)
    if ex.degraded:
        return _fail(name, "degraded_extraction", error=ex.error)
    if ex.empty:
        return _fail(name, "empty_extraction")
    return _pass(name, doc_type=ex.doc_type, named=len(ex.named), tracks=ex.tracks)


def gate_names_claimant(claim: ClaimFacts, doc: DocFacts, ex: Extraction, policy: Mapping[str, Any]) -> Gate:
    name = "names_claimant"
    if not any(roles.name_key(n) for n in claim.claimant_names):
        return _fail(name, "claimant_name_unknown")
    for party in _sure(ex, policy):
        if any(roles.names_match(party.name, n) for n in claim.claimant_names):
            return _pass(name, where=party.where, confidence=party.confidence, by="name")
    return _fail(name, "claimant_not_named", named=len(ex.named), sure=len(_sure(ex, policy)))


def gate_names_profile(claim: ClaimFacts, doc: DocFacts, ex: Extraction, policy: Mapping[str, Any]) -> Gate:
    name = "names_profile"
    if claim.profile_id and page_identity.matched(claim.profile_id, ex.profile_refs):
        return _pass(name, where="profile_ref", by="page_id")
    if not claim.profile_name:
        if claim.profile_in_catalog is False:
            return _fail(name, "profile_not_in_catalog")
        return _fail(name, "catalog_unreadable", what="profile name")
    for party in _sure(ex, policy):
        if roles.names_match(party.name, claim.profile_name):
            return _pass(name, where=party.where, confidence=party.confidence, by="name",
                         same_as_claimant=any(roles.names_match(claim.profile_name, n) for n in claim.claimant_names))
    return _fail(name, "profile_not_named", named=len(ex.named), sure=len(_sure(ex, policy)))


def gate_doc_type(claim: ClaimFacts, doc: DocFacts, ex: Extraction, policy: Mapping[str, Any]) -> Gate:
    name = "doc_type"
    accepted = policy["accepted_doc_types"].get(claim.profile_type)
    if not accepted:
        return _fail(name, "claim_class_unknown", claim_class=claim.profile_type)
    if ex.doc_type not in accepted:
        return _fail(name, "doc_type_not_accepted", doc_type=ex.doc_type, claim_class=claim.profile_type)
    return _pass(name, doc_type=ex.doc_type, claim_class=claim.profile_type)


def gate_no_contradiction(claim: ClaimFacts, doc: DocFacts, ex: Extraction, policy: Mapping[str, Any]) -> Gate:
    """Catalog and bound code. The catalog half is the claim side's OWN contradiction rule, re-run
    on its snapshot - not a second reading of the same facts."""
    name = "no_contradiction"
    if claim.decline_snapshot is None:
        return _fail(name, "catalog_unreadable", what="decline snapshot")
    found = decline_rules.reproduce(claim.decline_snapshot)
    if found.contradiction:
        return _fail(name, "contradiction", contradiction=found.contradiction, rule_id=found.rule_id)
    others = (claim.decline_snapshot.get("claim") or {}).get("pk_profile_other_claims") or []
    holders = sorted({str(o.get("userId")) for o in others
                      if isinstance(o, dict) and o.get("status") == HELD_PROFILE_STATUS})
    if holders:
        return _fail(name, "profile_already_claimed", other_accounts=len(holders))
    if claim.code_found_other_claims is None:
        return _fail(name, "bound_code_unmeasured")
    if claim.code_found_other_claims:
        return _fail(name, "bound_code_other_claim", other_claims=list(claim.code_found_other_claims))
    rel = (claim.releases or {}).get(doc.source_sha256)
    if rel is None:
        return _fail(name, "releases_unmeasured")
    if rel["named"] > 0 and rel["on_profile"] == 0:
        return _fail(name, "releases_not_on_profile", named=rel["named"])
    if rel["on_profile"] == 0 and policy["require_release_on_profile"]:
        return _fail(name, "no_release_named")
    return _pass(name, rule_id=found.rule_id, releases_named=rel["named"], releases_on_profile=rel["on_profile"])


def poison_of(doc: DocFacts) -> str:
    """The reason this document must not approve anything, '' when it is clean. Read on its own,
    off the rank order, so a bad document poisons the claim wherever it would have stopped."""
    for verdict in ("forged", "contradicted"):
        if verdict in doc.blocking_verdicts:
            return BLOCKING[verdict]
    return "document_reused" if doc.other_filers > 0 else ""


def gate_clean(claim: ClaimFacts, doc: DocFacts, ex: Extraction, policy: Mapping[str, Any]) -> Gate:
    name = "clean"
    bad = poison_of(doc)
    if bad:
        return _fail(name, bad, blocking_verdicts=list(doc.blocking_verdicts), other_filers=doc.other_filers)
    pop, credits = claim.profile.get("popularity"), claim.profile.get("creditCount")
    if not isinstance(pop, int) or not isinstance(credits, int):
        return _fail(name, "catalog_unreadable", what="profile size")
    if pop >= decline_rules.BIG_POPULARITY or credits >= decline_rules.BIG_CREDITS:
        return _fail(name, "big_profile", popularity=pop, credits=credits)
    if claim.account_hold is None:
        return _fail(name, "account_hold_unmeasured")
    if claim.account_hold:
        return _fail(name, "account_hold")
    return _pass(name, popularity=pop, credits=credits)


LADDER = (gate_readable, gate_names_claimant, gate_names_profile, gate_doc_type, gate_no_contradiction, gate_clean)


def outcome_of(gate: Gate, policy: Mapping[str, Any]) -> str:
    if gate.reason == "contradiction" and gate.detail.get("contradiction") in policy["refuse_on_contradiction"]:
        return REFUSED
    return REASONS[gate.reason]


def reason_code(gate: Gate) -> str:
    """The reason as recorded: a contradiction carries its class, so a refusal is never bare."""
    if gate.reason == "contradiction":
        return f"contradiction:{gate.detail.get('contradiction')}"
    return gate.reason


@dataclass(frozen=True)
class DocVerdict:
    outcome: str
    reason: str
    doc: DocFacts
    extraction_sha256: str
    gates: tuple[Gate, ...]

    @property
    def depth(self) -> int:
        """How far up the ladder this document got: the number of predicates it passed."""
        return sum(1 for g in self.gates if g.ok)


def evaluate_document(claim: ClaimFacts, doc: DocFacts, policy: Mapping[str, Any]) -> DocVerdict:
    ex = normalise(doc.extraction, doc.source_sha256, doc.extractor) if doc.extraction is not None else None
    digest = ex.extraction_sha256 if ex is not None else ""
    gates: list[Gate] = []
    for gate in LADDER:
        g = gate(claim, doc, ex, policy)  # type: ignore[arg-type]
        gates.append(g)
        if not g.ok:
            return DocVerdict(outcome_of(g, policy), reason_code(g), doc, digest, tuple(gates))
    return DocVerdict(APPROVED, "document_names_claimant_and_profile", doc, digest, tuple(gates))


@dataclass(frozen=True)
class Decision:
    claim_id: int
    user_id: int
    profile_id: str
    outcome: str
    reason: str
    intake_id: str
    source_sha256: str
    extraction_sha256: str
    gates: tuple[Gate, ...]
    documents: tuple[dict[str, Any], ...]      # every document read: its own outcome and reason
    policy_sha256: str
    paid: bool | None = None

    @property
    def key(self) -> str:
        """What this decision IS. The outcome and the evidence are in it, so a decision that
        changes gets a new key and is never mistaken for the one already recorded."""
        return hashlib.sha256("|".join((
            str(self.claim_id), VERSION, self.policy_sha256, self.outcome, self.reason,
            self.source_sha256, self.extraction_sha256)).encode()).hexdigest()

    def as_dict(self) -> dict[str, Any]:
        return {"claim_id": self.claim_id, "user_id": self.user_id, "profile_id": self.profile_id,
                "outcome": self.outcome, "reason": self.reason, "intake_id": self.intake_id,
                "source_sha256": self.source_sha256, "extraction_sha256": self.extraction_sha256,
                "gates": [g.as_dict() for g in self.gates], "documents": list(self.documents),
                "ladder_version": VERSION, "policy_sha256": self.policy_sha256, "decision_key": self.key,
                "paid": self.paid}


_RANK = {APPROVED: 0, REFUSED: 1, REVIEW: 2, UNREADABLE: 3}


def decide_claim(claim: ClaimFacts, docs: Iterable[DocFacts], policy: Mapping[str, Any]) -> Decision | None:
    """ONE decision for a claim over every document on file for its claimant; None when there is no
    document (no document, no decision) or the claim is no longer open (nothing left to decide)."""
    docs = sorted(docs, key=lambda d: (d.received_at, d.source_sha256, d.intake_id))
    if not docs or claim.status not in decline_rules.OPEN_STATUSES:
        return None
    verdicts = [evaluate_document(claim, d, policy) for d in docs]
    # best outcome first; among equals the document that got furthest, then the oldest
    best = min(verdicts, key=lambda v: (_RANK[v.outcome], -v.depth, v.doc.received_at, v.doc.source_sha256))
    outcome, reason, gates = best.outcome, best.reason, best.gates
    if outcome == APPROVED:
        bad = next((v for v in verdicts if poison_of(v.doc)), None)
        if bad is not None:
            why = poison_of(bad.doc)
            outcome, reason = REASONS[why], why
            gates = gates + (_fail("clean_across_documents", why, intake_id=bad.doc.intake_id,
                                   source_sha256=bad.doc.source_sha256),)
    summary = tuple({"intake_id": v.doc.intake_id, "source_sha256": v.doc.source_sha256,
                     "extraction_sha256": v.extraction_sha256, "outcome": v.outcome, "reason": v.reason}
                    for v in verdicts)
    return Decision(claim.claim_id, claim.user_id, claim.profile_id, outcome, reason, best.doc.intake_id,
                    best.doc.source_sha256, best.extraction_sha256, gates, summary, sha256_of(policy), claim.paid)


# --------------------------------------------------------------------------------------------
# Plan: a snapshot in, decisions out. Pure - no store, no clock, no network.
# --------------------------------------------------------------------------------------------

def plan(snapshot: Mapping[str, Any], policy: Mapping[str, Any]) -> tuple[list[tuple[Decision, dict[str, Any]]],
                                                                          dict[str, int]]:
    """Every decision the snapshot supports, each with the inputs it stood on, plus what was
    skipped and why. Sorted by claim id, so two runs over one snapshot are byte-identical."""
    documents = snapshot.get("documents") or {}
    out: list[tuple[Decision, dict[str, Any]]] = []
    skipped = {"no_document": 0, "not_open": 0}
    for raw in sorted(snapshot.get("claims") or [], key=lambda c: int(c["claim_id"])):
        claim = ClaimFacts.from_dict(raw)
        docs = [DocFacts.from_dict(d) for d in documents.get(str(claim.user_id)) or []]
        decision = decide_claim(claim, docs, policy)
        if decision is None:
            skipped["no_document" if not docs else "not_open"] += 1
            continue
        out.append((decision, inputs_of(raw, docs, policy)))
    return out, skipped


def inputs_of(claim_raw: Mapping[str, Any], docs: Iterable[DocFacts], policy: Mapping[str, Any]) -> dict[str, Any]:
    """Exactly what `decide_claim` read, minus the extraction bodies (stored once, by hash)."""
    return {"claim": dict(claim_raw), "policy": dict(policy),
            "documents": [d.stored(sha256_of(d.extraction) if d.extraction is not None else "") for d in docs]}


def split(decisions: Iterable[Decision]) -> dict[str, Any]:
    """The report: how many of each outcome, and under each its reason codes."""
    by: dict[str, dict[str, int]] = {o: {} for o in OUTCOMES}
    n = 0
    for d in decisions:
        n += 1
        by[d.outcome][d.reason] = by[d.outcome].get(d.reason, 0) + 1
    return {"claims_decided": n,
            "auto_decided": sum(by[APPROVED].values()) + sum(by[REFUSED].values()),
            "needs_human_review": sum(by[REVIEW].values()), "unreadable": sum(by[UNREADABLE].values()),
            "by_outcome": {o: {"n": sum(r.values()), "reasons": dict(sorted(r.items(), key=lambda kv: (-kv[1], kv[0])))}
                           for o, r in by.items()}}


# --------------------------------------------------------------------------------------------
# Store
# --------------------------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS claim_doc_extractions (
  source_sha256 TEXT NOT NULL,            -- the document's bytes
  extraction_sha256 TEXT NOT NULL,        -- sha256 of the canonical extraction JSON below
  extractor TEXT NOT NULL,
  extraction_json TEXT NOT NULL,          -- verbatim: what the predicates were given
  recorded_at TEXT NOT NULL,
  PRIMARY KEY (source_sha256, extraction_sha256)
);
CREATE TRIGGER IF NOT EXISTS claim_doc_extractions_no_update BEFORE UPDATE ON claim_doc_extractions
BEGIN SELECT RAISE(ABORT, 'claim_doc_extractions is append-only'); END;
CREATE TRIGGER IF NOT EXISTS claim_doc_extractions_no_delete BEFORE DELETE ON claim_doc_extractions
BEGIN SELECT RAISE(ABORT, 'claim_doc_extractions is append-only'); END;
CREATE TABLE IF NOT EXISTS claim_doc_decisions (
  claim_id INTEGER PRIMARY KEY,           -- ONE decision per claim
  user_id INTEGER NOT NULL,
  profile_id TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('approved', 'refused', 'needs_human_review', 'unreadable')),
  reason TEXT NOT NULL CHECK (reason != ''),             -- never a bare outcome
  intake_id TEXT NOT NULL,
  source_sha256 TEXT NOT NULL CHECK (source_sha256 != ''),   -- no document, no decision
  extraction_sha256 TEXT NOT NULL,
  decision_key TEXT NOT NULL,
  ladder_version TEXT NOT NULL,
  gates_json TEXT NOT NULL,
  inputs_json TEXT NOT NULL,              -- what decide_claim read; extraction bodies by hash
  decided_at TEXT NOT NULL,
  -- shadow = stands; released = a person withdrew it; retired = the claim left the population
  state TEXT NOT NULL DEFAULT 'shadow' CHECK (state IN ('shadow', 'released', 'retired')),
  state_at TEXT NOT NULL,
  state_by TEXT NOT NULL DEFAULT '',
  state_reason TEXT NOT NULL DEFAULT '',
  -- an approval or a refusal stands on an extraction that was actually read
  CHECK (outcome NOT IN ('approved', 'refused') OR extraction_sha256 != '')
);
CREATE TABLE IF NOT EXISTS claim_doc_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  claim_id INTEGER NOT NULL,
  event TEXT NOT NULL,           -- decided | superseded | drift | released | redecided | retired | reopened
  decision_key TEXT NOT NULL,
  outcome TEXT NOT NULL,
  reason TEXT NOT NULL,
  detail_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS claim_doc_events_claim ON claim_doc_events(claim_id);
CREATE TRIGGER IF NOT EXISTS claim_doc_events_no_update BEFORE UPDATE ON claim_doc_events
BEGIN SELECT RAISE(ABORT, 'claim_doc_events is append-only'); END;
CREATE TRIGGER IF NOT EXISTS claim_doc_events_no_delete BEFORE DELETE ON claim_doc_events
BEGIN SELECT RAISE(ABORT, 'claim_doc_events is append-only'); END;
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def open_store(path: str) -> sqlite3.Connection:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    made = db.execute("SELECT sql FROM sqlite_master WHERE name = 'claim_doc_decisions'").fetchone()
    if "'retired'" not in (made[0] or ""):
        # CREATE TABLE IF NOT EXISTS leaves an older table as it is: say so before a pass half-runs
        raise RuntimeError(f"{path}: claim_doc_decisions predates the 'retired' state; this store cannot be reconciled")
    return db


def open_store_ro(path: str) -> sqlite3.Connection:
    """WAL-aware read-only (never `immutable=1`: that ignores the -wal and reads stale rows)."""
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def _event(db: sqlite3.Connection, at: str, d: Decision, event: str, **detail: Any) -> None:
    db.execute("INSERT INTO claim_doc_events (at, claim_id, event, decision_key, outcome, reason, detail_json) "
               "VALUES (?,?,?,?,?,?,?)", (at, d.claim_id, event, d.key, d.outcome, d.reason, canonical(detail)))


def record_extractions(db: sqlite3.Connection, docs: Iterable[DocFacts], at: str) -> None:
    for d in docs:
        if d.extraction is None:
            continue
        db.execute("INSERT OR IGNORE INTO claim_doc_extractions "
                   "(source_sha256, extraction_sha256, extractor, extraction_json, recorded_at) VALUES (?,?,?,?,?)",
                   (d.source_sha256, sha256_of(d.extraction), d.extractor, canonical(d.extraction), at))


def record(db: sqlite3.Connection, decision: Decision, inputs: Mapping[str, Any], docs: Iterable[DocFacts],
           *, at: str | None = None) -> str:
    """Write one decision. Returns what happened:

      decided     first decision for the claim
      unchanged   the same decision is already on file (a re-run changes nothing)
      superseded  a review / unreadable row replaced by a different decision (a new document, say)
      drift       an approved / refused row is NOT replaced; the differing re-read is logged once
      redecided   a released row replaced by a different decision
      released    a released row whose decision has not changed: it stays released
      reopened    a retired row whose claim is back in the population: it stands again
    """
    at = at or utcnow()
    with db:
        record_extractions(db, docs, at)
        row = db.execute("SELECT * FROM claim_doc_decisions WHERE claim_id = ?", (decision.claim_id,)).fetchone()
        values = (decision.user_id, decision.profile_id, decision.outcome, decision.reason, decision.intake_id,
                  decision.source_sha256, decision.extraction_sha256, decision.key, VERSION,
                  canonical([g.as_dict() for g in decision.gates]), canonical(inputs), at, at)
        if row is None:
            db.execute("INSERT INTO claim_doc_decisions (claim_id, user_id, profile_id, outcome, reason, intake_id, "
                       "source_sha256, extraction_sha256, decision_key, ladder_version, gates_json, inputs_json, "
                       "decided_at, state, state_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'shadow',?)",
                       (decision.claim_id,) + values)
            _event(db, at, decision, "decided")
            return "decided"
        if row["decision_key"] == decision.key and row["state"] != RETIRED:
            return "released" if row["state"] == "released" else "unchanged"
        before = {"decision_key": row["decision_key"], "outcome": row["outcome"], "reason": row["reason"]}
        if row["state"] == "shadow" and row["outcome"] in TERMINAL:
            seen = db.execute("SELECT 1 FROM claim_doc_events WHERE claim_id = ? AND event = 'drift' AND "
                              "decision_key = ?", (decision.claim_id, decision.key)).fetchone()
            if seen is None:
                _event(db, at, decision, "drift", standing=before)
            return "drift"
        event = {"released": "redecided", RETIRED: "reopened"}.get(row["state"], "superseded")
        db.execute("UPDATE claim_doc_decisions SET user_id=?, profile_id=?, outcome=?, reason=?, intake_id=?, "
                   "source_sha256=?, extraction_sha256=?, decision_key=?, ladder_version=?, gates_json=?, "
                   "inputs_json=?, decided_at=?, state='shadow', state_at=?, state_by='', state_reason='' "
                   "WHERE claim_id=?", values + (decision.claim_id,))
        _event(db, at, decision, event, before=before)
        return event


def release(db: sqlite3.Connection, claim_id: int, *, by: str, why: str, at: str | None = None) -> bool:
    """The revert of a recorded decision: it no longer stands. Nothing is deleted; the row keeps
    what was decided and gains who released it and why."""
    if not by.strip() or not why.strip():
        raise ValueError("a release names who and why")
    at = at or utcnow()
    with db:
        row = db.execute("SELECT * FROM claim_doc_decisions WHERE claim_id = ?", (claim_id,)).fetchone()
        if row is None or row["state"] == "released":
            return False
        db.execute("UPDATE claim_doc_decisions SET state='released', state_at=?, state_by=?, state_reason=? "
                   "WHERE claim_id=?", (at, by.strip(), why.strip(), claim_id))
        db.execute("INSERT INTO claim_doc_events (at, claim_id, event, decision_key, outcome, reason, detail_json) "
                   "VALUES (?,?,?,?,?,?,?)", (at, claim_id, "released", row["decision_key"], row["outcome"],
                                              row["reason"], canonical({"by": by.strip(), "why": why.strip()})))
        return True


def retire_absent(db: sqlite3.Connection, present: Iterable[int], *, at: str | None = None) -> int:
    """Retire every standing decision whose claim this pass did not decide. `present` is the claim
    ids the pass DID decide, out of a snapshot of the whole open population: a claim that closed, or
    whose last document left the file, is not in it. Its row keeps what was decided and stops being
    listed as work. Nothing is deleted, and the row stands again the day the claim is back
    (`reopened`). A released row is left alone: a person already withdrew it."""
    at = at or utcnow()
    keep = {int(c) for c in present}
    n = 0
    with db:
        for row in db.execute("SELECT claim_id, decision_key, outcome, reason FROM claim_doc_decisions "
                              "WHERE state = 'shadow' ORDER BY claim_id").fetchall():
            if row["claim_id"] in keep:
                continue
            db.execute("UPDATE claim_doc_decisions SET state=?, state_at=?, state_by=?, state_reason=? "
                       "WHERE claim_id=?", (RETIRED, at, RETIRED_BY, RETIRED_REASON, row["claim_id"]))
            db.execute("INSERT INTO claim_doc_events (at, claim_id, event, decision_key, outcome, reason, "
                       "detail_json) VALUES (?,?,?,?,?,?,?)",
                       (at, row["claim_id"], RETIRED, row["decision_key"], row["outcome"], row["reason"],
                        canonical({"why": RETIRED_REASON})))
            n += 1
    return n


class NotReproducible(RuntimeError):
    pass


def reproduce(db: sqlite3.Connection, claim_id: int) -> Decision:
    """Re-run the ladder on what a recorded decision stored. Raises when a stored extraction is
    missing or no longer hashes to its key: a decision nobody can re-derive is not evidence."""
    row = db.execute("SELECT * FROM claim_doc_decisions WHERE claim_id = ?", (claim_id,)).fetchone()
    if row is None:
        raise NotReproducible(f"claim {claim_id}: no decision on file")
    inputs = json.loads(row["inputs_json"])
    docs: list[DocFacts] = []
    for d in inputs["documents"]:
        body = None
        if d.get("has_extraction"):
            got = db.execute("SELECT extraction_json FROM claim_doc_extractions WHERE source_sha256 = ? AND "
                             "extraction_sha256 = ?", (d["source_sha256"], d["extraction_sha256"])).fetchone()
            if got is None:
                raise NotReproducible(f"claim {claim_id}: extraction {d['extraction_sha256'][:12]} is not on file")
            body = json.loads(got[0])
            if sha256_of(body) != d["extraction_sha256"]:
                raise NotReproducible(f"claim {claim_id}: extraction {d['extraction_sha256'][:12]} does not hash "
                                      "to its key")
        docs.append(DocFacts.from_dict({**d, "extraction": body}))
    decision = decide_claim(ClaimFacts.from_dict(inputs["claim"]), docs, check_policy(inputs["policy"]))
    if decision is None:
        raise NotReproducible(f"claim {claim_id}: the stored inputs support no decision")
    return decision


def verify(db: sqlite3.Connection) -> dict[str, Any]:
    """Every recorded decision, re-derived. `mismatch` lists claims whose stored inputs no longer
    produce the stored decision."""
    ok, mismatch = 0, []
    for row in db.execute("SELECT claim_id, decision_key FROM claim_doc_decisions ORDER BY claim_id").fetchall():
        try:
            same = reproduce(db, row["claim_id"]).key == row["decision_key"]
        except NotReproducible as exc:
            mismatch.append({"claim_id": row["claim_id"], "why": str(exc)})
            continue
        if same:
            ok += 1
        else:
            mismatch.append({"claim_id": row["claim_id"], "why": "re-derived decision differs"})
    return {"reproduced": ok, "mismatch": mismatch}


def queue(db: sqlite3.Connection, outcome: str = REVIEW) -> list[dict[str, Any]]:
    """The standing decisions with one outcome, oldest first: for `needs_human_review`, the list a
    person works, each row with the reason it is theirs and the document it stopped on."""
    if outcome not in OUTCOMES:
        raise ValueError(f"unknown outcome {outcome!r}")
    out = []
    for r in db.execute("SELECT * FROM claim_doc_decisions WHERE outcome = ? AND state = 'shadow' "
                        "ORDER BY decided_at, claim_id", (outcome,)).fetchall():
        gates = json.loads(r["gates_json"])
        stopped = next((g for g in gates if not g["ok"]), None)
        out.append({"claim_id": r["claim_id"], "user_id": r["user_id"], "profile_id": r["profile_id"],
                    "outcome": r["outcome"], "reason": r["reason"], "decided_at": r["decided_at"],
                    "intake_id": r["intake_id"], "source_sha256": r["source_sha256"],
                    "stopped_at": stopped["gate"] if stopped else "", "detail": stopped["detail"] if stopped else {},
                    "documents_on_file": len(json.loads(r["inputs_json"])["documents"])})
    return out


def run(snapshot: Mapping[str, Any], policy: Mapping[str, Any], db: sqlite3.Connection, *,
        at: str | None = None) -> dict[str, Any]:
    decisions, skipped = plan(snapshot, policy)
    documents = snapshot.get("documents") or {}
    events: dict[str, int] = {}
    for decision, inputs in decisions:
        docs = [DocFacts.from_dict(d) for d in documents.get(str(decision.user_id)) or []]
        what = record(db, decision, inputs, docs, at=at)
        events[what] = events.get(what, 0) + 1
    # the snapshot is the whole open population, so a standing row it did not decide is stale
    retired = retire_absent(db, (d.claim_id for d, _ in decisions), at=at)
    if retired:
        events[RETIRED] = retired
    return {"split": split(d for d, _ in decisions), "skipped": skipped, "recorded": events}


# --------------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------------

def _load(path: str) -> dict[str, Any]:
    snap = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(snap, dict) or snap.get("version") != VERSION:
        raise SystemExit(f"{path}: not a {VERSION} snapshot")
    return snap


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "run"):
        p = sub.add_parser(name)
        p.add_argument("--snapshot", required=True, help="claim_verify.doc_sources output")
        p.add_argument("--policy", default=str(DEFAULT_POLICY))
        if name == "plan":
            p.add_argument("--out", help="write every decision as JSONL (sorted, no clock)")
        else:
            p.add_argument("--store", default=DEFAULT_STORE)
    for name in ("report", "verify"):
        sub.add_parser(name).add_argument("--store", default=DEFAULT_STORE)
    p = sub.add_parser("queue")
    p.add_argument("--store", default=DEFAULT_STORE)
    p.add_argument("--outcome", default=REVIEW, choices=OUTCOMES)
    p = sub.add_parser("release")
    p.add_argument("--store", default=DEFAULT_STORE)
    p.add_argument("--claim-id", type=int, required=True)
    p.add_argument("--by", required=True)
    p.add_argument("--why", required=True)
    args = ap.parse_args(argv)

    if args.cmd == "plan":
        decisions, skipped = plan(_load(args.snapshot), load_policy(args.policy))
        if args.out:
            Path(args.out).write_text("".join(canonical(d.as_dict()) + "\n" for d, _ in decisions), encoding="utf-8")
        print(json.dumps({"split": split(d for d, _ in decisions), "skipped": skipped}, indent=2))
        return 0
    if args.cmd == "run":
        if os.path.exists(KILL_FILE):
            print(f"claim-doc-ladder: {KILL_FILE} is present; nothing recorded", file=sys.stderr)
            return 3
        print(json.dumps(run(_load(args.snapshot), load_policy(args.policy), open_store(args.store)), indent=2))
        return 0
    if args.cmd == "release":
        done = release(open_store(args.store), args.claim_id, by=args.by, why=args.why)
        print("released" if done else "nothing to release")
        return 0 if done else 1
    db = open_store_ro(args.store)
    if args.cmd == "queue":
        for row in queue(db, args.outcome):
            print(canonical(row))
        return 0
    if args.cmd == "verify":
        out = verify(db)
        print(json.dumps(out, indent=2))
        return 1 if out["mismatch"] else 0
    rows = db.execute("SELECT outcome, reason, state, COUNT(*) FROM claim_doc_decisions GROUP BY 1, 2, 3 "
                      "ORDER BY 1, 4 DESC, 2").fetchall()
    print(json.dumps([{"outcome": r[0], "reason": r[1], "state": r[2], "n": r[3]} for r in rows], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
