"""Shadow store for proof forensics (SQLite under /var/lib, mode 0600).

Mirrors what core-backend C1b will hold (`credit_proof_forensics`,
`credit_proof_text_fingerprints`) so the rows can be copied there once it
exists. Append-only: a re-analysis with a new FORENSICS_VERSION adds rows,
it never rewrites old ones. Holds no document text: only signals (with
regions and short non-personal excerpts), hashes and entity hashes.

An UNDETERMINED verdict (a check could not run) is not final: the proof is
analysed again on later runs, up to MAX_ATTEMPTS verdict rows per proof,
submitter, track and request (each claimed role has its own verdict row).
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import FORENSICS_VERSION
from .fingerprint import (MINHASH_FAMILY, MINHASH_MIN_SHINGLES, MINHASH_REUSE, PHASH_MAX_DISTANCE, Fingerprint, hamming, jaccard)
from . import content
from .signals import HARD, INFO, POSITIVE, SOFT, Evidence, Signal
from .verdict import UNDETERMINED

DEFAULT_PATH = os.environ.get("CREDIT_PROOF_STORE",
                              os.path.join(os.environ.get("CREDIT_VERIFY_STATE_DIR", "/var/lib/hydra-credit-verify"),
                                           "proof.sqlite"))
MAX_ATTEMPTS = 3

SCHEMA = """
CREATE TABLE IF NOT EXISTS proofs (
  proof_id TEXT PRIMARY KEY,           -- sha256 of the bytes
  first_seen TEXT NOT NULL,
  source TEXT NOT NULL,                -- intercom | app | test
  source_ref TEXT,                     -- e.g. intercom conversation id / part / file index
  contact_h TEXT,
  mime TEXT,
  bytes INTEGER
);
CREATE TABLE IF NOT EXISTS forensics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  proof_id TEXT NOT NULL,
  analyzer_version TEXT NOT NULL,
  check_id TEXT NOT NULL,
  name TEXT NOT NULL,
  severity TEXT NOT NULL,
  value_json TEXT,
  reason TEXT,
  evidence_json TEXT,
  created_at TEXT NOT NULL,
  request_id TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS fingerprints (
  proof_id TEXT NOT NULL,
  contact_h TEXT,
  kind TEXT, mime TEXT,
  phash TEXT, minhash_json TEXT, n_shingles INTEGER,
  entities_json TEXT,
  track_key TEXT, role_families TEXT,
  claimant_named INTEGER,              -- F5b: 1 named, 0 not named, NULL not checked
  track_listed INTEGER,                -- F5a: submitter's track title/ISRC in the document; NULL not checked
  matched_name_hash TEXT,              -- content.name_hash of the name that matched the claimant; NULL none/unknown
  name_verified INTEGER,               -- 1 that name is a verified identity
  created_at TEXT NOT NULL,
  PRIMARY KEY (proof_id, contact_h, track_key)
);
CREATE TABLE IF NOT EXISTS proof_intake (
  intake_id TEXT PRIMARY KEY,          -- deterministic: <user_id>:<sha256 prefix>, so a re-file is the same row
  user_id INTEGER NOT NULL,            -- the Muso account, matched by a VERIFIED handle, never a name
  subject TEXT NOT NULL,               -- credit | claim (what the document is meant to prove)
  candidate_request_ids_json TEXT NOT NULL DEFAULT '[]',   -- ['<credit request uuid>', ...]
  conversation_id TEXT NOT NULL,       -- the Intercom conversation it arrived in
  source TEXT NOT NULL,                -- intercom | email
  file_sha256 TEXT NOT NULL,           -- the document's identity (its proof id)
  file_path TEXT,                      -- where the bytes are on this host, NULL when only Intercom has them
  mime TEXT, bytes INTEGER,
  received_at TEXT NOT NULL,           -- when the customer sent it (UTC)
  filed_by TEXT NOT NULL,              -- the writer: never a judge
  matched_by TEXT,                     -- professional_id | proof_on_file (how the account was verified)
  contact_h TEXT,                      -- hash of the Intercom contact id; no contact id, email or name is stored
  detail_json TEXT,                    -- candidate request status/basis, per-file provenance
  UNIQUE (user_id, file_sha256)        -- idempotent on (user, document): a re-file is not a second row
);
CREATE INDEX IF NOT EXISTS proof_intake_user ON proof_intake(user_id, conversation_id);
CREATE INDEX IF NOT EXISTS proof_intake_sha ON proof_intake(file_sha256);
CREATE TABLE IF NOT EXISTS verdicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  proof_id TEXT NOT NULL,
  analyzer_version TEXT NOT NULL,
  contact_h TEXT NOT NULL,
  track_key TEXT NOT NULL,
  verdict TEXT NOT NULL,
  reasons_json TEXT,
  context_json TEXT,
  created_at TEXT NOT NULL,
  request_id TEXT NOT NULL DEFAULT ''
);
"""
# Columns added after the first store version: added in place to an existing
# store (old rows read NULL / the default).
MIGRATIONS = (
    ("fingerprints", "claimant_named", "INTEGER"),
    ("fingerprints", "track_listed", "INTEGER"),
    ("fingerprints", "matched_name_hash", "TEXT"),
    ("fingerprints", "name_verified", "INTEGER"),
    ("forensics", "request_id", "TEXT NOT NULL DEFAULT ''"),
    ("verdicts", "contact_h", "TEXT NOT NULL DEFAULT ''"),
    ("verdicts", "track_key", "TEXT NOT NULL DEFAULT ''"),
    ("verdicts", "request_id", "TEXT NOT NULL DEFAULT ''"),
)
INDEXES = """
CREATE INDEX IF NOT EXISTS forensics_proof ON forensics(proof_id, analyzer_version);
CREATE INDEX IF NOT EXISTS verdicts_key ON verdicts(proof_id, analyzer_version, contact_h, track_key, request_id);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class ProofStore:
    def __init__(self, path: str | None = None):
        self.path = path or DEFAULT_PATH
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if not os.path.exists(self.path):
                os.close(os.open(self.path, os.O_CREAT | os.O_WRONLY, 0o600))
        self.db = sqlite3.connect(self.path, timeout=30, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.db.executescript(SCHEMA)
        for table, column, decl in MIGRATIONS:
            have = {r["name"] for r in self.db.execute(f"PRAGMA table_info({table})")}
            if column not in have:
                self.db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
        self.db.executescript(INDEXES)
        # `filed_documents` was a draft intake table (d2); `proof_intake` is the contract
        # (proof-loop lead 2026-10-27). Dropped only while EMPTY, so no filing can be lost.
        if self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='filed_documents'").fetchone() \
                and self.db.execute("SELECT COUNT(*) FROM filed_documents").fetchone()[0] == 0:
            self.db.execute("DROP TABLE filed_documents")
        self.db.commit()

    readonly = False

    @classmethod
    def for_run(cls, path: str | None, apply: bool) -> "ProofStore":
        """The store a `file` run uses. --apply opens it for writing (schema + migrations).
        A dry run opens it READ-ONLY (mode=ro: no schema, no index, no migration, no drop) so a
        count-only run cannot change the production database (QA #1417); a store that does not
        exist yet is replaced by an in-memory one, so nothing is created on disk either."""
        if apply:
            return cls(path)
        p = path or DEFAULT_PATH
        if not os.path.exists(p):
            return cls(":memory:")
        self = cls.__new__(cls)
        self.path = p
        self.db = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.readonly = True
        return self

    def close(self) -> None:
        self.db.close()

    def analyzed(self, proof_id: str, contact_h: str, track_key: str | None, request_id: str = "") -> bool:
        """True once this proof from this submitter for this track and request
        has a final verdict under FORENSICS_VERSION, or came out UNDETERMINED
        MAX_ATTEMPTS times."""
        with self.lock:
            rows = self.db.execute("SELECT verdict FROM verdicts WHERE proof_id=? AND analyzer_version=? AND "
                                   "contact_h=? AND track_key=? AND request_id=?",
                                   (proof_id, FORENSICS_VERSION, contact_h, track_key or "", request_id)).fetchall()
        undetermined = sum(1 for r in rows if r["verdict"] == UNDETERMINED)
        return len(rows) > undetermined or undetermined >= MAX_ATTEMPTS

    def record(self, *, fp: Fingerprint, source: str, source_ref: str, nbytes: int, signals: list[Signal],
               verdict: str | None, reasons: list[str], context: dict[str, Any], request_id: str = "") -> None:
        """`verdict` None stores the file's forensics without a verdict row."""
        now = utcnow()
        with self.lock:
            self.db.execute("INSERT OR IGNORE INTO proofs (proof_id, first_seen, source, source_ref, contact_h, mime, "
                            "bytes) VALUES (?,?,?,?,?,?,?)",
                            (fp.proof_id, now, source, source_ref, fp.contact_h, fp.mime, nbytes))
            self.db.execute("INSERT OR REPLACE INTO fingerprints (proof_id, contact_h, kind, mime, phash, "
                            "minhash_json, n_shingles, entities_json, track_key, role_families, claimant_named, "
                            "track_listed, matched_name_hash, name_verified, created_at) "
                            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            (fp.proof_id, fp.contact_h, fp.kind, fp.mime,
                             None if fp.phash is None else format(fp.phash, "016x"), json.dumps(fp.minhash),
                             fp.n_shingles, json.dumps(fp.entities), fp.track_key or "", ",".join(fp.role_families),
                             None if fp.claimant_named is None else int(fp.claimant_named),
                             None if fp.track_listed is None else int(fp.track_listed), fp.name_h,
                             None if fp.name_verified is None else int(fp.name_verified), now))
            self.db.executemany(
                "INSERT INTO forensics (proof_id, analyzer_version, check_id, name, severity, value_json, reason, "
                "evidence_json, created_at, request_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
                [(fp.proof_id, FORENSICS_VERSION, s.check, s.name, s.severity, json.dumps(s.value, default=str),
                  s.reason, json.dumps(s.evidence.as_dict() if s.evidence else None), now, request_id)
                 for s in signals])
            if verdict is not None:
                self.db.execute("INSERT INTO verdicts (proof_id, analyzer_version, contact_h, track_key, verdict, "
                                "reasons_json, context_json, created_at, request_id) VALUES (?,?,?,?,?,?,?,?,?)",
                                (fp.proof_id, FORENSICS_VERSION, fp.contact_h, fp.track_key or "", verdict,
                                 json.dumps(reasons), json.dumps(context), now, request_id))
            self.db.commit()

    def known_proofs(self) -> set[str]:
        """Every proof id the store already holds, from either intake path (H3 analysis or
        this intake): a re-filed document is a duplicate, never a second analysis."""
        with self.lock:
            rows = self.db.execute("SELECT proof_id FROM proofs").fetchall()
            intake = self.db.execute("SELECT file_sha256 FROM proof_intake").fetchall()
        return {r[0] for r in rows} | {r[0] for r in intake}

    def already_filed(self, user_id: int, file_sha256: str) -> bool:
        """The intake's own idempotency key: (user, document)."""
        with self.lock:
            try:
                return self.db.execute("SELECT 1 FROM proof_intake WHERE user_id=? AND file_sha256=?",
                                       (int(user_id), file_sha256)).fetchone() is not None
            except sqlite3.OperationalError:
                if self.readonly:
                    return False             # a read-only dry run over a store without the table yet
                raise

    def missing_candidates(self, user_id: int, file_sha256: str, request_ids: list[str]) -> list[str]:
        """The request ids not yet candidates on the (user, document) filing."""
        with self.lock:
            try:
                row = self.db.execute("SELECT candidate_request_ids_json FROM proof_intake WHERE user_id=? "
                                      "AND file_sha256=?", (int(user_id), file_sha256)).fetchone()
            except sqlite3.OperationalError:
                if self.readonly:
                    return []
                raise
        if row is None:
            return []
        try:
            have = {str(x) for x in json.loads(row[0] or "[]")}
        except ValueError:
            have = set()
        return [str(r) for r in dict.fromkeys(request_ids) if str(r) not in have]

    def add_candidates(self, user_id: int, file_sha256: str, request_ids: list[str]) -> bool:
        """Merge newly open candidate requests into an existing filing (union, never a
        removal: a request that closed is skipped by the reader, not erased here). True
        when the row changed."""
        if self.readonly:
            raise RuntimeError("read-only proof store: add_candidates needs --apply")
        new = self.missing_candidates(user_id, file_sha256, request_ids)
        if not new:
            return False
        with self.lock:
            row = self.db.execute("SELECT candidate_request_ids_json FROM proof_intake WHERE user_id=? AND file_sha256=?",
                                  (int(user_id), file_sha256)).fetchone()
            try:
                have = [str(x) for x in json.loads(row[0] or "[]")]
            except ValueError:
                have = []
            self.db.execute("UPDATE proof_intake SET candidate_request_ids_json=? WHERE user_id=? AND file_sha256=?",
                            (json.dumps(have + new), int(user_id), file_sha256))
            self.db.commit()
        return True

    def file_document(self, *, file_sha256: str, user_id: int, conversation_id: str, subject: str = "credit",
                      candidate_request_ids: list[str] | None = None, source: str = "intercom",
                      file_path: str | None = None, received_at: str = "", filed_by: str = "credit-proof.py file",
                      matched_by: str = "", contact_h: str = "", mime: str | None = None, nbytes: int = 0,
                      detail: Any = None) -> str | None:
        """Record a document the customer sent: the account, the subject, the candidate credit
        requests, the conversation it arrived in and its sha256 - and NOTHING else. No
        forensics row, no fingerprint, no verdict: judgement is H3's and doc-verify's. The
        contract is the proof-loop lead's `proof_intake` row (one per file, idempotent on
        (user_id, sha256), writers never judge). Returns the intake id, or None when the row
        already existed."""
        if self.readonly:
            raise RuntimeError("read-only proof store: file_document needs --apply")
        intake_id = f"{int(user_id)}:{file_sha256[:32]}"
        with self.lock:
            cur = self.db.execute(
                "INSERT OR IGNORE INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                " conversation_id, source, file_sha256, file_path, mime, bytes, received_at, filed_by,"
                " matched_by, contact_h, detail_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (intake_id, int(user_id), subject,
                 json.dumps([str(r) for r in (candidate_request_ids or [])]), str(conversation_id), source,
                 file_sha256, file_path, mime, int(nbytes or 0), received_at or utcnow(), filed_by,
                 matched_by, contact_h or "", json.dumps(detail, default=str)))
            self.db.commit()
            return intake_id if cur.rowcount > 0 else None

    def _prior(self) -> list[Fingerprint]:
        with self.lock:
            rows = self.db.execute("SELECT * FROM fingerprints").fetchall()
        return [_fingerprint(r) for r in rows]

    def remember(self, prior: list[Fingerprint], fp: Fingerprint) -> None:
        """Bring a _prior() list in step with record(fp): the stored row
        replaces any earlier one under the same key and moves last, as
        INSERT OR REPLACE does."""
        with self.lock:
            row = self.db.execute("SELECT * FROM fingerprints WHERE proof_id=? AND contact_h=? AND track_key=?",
                                  (fp.proof_id, fp.contact_h, fp.track_key or "")).fetchone()
        if row is None:
            return
        new = _fingerprint(row)
        prior[:] = [p for p in prior if (p.proof_id, p.contact_h, p.track_key)
                    != (new.proof_id, new.contact_h, new.track_key)] + [new]

    def reuse_signals(self, fp: Fingerprint, path: str, linked: bool = False,
                      prior: list[Fingerprint] | None = None) -> list[Signal]:
        """Compare with every earlier proof from ANY account (removed and
        fraud requests included: the store never deletes). Matches are
        grouped by the other account, which yields at most one reuse signal
        (cross_account) however many tracks it used the document for.
        `prior`: the stored fingerprints already loaded (_prior()), kept in
        step with record() by the caller."""
        out: list[Signal] = []
        families: set[str] = set()
        accounts: dict[str, dict[str, Any]] = {}
        for other in (self._prior() if prior is None else prior):
            if other.proof_id == fp.proof_id and other.contact_h == fp.contact_h and other.track_key == fp.track_key:
                continue          # this very proof (re-analysis)
            same_contact = bool(fp.contact_h) and other.contact_h == fp.contact_h
            how = None
            if other.proof_id == fp.proof_id:
                how = "identical_file"
            elif fp.mime.startswith("image/") and other.mime.startswith("image/") and fp.phash is not None \
                    and other.phash is not None and hamming(fp.phash, other.phash) <= PHASH_MAX_DISTANCE:
                # Images only: rendered document pages look alike (white page,
                # text) - documents are compared by text + entities.
                how = "near_identical_image"
            elif fp.n_shingles >= MINHASH_MIN_SHINGLES and other.n_shingles >= MINHASH_MIN_SHINGLES:
                j = jaccard(fp.minhash, other.minhash)
                overlap = fp.entity_overlap(other) if j >= MINHASH_FAMILY else []
                if j >= MINHASH_REUSE and overlap:
                    how = "same_text_and_entities"
                elif j >= MINHASH_FAMILY and not same_contact and other.contact_h:
                    families.add(other.contact_h)
            if how is None:
                continue
            if same_contact:
                out.append(Signal("F2", "reupload_same_account", INFO, value={"how": how},
                                  evidence=Evidence(file=path, tool="credit_verify.fingerprint",
                                                    excerpt=f"matches proof {other.proof_id[:12]}")))
                continue
            acc = accounts.setdefault(other.contact_h, {"how": set(), "tracks": set(), "proof": other.proof_id,
                                                        "names": set(), "verified": set()})
            acc["how"].add(how)
            acc["tracks"].add(other.track_key or "")
            if other.claimant_named:
                acc["names"].add(other.name_h)
                if other.name_verified:
                    acc["verified"].add(other.name_h)
            if how == "identical_file":
                acc["proof"] = other.proof_id
        for acc in accounts.values():
            out.extend(cross_account(fp, acc["how"], acc["tracks"], linked,
                                     Evidence(file=path, tool="credit_verify.fingerprint",
                                              excerpt=f"matches proof {acc['proof'][:12]}"),
                                     acc["names"], acc["verified"]))
        if len(families) >= 2:
            out.append(Signal("F2b", "template_family", INFO, value={"other_accounts": len(families)},
                              evidence=Evidence(file=path, tool="credit_verify.fingerprint")))
        # One signal per kind is enough for the verdict and the audit.
        seen: set[str] = set()
        uniq = []
        for s in out:
            if s.name not in seen:
                seen.add(s.name)
                uniq.append(s)
        return uniq


