"""Stage 2, SHADOW: judge the documents already on file for the decider's
"proof on file" holds.

Fable's design (credit-trust-system-fable-a1/decider-stage2-2026-10-17.md) and
backlog ruling 2 (captain-calls-fable-d5/credit-backlog-1019.md): the decider
holds every row whose user already sent documents ("proof on file: human
review", never re-asked). Stage 2 reads those documents, runs the H3
forensics and content checks against each held request, and records what the
decider WOULD do. This module writes only its own table in the proof store
(`stage2_shadow`): no credit request is changed and nothing is sent. Going
live is the decider's job (credit-trust-llm-t01) after Fable's 50-row sample.

Inputs, all read-only:
  - the decider ledger (`decisions`): the held rows, paid-first priority;
  - Trino (`postgresql_core` / `postgresql_catalog`): request status, track,
    artists, ISRC, claimed roles, popularity, account and profile names. One
    batched SELECT per 100 ids with a query time limit; never the admin API
    (firstmate 033: no bulk paging of prod admin APIs). A batch that fails is
    skipped and its requests wait for the next run, but a lookup no batch of
    which answers at all is a Trino outage: nothing is judged and the CLI exits
    non-zero, so an empty pass never looks clean;
  - the proof-on-file export: which Intercom conversations hold the user's
    documents;
  - Intercom: one GET per conversation (attachment list + contact), then the
    customer's attachments, fetched into a private temp dir and deleted.

Documents are matched to the request by ACCOUNT (the export's user id), never
by what the text claims. One sandboxed run per file and claimant-name set
covers all of the account's held tracks (pipeline.analyze_against): each
request is checked against its own names (the account's names plus that
request's profile name), never another profile's.

Per held request and claimed role (Fable's table; shadow outcome only):
  reject_hold   any document FORGED_LIKELY for it. A document that does not
                list the track (another song) is never called forged for it
                because it fits another claim (another ISRC, artist or
                profile name): that is a coverage gap; only
                track-independent signals count there
  human         an account hold (a document on file for the account is
                FORGED_LIKELY for another of its claims, this run or an
                earlier one), popularity 0/unknown (unattributed), an org-affiliated
                account or one whose affiliation is unknown (export missing,
                stale, or the account absent or held there), another document
                covering the track that contradicts it (INCONSISTENT or
                forensic doubt), T2 (60-79: needs a second independent
                anchor, i.e. a trusted-source credit on the same release, a
                cited web page or a footprint of 3 or more; that is decider
                evidence, added by the go-live wiring), T3 (>= 80); also an
                image that would be GENUINE but for its AI-generation
                metadata (genuine_but_ai), never auto-approved
  approve       T0/T1 (< 60), a GENUINE or VERIFIED document and no
                contradiction
  review        no approving document, and one that covers the track or is a
                document of record is SUSPECT on forensic grounds
                (provenance, edits, reuse; not AI-source alone): a human looks
  need_more     best document PLAUSIBLE or INCONSISTENT, or SUSPECT only
                because it does not cover the claim (another song, role or
                artist, or nothing ties it to the track): the gap is named
  no_document   no readable document (Gmail-only, nothing fetchable)
  undetermined  documents read but every check UNDETERMINED (tooling errors);
                judged again on later runs, up to MAX_ATTEMPTS runs

A user whose conversations or downloads failed and of whom no document was
read gets an `undetermined` row per request and role ("documents could not
be fetched"), so the MAX_ATTEMPTS cap bounds the retries. Rows are
committed per user once some conversation GET in the run has answered
(succeeded or not found); when every attempted GET raised, the run is an
Intercom outage and writes no rows (the CLI exits non-zero). A user with some failed fetches
gets `undetermined` ("some documents could not be fetched") for every
outcome but reject_hold, so all the documents are judged on a later run.
"""

from __future__ import annotations

import csv
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import uuid
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

from credit_retro.takeback import _read_affiliation
from credit_review.decide import muso_user_id

from . import FORENSICS_VERSION, content
from .intercom import ORIGINAL, contact_hash
from .pipeline import MultiRunner, ProofResult, _multi_sandbox, extract_against, finalize_against
from .sandbox import MAX_BYTES
from .signals import SOFT, ClaimContext
from .store import MAX_ATTEMPTS, ProofStore
from .verdict import FORGED_LIKELY, decide

