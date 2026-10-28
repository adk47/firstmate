"""Doc-verify runs: pick the documents, locate their bytes, run the steps,
record every step and the outcome.

Which documents: every (document, claim) pair H3 judged for a linked credit
request (verdicts.request_id '<uuid>#<role>', i.e. what stage 2 reads before
it can approve anything) whose verdict row was written at or after the
`since` cutoff. The first run records `since` = now in dv_state, so the cron
covers every document returned after it went live; `--since` widens one run.
A pair is done once it has an outcome under the current VERSION.

Bytes: the Intercom attachment cache (Caroline's edge plugin) or the
customer's attachment fetched from Intercom (read-only GET), into a 0700 temp
dir under /dev/shm that is deleted after the document. The file's sha256 must
equal the proof id, so a re-uploaded or changed attachment is never verified
in place of the one H3 judged.

Text and file facts come from the same sandbox as H3 (no network, no
credentials, unprivileged transient user); the parent never parses the file.
"""

from __future__ import annotations

import glob
import hashlib
import os
import shutil
import sqlite3
import tempfile
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable

from credit_verify.proof import FORENSICS_VERSION
from credit_verify.proof.intercom import ORIGINAL
from credit_verify.proof.sandbox import MAX_BYTES, SandboxError

from . import VERSION
from . import crosscheck as xc
from . import forensics, gate, intake_read, intel, pace
from .extract import MIN_CONFIDENCE, Extraction, Extractor, claimant_elsewhere, supports
from .store import DocVerifyStore, utcnow

PROOF_STORE = os.environ.get("CREDIT_PROOF_STORE", "/var/lib/hydra-credit-verify/proof.sqlite")
CACHE_ROOT = os.environ.get("CREDIT_PROOF_INTERCOM_CACHE", "/root/.openclaw-edge/media/intercom")
TRANSIENT = ("http ", "transport:", "daily model spend cap", "no OpenRouter key", "unusable model answer")
MAX_EXTRACT_ATTEMPTS = 3

SandboxRun = Callable[..., dict[str, Any]]
Fetch = Callable[[str], "dict[str, Any] | None"]
Download = Callable[[str, str], int]
RawCredits = Callable[[str], list[dict[str, Any]]]
Requests = Callable[[list[str]], dict[str, Any]]


def ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)


def sha256_file(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read(MAX_BYTES + 1)).hexdigest()


# -- selection ------------------------------------------------------------------
def candidates(proof_db: sqlite3.Connection, store: DocVerifyStore, since: str, limit: int,
               keep: Callable[[str], bool] | None = None) -> dict[str, list[str]]:
    """proof id -> its claim keys ('<uuid>#<role>') still to verify, oldest
    verdict first, at most `limit` documents."""
    rows = proof_db.execute(
        "SELECT proof_id, request_id, MAX(id) FROM verdicts WHERE request_id LIKE '%#%' AND created_at >= ? "
        "AND analyzer_version = ? GROUP BY proof_id, request_id ORDER BY MAX(id)",
        (since, FORENSICS_VERSION)).fetchall()
    out: dict[str, list[str]] = {}
    for proof_id, key, _ in rows:
        if (keep is not None and not keep(proof_id)) or store.done(proof_id, key):
            continue
        if proof_id not in out and len(out) >= limit:
            continue
        out.setdefault(proof_id, []).append(key)
    return out


def source_refs(proof_db: sqlite3.Connection, proof_id: str) -> list[str]:
    refs = [r[0] for r in proof_db.execute("SELECT source_ref FROM proofs WHERE proof_id=?", (proof_id,))]
    try:
        refs += [r[0] for r in proof_db.execute("SELECT DISTINCT source_ref FROM stage2_shadow WHERE proof_id=?",
                                                (proof_id,))]
    except sqlite3.OperationalError:
        pass                      # an H3 store without stage 2
    return [r for r in dict.fromkeys(refs) if r]


