"""Document intake for credit proofs: file WHAT a customer sent us, to WHOSE account and
WHICH credit requests it may answer.

Filing only. Nothing here judges a document: no analyzer, no sandbox, no verdict, no
`forensics` row. A filed document is a record of identity (sha256), attribution (the
Muso account, matched by a VERIFIED account handle, never by a name), provenance (the
Intercom conversation it arrived in, cache or API) and the candidate credit requests
the account currently has open. Judgement stays H3's (`pipeline.py`) and doc-verify's.

Why this exists (doc-intake-backfill-d2, 2026-10-27): `intercom.py` only analyses
"proof conversations" - a teammate or the bot asked for documentation INSIDE the same
thread and the customer attached a file after that ask - and only files that Caroline's
edge plugin happened to cache. A customer who replies to core's "we require more
details" email opens a NEW thread, and most document conversations were never cached,
so those documents never reach any reader. Measured on the 144 waiting document
conversations: 540 attachments, of which the in-thread + cache rules could see 53.

Account matching, in this order, each "verified" in the sense that the handle is one
the product itself binds to the account (never a name, never an email typed in a
conversation):

  1. the Intercom contact's `external_id` against `users.neptuneprofessionalid`
     (the id the web app boots Intercom with, firstmate 090);
  2. the proof-on-file export's `user_id` for that conversation (`cs-intercom` part,
     an exact contact-email -> `users.email` join made by the feed);
  3. otherwise UNMATCHED.

Two handles that disagree, or an account that two users both claim, is AMBIGUOUS and is
skipped: an ambiguous document is never filed against a guess.

Candidate credit requests for a filed document: the rows the account currently has open
(`unverified` / `user_verification_needed`) union the decider's current "proof on file"
holds. They are candidates, not claims: nothing is written to a credit request.
"""

from __future__ import annotations

import hashlib
import os
import re
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

from .intercom import CACHE_ROOT, ORIGINAL, contact_hash
from .sandbox import MAX_BYTES
from .store import ProofStore

PROOF_ON_FILE = os.environ.get("CREDIT_TRUST_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")

Fetch = Callable[[str], dict[str, Any] | None]
Download = Callable[[str, str], int]
Lookup = Callable[[list[str]], dict[str, list[int]]]     # professional id -> user ids


# ── inputs ──────────────────────────────────────────────────────────────────
def read_conversations(path: str) -> list[str]:
    """Conversation ids from a list file: one per line or whitespace separated,
    `#` comments allowed, blank lines ignored."""
    out: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            for token in line.split("#", 1)[0].split():
                t = token.strip()
                if t.isdigit() and t not in out:
                    out.append(t)
    return out


def export_users(path: str = PROOF_ON_FILE) -> dict[str, set[int]]:
    """conversation id -> the accounts the proof-on-file export files it under."""
    import json
    out: dict[str, set[int]] = {}
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return out
    for e in doc.get("entries") or []:
        if not isinstance(e, dict) or e.get("source") != "intercom":
            continue
        ref = str(e.get("ref") or "")
        uid = e.get("user_id")
        if ref.isdigit() and isinstance(uid, int) and not isinstance(uid, bool):
            out.setdefault(ref, set()).add(uid)
        elif ref.isdigit() and str(uid).isdigit():
            out.setdefault(ref, set()).add(int(uid))
    return out


def open_rows_json(path: str) -> dict[int, list[dict[str, Any]]]:
    """{user id: [{request_id, status}]} of the accounts' open credit requests (JSON written
    by the operator or by the run that built the list)."""
    import json
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    out: dict[int, list[dict[str, Any]]] = {}
    for k, rows in (raw or {}).items():
        try:
            uid = int(k)
        except (TypeError, ValueError):
            continue
        out[uid] = [r for r in rows if isinstance(r, dict) and r.get("request_id")]
    return out


