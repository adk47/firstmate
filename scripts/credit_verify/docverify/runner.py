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
import json
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
from . import artifacts, challenge, forensics, gate, intake_read, intel, pace
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
    gmail_raw: Any = None          # message id -> RFC 822 bytes (gmail_intake.gog_raw) for email filings


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
                                                        cache_root=deps.cache_root, gmail_raw=deps.gmail_raw)
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
        # (what, date) pairs an EARLIER read of this document also extracted at >= OCR_DATE_MIN (Fable 127: an
        # OCR date is impossible content only when stable on a re-read); read before this read is recorded
        stable_dates = earlier_firm_dates(store, proof_id)
        store.step(run_id, proof_id, "extract", "ok" if ex.ok else "error", ex.as_dict())
        # JUNK PROOF option C (captain-1028-214x): what kind of artifact this is, with the full text; a record
        # only - it decides no outcome here (artifacts.junk_list builds the purge / decline proposal).
        art, why = artifacts.classify(text=text if path else None, ex=ex.as_dict(), facts=facts, kind=raw.get("kind"))
        store.step(run_id, proof_id, "artifact", art or "none", {"artifact": art, "why": why,
                                                                  "text_checked": bool(path and text.strip())})
        if not ex.ok and ex.error and ex.error.startswith(TRANSIENT) \
                and extract_attempts(store, proof_id) < MAX_EXTRACT_ATTEMPTS:
            stats.retry += 1
            return rows                       # judged again next run
        reqs = deps.requests([k.split("#", 1)[0] for k in keys])
        if intake is not None:
            if ex.ok:
                keys = cut_fanout(store, run_id, proof_id, intake, keys, reqs, ex)
            keys = keys[:MAX_INTAKE_CLAIMS]           # the per-run claim cap, applied after the cut
            if not keys:
                return rows
        # Document-level issuer checks (the issuer does not change per claim).
        issuer, itype = ex.issuer_name, ex.issuer.get("type")
        official, how = cached_official(store, deps.net, issuer) if issuer else ([], "no issuer")
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
            findings = forensics.check(h3, ex, facts, mime, text_source=raw.get("text_source"),
                                       stable_dates=stable_dates)
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
                # Ruling 057: the evidence says WHEN Muso's stored credits were read (a cache hit can be
                # up to the TTL old). It is never a same-run read: only D5b's fresh capture sets fresh_since.
                checks[-1].detail["raw_credits_read_at"] = store.raw_credits_read_at(r.track_id)
                rel = None
                if r.isrc:
                    if r.isrc not in release_cache:
                        release_cache[r.isrc] = cached_release(store, deps.net, r.isrc)
                    rel = release_cache[r.isrc]
                checks.append(xc.isrc_check(rel, role, r.names))
                checks.append(xc.label_check(issuer, itype, rel))
                # F9: a code we issued with the per-need ask, shown in this document inside its window
                chs = store.challenges(rid) if intake is not None else []
                ch = challenge.check(text, chs, user_id=r.user_id,
                                     received_at=intake.received_at if intake is not None else None,
                                     consumer=f"intake:{intake.intake_id}" if intake is not None else None)
                if ch is not None and ch.status == xc.POSITIVE and \
                        not store.consume_challenge(ch.detail["challenge_id"], f"intake:{intake.intake_id}"):
                    # another filing claimed this one-use code first (a concurrent reader): never F9 here
                    ch = xc.Check("xc_challenge", xc.WEAK, {"why": ["the code was already used by another document"],
                                                            "challenge_id": ch.detail["challenge_id"], "raced": True})
                if ch is not None:
                    checks.append(ch)
            for c in checks[3:]:
                store.step(run_id, proof_id, c.step, c.status, c.detail, key)
            uid = r.user_id if r else None
            support = supports(ex, r.names, role, r.title, r.isrc) if r else None
            elsewhere = claimant_elsewhere(ex, r.names, r.title) if r else []
            # A deny reaches a request only when the document itself names its track/ISRC or its extracted credit
            # supports it. The <= 5-candidate tie attributes a filing (asks, junk purge); it is never positive
            # evidence that the document is about THIS track (Fable NO-GO #1482: e9ec352a is a 5-request filing).
            covers = bool(r is not None and (named_by(ex, r, MIN_CONFIDENCE) or support is not None))
            o = gate.decide(h3_verdict=h3.verdict, kind=h3.kind or raw.get("kind"), ex=ex, findings=findings, covers=covers,
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
                                 issuer_site_names=[ex.signatory.get("name")] if sig.status == xc.POSITIVE else [],
                                 artist_search=lambda name: cached_artist(store, deps.net, name))
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
        reread_carried: bool = False,
        log: Callable[[str], None] = lambda m: None) -> tuple[Stats, list[dict[str, Any]]]:
    """One run. `pairs` (eval): verify exactly these documents and claims,
    ignoring `since` and what is already done. The cron (no `pairs`) then fills the rest of
    `max_docs` with documents filed in proof_intake (D2) unless `intake` is False.
    `shard=(i, n)`: this run is worker i of n and takes only the documents whose sha256 falls in
    its shard (pace.shard_of), so parallel workers never read the same document.
    `reread_carried` (Fable 134/136): NEW filings first (the ordinary intake selection), then the idle room goes to
    filings with claims whose standing row was carried forward into this VERSION without a read; those claims are
    re-read under the current rule. The new rows are ordinary rows of this VERSION, with their steps; nothing is
    hand-written. A re-read never starves a new document."""
    intake_from_store = (pairs is None) if intake is None else intake
    keep = None if shard is None else (lambda pid: pace.shard_of(pid, shard[1]) == shard[0])
    run_id = f"dv-{utcnow()}-{uuid.uuid4().hex[:8]}"
    stats = Stats(run_id)
    proof_db = ro(proof_store)
    rows: list[dict[str, Any]] = []
    try:
        if reread_carried:
            pairs, intake_from_store = {}, True
        elif pairs is None:
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
            docs = intake_read.intake_docs(proof_db, store.intake_settled, room, keep=keep, paying=paying)
            if reread_carried and len(docs) < room:             # carried re-reads only fill the idle room
                taken = {d.intake_id for d in docs}
                docs += [d for d in intake_read.intake_docs(proof_db, lambda iid, ids: not store.intake_carried_keys(iid),
                                                            room - len(docs) + len(taken), keep=keep, paying=paying)
                         if d.intake_id not in taken][:room - len(docs)]
            for doc in docs:
                stats.documents += 1
                stats.intake += 1
                try:
                    keys = intake_keys(doc, deps)        # every open claim, uncapped
                    store.record_intake_keys(doc.intake_id, doc.candidate_ids, keys)
                    store.step(run_id, doc.sha, "intake_keys", "ok" if keys else "closed",
                               {"candidates": len(doc.candidate_ids), "keys": len(keys), "first_keys": keys[:20]},
                               f"intake:{doc.intake_id}")
                    finished = store.intake_finished_keys(doc.intake_id)
                    if reread_carried:
                        finished -= store.intake_carried_keys(doc.intake_id)    # carried = not read under this rule
                    todo = [k for k in keys if k not in finished]      # capped after the fan-out cut
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