# -- bytes ----------------------------------------------------------------------
def locate(refs: list[str], proof_id: str, tmp: str, *, fetch: Fetch | None, dl: Download | None,
           cache_root: str = CACHE_ROOT) -> tuple[str | None, str | None, list[str]]:
    """(path, source_ref, errors): the first copy whose sha256 is the proof id."""
    from credit_verify.proof.stage2 import customer_attachments
    errors: list[str] = []
    root = os.path.realpath(cache_root)
    for ref in refs:
        paths: list[str] = []
        if ref.startswith("intercom:"):
            parts = ref.split(":")
            if len(parts) != 3 or not parts[1].isdigit():
                continue
            conv, name = parts[1], parts[2]
            if ORIGINAL.match(name):
                paths = sorted(glob.glob(os.path.join(root, conv, "*", name)))
            elif name.isdigit() and fetch and dl:
                try:
                    doc = fetch(conv)
                    atts = customer_attachments(doc or {})
                    if int(name) < len(atts):
                        dest = os.path.join(tmp, f"{conv}-{name}")
                        dl(str(atts[int(name)]["url"]), dest)
                        paths = [dest]
                except Exception as exc:  # noqa: BLE001 - recorded, the next ref is tried
                    errors.append(f"{ref}: {type(exc).__name__}")
        elif "/" in ref and not ref.startswith("/"):
            p = os.path.realpath(os.path.join(root, ref))
            if p.startswith(root + os.sep):
                paths = [p]
        for p in paths:
            try:
                if os.path.isfile(p) and sha256_file(p) == proof_id:
                    return p, ref, errors
            except OSError as exc:
                errors.append(f"{ref}: {type(exc).__name__}")
        if paths:
            errors.append(f"{ref}: no copy with the proof's sha256")
    return None, None, errors or ["no locatable source"]


# -- the run ------------------------------------------------------------------------
@dataclass
class Deps:
    sandbox: SandboxRun
    extractor: Extractor
    net: xc.Net
    raw_credits: RawCredits
    requests: Requests
    fetch: Fetch | None = None
    dl: Download | None = None
    cache_root: str = CACHE_ROOT
    # When this run requested a fresh Spotify+Tidal capture (IDP helpers.fresh_capture), the
    # request time; None = no capture requested, so nothing can be `contradicted` (D5).
    fresh_since: str | None = None
    # D2: the H3 sandbox runner for documents filed in proof_intake (pipeline._multi_sandbox
    # when None) and the H3 store read READ-ONLY for their reuse matching.
    h3_runner: Any = None
    shadow_store: Any = None
    # Muso credits graph name index for the people check (intel.trino_name_index); None = skipped.
    people_graph: intel.NameIndex | None = None


@dataclass
class Stats:
    run_id: str
    documents: int = 0
    pairs: int = 0
    retry: int = 0
    superseded: int = 0
    intake: int = 0
    outcomes: dict[str, int] = field(default_factory=lambda: defaultdict(int))
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {"run_id": self.run_id, "documents": self.documents, "pairs": self.pairs, "retry": self.retry,
                "superseded": self.superseded, "intake": self.intake,
                "outcomes": dict(self.outcomes), "errors": self.errors[:10]}


def extract_attempts(store: DocVerifyStore, proof_id: str) -> int:
    return store.db.execute("SELECT COUNT(*) FROM dv_steps WHERE proof_id=? AND step='extract' AND status='error' "
                            "AND version=?", (proof_id, VERSION)).fetchone()[0]


