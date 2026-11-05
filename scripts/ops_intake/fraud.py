"""The fraud lens, run BEFORE any W1 write that touches a profile or a request.

Three independent checks, and the answer is the most restrictive one:

* **band / hold** - ``scripts/credit_review/fraud_lens.py``: is the target held
  (never messaged, never closed), watchlisted, or single-signal ask-only?
* **reused document** - the H3 F2 signals from the proof store
  (``scripts/credit_verify/proof/store.py``: identical sha256 or pHash within
  distance). A document already submitted by another account is the census's
  "reused file" case, and it is why the 11-04 verdicts came back HOLD.
* **requester-linked account** - does the TARGET belong to the person asking?
  The requester's own Slack email, Intercom contact or claimed profiles vs the
  target's. A match is not a small thing: it means the ask is "let me act on my
  own request", which is the exact shape of every insider-approval abuse. That
  is a W2 refusal and a page, never a quiet refusal (spec j2 item 4).

**"Unknown" is a decision, not a pass.** Every unmeasurable input (a Trino
outage, a proof store that is not mounted, a requester with no resolvable
email) lands in ``unmeasured`` and forces ``decision='refuse'``: no lens, no
write. The census's own worst finding was a hide executed for a profile whose
register identity was UNKNOWN - the fix is to make unmeasured refuse, not to
default to clean.

:func:`evaluate` is pure so the tests can prove every branch without Trino, the
proof store or Intercom. :class:`ProductionLens` is the thin adapter that reads
the real sources, and it converts EVERY exception into ``unmeasured``.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable

# Lens bands (credit_review.fraud_lens.Verdict) that forbid a write.
HOLD_BANDS = ("held",)
# Bands that are reported on the ask row but do not stop a reversible write.
NOTE_BANDS = ("watch", "ask_only")

HARD_REUSE_SIGNALS = (
    "reused_on_another_track",
    "reused_by_another_account_same_claim",
    "reused_by_another_account",
    "impersonation_suspected",
)


@dataclass(frozen=True)
class Frame:
    """Everything the lens is allowed to look at, gathered by the adapter."""

    target_ids: tuple[str, ...] = ()
    requester_id: str = ""
    requester_email: str | None = None
    band: str | None = None                 # held | watch | ask_only | clean | None(unknown)
    band_reasons: tuple[str, ...] = ()
    reuse_signals: tuple[dict[str, Any], ...] = ()
    requester_linked: bool | None = None    # None = could not measure
    requester_link_evidence: tuple[str, ...] = ()
    identity_verdict: str | None = None     # OWNED | MATCH | UNKNOWN | None
    unmeasured: tuple[str, ...] = ()
    notes: tuple[str, ...] = ()

    def evidence(self) -> dict[str, Any]:
        return {
            "target_ids": list(self.target_ids),
            "band": self.band,
            "band_reasons": list(self.band_reasons),
            "requester_linked": self.requester_linked,
            "requester_link_evidence": list(self.requester_link_evidence),
            "identity_verdict": self.identity_verdict,
            "reuse_signals": [s.get("signal") or s.get("code") for s in self.reuse_signals],
            "unmeasured": list(self.unmeasured),
            "notes": list(self.notes),
        }


@dataclass(frozen=True)
class LensResult:
    # allow | hold | refuse | ask | unknown
    decision: str
    reasons: tuple[str, ...] = ()
    evidence: dict[str, Any] = field(default_factory=dict)
    page: bool = False

    @property
    def permits_write(self) -> bool:
        return self.decision == "allow"

    def as_row(self) -> dict[str, Any]:
        return {"decision": self.decision, "reasons": list(self.reasons),
                "page": self.page, "evidence": self.evidence}


def evaluate(frame: Frame, *, require_identity_verdict: Iterable[str] = ()) -> LensResult:
    """Most restrictive wins. Pure; no I/O."""
    reasons: list[str] = []

    if frame.unmeasured:
        return LensResult(
            decision="refuse",
            reasons=tuple(f"unmeasured:{name}" for name in frame.unmeasured),
            evidence=frame.evidence(), page=False)

    if frame.requester_linked is True:
        return LensResult(
            decision="refuse",
            reasons=("requester-linked-account",) + tuple(frame.requester_link_evidence),
            evidence=frame.evidence(), page=True)

    if frame.requester_linked is None:
        return LensResult(decision="refuse", reasons=("requester-link-unmeasured",),
                          evidence=frame.evidence(), page=False)

    if frame.band is None:
        return LensResult(decision="refuse", reasons=("band-unmeasured",),
                          evidence=frame.evidence(), page=False)

    if frame.band in HOLD_BANDS:
        return LensResult(decision="hold",
                          reasons=("fraud-lens-held",) + tuple(frame.band_reasons),
                          evidence=frame.evidence(), page=True)

    reuse = [s for s in frame.reuse_signals
             if (s.get("signal") or s.get("code")) in HARD_REUSE_SIGNALS]
    if reuse:
        return LensResult(
            decision="hold",
            reasons=("reused-document",) + tuple(sorted({
                str(s.get("signal") or s.get("code")) for s in reuse})),
            evidence=frame.evidence(), page=True)

    needed = tuple(require_identity_verdict)
    if needed:
        verdict = (frame.identity_verdict or "UNKNOWN").upper()
        if verdict == "UNKNOWN" or verdict not in {v.upper() for v in needed}:
            # Spec j2 item 4 / census: 1 profile was hidden while its register
            # identity verdict was UNKNOWN. Ask, never hide.
            return LensResult(decision="ask",
                              reasons=(f"identity-verdict:{verdict}",),
                              evidence=frame.evidence(), page=False)

    if frame.band in NOTE_BANDS:
        reasons.append(f"band:{frame.band}")
        reasons.extend(frame.band_reasons)
    if frame.notes:
        reasons.extend(frame.notes)

    return LensResult(decision="allow", reasons=tuple(reasons),
                      evidence=frame.evidence(), page=False)


class ProductionLens:
    """Adapter over scripts/ops_intake/lens_sources.py. Every failure becomes
    ``unmeasured`` so the caller refuses the write instead of assuming clean."""

    def __init__(self, *, query=None, user_ids_fn=None, band_fn=None, reuse_fn=None,
                 identity_fn=None, link_fn=None):
        # Injected in tests; lazily resolved in production so importing this
        # module never drags Trino or the proof store into a unit test.
        self._query = query
        self._user_ids_fn = user_ids_fn
        self._band_fn = band_fn
        self._reuse_fn = reuse_fn
        self._identity_fn = identity_fn
        self._link_fn = link_fn

    def _sources(self):
        from . import lens_sources  # noqa: PLC0415
        return lens_sources

    def frame_for(self, *, target_ids: Iterable[str], requester_id: str,
                  requester_email: str | None, profile_ids: Iterable[str] = (),
                  request_ids: Iterable[str] = (),
                  need_identity: bool = False,
                  need_reuse: bool = True) -> Frame:
        src = self._sources()
        targets = tuple(dict.fromkeys(str(t) for t in target_ids if t))
        profiles = tuple(dict.fromkeys(str(i) for i in profile_ids if i))
        requests = tuple(dict.fromkeys(str(i) for i in request_ids if i))
        unmeasured: list[str] = []

        user_ids: list[str] = []
        if targets:
            user_ids_fn = self._user_ids_fn or (lambda ids: src.user_ids_for(ids, query=self._query))
            user_ids, missing = user_ids_fn(list(targets))
            unmeasured.extend(missing)

        band, band_reasons, band_missing = (None, (), [])
        if user_ids:
            band_fn = self._band_fn or (lambda uids: src.band_for_ids(uids))
            band, band_reasons, band_missing = band_fn(user_ids)
            unmeasured.extend(band_missing)
        else:
            unmeasured.append("band:no-user-id")

        reuse: list[dict[str, Any]] = []
        if need_reuse and targets:
            reuse_fn = self._reuse_fn or (lambda ids: src.reuse_signals(ids))
            reuse, reuse_missing = reuse_fn(list(targets))
            unmeasured.extend(reuse_missing)

        identity = None
        if need_identity:
            identity_fn = self._identity_fn or (lambda ids: src.register_verdict(ids))
            identity, _basis, identity_missing = identity_fn(list(profiles or targets))
            unmeasured.extend(identity_missing)

        linked: bool | None = None
        link_evidence: tuple[str, ...] = ()
        owned_targets = list(dict.fromkeys(profiles + requests))
        if owned_targets:
            link_fn = self._link_fn or (lambda email, ids: src.requester_linked(
                email, ids, query=self._query))
            linked, link_evidence, link_missing = link_fn(requester_email, owned_targets)
            unmeasured.extend(link_missing)

        return Frame(target_ids=targets, requester_id=requester_id,
                     requester_email=requester_email, band=band,
                     band_reasons=tuple(band_reasons), reuse_signals=tuple(reuse),
                     requester_linked=linked, requester_link_evidence=tuple(link_evidence),
                     identity_verdict=identity, unmeasured=tuple(
                         dict.fromkeys(unmeasured)))


def evaluate_link(frame: Frame) -> LensResult:
    """The conflict-of-interest half of the lens, on its own.

    This check gates READ-ONLY answers too: if the person asking is the person
    the request/profile belongs to, the router must not answer it as if it were
    a third party - that is the insider shape (spec j2 red-team case 4).
    An UNMEASURED link refuses as well: "we could not tell whether this is the
    requester's own account" is not a pass, on a read or a write.
    """
    if frame.requester_linked is True:
        return LensResult(decision="refuse",
                          reasons=("requester-linked-account",) + tuple(frame.requester_link_evidence),
                          evidence=frame.evidence(), page=True)
    if frame.requester_linked is None:
        return LensResult(decision="refuse", reasons=("requester-link-unmeasured",),
                          evidence=frame.evidence(), page=True)
    return LensResult(decision="allow", evidence=frame.evidence())