DECIDE_LEDGER = os.environ.get("CREDIT_TRUST_DECIDE_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
PROOF_ON_FILE = os.environ.get("CREDIT_TRUST_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")
ORG_AFFILIATION = os.environ.get("CREDIT_TRUST_ORG_AFFILIATION", "/var/lib/credit-trust/org-affiliation.json")
TRINO = os.environ.get("CREDIT_PROOF_TRINO", "/opt/hydra/scripts/trino-query.sh")
CACHE_ROOT = os.environ.get("CREDIT_PROOF_INTERCOM_CACHE", "/root/.openclaw-edge/media/intercom")
HELD = ("unverified", "user_verification_needed")
MAX_CONVERSATIONS = 8        # most recent conversations per user
MAX_FILES = 24               # per user
MAX_TRACKS = 60              # claimed tracks checked per user per run (oldest first)
# Measured on node-8 2026-10-21: the IN-list lookups cost superlinearly in the
# list size (100 ids ~2 s, 300 ids 17 s for the status query and 57.5 s for the
# request join, at the 60 s limit), and 11 of 16 hourly runs died on it.
TRINO_BATCH = 100
TRINO_TIMEOUT_S = 60
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS stage2_shadow (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  judged_at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  role TEXT NOT NULL,
  user_id INTEGER,
  paid INTEGER,
  popularity INTEGER,
  tier TEXT,
  outcome TEXT NOT NULL,       -- approve | reject_hold | human | review | need_more | no_document | undetermined
  reason TEXT NOT NULL,
  verdict TEXT,                -- best document verdict for this role
  proof_id TEXT,               -- sha256 of that document
  source_ref TEXT,             -- intercom:<conversation>:<file>
  doc_kind TEXT,
  documents INTEGER NOT NULL,  -- documents checked for this request
  detail_json TEXT NOT NULL,   -- per-document verdicts + reasons + track_listed
  analyzer_version TEXT        -- FORENSICS_VERSION that produced the verdicts
);
CREATE INDEX IF NOT EXISTS stage2_req ON stage2_shadow(request_id, role);
CREATE INDEX IF NOT EXISTS stage2_run ON stage2_shadow(run_id);
"""

# Soft content signals that say the document does not COVER the claim (a
# different song, another role, another artist's dashboard): a named gap for
# the user, not forensic doubt about the document.
COVERAGE_GAPS = frozenset({"track_not_named", "claimed_role_not_listed", "dsp_artist_not_track_artist"})
# Content signals that only say the document fits another claim of the
# account (another recording, another artist, another profile's name).
CLAIM_SPECIFIC = frozenset({"isrc_other_recording", "dsp_artist_not_track_artist", "claimant_not_named"})
# Files that could not be checked at all (a video, an empty or oversize file):
# not evidence either way. A polyglot or an encrypted PDF stays forensic.
UNCHECKABLE = frozenset({"reject_unaccepted_type", "reject_too_large", "reject_empty_file", "reject_pixel_bounds"})


def forensic_doubt(d: dict[str, Any]) -> bool:
    """A SUSPECT document whose soft signals are about the document itself
    (provenance, edits, reuse), not about what it covers. H3 also says
    SUSPECT when nothing ties the document to the track (no soft signal at
    all): that is a coverage gap. It counts for a claim only when the
    document covers the track or is a document of record: an edited
    screenshot of something else is a named gap, not doubt about this claim."""
    if d.get("track_listed") is not True and d.get("kind") not in content.RECORD_KINDS:
        return False
    return d["verdict"] == "SUSPECT" and bool(set(d.get("soft") or []) - COVERAGE_GAPS - UNCHECKABLE
                                              - content.AI_SOURCE)


GENUINE_CEILING = frozenset({"claimed_role_not_expressible", "claimed_role_not_listed", "claim_text_not_rendered"})


def genuine_but_ai(d: dict[str, Any]) -> bool:
    """An image that would be GENUINE without its AI-generation metadata: it
    names the verified claimant in the role on the track and its only soft
    signals are AI-source."""
    soft, sig = set(d.get("soft") or []), set(d.get("signals") or [])
    return (d["verdict"] == "SUSPECT" and d.get("track_listed") is True and bool(soft)
            and soft <= content.AI_SOURCE and "claimant_named" in sig and not sig & GENUINE_CEILING)


KIND_LABEL = {"split_sheet": "split sheet", "contract": "contract", "invoice": "invoice",
              "letter_of_direction": "letter of direction", "pro_portal": "PRO registration",
              "distributor_portal": "distributor screenshot", "dsp_for_artists": "streaming-dashboard screenshot",
              "daw_session": "session screenshot", "catalog_page": "credits page"}


def _doc(d: dict[str, Any]) -> str:
    """'the split sheet you sent (Intercom conversation …41214, file 2)': kind and
    where it came from, never its content."""
    ref = str(d.get("source_ref") or "")
    parts = ref.split(":")
    where = ""
    if len(parts) == 3:
        file = str(int(parts[2]) + 1) if parts[2].isdigit() else parts[2]
        where = f" (Intercom conversation …{parts[1][-5:]}, file {file})"
    return f"the {KIND_LABEL.get(d.get('kind') or '', 'file')} you sent{where}"


def gap_reason(r: "Request", role: str, best: dict[str, Any], results: list[dict[str, Any]]) -> str:
    """The concrete gap for a need_more, so an ask is never a generic re-ask
    (Fable sample 2026-10-20, change 3): which document was read, what it
    covers (titles from the catalog, never text from the document) and what is
    missing for THIS track and role. Titles and roles come from the request."""
    title = f"“{r.title}”" if r.title else "this track"
    soft = set(best.get("soft") or [])
    sig = set(best.get("signals") or []) | soft
    want = f"a document that names {title} and your {role} credit"
    doc = _doc(best)
    doc = doc[0].upper() + doc[1:]
    if soft & UNCHECKABLE:
        return f"{doc} could not be read (file type or size); for {title} we need {want}."
    if "isrc_other_recording" in sig:
        return f"{doc} carries the ISRC of a different recording than {title}; " \
               f"for {title} we need {want}."
    covers = [t for t in (best.get("lists") or []) if t and t != r.title][:2]
    if best.get("track_listed") is True:
        if best.get("named") is False:
            return f"{doc} names {title} but does not show your name; we need " \
                   f"a document for {title} that shows you as {role}."
        if "claimed_role_not_listed" in sig:
            return f"{doc} names {title} but not the role you claimed ({role}); we " \
                   f"need a document that shows your {role} credit on it."
        if "claimed_role_not_expressible" in sig:
            return f"{doc} names {title} but can't show the role you claimed ({role}); we " \
                   f"need a document that shows your {role} credit on it."
        if "split_shares_do_not_add_up" in sig:
            return f"{doc} names {title} but its split shares do not add up to 100%; we " \
                   f"need a corrected document that shows your {role} credit on it."
        if "claim_text_not_rendered" in sig:
            return f"{doc} names {title} only in text the rendered page does not show; we " \
                   f"need a document for {title} that visibly shows you as {role}."
        return f"{doc} names {title} but cannot on its own confirm your {role} credit on it; " \
               f"we need a document for {title} that shows you as {role}."
    if covers:
        shown = " and ".join(f"“{t}”" for t in covers)
        return f"{doc} covers {shown}, not {title}; for {title} we need {want}."
    return f"{doc} does not name {title} or its ISRC; for {title} we need {want}."
RANK = {"VERIFIED": 7, "GENUINE": 6, "PLAUSIBLE": 5, "INCONSISTENT": 4, "SUSPECT": 3,
        "CLEAN_UNLINKED": 2, "UNDETERMINED": 1, "FORGED_LIKELY": 0}
APPROVING = ("VERIFIED", "GENUINE")


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── inputs ──────────────────────────────────────────────────────────────────
@dataclass
class Held:
    request_id: str
    user_id: int
    paid: int | None
    decided_at: str


def held_rows(ledger_path: str = DECIDE_LEDGER) -> list[Held]:
    """The decider's current "proof on file" holds (its latest apply decision
    per request), paid first, then oldest decision first."""
    db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True, timeout=30)
    try:
        rows = db.execute(
            "WITH last AS (SELECT request_id, MAX(id) id FROM decisions WHERE mode IN ('apply', 'judge') "
            "GROUP BY request_id) "
            "SELECT d.request_id, d.user_id, d.paid_priority, d.decided_at FROM decisions d JOIN last USING(id) "
            "WHERE d.decision='hold' AND d.reason LIKE 'proof on file%'").fetchall()
    finally:
        db.close()
    out = [Held(r[0], int(r[1]), r[2], r[3]) for r in rows if r[1] is not None and UUID.match(str(r[0]))]
    out.sort(key=lambda h: (0 if h.paid == 1 else 1, h.decided_at))
    return out


@dataclass
class Request:
    request_id: str
    user_id: int
    status: str
    roles: list[str]
    title: str
    artists: list[str]
    popularity: int | None
    track_id: str
    isrc: str | None
    release_date: str | None
    created_at: str
    names: list[str]


Trino = Callable[[str], str]


_TRINO_NOISE = re.compile(r"org\.jline|^WARNING: Unable to create a system terminal|^SET SESSION$|"
                          r"^command terminated with exit code")
TRINO_TIME_LIMIT = "exceeded the maximum execution time limit"
TRINO_RETRY_WAIT_S = 5.0


def trino_error(stderr: str) -> str:
    """The Trino CLI's own failure line, without the kubectl/jline noise that used to fill the kept
    300 characters (2026-10-28: every reader error read 'org.jline.utils.Log logr ... dumb terminal')."""
    lines = [ln.strip() for ln in (stderr or "").splitlines() if ln.strip() and not _TRINO_NOISE.search(ln.strip())]
    return " | ".join(lines)[-300:] or (stderr or "").strip()[-300:]


def trino_query(sql: str, *, sleep: Callable[[float], None] = time.sleep, run: Any = subprocess.run) -> str:
    """Read-only SELECT through the repo's Trino wrapper, with a query time
    limit; CSV on stdout. Trino is shared with the stats and cube jobs: a query that hits the time
    limit under their load is retried ONCE (2026-10-28: ~1 in 9 reader request look-ups timed out at
    60 s that take 1.9 s on an idle coordinator). Any other failure raises at once."""
    if not sql.lstrip().upper().startswith("SELECT"):
        raise ValueError("stage 2 only runs SELECTs")
    stmt = f"SET SESSION query_max_execution_time = '{TRINO_TIMEOUT_S}s'; {sql}"
    for attempt in (1, 2):
        p = run(["bash", TRINO], input=stmt, capture_output=True, text=True,
                timeout=TRINO_TIMEOUT_S + 60, check=False)
        if p.returncode == 0:
            return p.stdout
        err = trino_error(p.stderr)
        if attempt == 1 and TRINO_TIME_LIMIT in err:
            sleep(TRINO_RETRY_WAIT_S)
            continue
        raise RuntimeError(f"trino rc={p.returncode}: {err}")
    raise AssertionError("unreachable")


def _pg_array(v: str) -> list[str]:
    v = (v or "").strip()
    if v.startswith("{") and v.endswith("}"):
        v = v[1:-1]
    return [x.strip().strip('"') for x in next(csv.reader([v]), []) if x.strip().strip('"')] if v else []


def _batch_count(ids: list[str]) -> int:
    """How many batches _batches() actually attempts for these ids."""
    n = sum(1 for x in ids if UUID.match(x))
    return -(-n // TRINO_BATCH) if n else 0


def _trino_outage(run_id: str, failures: list[str], what: str) -> dict[str, Any]:
    """Stats for a run that judged nothing because Trino answered no batch at all.
    `trino_unavailable` names which lookup went dark, so the caller can exit non-zero."""
    return {"run_id": run_id, "held_unjudged": 0, "users": 0, "rows": 0, "skipped_not_held": 0,
            "skipped_partial_lookup": 0, "documents": 0, "errors": failures[:5], "retry_users": 0,
            "intercom_unavailable": False, "outcomes": defaultdict(int),
            "trino_batches_skipped": len(failures), "trino_unavailable": what}


def _batches(ids: list[str], trino: Trino, sql_for: Callable[[str], str],
             failures: list[str] | None, failed_ids: set[str] | None = None) -> Iterable[list[str]]:
    """CSV rows of each batch's query. ONE attempt per batch: trino_query already
    retries a query-time-limit error once, so a second retry here would spend four
    60 s subprocess calls on one dead batch instead of two (QA r1 finding 1). A
    batch that fails is skipped and recorded in `failures`: its requests are simply
    not judged this run (they come back next run), and the other batches still go
    through. One slow batch never kills the run. `failed_ids`, when given, collects
    every id of a skipped batch: its answer is UNKNOWN, which is not the same as
    "Trino returned no row for it" (QA r2)."""
    for i in range(0, len(ids), TRINO_BATCH):
        batch = [x for x in ids[i:i + TRINO_BATCH] if UUID.match(x)]
        if not batch:
            continue
        inlist = ",".join(f"uuid '{x}'" for x in batch)
        try:
            text = trino(sql_for(inlist))
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            if failures is None:
                raise
            failures.append(f"trino batch of {len(batch)} skipped: {str(exc)[-120:]}")
            if failed_ids is not None:
                failed_ids.update(batch)
            continue
        yield list(csv.reader(io.StringIO(text)))


def statuses(ids: list[str], trino: Trino = trino_query, failures: list[str] | None = None,
             unknown: set[str] | None = None) -> dict[str, str]:
    """request id -> current status (a light primary-key lookup per TRINO_BATCH ids),
    so users are picked only from rows that are still held. Ids of a skipped batch go
    into `unknown` (when given): their status was never read."""
    out: dict[str, str] = {}
    sql = ("SELECT cast(id as varchar), status FROM postgresql_core.public.credit_requests "
           "WHERE id IN ({}) AND deletedat IS NULL").format
    for rows in _batches(ids, trino, sql, failures, unknown):
        for r in rows:
            if len(r) == 2 and UUID.match(r[0]):
                out[r[0]] = r[1]
    return out


def requests(ids: list[str], trino: Trino = trino_query,
             failures: list[str] | None = None) -> dict[str, Request]:
    out: dict[str, Request] = {}

    def sql_for(inlist: str) -> str:
        return ("SELECT cast(cr.id as varchar), cr.status, cr.credits, cr.spotifytracktitle, "
               "json_format(cr.spotifytrackartists), cr.spotifypopularity, cast(cr.trackid as varchar), "
               "json_extract_scalar(cr.metadata, '$.isrc'), json_extract_scalar(cr.metadata, '$.releaseDate'), "
               "cr.userid, cast(cr.createdat as varchar), u.fullname, u.firstname, u.lastname, p.name "
               "FROM postgresql_core.public.credit_requests cr "
               "LEFT JOIN postgresql_core.public.users u ON u.id = cr.userid "
               "LEFT JOIN postgresql_catalog.public.catalog_profile p ON p.profile_id = cast(cr.profileid as varchar) "
               f"WHERE cr.id IN ({inlist}) AND cr.deletedat IS NULL")
    for rows in _batches(ids, trino, sql_for, failures):
        for r in rows:
            if len(r) < 15 or not UUID.match(r[0]):
                continue          # header, CLI warnings
            try:
                artists = [a.get("name") for a in json.loads(r[4] or "[]") if isinstance(a, dict) and a.get("name")]
            except ValueError:
                artists = []
            first_last = " ".join(x for x in (r[12], r[13]) if x).strip()
            names = [n for n in dict.fromkeys(x.strip() for x in (r[14], r[11], first_last) if x and x.strip())]
            out[r[0]] = Request(request_id=r[0], user_id=int(r[9]) if r[9].isdigit() else 0, status=r[1],
                                roles=_pg_array(r[2]), title=r[3], artists=artists,
                                popularity=int(r[5]) if r[5].lstrip("-").isdigit() else None, track_id=r[6],
                                isrc=r[7] or None, release_date=r[8] or None, created_at=r[10], names=names)
    return out


def proof_conversations(path: str = PROOF_ON_FILE) -> dict[int, list[str]]:
    """user id -> Intercom conversation ids with that user's documents, most
    recent first (Intercom ids increase over time)."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    by: dict[int, set[str]] = defaultdict(set)
    for e in doc.get("entries") or []:
        uid = muso_user_id(e.get("user_id"))
        if e.get("source") == "intercom" and str(e.get("ref") or "").isdigit() and uid is not None:
            by[uid].add(str(e["ref"]))
    return {u: sorted(c, key=int, reverse=True) for u, c in by.items()}


