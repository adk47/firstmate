"""One proof end to end: sandboxed extraction -> reuse matching -> verdict ->
append-only store. Trusted-side code only (no document parsing here)."""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any, Callable

from credit_review.roles import family_of

from . import content, sandbox
from .fingerprint import Fingerprint
from .signals import ERROR, ClaimContext, Evidence, Signal
from .store import ProofStore
from .verdict import decide


@dataclass
class ProofResult:
    """The verdict for one claimed role (request) of a proof."""
    proof_id: str
    verdict: str
    reasons: list[str]
    signals: list[Signal]
    kind: str
    mime: str | None
    request_id: str = ""
    track_listed: bool | None = None

    def as_dict(self) -> dict[str, Any]:
        return {"proof_id": self.proof_id, "request_id": self.request_id, "verdict": self.verdict,
                "reasons": self.reasons, "kind": self.kind, "mime": self.mime,
                "signals": [s.as_dict() for s in self.signals]}


Runner = Callable[[str, str | None, dict[str, Any]], dict[str, Any]]


def extract(path: str, declared: str | None, ctx: ClaimContext, runner: Runner = sandbox.run) -> dict[str, Any]:
    """The untrusted part (sandboxed); safe to run in parallel."""
    try:
        return runner(path, declared, ctx.as_dict())
    except sandbox.SandboxError as exc:
        return {"fatal": str(exc)}


def analyze_proof(store: ProofStore, path: str, *, contact_h: str, source: str, source_ref: str,
                  declared: str | None = None, ctx: ClaimContext | None = None,
                  runner: Runner = sandbox.run) -> list[ProofResult]:
    ctx = ctx or ClaimContext()
    return finalize(store, path, extract(path, declared, ctx, runner), contact_h=contact_h, source=source,
                    source_ref=source_ref, ctx=ctx)


MultiRunner = Callable[[str, str | None, dict[str, Any], list[dict[str, Any]]], dict[str, Any]]


def _multi_sandbox(path: str, declared: str | None, context: dict[str, Any],
                   contexts: list[dict[str, Any]]) -> dict[str, Any]:
    return sandbox.run(path, declared, context, contexts)


def extract_against(path: str, contexts: list[ClaimContext], declared: str | None = None,
                    runner: MultiRunner = _multi_sandbox) -> dict[str, Any]:
    """The untrusted part for one document and several claim contexts
    (sandboxed); safe to run in parallel."""
    try:
        return runner(path, declared, contexts[0].as_dict(), [c.as_dict() for c in contexts])
    except sandbox.SandboxError as exc:
        return {"fatal": str(exc)}


def finalize_against(store: ProofStore, path: str, raw: dict[str, Any], *, contact_h: str, source: str,
                     source_ref: str, contexts: list[ClaimContext]) -> list[list[ProofResult]]:
    """Finalize each context of an extract_against answer exactly as
    analyze_proof would (reuse, verdict, record); run one at a time. The
    stored fingerprints are read once for the document and kept in step with
    what each context records."""
    per = raw.get("per_context")
    prior = store._prior()
    out = []
    for i, ctx in enumerate(contexts):
        mine = dict(raw)
        mine.pop("per_context", None)
        if isinstance(per, list) and len(per) == len(contexts):
            pc = per[i]
            mine.update(signals=list(raw.get("signals") or []) + list(pc.get("signals") or []),
                        kind=pc.get("kind"), track_listed=pc.get("track_listed"), entities=pc.get("entities") or {})
        elif "entities" in raw and not raw.get("fatal"):
            # An analysed file without one answer per context: never judge a
            # context on another context's content checks.
            mine = {**mine, "fatal": "sandbox returned no per-context content checks"}
        out.append(finalize(store, path, mine, contact_h=contact_h, source=source, source_ref=source_ref, ctx=ctx,
                            prior=prior))
    return out


def analyze_against(store: ProofStore, path: str, *, contact_h: str, source: str, source_ref: str,
                    contexts: list[ClaimContext], declared: str | None = None,
                    runner: MultiRunner = _multi_sandbox) -> list[list[ProofResult]]:
    """One document of ONE account checked against several of that account's
    claimed tracks (stage 2): the file forensics run once in the sandbox, the
    content cross-checks once per context, then each context is finalized.
    Returns one list of per-role results per context, in order. Every context
    must carry the same claimant names (the PDF checks use the first
    context's)."""
    if not contexts:
        return []
    return finalize_against(store, path, extract_against(path, contexts, declared, runner), contact_h=contact_h,
                            source=source, source_ref=source_ref, contexts=contexts)