FANOUT = 50     # candidate requests above which a filed document is read only against the tracks it names


def lookup_key(name: str | None) -> str:
    """A LOSSLESS cache key for a name (QA #1499): NFKC, casefold, collapsed whitespace - every letter kept, so
    non-Latin names never collide (xc.fold drops non-ASCII letters: 张伟 and 李娜 both fold to '')."""
    import unicodedata
    return " ".join(unicodedata.normalize("NFKC", str(name or "")).casefold().split())


def cached_official(store: DocVerifyStore, net: Any, issuer: str) -> tuple[list[str], str]:
    """xc.official_domains through the shared 24 h cache, keyed on the folded issuer; a MusicBrainz error is not
    cached (Fable 149)."""
    key = lookup_key(issuer)
    if not key:
        return xc.official_domains(net, issuer)          # nothing to key on: never cached
    v = store.cached_lookup("issuer_domains", key, lambda: list(xc.official_domains(net, issuer)),
                            ok=lambda v: not str(v[1]).startswith("musicbrainz error"))
    return list(v[0]), str(v[1])


def cached_artist(store: DocVerifyStore, net: Any, name: str) -> Any:
    """MusicBrainz artist search through the shared 24 h cache, keyed losslessly on the name (never cached when
    the key is empty)."""
    fetch = lambda: net.mb("artist", {"query": f'artist:"{name[:80]}"', "limit": "3"})   # noqa: E731
    key = lookup_key(name)
    return store.cached_lookup("mb_artist", key, fetch) if key else fetch()