OrgCheck = Callable[[int], "str | None"]


def org_affiliation(path: str = ORG_AFFILIATION, now: datetime | None = None) -> OrgCheck:
    """user id -> why the account goes to a human, or None when the export
    clears it. The org-affiliation/v1 consumer rules are credit_retro's
    (_read_affiliation): a missing, malformed or stale (> 2 h) export is
    UNKNOWN for everyone; a user absent from `users` or listed in `held` is
    UNKNOWN. Any verdict other than none is affiliated, and none counts only
    on full coverage. UNKNOWN is a human, never an approval."""
    try:
        users, held = _read_affiliation(path, now or datetime.now(timezone.utc))
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        why = f"org affiliation unknown: the export is unusable ({type(exc).__name__})"
        return lambda uid: why

    def check(uid: int) -> str | None:
        u = str(uid)
        if u in held:
            return "org affiliation unknown: the export holds this account"
        v = users.get(u)
        if v is None:
            return "org affiliation unknown: the account is not in the export"
        if v["verdict"] != "none":
            return f"the account is org-affiliated ({v['verdict']})"
        if v.get("coverage") != "full":
            return "org affiliation unknown: not checked on full coverage"
        return None
    return check


# ── documents ───────────────────────────────────────────────────────────────
Fetch = Callable[[str], dict[str, Any] | None]
Download = Callable[[str, str], int]