def finalize(store: ProofStore, path: str, raw: dict[str, Any], *, contact_h: str, source: str, source_ref: str,
             ctx: ClaimContext, prior: list[Fingerprint] | None = None) -> list[ProofResult]:
    """Reuse matching against everything stored so far, verdict, record: one
    verdict per claimed role (ctx.claims()), each judged only on its own role.
    Run these one at a time so two copies of a document analysed in the same
    batch still see each other. `prior`: the stored fingerprints already read
    (store._prior()); updated here with what this call records."""
    signals = [Signal.from_dict(d) for d in raw.get("signals") or []]
    if raw.get("fatal"):
        signals.append(Signal("F1", "analysis_failed", ERROR, value=str(raw["fatal"])[:300],
                              evidence=Evidence(file=path, tool="credit_verify.sandbox", tool_version=sandbox.mode())))
    proof_id = raw.get("sha256") or ""
    if not proof_id:
        import hashlib
        with open(path, "rb") as fh:
            proof_id = hashlib.sha256(fh.read()).hexdigest()
    signals = content.kind_adjusted(signals, raw.get("kind"))
    names = {s.name for s in signals}
    named = (True if names & {"claimant_named", "claimant_named_unverified"} else
             False if "claimant_not_named" in names else None)
    who = next((s.value for s in signals if s.name in ("claimant_named", "claimant_named_unverified")
                and isinstance(s.value, dict)), {})
    fp = Fingerprint(proof_id=proof_id, contact_h=contact_h, kind=raw.get("kind") or "unknown",
                     mime=raw.get("mime") or "", phash=raw.get("phash"), minhash=raw.get("minhash") or [],
                     n_shingles=raw.get("n_shingles") or 0, entities=raw.get("entities") or {},
                     track_key=ctx.track_key, role_families=sorted({family_of(r) for r in ctx.claimed_roles}),
                     track_listed=raw.get("track_listed"), claimant_named=named, name_h=who.get("name_h"),
                     name_verified=who.get("verified_identity") if who else None, text_sha=raw.get("text_sha"))
    analysed = "entities" in raw and not raw.get("fatal")
    if not ctx.paired:
        signals.append(Signal("F5", "claim_context_mismatch", ERROR,
                              value={"request_ids": len(ctx.request_ids), "claimed_roles": len(ctx.claimed_roles)},
                              evidence=Evidence(file=path, tool="credit_verify.pipeline")))
        verdict, reasons = decide(signals, ctx)
        store.record(fp=fp, source=source, source_ref=source_ref, nbytes=int(raw.get("bytes") or 0),
                     signals=signals, verdict=None, reasons=reasons, request_id=ctx.request_id,
                     context={"linked": ctx.linked, "request_ids": ctx.request_ids})
        if prior is not None:
            store.remember(prior, fp)
        return [ProofResult(proof_id, verdict, reasons, signals, fp.kind, raw.get("mime"), ctx.request_id,
                            fp.track_listed)]
    results = []
    for claim in ctx.claims():
        mine = replace(fp, role_families=sorted({family_of(r) for r in claim.claimed_roles}))
        sig = list(signals)
        if analysed and claim.linked:
            sig += content.role_signals(fp.kind, fp.document_roles, claim.claimed_roles, named, path)
        if raw.get("mime") and not raw.get("fatal"):
            sig += store.reuse_signals(mine, path, linked=claim.linked, prior=prior)
        verdict, reasons = decide(sig, claim)
        results.append(ProofResult(proof_id, verdict, reasons, sig, fp.kind, raw.get("mime"), claim.request_id,
                                   fp.track_listed))
    for claim, res in zip(ctx.claims(), results):
        store.record(fp=fp, source=source, source_ref=source_ref, nbytes=int(raw.get("bytes") or 0),
                     signals=res.signals, verdict=res.verdict, reasons=res.reasons, request_id=res.request_id,
                     context={"linked": claim.linked, "request_ids": claim.request_ids,
                              "claimed_roles": claim.claimed_roles, "track_key": claim.track_key,
                              "facts": raw.get("facts") or {}, "text_source": raw.get("text_source")})
    if prior is not None:
        store.remember(prior, fp)
    return results