def trino_query(sql: str) -> str:
    """Read-only SELECT through the repo's Trino wrapper (CSV on stdout)."""
    import subprocess
    if not sql.lstrip().upper().startswith("SELECT"):
        raise ValueError("intake only runs SELECTs")
    p = subprocess.run([os.environ.get("CREDIT_PROOF_TRINO", "/opt/hydra/scripts/trino-query.sh")],
                       input="SET SESSION query_max_execution_time='180s'; " + sql,
                       capture_output=True, text=True, timeout=300, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"trino rc={p.returncode}: {p.stderr.strip()[-300:]}")
    return p.stdout


OPEN = ("unverified", "user_verification_needed")


def open_rows_trino(user_ids: list[int], trino: Callable[[str], str] = trino_query) -> dict[int, list[dict[str, Any]]]:
    """{user id: [{request_id, status}]}: the accounts' open credit requests, one read-only
    SELECT per 200 accounts (used when no --open-rows file is given). Raises when Trino
    cannot be read, so a run never files a document with a silently empty candidate list."""
    import csv
    import io
    uids = sorted({int(u) for u in user_ids})
    out: dict[int, list[dict[str, Any]]] = {}
    for k in range(0, len(uids), 200):
        sql = ("SELECT cast(id as varchar), status, cast(userid as varchar) FROM postgresql_core.public.credit_requests "
               f"WHERE userid IN ({','.join(str(u) for u in uids[k:k + 200])}) "
               f"AND status IN ({','.join(repr(s) for s in OPEN)}) AND deletedat IS NULL ORDER BY createdat")
        for r in csv.reader(io.StringIO(trino(sql))):
            if len(r) >= 3 and r[2].isdigit() and re.fullmatch(r"[0-9a-f-]{36}", r[0] or "") and r[1] in OPEN:
                out.setdefault(int(r[2]), []).append({"request_id": r[0], "status": r[1]})
    return out


def professional_lookup(professional_ids: list[str]) -> dict[str, list[int]]:
    """professional id -> the Muso accounts whose `users.neptuneprofessionalid` it is (the id
    the web app boots Intercom with). Read-only replica through Trino; raises when it cannot
    be read, so a caller never files against a guess."""
    import csv
    import io
    ids = [i for i in dict.fromkeys(str(x).strip() for x in professional_ids)
           if i and "'" not in i and "\\" not in i]
    out: dict[str, list[int]] = {}
    for k in range(0, len(ids), 200):
        chunk = ids[k:k + 200]
        sql = ("SELECT neptuneprofessionalid, cast(id as varchar) FROM postgresql_core.public.users "
               "WHERE neptuneprofessionalid IN (" + ",".join("'" + x + "'" for x in chunk) + ")")
        for r in csv.reader(io.StringIO("\n".join(ln for ln in trino_query(sql).splitlines() if ln.startswith('"')))):
            if len(r) >= 2 and r[1].isdigit() and r[0]:
                out.setdefault(r[0], []).append(int(r[1]))
    return out


def professional_ids(fetch: Fetch, conv_id: str, doc: dict[str, Any] | None = None) -> str:
    """The conversation contact's external_id ("" when absent)."""
    doc = doc if doc is not None else fetch(conv_id)
    contacts = (((doc or {}).get("contacts") or {}).get("contacts")) or [{}]
    return str((contacts[0] or {}).get("external_id") or "")


def resolve_account(pro_ids: Iterable[int], export_ids: Iterable[int]) -> tuple[int | None, str]:
    """(user id, how) or (None, why). Never a name, never a guess: a professional-id
    hit wins only when it is unique AND does not contradict the export; the export
    decides only when the professional id resolved nothing."""
    pro = sorted(set(pro_ids))
    exp = sorted(set(export_ids))
    if len(pro) > 1:
        return None, "ambiguous: the professional id maps to several accounts"
    if len(exp) > 1:
        return None, "ambiguous: the proof-on-file export lists several accounts"
    if pro and exp and pro[0] != exp[0]:
        return None, "ambiguous: the professional id and the export disagree"
    if pro:
        return pro[0], "professional_id"
    if exp:
        return exp[0], "proof_on_file"
    return None, "unmatched: no verified account handle"