def download(url: str, dest: str) -> int:
    if not url.startswith("https://"):
        raise ValueError("attachment URL is not https")
    with urllib.request.urlopen(urllib.request.Request(url), timeout=60) as resp, open(dest, "wb") as fh:
        n = 0
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            n += len(chunk)
            if n > MAX_BYTES + 1:
                break                    # analyze.py reports reject_too_large on the cut file
            fh.write(chunk)
    return n


@dataclass
class Document:
    path: str
    source_ref: str
    contact_h: str


def customer_attachments(conv: dict[str, Any]) -> list[dict[str, Any]]:
    source = conv.get("source") or {}
    parts = [source] + list(((conv.get("conversation_parts") or {}).get("conversation_parts")) or [])
    out = []
    for p in parts:
        if (p.get("author") or {}).get("type") not in ("user", "lead", "contact"):
            continue
        for a in p.get("attachments") or []:
            if isinstance(a, dict) and a.get("url"):
                out.append(a)
    return out


def documents(conv_ids: list[str], fetch: Fetch, tmp: str, dl: Download = download,
              cache_root: str = CACHE_ROOT) -> tuple[list[Document], list[str], int, bool]:
    """The user's documents: cached originals when the edge plugin has them,
    else the customer's attachments fetched from Intercom. Returns
    (documents, errors, failures, answered): a failure is a GET or download
    that errored (worth another try); a conversation that no longer exists
    is an error but no failure; `answered` says some conversation GET
    succeeded or came back not found (Intercom is up)."""
    docs: list[Document] = []
    errors: list[str] = []
    failures = 0
    answered = False
    for conv_id in conv_ids[:MAX_CONVERSATIONS]:
        try:
            conv = fetch(conv_id)
        except Exception as exc:  # noqa: BLE001 - one conversation must not stop the user
            errors.append(f"intercom …{conv_id[-5:]}: {type(exc).__name__}")
            failures += 1
            continue
        answered = True
        if not conv:
            errors.append(f"intercom …{conv_id[-5:]}: not found")
            continue
        contacts = ((conv.get("contacts") or {}).get("contacts")) or [{}]
        ch = contact_hash(contacts[0].get("id"))
        cached = []
        cdir = os.path.join(cache_root, conv_id)
        if os.path.isdir(cdir):
            for sub in sorted(os.listdir(cdir)):
                d = os.path.join(cdir, sub)
                if os.path.isdir(d):
                    cached += [os.path.join(d, f) for f in sorted(os.listdir(d)) if ORIGINAL.match(f)]
        if cached:
            docs += [Document(p, f"intercom:{conv_id}:{os.path.basename(p)}", ch) for p in cached]
        else:
            for n, a in enumerate(customer_attachments(conv)):
                name = re.sub(r"[^A-Za-z0-9._-]", "_", str(a.get("name") or f"file{n}"))[-80:]
                dest = os.path.join(tmp, f"{conv_id}-{n}-{name}")
                try:
                    dl(str(a["url"]), dest)
                except Exception as exc:  # noqa: BLE001
                    errors.append(f"attachment …{conv_id[-5:]}#{n}: {type(exc).__name__}")
                    failures += 1
                    continue
                docs.append(Document(dest, f"intercom:{conv_id}:{n}", ch))
        if len(docs) >= MAX_FILES:
            break
    return docs[:MAX_FILES], errors, failures, answered