def cached_release(store: DocVerifyStore, net: Any, isrc: str) -> xc.Release:
    """xc.release_facts (MusicBrainz + Deezer) through the shared 24 h cache, keyed on the normalized ISRC; facts
    that carry any source error are not cached (Fable 149)."""
    from dataclasses import asdict

    from .extract import norm_isrc
    v = store.cached_lookup("isrc_release", norm_isrc(isrc) or isrc, lambda: asdict(xc.release_facts(net, isrc)),
                            ok=lambda v: not v.get("errors"))
    return xc.Release(**v)


def earlier_firm_dates(store: DocVerifyStore, proof_id: str) -> frozenset[tuple[str, str]]:
    """(what, date) pairs the IMMEDIATELY PRECEDING successful extraction of this document read at >= OCR_DATE_MIN,
    minus any `what` for which some firm read ever gave a DIFFERENT date (QA #1489: reads A -> B -> A must never make
    A 'stable'). Called before this run's read is recorded, so a read never confirms itself."""
    reads: list[set[tuple[str, str]]] = []
    for (det,) in store.db.execute("SELECT detail_json FROM dv_steps WHERE proof_id=? AND step='extract' AND "
                                   "status='ok' ORDER BY id", (proof_id,)):
        try:
            dates = (json.loads(det or "{}") or {}).get("dates") or []
        except ValueError:
            continue
        firm: set[tuple[str, str]] = set()
        for d in dates:
            try:
                if float(d.get("confidence") or 0) >= forensics.OCR_DATE_MIN and d.get("what") and d.get("date"):
                    firm.add((str(d["what"]), str(d["date"])))
            except (TypeError, ValueError, AttributeError):
                continue
        reads.append(firm)
    if not reads:
        return frozenset()
    seen: dict[str, set[str]] = {}
    for firm in reads:
        for what, d in firm:
            seen.setdefault(what, set()).add(d)
    conflicted = {what for what, ds in seen.items() if len(ds) > 1}
    return frozenset(p for p in reads[-1] if p[0] not in conflicted)


def named_by(ex: Any, r: Any, min_confidence: float | None = None) -> bool:
    """Does the document name this request's track: the exact normalized title (featured artist
    dropped, as `supports` reads it) in its tracks or credits, or the request's ISRC on it.
    `min_confidence`: only entries the extraction read at least that sure count (the fraud-deny tie, QA #1482:
    a 0.1-confidence misread title must never tie a deny to a request). None = any (the fan-out cut)."""
    from .extract import _title_key, norm_isrc

    def sure(e: dict[str, Any]) -> bool:
        if min_confidence is None:
            return True
        try:
            return float(e.get("confidence")) >= min_confidence
        except (TypeError, ValueError):
            return False
    tracks = [t for t in ex.tracks if sure(t)]
    titles = {_title_key(t.get("title")) for t in tracks if t.get("title")} | \
        {_title_key(c.get("track")) for c in ex.credits if c.get("track") and sure(c)}
    titles.discard("")
    isrc = norm_isrc(getattr(r, "isrc", None))
    isrcs = {norm_isrc(t.get("isrc")) for t in tracks if t.get("isrc")}
    return bool(_title_key(getattr(r, "title", "")) in titles or (isrc and isrc in isrcs))


def cut_fanout(store: DocVerifyStore, run_id: str, proof_id: str, intake: intake_read.IntakeDoc,
               keys: list[str], reqs: dict[str, Any], ex: Any) -> list[str]:
    """Proof-loop lead 070: a filing of an account with more than FANOUT candidate requests is read only
    against the requests whose track the document names. The rest are recorded ONCE as not matched (no
    pair row) and count as finished. A document that names no track is read in full, as before."""
    rids = {k.split("#", 1)[0] for k in keys}
    if len(rids) <= FANOUT or not (ex.tracks or any(c.get("track") for c in ex.credits)):
        return keys
    keep = [k for k in keys if (r := reqs.get(k.split("#", 1)[0])) is not None and named_by(ex, r)]
    rest = [k for k in keys if k not in keep]
    if rest:
        store.record_intake_unmatched(intake.intake_id, rest)
    store.step(run_id, proof_id, "intake_fanout", "ok",
               {"candidates": len(rids), "matched_keys": len(keep), "not_matched_keys": len(rest)},
               f"intake:{intake.intake_id}")
    return keep


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