def candidate_requests(user_id: int | None, *, open_rows: dict[int, list[dict[str, Any]]],
                       held: dict[int, list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """The account's candidate credit requests: current open rows union the decider's
    current proof-on-file holds, deduplicated, each with the reason it is a candidate."""
    if user_id is None:
        return []
    out: dict[str, dict[str, Any]] = {}
    for r in open_rows.get(user_id, []):
        out.setdefault(str(r["request_id"]), {"request_id": str(r["request_id"]),
                                              "status": r.get("status") or "unknown",
                                              "basis": "open_credit_request"})
    for h in held.get(user_id, []):
        cur = out.setdefault(str(h["request_id"]), {"request_id": str(h["request_id"]),
                                                    "status": "held", "basis": "proof_on_file_hold"})
        if cur["basis"] == "open_credit_request":
            cur["basis"] = "open_credit_request+proof_on_file_hold"
    return sorted(out.values(), key=lambda r: r["request_id"])


# ── documents ───────────────────────────────────────────────────────────────
@dataclass
class Filing:
    conversation_id: str
    contact_h: str
    user_id: int | None
    matched_by: str
    candidate_requests: list[dict[str, Any]] = field(default_factory=list)
    files: list[dict[str, Any]] = field(default_factory=list)     # {sha, mime, bytes, source_ref}


def customer_attachments(conv: dict[str, Any]) -> list[dict[str, Any]]:
    """Every attachment a customer/lead/contact posted, in order (any part, not only
    files sent after an in-thread ask: a reply to our email starts a new thread)."""
    source = conv.get("source") or {}
    parts = [source] + list(((conv.get("conversation_parts") or {}).get("conversation_parts")) or [])
    out = []
    for p in parts:
        if (p.get("author") or {}).get("type") not in ("user", "lead", "contact"):
            continue
        for a in p.get("attachments") or []:
            if isinstance(a, dict) and a.get("url"):
                out.append(dict(a, _received_at=p.get("created_at") or conv.get("created_at")))
    return out


CUSTOMER_AUTHORS = ("user", "lead", "contact")


def all_attachments(conv: dict[str, Any], customers: bool = True) -> list[dict[str, Any]]:
    """Every attachment in the conversation (size bookkeeping only); customers=False keeps only
    the attachments staff, bots or anyone not a customer posted."""
    source = conv.get("source") or {}
    parts = [source] + list(((conv.get("conversation_parts") or {}).get("conversation_parts")) or [])
    return [a for p in parts if customers or (p.get("author") or {}).get("type") not in CUSTOMER_AUTHORS
            for a in (p.get("attachments") or []) if isinstance(a, dict)]


def cached_originals(cache_root: str, conv_id: str) -> list[str]:
    cdir = os.path.join(cache_root, conv_id)
    out: list[str] = []
    if not os.path.isdir(cdir):
        return out
    for dirpath, _dirs, names in os.walk(cdir):
        for n in sorted(names):
            if ORIGINAL.match(n):
                out.append(os.path.join(dirpath, n))
    return out


def _sha_file(path: str) -> tuple[str, int]:
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as fh:
        while True:
            b = fh.read(1 << 16)
            if not b:
                break
            n += len(b)
            if n > MAX_BYTES:
                raise ValueError("too_large")
            h.update(b)
    return h.hexdigest(), n


# Intercom serves customer attachments from these hosts only (measured on node-8 2026-10-28:
# musoai.intercom-attachments-{3,5,6}.com); any other URL is refused before a connection.
ATTACHMENT_HOST = re.compile(r"(?:[a-z0-9-]+\.intercom-attachments(?:-\d+)?\.com|downloads\.intercomcdn\.(?:com|eu)"
                             r"|[a-z0-9-]+\.intercomcdn\.com)")


def attachment_url_ok(url: str) -> bool:
    import urllib.parse
    u = urllib.parse.urlsplit(url)
    return u.scheme == "https" and bool(u.hostname) and ATTACHMENT_HOST.fullmatch(u.hostname or "") is not None \
        and u.port in (None, 443)


def _download(url: str, dest: str) -> int:
    if not attachment_url_ok(url):
        raise ValueError("attachment URL is not an https Intercom attachment host")
    with urllib.request.urlopen(urllib.request.Request(url), timeout=120) as resp, open(dest, "wb") as fh:
        n = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            n += len(chunk)
            if n > MAX_BYTES:
                raise ValueError("too_large")
            fh.write(chunk)
    return n


MAX_FETCHES = 60             # Intercom attachment downloads per run (proof-loop lead 2026-10-27)


def collect_files(conv_id: str, doc: dict[str, Any] | None, *, cache_root: str, tmp: str,
                  dl: Download = _download, budget: list[int] | None = None,
                  notes: dict[str, int] | None = None) -> tuple[list[dict[str, Any]], list[str]]:
    """(files, errors) for one conversation: its cached originals (no network) plus every
    customer attachment no cached file accounts for, fetched from Intercom. An attachment
    is accounted for when a not-yet-matched cached original has its exact `filesize`; one
    without a filesize is always fetched (a duplicate sha256 is then dropped). A partly
    cached conversation therefore never loses its uncached documents (QA #1417). Each file
    carries its sha256 - the proof id the reader keys on."""
    files: list[dict[str, Any]] = []
    errors: list[str] = []
    seen: set[str] = set()          # Intercom lists some attachments twice in one part
    for path in cached_originals(cache_root, conv_id):
        try:
            sha, n = _sha_file(path)
        except (OSError, ValueError) as exc:
            errors.append(f"…{conv_id[-5:]}: cache {os.path.basename(path)} {type(exc).__name__}")
            continue
        rel = os.path.relpath(path, os.path.join(cache_root, conv_id))
        try:
            ts = os.stat(path).st_mtime
        except OSError:
            ts = None
        files.append({"sha": sha, "bytes": n, "source_ref": f"{conv_id}/{rel}", "path": path,
                      "received_at": _iso(ts), "mime": _guess_mime(path), "from": "cache"})
    # The cache keeps EVERY attachment of the conversation, staff ones included (QA #1417): a cached
    # original is the customer's only when its byte size is that of a customer attachment and of no
    # staff attachment. Anything else is never filed as the customer's document (counted).
    cust_sizes = {a.get("filesize") for a in customer_attachments(doc or {})}
    staff_sizes = {a.get("filesize") for a in all_attachments(doc or {}, customers=False)}
    kept = [f for f in files if f["bytes"] in cust_sizes and f["bytes"] not in staff_sizes]
    if notes is not None and len(kept) < len(files):
        notes["cache_not_customer"] = notes.get("cache_not_customer", 0) + len(files) - len(kept)
    files = kept
    seen.update(f["sha"] for f in files)
    # Size is not identity (QA #1417): a cached original accounts for a customer attachment only
    # when that byte size occurs EXACTLY ONCE among all the conversation's attachments (any
    # author) and exactly once among the cached files - the cache holds only this conversation's
    # attachments, so the two are then the same file. Any shared size: every attachment of that
    # size is fetched and deduplicated by sha256 (Intercom gives no hash to match on).
    from collections import Counter
    in_conv = Counter(a.get("filesize") for a in all_attachments(doc or {}))
    in_cache = Counter(f["bytes"] for f in files)
    atts = [a for a in customer_attachments(doc or {})
            if not (isinstance(a.get("filesize"), int) and in_conv[a["filesize"]] == 1 and in_cache[a["filesize"]] == 1)]
    if atts and budget is not None and budget[0] < len(atts):
        return [], ["deferred: --max-fetches reached"]   # the whole conversation (cached part too) waits
    for i, a in enumerate(atts):
        if budget is not None:
            budget[0] -= 1
        name = re.sub(r"[^A-Za-z0-9._-]", "_", str(a.get("name") or f"file{i}"))[-80:]
        dest = os.path.join(tmp, f"{conv_id}-{i}-{name}")
        try:
            n = dl(str(a["url"]), dest)
            sha, nn = _sha_file(dest)
        except (OSError, ValueError, KeyError) as exc:
            errors.append(f"…{conv_id[-5:]}#{i}: {type(exc).__name__}")
            continue
        if sha in seen:                 # the same bytes listed twice: one document, not two
            continue
        seen.add(sha)
        files.append({"sha": sha, "bytes": nn or n, "source_ref": f"intercom:{conv_id}:{i}", "path": None,
                      "received_at": _iso(a.get("_received_at")),
                      "mime": str(a.get("content_type") or _guess_mime(dest)), "from": "intercom"})
    return files, errors


def _iso(epoch: Any) -> str:
    """An Intercom/mtime epoch as the UTC stamp the contract asks for ("" when unknown)."""
    from datetime import datetime, timezone
    try:
        return datetime.fromtimestamp(float(epoch), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OSError):
        return ""


def _guess_mime(path: str) -> str:
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    return {"pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg",
            "jpeg": "image/jpeg", "heic": "image/heic", "webp": "image/webp"}.get(ext, "application/octet-stream")


# ── the run ─────────────────────────────────────────────────────────────────
def run(store: ProofStore, *, conversations: list[str], fetch: Fetch, lookup: Lookup,
        open_rows: dict[int, list[dict[str, Any]]] | None = None,
        held: dict[int, list[dict[str, Any]]] | None = None,
        export_path: str = PROOF_ON_FILE, cache_root: str = CACHE_ROOT,
        dl: Download = _download, apply: bool = False, limit: int | None = None, workers: int = 3,
        subject: str = "credit", filed_by: str = "credit-proof.py file", max_fetches: int = MAX_FETCHES,
        open_rows_fn: Callable[[list[int]], dict[int, list[dict[str, Any]]]] | None = None,
        log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    """File every document of `conversations`. `apply=False` counts only: nothing is
    written to the store (a document only Intercom holds is still downloaded to a private
    temp dir to learn its sha256, then deleted). At most `max_fetches` attachments are
    downloaded per run; a conversation that would exceed it is deferred to the next run.
    Idempotent on (user, document): a document H3 already analysed is still filed for the
    account (H3's rows carry no request link; filing it is what lets the reader judge it).

    Returns counts a supervisor reads: filed / duplicate / unmatched / ambiguous /
    no_document / errors, files and conversations each, and the filed conversation ids
    in the order they were filed. No document text and no account name is in it."""
    export = export_users(export_path)
    open_rows = open_rows or {}
    held = held or {}
    stats: dict[str, Any] = {"conversations": len(conversations), "filed_conversations": [], "duplicate_conversations": [],
                             "unmatched_conversations": [], "ambiguous_conversations": [], "no_document_conversations": [],
                             "deferred_conversations": [], "fetches_used": 0, "candidates_refreshed": 0,
                             "cache_not_customer": 0,
                             "files_filed": 0, "files_duplicate": 0, "files_error": 0,
                             "users": 0, "with_candidate_requests": 0, "candidate_requests": 0,
                             "errors": []}
    ids = [str(x) for x in conversations]
    docs: dict[str, dict[str, Any] | None] = {}

    def get(cid: str) -> None:
        try:
            docs[cid] = fetch(cid)
        except Exception as exc:  # noqa: BLE001 - one conversation must not stop the run
            docs[cid] = None
            stats["errors"].append(f"…{cid[-5:]}: {type(exc).__name__}")

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        list(pool.map(get, ids))

    exts = {cid: professional_ids(lambda _c: docs.get(cid), cid, docs.get(cid)) for cid in ids}
    resolved = lookup(sorted({e for e in exts.values() if e})) if any(exts.values()) else {}
    todo = ids[:limit] if limit else ids
    if open_rows_fn is not None:        # one SELECT for every account this run can resolve
        uids = [u for u in (resolve_account(resolved.get(exts.get(c) or "", []), export.get(c, ()))[0]
                            for c in todo if docs.get(c) is not None) if u is not None]
        open_rows = {**open_rows_fn(uids), **open_rows} if uids else open_rows
    filed: set[tuple[int, str]] = set()     # (user, sha256) filed or counted this run
    budget = [max(0, int(max_fetches))]
    tmp = tempfile.mkdtemp(prefix="cvdocintake-", dir="/dev/shm" if os.path.isdir("/dev/shm") else None)
    os.chmod(tmp, 0o700)
    try:
        for cid in todo:
            doc = docs.get(cid)
            if doc is None:
                stats["unmatched_conversations"].append(cid)
                continue
            uid, how = resolve_account(resolved.get(exts.get(cid) or "", []), export.get(cid, ()))
            before = budget[0]
            files, errs = collect_files(cid, doc, cache_root=cache_root, tmp=tmp, dl=dl, budget=budget, notes=stats)
            stats["fetches_used"] += before - budget[0]
            if errs and errs[0].startswith("deferred"):
                stats["deferred_conversations"].append(cid)
                continue
            stats["errors"] += errs[:3]
            stats["files_error"] += len(errs)
            if not files:
                stats["no_document_conversations"].append(cid)
                continue
            if uid is None:
                key = "ambiguous_conversations" if how.startswith("ambiguous") else "unmatched_conversations"
                stats[key].append(cid)
                log(f"…{cid[-5:]}: {how} ({len(files)} file(s))")
                continue
            ch = contact_hash((((doc.get("contacts") or {}).get("contacts")) or [{}])[0].get("id"))
            cands = candidate_requests(uid, open_rows=open_rows, held=held)
            stats["users"] += 1
            if cands:
                stats["with_candidate_requests"] += 1
                stats["candidate_requests"] += len(cands)
            filed_here = 0
            for f in files:
                if (uid, f["sha"]) in filed:
                    stats["files_duplicate"] += 1
                    continue
                if store.already_filed(uid, f["sha"]):
                    # A request that opened after the filing becomes a candidate on it (QA #1417):
                    # the union is written (never a removal), so the reader picks the new claim up.
                    if apply and store.add_candidates(uid, f["sha"], [c["request_id"] for c in cands]):
                        stats["candidates_refreshed"] += 1
                    elif not apply and store.missing_candidates(uid, f["sha"], [c["request_id"] for c in cands]):
                        stats["candidates_refreshed"] += 1
                    stats["files_duplicate"] += 1
                    filed.add((uid, f["sha"]))
                    continue
                if apply:
                    wrote = store.file_document(file_sha256=f["sha"], user_id=uid, conversation_id=cid,
                                                subject=subject,
                                                candidate_request_ids=[c["request_id"] for c in cands],
                                                source="intercom", file_path=f.get("path"),
                                                received_at=f.get("received_at") or "", filed_by=filed_by,
                                                matched_by=how, contact_h=ch, mime=f["mime"],
                                                nbytes=int(f.get("bytes") or 0),
                                                detail={"provenance": f["source_ref"], "from": f["from"],
                                                        "candidates": cands})
                    if wrote is None:
                        stats["files_duplicate"] += 1
                        continue
                stats["files_filed"] += 1
                filed_here += 1
                filed.add((uid, f["sha"]))
            stats["filed_conversations" if filed_here else "duplicate_conversations"].append(cid)
            log(f"…{cid[-5:]}: user …{str(uid)[-4:]} {how}, {len(files)} file(s), "
                f"{len(cands)} candidate request(s), {filed_here} filed")
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
    return stats