# ── judgement ───────────────────────────────────────────────────────────────
def tier(popularity: int | None) -> str:
    """Fable's track tier. A popularity of 0 or unknown is unattributed, not
    small: it goes to a human on the agent path (firstmate 036;
    docs/credit-verification/credit-trust-decide.md: "a stored popularity of
    0 is unattributed, not big: the row goes to a human")."""
    if not popularity:
        return "unattributed"
    return "T0/T1" if popularity < 60 else "T2" if popularity < 80 else "T3"


def contexts_for(reqs: list[Request]) -> list[ClaimContext]:
    """One context per claimed track and claimant-name set (each request's
    own names: the account's plus its profile's); one claim (request#role)
    per role."""
    by_track: dict[tuple[str, tuple[str, ...]], list[Request]] = defaultdict(list)
    for r in reqs:
        by_track[(r.track_id or r.request_id, tuple(sorted(set(r.names))))].append(r)
    out = []
    for (track, names), rs in list(by_track.items())[:MAX_TRACKS]:
        ids, roles = [], []
        for r in rs:
            for role in (r.roles or ["unknown"]):
                ids.append(f"{r.request_id}#{role}")
                roles.append(role)
        first = rs[0]
        out.append(ClaimContext(request_ids=ids, claimed_roles=roles, track_title=first.title or None,
                                track_artists=first.artists, isrcs=[first.isrc] if first.isrc else [],
                                claimant_names=list(names), release_date=first.release_date, track_key=track))
    return out


def name_groups(ctxs: list[ClaimContext]) -> list[list[ClaimContext]]:
    """Contexts sharing one claimant-name set: one sandbox run each (the PDF
    checks use the first context's names)."""
    by: dict[tuple[str, ...], list[ClaimContext]] = defaultdict(list)
    for c in ctxs:
        by[tuple(c.claimant_names)].append(c)
    return list(by.values())