def _fingerprint(r: sqlite3.Row) -> Fingerprint:
    return Fingerprint(proof_id=r["proof_id"], contact_h=r["contact_h"] or "", kind=r["kind"] or "",
                       mime=r["mime"] or "", phash=int(r["phash"], 16) if r["phash"] else None,
                       minhash=json.loads(r["minhash_json"] or "[]"), n_shingles=r["n_shingles"] or 0,
                       entities=json.loads(r["entities_json"] or "{}"),
                       track_key=r["track_key"] or None,
                       role_families=[x for x in (r["role_families"] or "").split(",") if x],
                       claimant_named=None if r["claimant_named"] is None else bool(r["claimant_named"]),
                       track_listed=None if r["track_listed"] is None else bool(r["track_listed"]),
                       name_h=r["matched_name_hash"],
                       name_verified=None if r["name_verified"] is None else bool(r["name_verified"]))


def cross_account(fp: Fingerprint, hows: set[str], tracks: set[str], linked: bool, ev: Evidence,
                  other_names: set[str | None] = frozenset(), other_verified: set[str | None] = frozenset()
                  ) -> list[Signal]:
    """Another account sent this document (`hows`: how it matched; `tracks`:
    the tracks that account used it for; `other_names`: the name hashes that
    account was matched under, None when unknown; `other_verified`: those that
    were verified identities). One rule, for the same track and
    for other tracks alike, judged on what the document says about THIS
    submitter's claim (one claimed role; each fact None when its check could
    not run):

      the name check ran and the document doesn't name the submitter
                                                -> hard: a stolen document,
                                                   on the same track or another;
      the very same file (byte-identical), naming the submitter, listing their
      track and their role                       -> positive: co-writers
                                                   sharing one split sheet, or
                                                   one document covering
                                                   several tracks;
      the submitter matched under the SAME name as the other account (or the
      other account's name is unknown)           -> soft: two accounts
                                                   presenting one credited
                                                   person; plus soft
                                                   impersonation_suspected when
                                                   the other matched it as a
                                                   verified identity and this
                                                   one only as a self-declared
                                                   name;
      a separate copy of the same PUBLIC page (PRO registration, catalog
      credits page) for a linked claim, naming the submitter (under a
      different name) and listing their track    -> info: the same as the very
                                                   same file (co-writers each
                                                   screenshot one page);
      the very same file for a linked claim, naming the submitter but not
      listing their track                        -> soft, for review;
      the very same file for a linked claim otherwise (a name check that
      could not run, a role it doesn't show)     -> info: the content checks
                                                   decide (PLAUSIBLE, or the
                                                   role's own soft signal),
                                                   the same for every uploader;
      anything else (no claim linked, an edited near-copy of a private
      document)
                                                -> soft, for review.

    A named claimant verdict never depends on upload order, with one documented exception: when two accounts
    present the same credited name (or an unknown name), the later one is held for review. An unnamed uploader
    verdict can: INCONSISTENT when uploaded before the owner, FORGED_LIKELY after. A document that cannot express the claimed role never proves
    it. An empty track (an Intercom/email shadow row) is unknown, never another track.
    """
    roles = fp.document_roles
    role_listed = content.role_listed(roles, fp.role_families)
    known = {t for t in tracks if t}
    same_track = bool(fp.track_key) and fp.track_key in known
    other_track = bool(fp.track_key) and bool(known) and not same_track
    value = {"how": sorted(hows), "tracks": len(tracks),
             "same_track": same_track if (same_track or other_track) else None}
    reused = Signal("F2", "reused_by_another_account", SOFT, value=value, evidence=ev)
    if fp.claimant_named is False:
        if other_track:
            return [Signal("F2", "reused_on_another_track", HARD, value=value,
                           reason="This document was already submitted by another account for a different track.",
                           evidence=ev)]
        return [Signal("F2", "reused_by_another_account_same_claim", HARD, value=value,
                       reason=("This document was already submitted by another account for the same credit."
                               if same_track else "This document was already submitted by another account."),
                       evidence=ev)]
    public_copy = fp.kind in content.PUBLIC_KINDS and bool(hows & {"same_text_and_entities", "near_identical_image"})
    if linked and fp.claimant_named and ("identical_file" in hows or public_copy) \
            and (fp.name_h is None or None in other_names or fp.name_h in other_names):
        out = [Signal("F2", "reused_by_another_account", SOFT, value={**value, "same_name": True}, evidence=ev)]
        if fp.name_h in other_verified and not fp.name_verified:
            out.append(Signal("F2", "impersonation_suspected", SOFT, value=value,
                              reason="Another account already showed this page under a verified identity "
                                     "with the same name.", evidence=ev))
        return out
    if "identical_file" in hows and linked:
        if fp.claimant_named and fp.track_listed and role_listed:
            return [Signal("F2", "shared_multi_track_document" if other_track else "shared_split_sheet", POSITIVE,
                           value={**value, "roles": sorted(roles)}, evidence=ev)]
        if fp.claimant_named is None:
            return [Signal("F2", "shared_document_claimant_undetermined", INFO, value=value, evidence=ev)]
        if fp.track_listed:
            return [Signal("F2", "shared_document_role_undetermined", INFO,
                           value={**value, "roles": sorted(roles), "role_listed": role_listed}, evidence=ev)]
    if linked and public_copy and fp.claimant_named and fp.track_listed:
        return [Signal("F2", "shared_public_page", INFO, value=value, evidence=ev)]
    return [reused]
