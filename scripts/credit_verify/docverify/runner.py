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
import time
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
from .store import provider_down as store_provider_down

PROOF_STORE = os.environ.get("CREDIT_PROOF_STORE", "/var/lib/hydra-credit-verify/proof.sqlite")
CACHE_ROOT = os.environ.get("CREDIT_PROOF_INTERCOM_CACHE", "/root/.openclaw-edge/media/intercom")
TRANSIENT = ("http ", "transport:", "daily model spend cap", "no OpenRouter key", "unusable model answer")
MAX_EXTRACT_ATTEMPTS = 3


class ProviderDown(RuntimeError):
    """The model provider / network / spend cap failed (store.provider_down): stop the run, write no outcome."""

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
KEYING_PER_RUN = 200      # keys per run: one read-only Trino SELECT per filing, no bytes, no download, no model
KEYING_SYSTEMIC_MIN = 3   # this many keying failures and ZERO keys = the lookup itself is down: fail the run


def key_filings(proof_db: sqlite3.Connection, store: DocVerifyStore, deps: Deps, run_id: str,
                limit: int = KEYING_PER_RUN, *, keep: Callable[[str], bool] | None = None,
                paying: set[int] | frozenset[int] | None = None,
                stats: "Stats | None" = None,
                log: Callable[[str], None] = lambda m: None) -> tuple[dict[str, list[str]], int]:
    """Key the candidate requests of filings that owe a key, INDEPENDENTLY of the read budget.

    (Fable 11-04, CLEAN DEFECT): the key was cut inside the read loop, so which filings were keyed was decided
    by how busy the READER was - a filing waited for a 40-doc/hour read budget it might not need (its bytes may
    be missing entirely, and keying needs none). Measured that morning: 246 filings had candidate request ids
    and no `dv_intake_keys`, no step and no outcome at any version: matched, eligible, skipped. Keying is cheap
    (one read-only Trino SELECT for the roles of the request ids it already carries) so it gets its own bound
    and runs before the reads, which means a filing is keyed on the first tick after it is filed.

    Returns ({intake_id: keys}, how many filings were keyed) and records `intake_keys` per filing with the
    status `ok` (claims to read), `closed` (every candidate request is closed: nothing to read) or `owed`
    (bytes missing: keyed, and the read waits for blob-backfill). It never reads a document.

    A FAILED keying is a run failure, not a quiet skip (QA #1763 finding 1): a filing left unkeyed because the
    lookup raised is exactly the missing-key condition this pass exists to end, so the error goes into
    `Stats.errors` (and the run's log) per filing, and when NOTHING in the pass could be keyed and at least
    KEYING_SYSTEMIC_MIN filings failed, the outage is systemic - the run fails with the last exception instead of
    reporting `keyed: 0, errors: []` and exiting 0.
    """
    keyed: dict[str, list[str]] = {}
    n = 0
    if limit <= 0:
        return keyed, n
    # readable=None: a filing whose bytes are owed still gets keyed. `settled` still filters: a filing already
    # keyed under this version with the same candidates owes nothing.
    docs = _intake_docs(proof_db, store, deps, limit, keep=keep, paying=paying, require_bytes=False,
                        settled=store.intake_keyed)
    readable = lambda d: not intake_read.needs_backfill(d, deps.blobs, store.blob_registered)  # noqa: E731
    failed: list[tuple[str, BaseException]] = []
    for doc in docs:
        try:
            keys = intake_keys(doc, deps)
        except ProviderDown:
            raise
        except Exception as exc:  # noqa: BLE001 - one filing must not stop the keying pass
            err = f"intake_keys {doc.intake_id[:16]}: {type(exc).__name__}: {str(exc)[:300]}"
            failed.append((err, exc))
            if stats is not None:
                stats.errors.append(err)
            store.step(run_id, doc.sha, "intake_keys", "error",
                       {"error": f"{type(exc).__name__}: {str(exc)[:300]}"}, f"intake:{doc.intake_id}")
            log(f"KEYING FAILED {doc.intake_id[:16]}: {type(exc).__name__}: {str(exc)[:200]}")
            continue
        store.record_intake_keys(doc.intake_id, doc.candidate_ids, keys)
        ready = readable(doc)
        store.step(run_id, doc.sha, "intake_keys", "ok" if keys and ready else ("owed" if keys else "closed"),
                   {"candidates": len(doc.candidate_ids), "keys": len(keys), "first_keys": keys[:20],
                    "bytes": "stored" if ready else "owed by blob-backfill"}, f"intake:{doc.intake_id}")
        keyed[doc.intake_id] = keys
        n += 1
        log(f"keyed intake {doc.intake_id[:16]}: {len(doc.candidate_ids)} candidate request(s), "
            f"{len(keys)} open claim(s){'' if ready else ', bytes owed'}")
    if failed and n == 0 and len(failed) >= KEYING_SYSTEMIC_MIN:
        # Nothing at all could be keyed: the lookup is down, not these filings. Failing the run pages somebody;
        # a `keyed: 0` with no error is the silent version of the defect this pass was written to fix.
        raise RuntimeError(f"keying failed for all {len(failed)} filing(s); last error: {failed[-1][0]}"
                           ) from failed[-1][1]
    if failed and stats is not None and n:
        log(f"KEYING: {len(failed)} filing(s) failed to key and stay unkeyed this run")
    return keyed, n