def claim_verdict(pr: ProofResult, ctx: ClaimContext) -> tuple[str, list[str], list[Any]]:
    """The document's verdict for one claim. A document that does not list
    the track (track_listed not True) is not forged FOR this claim because
    it fits another claim (another recording's ISRC, another artist's
    dashboard, another profile's name): those are coverage gaps, so it is
    decided again without the CLAIM_SPECIFIC signals. Track-independent
    signals (hard ones, and mismatches such as split_shares_do_not_add_up
    with an edit) still make it FORGED_LIKELY. A document that lists the
    track keeps its verdict."""
    if pr.verdict != FORGED_LIKELY or pr.track_listed is True \
            or not any(s.name in CLAIM_SPECIFIC for s in pr.signals):
        return pr.verdict, pr.reasons, pr.signals
    kept = [s for s in pr.signals if s.name not in CLAIM_SPECIFIC]
    v, reasons = decide(kept, ctx)
    if v == FORGED_LIKELY:
        return v, reasons, kept
    return v, ["the document does not cover this track: what does not fit it is a coverage gap"] + reasons, kept


@dataclass
class Outcome:
    outcome: str
    reason: str
    best: dict[str, Any] | None = None
    documents: list[dict[str, Any]] = field(default_factory=list)


def contradiction(best: dict[str, Any], results: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Another document on file that covers this track (track_listed) and is
    INCONSISTENT for the claim or has forensic doubt. A document for another
    song never contradicts."""
    return next((d for d in results if d is not best and d.get("track_listed") is True
                 and (d["verdict"] == "INCONSISTENT" or forensic_doubt(d))), None)


def judge(r: Request, role: str, results: list[dict[str, Any]], *, org: str | None, readable: int) -> Outcome:
    """Fable's stage-2 table for one claimed role, on every document's verdict
    for it. `org`: why the account's org affiliation sends it to a human
    (org_affiliation), or None."""
    if any(d["verdict"] == "FORGED_LIKELY" for d in results):
        bad = next(d for d in results if d["verdict"] == "FORGED_LIKELY")
        return Outcome("reject_hold", "a document on file is likely forged: reject + account hold (human confirms)",
                       bad, results)
    best = max(results, key=lambda d: RANK.get(d["verdict"], 0)) if results else None
    t = tier(r.popularity)
    if best is None:
        why = "no readable document on file (Gmail-only or nothing fetchable)" if not readable else \
            "documents read but none could be checked for this track"
        return Outcome("no_document" if not readable else "undetermined", why, None, results)
    v = best["verdict"]
    if v in APPROVING:
        if t == "unattributed":
            return Outcome("human", "genuine document, but the track's popularity is 0/unknown (unattributed)",
                           best, results)
        if org:
            return Outcome("human", f"genuine document, but {org}", best, results)
        against = contradiction(best, results)
        if against:
            return Outcome("human", f"{v} document, but another document on file for this track contradicts it "
                                    f"({against['verdict']}, {against.get('source_ref')})", best, results)
        if t == "T0/T1":
            return Outcome("approve", f"{v} document names the claimant in the role on this track", best, results)
        if t == "T2":
            return Outcome("human", f"{v} document, but T2 needs a second independent anchor (a trusted-source "
                                    "credit on the same release, a cited web page, or a footprint of 3 or more): "
                                    "decider evidence, added at go-live", best, results)
        return Outcome("human", f"{v} document, but {t} stays human", best, results)
    ai = next((d for d in results if genuine_but_ai(d)), None)
    if ai:
        return Outcome("human", "an image with AI-generation metadata otherwise names you in the role on this "
                                f"track ({ai.get('source_ref')}): a human confirms; never auto-approved", ai, results)
    doubt = [d for d in results if forensic_doubt(d)]
    if doubt:
        return Outcome("review", "a document on file has forensic doubts (SUSPECT): a human looks", doubt[0],
                       results)
    if v in ("PLAUSIBLE", "INCONSISTENT", "SUSPECT"):
        return Outcome("need_more", gap_reason(r, role, best, results)[:400], best, results)
    return Outcome("undetermined", f"best document {v}", best, results)


def ensure_schema(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)
    if "analyzer_version" not in {r[1] for r in db.execute("PRAGMA table_info(stage2_shadow)")}:
        db.execute("ALTER TABLE stage2_shadow ADD COLUMN analyzer_version TEXT")
        db.commit()


def held_account(db: sqlite3.Connection, user_id: int) -> str | None:
    """The document behind an earlier reject_hold for the account ("" when
    unknown), or None when it has none."""
    row = db.execute("SELECT source_ref FROM stage2_shadow WHERE user_id=? AND outcome='reject_hold' "
                     "AND analyzer_version=? ORDER BY id DESC LIMIT 1", (user_id, FORENSICS_VERSION)).fetchone()
    return None if row is None else (row[0] or "")


def judged(db: sqlite3.Connection, request_id: str) -> bool:
    """True once a run judged the request without an undetermined role, or
    after MAX_ATTEMPTS runs (the last one stands), under the CURRENT analyzer
    version: a new FORENSICS_VERSION re-judges every request."""
    runs = db.execute("SELECT SUM(outcome = 'undetermined') FROM stage2_shadow WHERE request_id=? "
                      "AND analyzer_version=? GROUP BY run_id", (request_id, FORENSICS_VERSION)).fetchall()
    return any(u == 0 for (u,) in runs) or len(runs) >= MAX_ATTEMPTS


def run(store: ProofStore, *, fetch: Fetch, trino: Trino = trino_query, runner: MultiRunner = _multi_sandbox,
        dl: Download = download, ledger_path: str = DECIDE_LEDGER, proof_path: str = PROOF_ON_FILE,
        org_path: str = ORG_AFFILIATION, cache_root: str = CACHE_ROOT, max_users: int = 60, workers: int = 3,
        run_id: str | None = None, log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    run_id = run_id or f"stage2-{utcnow()}-{uuid.uuid4().hex[:8]}"
    db = store.db
    ensure_schema(db)
    unjudged = [h for h in held_rows(ledger_path) if not judged(db, h.request_id)]
    lookup_failures: list[str] = []
    status_ids = [h.request_id for h in unjudged]
    status_batches = _batch_count(status_ids)
    status_unknown: set[str] = set()
    st = statuses(status_ids, trino, lookup_failures, status_unknown)
    if status_batches and len(lookup_failures) >= status_batches:
        # No status batch answered: that is a Trino outage, not an empty queue. Returning
        # normally would label every pending request skipped_not_held and leave the cron
        # green while judging nothing (QA r1 finding 2).
        log(f"stage2: TRINO UNAVAILABLE - all {status_batches} status batch(es) failed; nothing judged")
        return _trino_outage(run_id, lookup_failures, "status")
    # A user with ANY request whose status batch failed is skipped whole this run (QA r2): the
    # request-completeness check below compares against the held set, so a request dropped
    # from that set by a failed status batch would otherwise go unnoticed and the user would
    # be judged on part of their requests. Unknown-status rows are never called not-held.
    unknown_users = {h.user_id for h in unjudged if h.request_id in status_unknown}
    not_held = [h for h in unjudged if h.request_id not in status_unknown and st.get(h.request_id) not in HELD]
    partial_status = [h for h in unjudged if h.user_id in unknown_users
                      and (h.request_id in status_unknown or st.get(h.request_id) in HELD)]
    held = [h for h in unjudged if st.get(h.request_id) in HELD and h.user_id not in unknown_users]
    if partial_status:
        log(f"stage2: {len(unknown_users)} user(s) skipped whole: a status batch failed for "
            f"{len(status_unknown & {h.request_id for h in unjudged})} of their request(s)")
    convs = proof_conversations(proof_path)
    org = org_affiliation(org_path)
    users: dict[int, list[Held]] = {}
    for h in held:                       # keeps the paid-first, oldest-first order
        users.setdefault(h.user_id, []).append(h)
    picked = list(users.items())[:max_users]
    req_ids = [h.request_id for _, hs in picked for h in hs]
    req_batches = _batch_count(req_ids)
    failures_before = len(lookup_failures)
    reqs = requests(req_ids, trino, lookup_failures)
    if req_batches and len(lookup_failures) - failures_before >= req_batches:
        log(f"stage2: TRINO UNAVAILABLE - all {req_batches} request batch(es) failed; nothing judged")
        return _trino_outage(run_id, lookup_failures, "requests")
    stats: dict[str, Any] = {"run_id": run_id, "held_unjudged": len(held), "users": len(picked), "rows": 0,
                             "skipped_not_held": len(not_held), "documents": 0, "errors": [],
                             "retry_users": 0, "intercom_unavailable": False, "outcomes": defaultdict(int),
                             "trino_batches_skipped": len(lookup_failures), "trino_unavailable": None,
                             "skipped_partial_lookup": len(partial_status)}
    stats["errors"] += lookup_failures[:5]
    buffered: list[tuple[Any, ...]] = []
    up = failed = False

    def write(rows: list[tuple[Any, ...]]) -> None:
        with db:
            db.executemany(
                "INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, paid, popularity,"
                " tier, outcome, reason, verdict, proof_id, source_ref, doc_kind, documents, detail_json,"
                " analyzer_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
        stats["rows"] += len(rows)
        for row in rows:
            stats["outcomes"][row[8]] += 1

    for uid, hs in picked:
        mine = [reqs[h.request_id] for h in hs if h.request_id in reqs and reqs[h.request_id].status in HELD]
        if len(mine) < len(hs):
            # A request of this user's was not answered by the request lookup: its batch failed, or
            # it left the held set between the two queries. Judge NOTHING for the user this run -
            # a judgment on part of their requests could approve what the full set would not - and
            # count it apart from genuinely-not-held rows so the summary stays honest. Next run.
            # skipped_partial_lookup counts every request left unjudged by an incomplete lookup.
            stats["skipped_partial_lookup"] += len(hs)
            continue
        paid = {h.request_id: h.paid for h in hs}
        tmp = tempfile.mkdtemp(prefix="cvstage2-", dir="/dev/shm" if os.path.isdir("/dev/shm") else None)
        os.chmod(tmp, 0o700)
        ctxs = contexts_for(mine)
        per_claim: dict[str, list[dict[str, Any]]] = defaultdict(list)
        lists: dict[str, set[str]] = defaultdict(set)    # proof -> held titles it lists (catalog titles)
        unfetched = partial = None
        try:
            docs, errs, failures, answered = documents(convs.get(uid, []), fetch, tmp, dl, cache_root)
            stats["errors"] += errs[:5]
            up, failed = up or answered, failed or bool(failures)
            if failures and not docs:
                stats["retry_users"] += 1
                unfetched = f"documents could not be fetched ({errs[0]})"
            elif failures:
                partial = f"some documents could not be fetched ({errs[0]})"
            stats["documents"] += len(docs)
            jobs = [] if unfetched else [(d, g) for d in docs for g in name_groups(ctxs)]
            with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:     # untrusted part in parallel
                raws = list(pool.map(lambda j: extract_against(j[0].path, j[1], runner=runner), jobs))
            for (d, group), raw in zip(jobs, raws):                            # reuse + verdict one at a time
                res: list[list[ProofResult]] = finalize_against(store, d.path, raw, contact_h=d.contact_h,
                                                                source="intercom", source_ref=d.source_ref,
                                                                contexts=group)
                for c, ctx_results in zip(group, res):
                    for pr in ctx_results:
                        v, reasons, sig = claim_verdict(pr, c)
                        names = {x.name for x in sig}
                        per_claim[pr.request_id].append({
                            "verdict": v, "proof_id": pr.proof_id, "source_ref": d.source_ref,
                            "kind": pr.kind, "track_listed": pr.track_listed, "reasons": reasons[:4],
                            "soft": sorted({x.name for x in sig if x.severity == SOFT}),
                            "signals": sorted(names),
                            "named": (True if names & {"claimant_named", "claimant_named_unverified"} else
                                      False if "claimant_not_named" in names else None)})
                        if pr.track_listed is True and c.track_title:
                            lists[pr.proof_id].add(c.track_title)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        for ds in per_claim.values():
            for d in ds:
                d["lists"] = sorted(lists.get(d["proof_id"], ()))
        checked = {rid for c in ctxs for rid in c.request_ids}
        forged = next((d["source_ref"] for ds in per_claim.values() for d in ds if d["verdict"] == FORGED_LIKELY),
                      None) or held_account(db, uid)
        now = utcnow()
        pending: list[tuple[Any, ...]] = []
        for r in mine:
            for role in (r.roles or ["unknown"]):
                key = f"{r.request_id}#{role}"
                if key not in checked:
                    continue          # beyond MAX_TRACKS this run: judged next run
                if unfetched:
                    o = Outcome("undetermined", unfetched)
                else:
                    o = judge(r, role, per_claim.get(key, []), org=org(uid), readable=len(docs))
                if partial and o.outcome != "reject_hold":
                    o = Outcome("undetermined", partial, o.best, o.documents)
                if o.outcome == "approve" and forged is not None:
                    o = Outcome("human", f"account hold: a document on file for this account is likely forged "
                                         f"({forged or 'earlier run'})", o.best, o.documents)
                b = o.best or {}
                pending.append((run_id, now, r.request_id, role, uid, paid.get(r.request_id), r.popularity,
                                tier(r.popularity), o.outcome, o.reason, b.get("verdict"), b.get("proof_id"),
                                b.get("source_ref"), b.get("kind"), len(o.documents),
                                json.dumps(o.documents[:12], default=str), FORENSICS_VERSION))
        if up:
            write(buffered + pending)
            buffered = []
        else:
            buffered += pending
        log(f"user …{str(uid)[-4:]}: {len(mine)} held, {len(docs)} documents")
    if failed and not up:
        stats["intercom_unavailable"] = True
        log("INTERCOM UNAVAILABLE: no rows written")
    elif buffered:
        write(buffered)
    stats["outcomes"] = dict(stats["outcomes"])
    return stats


# ── Fable's sample ──────────────────────────────────────────────────────────
SAMPLE_PLAN = (("approve", 25), ("reject_hold", 5), ("review", 6), ("need_more", 8), ("human", 4),
               ("undetermined", 1), ("no_document", 1))


def sample(db: sqlite3.Connection, n: int = 50, seed: int = 1019) -> list[sqlite3.Row]:
    """A stratified sample of the latest shadow verdict per request/role:
    approvals first (a false GENUINE is the failure that matters), then the
    rest; unfilled strata pass their share on, in plan order."""
    import random
    db.row_factory = sqlite3.Row
    rows = db.execute("SELECT s.* FROM stage2_shadow s JOIN (SELECT request_id, role, MAX(id) id FROM stage2_shadow "
                      "WHERE analyzer_version=? GROUP BY request_id, role) l USING(id)",
                      (FORENSICS_VERSION,)).fetchall()
    rng = random.Random(seed)
    by: dict[str, list[sqlite3.Row]] = defaultdict(list)
    for r in rows:
        by[r["outcome"]].append(r)
    picked: list[sqlite3.Row] = []
    carry = 0
    for outcome, k in SAMPLE_PLAN:
        pool = by.get(outcome, [])
        rng.shuffle(pool)
        take = pool[:k + carry]
        carry = k + carry - len(take)
        picked += take
    rest = [r for r in rows if r not in picked]
    rng.shuffle(rest)
    return (picked + rest)[:n]


def sample_markdown(rows: Iterable[sqlite3.Row]) -> str:
    lines = ["# Stage 2 shadow: verdict sample for Fable", "",
             "One row per request and claimed role. Check each against the document (Intercom conversation and "
             "file below) and mark agree / disagree. A false `approve` is the failure that blocks go-live.", "",
             "| # | request | user | paid | role | track tier | outcome | best verdict | document | reason | analyzer "
             "| agree? |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1):
        ref = r["source_ref"] or ""
        lines.append(f"| {i} | `{r['request_id']}` | {r['user_id']} | {'yes' if r['paid'] == 1 else 'no'} | "
                     f"{r['role']} | {r['tier']} (pop {r['popularity']}) | **{r['outcome']}** | "
                     f"{r['verdict'] or '-'} | {r['doc_kind'] or '-'} `{ref}` | "
                     f"{(r['reason'] or '').replace('|', '/')[:400]} | {r['analyzer_version'] or '-'} | |")
    return "\n".join(lines) + "\n"


def summary(db: sqlite3.Connection) -> dict[str, Any]:
    rows = db.execute("SELECT s.outcome, s.paid, COUNT(*) FROM stage2_shadow s JOIN (SELECT request_id, role, "
                      "MAX(id) id FROM stage2_shadow WHERE analyzer_version=? GROUP BY request_id, role) l USING(id) "
                      "GROUP BY 1, 2", (FORENSICS_VERSION,)).fetchall()
    out: dict[str, Any] = defaultdict(lambda: {"paid": 0, "free": 0})
    for outcome, paid, n in rows:
        out[outcome]["paid" if paid == 1 else "free"] += n
    return dict(out)