def verify_document(store: DocVerifyStore, proof_db: sqlite3.Connection, proof_id: str, keys: list[str],
                    deps: Deps, run_id: str, stats: Stats, held: set[int],
                    intake: intake_read.IntakeDoc | None = None) -> list[dict[str, Any]]:
    """All steps for one document and its claims; returns the outcome rows. With `intake`
    (D2) the document is a proof_intake filing: its bytes are found in its conversation by
    sha256, H3 runs here in shadow, outcomes carry the intake_id, and no hold is written."""
    tmp = tempfile.mkdtemp(prefix="cvdocverify-", dir="/dev/shm" if os.path.isdir("/dev/shm") else None)
    os.chmod(tmp, 0o700)
    rows: list[dict[str, Any]] = []
    try:
        if intake is not None:
            path, ref, errs = intake_read.locate_intake(intake, tmp, fetch=deps.fetch, dl=deps.dl,
                                                        cache_root=deps.cache_root)
        else:
            path, ref, errs = locate(source_refs(proof_db, proof_id), proof_id, tmp, fetch=deps.fetch, dl=deps.dl,
                                     cache_root=deps.cache_root)
        store.step(run_id, proof_id, "locate", "ok" if path else "error", {"source_ref": ref, "errors": errs[:5]})
        if not path and any("Error" in e for e in errs) \
                and store.db.execute("SELECT COUNT(*) FROM dv_steps WHERE proof_id=? AND step='locate' AND "
                                     "status='error' AND version=?", (proof_id, VERSION)).fetchone()[0] < 3:
            stats.retry += 1
            return rows                       # Intercom/download failure: tried again, up to 3 runs
        raw: dict[str, Any] = {}
        if path:
            try:
                raw = deps.sandbox(path, None, {}, want_text=True)
            except SandboxError as exc:
                raw = {"fatal": str(exc)[:300]}
        text = str(raw.get("doc_text") or "")
        facts = raw.get("facts") or {}
        mime = raw.get("mime")
        store.step(run_id, proof_id, "text", "ok" if text.strip() else "error",
                   {"chars": len(text), "mime": mime, "kind": raw.get("kind"), "text_source": raw.get("text_source"),
                    "facts": facts, "fatal": raw.get("fatal")})
        if path and text.strip():
            ex = deps.extractor.extract(text, {"mime": mime, "kind": raw.get("kind"), "facts": facts}, proof_id)
        else:
            ex = Extraction(ok=False, degraded=True, error="document not located" if not path else
                            f"sandbox failed: {str(raw['fatal'])[:120]}" if raw.get("fatal") else "no readable text")
        store.step(run_id, proof_id, "extract", "ok" if ex.ok else "error", ex.as_dict())
        if not ex.ok and ex.error and ex.error.startswith(TRANSIENT) \
                and extract_attempts(store, proof_id) < MAX_EXTRACT_ATTEMPTS:
            stats.retry += 1
            return rows                       # judged again next run
        reqs = deps.requests([k.split("#", 1)[0] for k in keys])
        # Document-level issuer checks (the issuer does not change per claim).
        issuer, itype = ex.issuer_name, ex.issuer.get("type")
        official, how = xc.official_domains(deps.net, issuer) if issuer else ([], "no issuer")
        dom = xc.domain_check(deps.net, ex.sender.get("domain"), issuer, official, how,
                              float(ex.sender.get("confidence") or 0.0))
        sig = xc.signatory_check(deps.net, ex.signatory.get("name") if ex.signatory.get("confidence", 0) >= MIN_CONFIDENCE
                                 else None, official)
        store.step(run_id, proof_id, "xc_domain", dom.status, dom.detail)
        store.step(run_id, proof_id, "xc_signatory", sig.status, sig.detail)
        h3_map: dict[str, forensics.H3] = {}
        if intake is not None and path:
            mine = list({rid: reqs[rid] for rid in (k.split("#", 1)[0] for k in keys) if rid in reqs}.values())
            try:
                shadow = deps.shadow_store or intake_read.ShadowProofStore.open(PROOF_STORE)
                h3_map = intake_read.shadow_h3(shadow, path, intake, mine, runner=deps.h3_runner)
                store.step(run_id, proof_id, "h3_shadow", "ok", {"claims": {k: v.verdict for k, v in h3_map.items()}},
                           f"intake:{intake.intake_id}")
            except Exception as exc:  # noqa: BLE001 - no H3 verdict means `unknown`, never a pass
                store.step(run_id, proof_id, "h3_shadow", "error", {"error": f"{type(exc).__name__}: {exc}"[:300]},
                           f"intake:{intake.intake_id}")
        # Captain 2026-10-27 21:5xZ: every domain on the document (registration age, look-alike,
        # MX/SPF/DMARC, free-mail for a company). Soft doubt blocks `verified`; never forges.
        sure = float(ex.sender.get("confidence") or 0.0) >= MIN_CONFIDENCE
        dint = intel.domain_intel(deps.net, ex.sender.get("domain") if sure else None,
                                  [e.rsplit("@", 1)[1] for e in ex.emails if "@" in e], issuer, itype, official,
                                  uncertain=[] if sure else [ex.sender.get("domain")])
        store.step(run_id, proof_id, "xc_domain_intel", dint.status, dint.detail)
        credits_cache: dict[str, tuple[list[dict[str, Any]] | None, str | None]] = {}
        release_cache: dict[str, xc.Release] = {}
        for key in keys:
            rid, _, role = key.partition("#")
            r = reqs.get(rid)
            h3 = (h3_map.get(key) or forensics.H3(verdict=None)) if intake is not None \
                else forensics.read_h3(proof_db, proof_id, key)
            findings = forensics.check(h3, ex, facts, mime)
            store.step(run_id, proof_id, "forensics", forensics.worst(findings) or "ok",
                       {"h3": h3.verdict, "h3_reasons": h3.reasons[:3], "findings": [f.as_dict() for f in findings]},
                       key)
            checks = [dom, sig, dint]
            if r is None:
                checks.append(xc.Check("xc_dsp", xc.ERROR, {"error": "request not found in core"}))
            else:
                if r.track_id not in credits_cache:
                    try:
                        credits_cache[r.track_id] = (deps.raw_credits(r.track_id), None)
                    except Exception as exc:  # noqa: BLE001
                        credits_cache[r.track_id] = (None, f"{type(exc).__name__}: {str(exc)[:120]}")
                rc, err = credits_cache[r.track_id]
                checks.append(xc.dsp(rc, role, r.names, err, deps.fresh_since))
                rel = None
                if r.isrc:
                    if r.isrc not in release_cache:
                        release_cache[r.isrc] = xc.release_facts(deps.net, r.isrc)
                    rel = release_cache[r.isrc]
                checks.append(xc.isrc_check(rel, role, r.names))
                checks.append(xc.label_check(issuer, itype, rel))
            for c in checks[3:]:
                store.step(run_id, proof_id, c.step, c.status, c.detail, key)
            uid = r.user_id if r else None
            support = supports(ex, r.names, role, r.title, r.isrc) if r else None
            elsewhere = claimant_elsewhere(ex, r.names, r.title) if r else []
            o = gate.decide(h3_verdict=h3.verdict, kind=h3.kind or raw.get("kind"), ex=ex, findings=findings,
                            checks=checks, account_held=uid in held if uid else False, extracted_support=support,
                            elsewhere=elsewhere)
            store.step(run_id, proof_id, "gate", o.outcome, {"reason": o.reason, "need": o.need,
                                                            "account_hold": o.account_hold,
                                                            "extracted_support": support}, key)
            hold = o.account_hold and intake is None     # the intake path writes no hold (proof-loop lead)
            store.outcome(run_id, proof_id=proof_id, request_id=rid, role=role, user_id=uid, source_ref=ref,
                          h3_verdict=h3.verdict, outcome=o.outcome, reason=o.reason, need=o.need,
                          account_hold=hold, detail={**o.detail, "issuer": ex.issuer,
                                                     "signatory": ex.signatory, "sender": ex.sender,
                                                     **({"would_hold": True} if o.account_hold and not hold else {}),
                                                     **({"received_at": intake.received_at,
                                                         "conversation_id": intake.conversation_id}
                                                        if intake is not None else {})},
                          intake_id=intake.intake_id if intake is not None else None)
            if hold and uid:
                held.add(uid)
                # A hold invalidates the account's earlier `verified` outcomes too,
                # whether they came earlier in this run or in an earlier run.
                n = store.supersede_verified(run_id, uid, f"{o.outcome} document {proof_id[:12]}")
                stats.superseded += n
            stats.pairs += 1
            stats.outcomes[o.outcome] += 1
            rows.append({"proof_id": proof_id, "request_id": rid, "role": role, "user_id": uid, "h3": h3.verdict,
                         "outcome": o.outcome, "reason": o.reason, "need": o.need, "account_hold": hold,
                         "checks": {c.step: c.status for c in checks},
                         "findings": [f.name for f in findings], "issuer": ex.issuer.get("name"),
                         "issuer_type": ex.issuer.get("type"), "sender_domain": ex.sender.get("domain"),
                         "signatory": ex.signatory.get("name"), "doc_type": ex.doc_type,
                         "extract_ok": ex.ok, "extracted_support": bool(support),
                         "intake_id": intake.intake_id if intake is not None else None})
        # Captain 2026-10-27 21:5xZ: does every person the document names exist (credits graph,
        # the claimed tracks' Spotify/Tidal credits, MusicBrainz, the issuer's site)? A flag for
        # a human, never an outcome: most collaborators have no public footprint.
        track_credits = [c for rc, _ in credits_cache.values() for c in (rc or [])]
        ppl = intel.people_check(deps.net, intel.people_of(ex), graph=deps.people_graph, track_credits=track_credits,
                                 issuer_site_names=[ex.signatory.get("name")] if sig.status == xc.POSITIVE else [])
        store.step(run_id, proof_id, "xc_people", ppl.status, ppl.detail)
        for row in rows:
            row["checks"]["xc_domain_intel"] = dint.status
            row["checks"]["xc_people"] = ppl.status
            row["people_nowhere"] = len(ppl.detail.get("found_nowhere") or [])
        return rows
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run(store: DocVerifyStore, deps: Deps, *, proof_store: str = PROOF_STORE, since: str | None = None,
        max_docs: int = 30, pairs: dict[str, list[str]] | None = None, intake: bool | None = None,
        shard: tuple[int, int] | None = None, paying: set[int] | frozenset[int] | None = None,
        log: Callable[[str], None] = lambda m: None) -> tuple[Stats, list[dict[str, Any]]]:
    """One run. `pairs` (eval): verify exactly these documents and claims,
    ignoring `since` and what is already done. The cron (no `pairs`) then fills the rest of
    `max_docs` with documents filed in proof_intake (D2) unless `intake` is False.
    `shard=(i, n)`: this run is worker i of n and takes only the documents whose sha256 falls in
    its shard (pace.shard_of), so parallel workers never read the same document."""
    intake_from_store = (pairs is None) if intake is None else intake
    keep = None if shard is None else (lambda pid: pace.shard_of(pid, shard[1]) == shard[0])
    run_id = f"dv-{utcnow()}-{uuid.uuid4().hex[:8]}"
    stats = Stats(run_id)
    proof_db = ro(proof_store)
    rows: list[dict[str, Any]] = []
    try:
        if pairs is None:
            cutoff = since or store.set_state_once("since", utcnow())
            pairs = candidates(proof_db, store, cutoff, max_docs, keep=keep)
            log(f"since {cutoff}: {len(pairs)} documents to verify")
        held = store.held_users()
        for uid in sorted(held):           # belt and braces: no held account keeps a standing `verified`
            stats.superseded += store.supersede_verified(run_id, uid, "account on hold")
        for proof_id, keys in pairs.items():
            stats.documents += 1
            try:
                rows += verify_document(store, proof_db, proof_id, keys, deps, run_id, stats, held)
            except Exception as exc:  # noqa: BLE001 - one document must not stop the run
                stats.errors.append(f"{proof_id[:12]}: {type(exc).__name__}: {str(exc)[:160]}")
                store.step(run_id, proof_id, "run", "error", {"error": f"{type(exc).__name__}: {str(exc)[:300]}"})
            log(f"document {proof_id[:12]}: {len(keys)} claims")
        if intake_from_store:
            room = max(0, max_docs - stats.documents)
            for doc in intake_read.intake_docs(proof_db, store.intake_settled, room, keep=keep, paying=paying):
                stats.documents += 1
                stats.intake += 1
                try:
                    keys = intake_keys(doc, deps)        # every open claim, uncapped
                    store.step(run_id, doc.sha, "intake_keys", "ok" if keys else "closed",
                               {"candidates": sorted(doc.candidate_ids), "keys": keys}, f"intake:{doc.intake_id}")
                    finished = store.intake_finished_keys(doc.intake_id)
                    todo = [k for k in keys if k not in finished][:MAX_INTAKE_CLAIMS]
                    if not todo:
                        continue
                    rows += verify_document(store, proof_db, doc.sha, todo, deps, run_id, stats, held, intake=doc)
                except Exception as exc:  # noqa: BLE001 - one document must not stop the run
                    stats.errors.append(f"intake {doc.intake_id[:16]}: {type(exc).__name__}: {str(exc)[:160]}")
                    store.step(run_id, doc.sha, "run", "error", {"error": f"{type(exc).__name__}: {str(exc)[:300]}"},
                               f"intake:{doc.intake_id}")
                log(f"intake {doc.intake_id[:16]}: {len(doc.candidate_ids)} candidate request(s)")
    finally:
        proof_db.close()
    return stats, rows


def intake_keys(doc: intake_read.IntakeDoc, deps: Deps) -> list[str]:
    """Claim keys '<request_id>#<role>' for a filed document's candidate requests that are
    still open (unverified / user_verification_needed) and belong to the filing account."""
    from credit_verify.proof.stage2 import HELD
    reqs = deps.requests(doc.candidate_ids)
    keys = []
    for rid in doc.candidate_ids:
        r = reqs.get(rid)
        if r is None or r.status not in HELD or (r.user_id and r.user_id != doc.user_id):
            continue
        keys += [f"{rid}#{role}" for role in (r.roles or ["unknown"])]
    return list(dict.fromkeys(keys))


MAX_INTAKE_CLAIMS = 60          # unfinished claims per filed document per run (stage 2's MAX_TRACKS)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