def _intake_docs(proof_db: sqlite3.Connection, store: DocVerifyStore, deps: Deps, limit: int, *,
                 keep: Callable[[str], bool] | None = None,
                 paying: set[int] | frozenset[int] | None = None,
                 settled: Callable[[str, list[str]], bool] | None = None,
                 require_bytes: bool = True) -> list:
    """Filed credit documents that still owe a read, best first (paid, then oldest). A document whose
    bytes are still owed to blob-backfill is skipped here: it cannot be read yet, and spending a slot on
    it is how a readable document behind it starves."""
    from credit_verify.docverify import intake_read
    if limit <= 0:
        return []
    readable = (lambda d: not intake_read.needs_backfill(d, deps.blobs, store.blob_registered)) \
        if require_bytes else None
    return intake_read.intake_docs(proof_db, settled or store.intake_settled, limit, keep=keep, paying=paying,
                                   readable=readable)


CLAIM_ACCOUNTS_KEY = "open_claim_accounts"
CLAIM_ACCOUNTS_TTL_S = 3600


def claim_accounts(store: DocVerifyStore, trino: Callable[[str], str], *,
                   now: Callable[[], float] = time.time) -> frozenset[int]:
    """The accounts with an open claim, from ONE replica read an hour shared by every worker (dv_state): a replica
    question costs ~2 s whatever it asks, and 12 workers run every 15 min. "Open" is the claim ladder's own list
    (`decline_rules.OPEN_STATUSES`). An answer with no account raises: it is never "nobody has an open claim"."""
    from claim_verify import decline_rules
    try:
        cached = json.loads(store.get_state(CLAIM_ACCOUNTS_KEY) or "{}")
        if now() - float(cached["at"]) < CLAIM_ACCOUNTS_TTL_S:
            return frozenset(int(u) for u in cached["ids"])
    except (ValueError, KeyError, TypeError):
        pass
    statuses = ",".join(f"'{s}'" for s in decline_rules.OPEN_STATUSES)
    ids = sorted({int(r[0]) for r in decline_rules._rows(trino(
        "SELECT DISTINCT cast(userid as varchar) FROM postgresql_core.public.claiming "
        f"WHERE deletedat IS NULL AND userid IS NOT NULL AND status IN ({statuses})")) if r and r[0].isdigit()})
    if not ids:
        raise RuntimeError("open claim accounts read: no rows")
    store.set_state(CLAIM_ACCOUNTS_KEY, json.dumps({"at": now(), "ids": ids}))
    return frozenset(ids)


def extract_settled(store: DocVerifyStore, proof_id: str) -> bool:
    """This document has an extraction answer under this VERSION: read ok, failed for good, or out of attempts.
    A provider outage is no answer, and a transient failure is one only after MAX_EXTRACT_ATTEMPTS."""
    got = store.db.execute("SELECT status, detail_json FROM dv_steps WHERE proof_id=? AND step='extract' AND "
                           "version=? AND status IN ('ok', 'error') ORDER BY id", (proof_id, VERSION)).fetchall()
    if not got or got[-1][0] == "ok":
        return bool(got)
    try:
        err = str((json.loads(got[-1][1] or "{}") or {}).get("error") or "")
    except ValueError:
        err = ""
    return not err.startswith(TRANSIENT) or sum(1 for s, _ in got if s == "error") >= MAX_EXTRACT_ATTEMPTS


CLAIM_ONLY_FLOOR = 5      # reads per run a claimant's filing is owed whatever the credit queue holds (per worker)
CLAIM_ONLY_SCAN = 10 ** 6  # "all of them": the run counts the ones it had no slot for


def claim_only_room(max_docs: int, credit_filings: int, floor: int = CLAIM_ONLY_FLOOR) -> int:
    """How many claim-only filings this run may read: the room the credit filings left in `max_docs`, and never
    fewer than `floor` (itself never above `max_docs`; a run asked for no document reads none).

    The room alone was the whole rule, and it starved them: a credit filing is selected first and the queue of
    those is longer than a run. Measured on node-8 2026-11-13T13:56Z, the first hour the claim-only selection
    was deployed: each of the 4 workers had 110-135 credit filings owing a read for its 10 slots, so the room was
    0 in every one and none of the 116 claim-only filings owing a read was selected
    (`data/verif-claim-doc-extract-r1/report.md`). The floor is ON TOP of `max_docs`: the credit filings are
    selected exactly as before and lose no slot, so a run reads at most `max_docs + floor` documents. Each
    extra read is one extraction under the same daily model cap."""
    if max_docs <= 0:
        return 0
    return max(max_docs - credit_filings, min(max(0, floor), max_docs))


def claim_only_docs(proof_db: sqlite3.Connection, store: DocVerifyStore, deps: Deps, limit: int, *,
                    keep: Callable[[str], bool] | None = None,
                    paying: set[int] | frozenset[int] | None = None) -> list[intake_read.IntakeDoc]:
    """Filed documents with NO candidate credit request whose account has an open claim and whose bytes have no
    extraction yet: paid first, then oldest. `intake_docs` selects a filing by its credit requests, so these were
    never read and the claim ladder answered `unreadable: not_extracted` for them (all 51 such claims on
    2026-11-13; this selects 110 documents of 48 accounts there). They are read for the extraction only
    (`verify_document` with no keys stops after it): no claim key, no H3, no outcome row. `deps.claimants` None =
    this selection is off. A read that fails RAISES, the open-claims read and the `proof_intake` read alike: a
    store that cannot be read is never "no such filing" (QA review of the PR; `intake_docs` answers `[]` there)."""
    if limit <= 0 or deps.claimants is None:
        return []
    accounts = deps.claimants()
    rows = proof_db.execute(
        "SELECT intake_id, user_id, file_sha256, conversation_id, file_path, contact_h, received_at, matched_by "
        "FROM proof_intake WHERE candidate_request_ids_json = '[]' ORDER BY received_at, intake_id").fetchall()
    if paying:
        rows = sorted(rows, key=lambda r: int(r[1]) not in paying)     # stable: oldest first within each
    out: list[intake_read.IntakeDoc] = []
    seen: set[str] = set()
    for r in rows:
        if len(out) >= limit:
            break
        if int(r[1]) not in accounts or not r[2] or r[2] in seen or (keep is not None and not keep(r[2])):
            continue
        doc = intake_read.IntakeDoc(r[0], int(r[1]), r[2], str(r[3]), r[4], r[5] or "", [], r[6] or "", r[7] or "")
        if intake_read.needs_backfill(doc, deps.blobs, store.blob_registered) or extract_settled(store, doc.sha):
            continue                      # bytes owed by blob-backfill, or already answered: not a slot
        seen.add(doc.sha)
        out.append(doc)
    return out


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
    blobs: Any = None              # docverify/blobs.BlobStore: filed bytes by sha256 (Fable 10-31; never Gmail)
    # The accounts with an open claim (claim_accounts): their filings with no candidate credit request are read
    # for the extraction the claim ladder decides on. None = those filings are not read.
    claimants: Callable[[], "set[int] | frozenset[int]"] | None = None


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
    provider_down: str | None = None          # the account-wide refusal that stopped this run (a FAILED run)
    blob_owed: int = 0                        # filings whose bytes only blob-backfill restores (never read here)
    keyed: int = 0                            # filings whose candidate requests were keyed this run (no read)
    claim_only: int = 0                       # filings with no credit request, read for a claim's extraction only
    claim_only_waiting: int = 0               # such filings owing a read that this run had no slot for

    def as_dict(self) -> dict[str, Any]:
        return {"run_id": self.run_id, "documents": self.documents, "pairs": self.pairs, "retry": self.retry,
                "superseded": self.superseded, "intake": self.intake,
                "outcomes": dict(self.outcomes), "errors": self.errors[:10], "blob_owed": self.blob_owed,
                "keyed": self.keyed, "claim_only": self.claim_only,
                "claim_only_waiting": self.claim_only_waiting,
                **({"provider_down": self.provider_down} if self.provider_down else {})}


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
                                                        cache_root=deps.cache_root, blobs=deps.blobs,
                                                        register=store.register_blob,
                                                        registered=store.blob_registered)
            if intake_read.BLOB_OWED in errs:
                stats.blob_owed += 1          # selection skips these; reached only on a race: no step, no outcome
                return rows
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
        if not ex.ok and store_provider_down(ex.error):
            # never an attempt, never an outcome: the document is read again when the provider is back
            store.step(run_id, proof_id, "extract", "provider_down", ex.as_dict())
            raise ProviderDown(ex.error)
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
        archive = ArchiveCheck(store, deps.net, run_id, proof_id, ex)
        dom = archive.domain(dom)
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
        dint = archive.intel(dint, ex.sender.get("domain") if sure else None)
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
                # Fable 250 / measured 10-31: the ISRC release facts (MusicBrainz + Deezer, ~95% of MusicBrainz traffic)
                # feed only two gate uses - confirming a claim that could otherwise be VERIFIED (which needs the
                # document itself to show the claimant in this role on this track), and rescuing an unreadable DSP
                # check from `unknown`; no fraud signal reads them. In one hour 2,520 of 2,556 looked-up ISRCs (99%)
                # served no such claim, so they are looked up only when one of the two can apply.
                rel = None
                needs_release = needs_release_facts(supports(ex, r.names, role, r.title, r.isrc), checks[-1])
                if r.isrc and needs_release:
                    if r.isrc not in release_cache:
                        release_cache[r.isrc] = cached_release(store, deps.net, r.isrc)
                    rel = release_cache[r.isrc]
                if r.isrc and not needs_release:
                    why = {"why": "not looked up: no use for the release facts on this claim (the document does not "
                                  "show the claimant in this role on this track, and the DSP check read)",
                           "isrc": r.isrc}
                    checks.append(xc.Check("xc_isrc", xc.SKIPPED, why))
                    checks.append(xc.Check("xc_label", xc.SKIPPED, why))
                else:
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
                                                            "extracted_support": support,
                                                            # QA #1476: F9 counted only on a dashboard
                                                            "f9": gate.f9_anchor(checks, ex, h3.kind or raw.get("kind"))},
                       key)
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
        reread_carried: bool = False, claim_only_floor: int = CLAIM_ONLY_FLOOR,
        log: Callable[[str], None] = lambda m: None) -> tuple[Stats, list[dict[str, Any]]]:
    """One run. `pairs` (eval): verify exactly these documents and claims,
    ignoring `since` and what is already done. The cron (no `pairs`) then fills the rest of
    `max_docs` with documents filed in proof_intake (D2) unless `intake` is False.
    `shard=(i, n)`: this run is worker i of n and takes only the documents whose sha256 falls in
    its shard (pace.shard_of), so parallel workers never read the same document.
    `reread_carried` (Fable 134/136): NEW filings first (the ordinary intake selection), then the idle room goes to
    filings with claims whose standing row was carried forward into this VERSION without a read; those claims are
    re-read under the current rule. The new rows are ordinary rows of this VERSION, with their steps; nothing is
    hand-written. A re-read never starves a new document.
    `claim_only_floor`: the reads a claimant's filing with no credit request is owed on top of `max_docs` when the
    credit filings fill it (`claim_only_room`); 0 = only the room they leave."""
    intake_from_store = (pairs is None) if intake is None else intake
    keep = None if shard is None else (lambda pid: pace.shard_of(pid, shard[1]) == shard[0])
    run_id = f"dv-{utcnow()}-{uuid.uuid4().hex[:8]}"
    stats = Stats(run_id)
    proof_db = ro(proof_store)
    rows: list[dict[str, Any]] = []
    try:
        pre_docs: list = []
        claim_docs: list = []
        if reread_carried:
            pairs, intake_from_store = {}, True
        elif pairs is None:
            cutoff = since or store.set_state_once("since", utcnow())
            # [key=new-filings-first] (2026-11-03, Fable 15:0xZ): a FILED document is new coverage; the
            # proof-store candidates are re-reads of documents this rule has already judged once. Selecting
            # the re-reads first let them spend the whole `max_docs` budget, so the intake room below was 0 on
            # every run: measured that day, 11,183 outcome rows and ZERO distinct intake_ids. The filings take
            # the budget first; the re-reads fill whatever is left. `reread_carried` keeps its own order
            # because there the re-reads ARE the work being asked for.
            if intake_from_store:
                pre_docs = _intake_docs(proof_db, store, deps, max_docs, keep=keep, paying=paying)
                # A claimant's filing with no credit request is a filed document too: behind the credit filings,
                # ahead of the re-reads. It takes the room they leave in `max_docs`, and a floor of its own when
                # they leave none: `pre_docs` is the same list with or without it.
                try:
                    # every one that owes a read, so the run line says how many are still waiting: a starved
                    # queue and an empty one both read `claim_only: 0`
                    owed = claim_only_docs(proof_db, store, deps, CLAIM_ONLY_SCAN if max_docs > 0 else 0,
                                           keep=keep, paying=paying)
                    claim_docs = owed[:claim_only_room(max_docs, len(pre_docs), claim_only_floor)]
                    stats.claim_only_waiting = len(owed) - len(claim_docs)
                except Exception as exc:  # noqa: BLE001 - unmeasured: none is read this run, and the run says so
                    stats.errors.append(f"claim-only filings not selected: {type(exc).__name__}: {str(exc)[:160]}")
                    log(f"claim-only filings NOT selected ({type(exc).__name__}: {str(exc)[:160]})")
            pairs = candidates(proof_db, store, cutoff, max(0, max_docs - len(pre_docs) - len(claim_docs)), keep=keep)
            log(f"since {cutoff}: {len(pre_docs)} filings + {len(claim_docs)} claim-only filings "
                f"({stats.claim_only_waiting} more waiting) + {len(pairs)} documents to verify")
        restored = store.restore_over_provider_down()    # idempotent: a no-op once the 10-29 rows are restored
        if restored:
            log(f"restored {restored} claim verdicts masked by a provider-refusal unknown")
        held = store.held_users()
        for uid in sorted(held):           # belt and braces: no held account keeps a standing `verified`
            stats.superseded += store.supersede_verified(run_id, uid, "account on hold")
        keyed_this_run: dict[str, list[str]] = {}
        if intake_from_store and not reread_carried:
            # KEYING FIRST, and on its own budget: a filing is keyed on the first tick after it is filed, no
            # matter how full the read budget is or whether its bytes are here at all (Fable 11-04).
            keyed_this_run, stats.keyed = key_filings(proof_db, store, deps, run_id, KEYING_PER_RUN, keep=keep,
                                                      paying=paying, stats=stats, log=log)
            if stats.keyed:
                log(f"keyed {stats.keyed} filing(s) that owed a key (read budget untouched)")
        if intake_from_store:
            room = max(0, max_docs - stats.documents)
            docs = pre_docs[:room] if pre_docs else _intake_docs(proof_db, store, deps, room, keep=keep,
                                                                 paying=paying)
            if reread_carried and len(docs) < room:             # carried re-reads only fill the idle room
                taken = {d.intake_id for d in docs}
                docs += [d for d in _intake_docs(
                    proof_db, store, deps, room - len(docs) + len(taken), keep=keep, paying=paying,
                    settled=lambda iid, ids: not store.intake_carried_keys(iid))
                         if d.intake_id not in taken][:room - len(docs)]
            for doc in docs:
                stats.documents += 1
                stats.intake += 1
                try:
                    keys = keyed_this_run.get(doc.intake_id)
                    if keys is None:                     # not keyed by this run's keying pass
                        keys = intake_keys(doc, deps)    # every open claim, uncapped
                        store.record_intake_keys(doc.intake_id, doc.candidate_ids, keys)
                        store.step(run_id, doc.sha, "intake_keys", "ok" if keys else "closed",
                                   {"candidates": len(doc.candidate_ids), "keys": len(keys),
                                    "first_keys": keys[:20]}, f"intake:{doc.intake_id}")
                    finished = store.intake_finished_keys(doc.intake_id)
                    if reread_carried:
                        finished -= store.intake_carried_keys(doc.intake_id)    # carried = not read under this rule
                    todo = [k for k in keys if k not in finished]      # capped after the fan-out cut
                    if not todo:
                        continue
                    rows += verify_document(store, proof_db, doc.sha, todo, deps, run_id, stats, held, intake=doc)
                except ProviderDown as exc:
                    stats.provider_down = str(exc)
                    stats.errors.append(f"provider down ({exc}): run stopped, nothing recorded")
                    log(f"provider down ({exc}): run stopped; the documents are read again next run")
                    return stats, rows
                except Exception as exc:  # noqa: BLE001 - one document must not stop the run
                    stats.errors.append(f"intake {doc.intake_id[:16]}: {type(exc).__name__}: {str(exc)[:160]}")
                    store.step(run_id, doc.sha, "run", "error", {"error": f"{type(exc).__name__}: {str(exc)[:300]}"},
                               f"intake:{doc.intake_id}")
                log(f"intake {doc.intake_id[:16]}: {len(doc.candidate_ids)} candidate request(s)")
        for doc in claim_docs:
            stats.documents += 1
            stats.claim_only += 1
            try:
                verify_document(store, proof_db, doc.sha, [], deps, run_id, stats, held, intake=doc)
            except ProviderDown as exc:
                stats.provider_down = str(exc)
                stats.errors.append(f"provider down ({exc}): run stopped, nothing recorded")
                log(f"provider down ({exc}): run stopped; the documents are read again next run")
                return stats, rows
            except Exception as exc:  # noqa: BLE001 - one document must not stop the run
                stats.errors.append(f"intake {doc.intake_id[:16]}: {type(exc).__name__}: {str(exc)[:160]}")
                store.step(run_id, doc.sha, "run", "error", {"error": f"{type(exc).__name__}: {str(exc)[:300]}"},
                           f"intake:{doc.intake_id}")
            log(f"intake {doc.intake_id[:16]}: no credit request, read for its claim")
        for proof_id, keys in pairs.items():
            stats.documents += 1
            try:
                rows += verify_document(store, proof_db, proof_id, keys, deps, run_id, stats, held)
            except ProviderDown as exc:
                stats.provider_down = str(exc)
                stats.errors.append(f"provider down ({exc}): run stopped, nothing recorded")
                log(f"provider down ({exc}): run stopped; the documents are read again next run")
                return stats, rows
            except Exception as exc:  # noqa: BLE001 - one document must not stop the run
                stats.errors.append(f"{proof_id[:12]}: {type(exc).__name__}: {str(exc)[:160]}")
                store.step(run_id, proof_id, "run", "error", {"error": f"{type(exc).__name__}: {str(exc)[:300]}"})
            log(f"document {proof_id[:12]}: {len(keys)} claims")
    finally:
        proof_db.close()
    return stats, rows


FANOUT = 50     # candidate requests above which a filed document is read only against the tracks it names


def lookup_key(name: str | None) -> str:
    """A LOSSLESS cache key for a name (QA #1499): NFKC, casefold, collapsed whitespace - every letter kept, so
    non-Latin names never collide (xc.fold drops non-ASCII letters: 张伟 and 李娜 both fold to '')."""
    import unicodedata
    return " ".join(unicodedata.normalize("NFKC", str(name or "")).casefold().split())


def needs_release_facts(support: Any, dsp_check: Any) -> bool:
    """The ISRC release facts can change this claim's outcome only when the document supports the claim (the
    VERIFIED path, where xc_isrc can confirm and xc_label can doubt) or the DSP check errored (a POSITIVE xc_isrc keeps
    the claim out of `unknown`). Every other gate path ignores them (gate.decide; no fraud signal reads them)."""
    return support is not None or getattr(dsp_check, "status", None) == xc.ERROR


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


def document_date(ex: Any) -> Any:
    """The document's own date: the earliest signed/issued/sent date read at >= 0.6 (None when there is none)."""
    from datetime import date as _date
    out = None
    for d in getattr(ex, "dates", None) or []:
        if d.get("what") in forensics.CLAIMED_DATE_KINDS and float(d.get("confidence") or 0) >= 0.6:
            try:
                v = _date.fromisoformat(str(d.get("date")))
            except ValueError:
                continue
            out = v if out is None or v < out else out
    return out


class ArchiveCheck:
    """Fable 140 (audit-25, 1372907): before a dead or young sender domain counts as a FABRICATED sender, the web
    archive is asked for its first capture (paced, cached 24 h per domain). A capture from before the document's own
    date makes it a lapsed / re-registered domain: xc_domain is WEAK (not contradicts), and the 'does not exist' /
    'registered N days ago' intel flags of that domain are set aside (recorded as lapsed_flags). The first capture
    is recorded in an `xc_domain_archive` step either way. No capture, no document date, or an archive error
    leaves the checks exactly as they were."""

    def __init__(self, store: DocVerifyStore, net: Any, run_id: str, proof_id: str, ex: Any):
        self.store, self.net, self.run_id, self.proof_id = store, net, run_id, proof_id
        self.doc_date = document_date(ex)
        self.seen: dict[str, bool] = {}

    def lapsed(self, domain: str | None) -> bool:
        if not domain or self.doc_date is None or not hasattr(self.net, "first_capture"):
            return False
        if domain in self.seen:
            return self.seen[domain]
        try:
            # cached per (domain, document date): the host-wide fallback answers 'archived before THIS date'
            first = self.store.cached_first_capture(f"{domain}<{self.doc_date:%Y%m%d}",
                                                    lambda _k: self.net.first_capture(domain, before=self.doc_date))
            ok, err = xc.lapsed_domain(first, self.doc_date), None
        except Exception as exc:  # noqa: BLE001 - an archive we cannot read never clears a sender
            first, ok, err = None, False, f"{type(exc).__name__}: {str(exc)[:120]}"
        self.store.step(self.run_id, self.proof_id, "xc_domain_archive", "lapsed" if ok else "error" if err else "ok",
                        {"domain": domain, "first_capture": first, "document_date": self.doc_date.isoformat(),
                         **({"error": err} if err else {})})
        self.seen[domain] = ok
        return ok

    def domain(self, dom: xc.Check) -> xc.Check:
        if dom.status != xc.CONTRADICTS or dom.detail.get("note") not in xc.DEAD_DOMAIN_NOTES:
            return dom
        if not self.lapsed(dom.detail.get("sender_domain")):
            return dom
        return xc.Check("xc_domain", xc.WEAK, {**dom.detail, "lapsed": True,
                                                "note": "lapsed domain: archived before the document's date, "
                                                        "not a fabricated sender"})

    def intel(self, dint: xc.Check, sender: str | None) -> xc.Check:
        from .intel import registrable_domain
        flags = list(dint.detail.get("flags") or [])
        snd = registrable_domain(sender) if sender else None
        dead = [f for f in flags if snd and f.startswith(f"{snd}: ") and
                (f.endswith(": does not exist") or " registered " in f and f.endswith(" days ago"))]
        if not dead or not self.lapsed(snd):
            return dint
        rest = [f for f in flags if f not in dead]
        detail = {**dint.detail, "flags": rest, "lapsed_flags": dead}
        return xc.Check("xc_domain_intel", xc.SOFT if rest else xc.UNKNOWN, detail)


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
