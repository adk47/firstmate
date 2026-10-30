"""Doc-verify's own append-only store. It reads the H3 proof store read-only
and writes only here, so it can never disturb stage 2 or the H3 crons.

Tables:
  dv_steps     one row per step per document and claim (extract, forensics,
               each cross-check, gate): status + detail. "Every step logged."
  dv_outcomes  one row per document, request and role: the outcome, its
               reason, the stronger-proof code for `unverifiable`, the account
               hold flag. The latest row per (proof, request, role, version)
               stands.
  dv_llm_calls one row per model call: model, prompt sha256, tokens, cost,
               outcome. The daily spend cap is read from here.
  dv_state     key/value (the `since` cutoff of the first run).

No document text is stored: extracted fields are, because they ARE the
claims being verified (issuer, signatory, sender domain, titles, roles).
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any

from . import CARRY, VERSION

MAX_UNKNOWN = 3
# 2026-10-29 22:00-01:05Z: the model provider answered HTTP 402 (out of credit) for ~3 h; every read became
# `unknown` and 3,521 claims (85 documents) used up MAX_UNKNOWN and settled with no real read. An ACCOUNT-WIDE
# refusal (credit, auth, rate limit, our own spend cap, no key) can never be about the DOCUMENT: it never uses a
# retry, never settles a claim, and the reader stops the run at the first one (runner.ProviderDown). A timeout or a
# 5xx can be the document (an oversized prompt), so those keep counting: a file that always times out must settle,
# never stall every run. Document-specific failures (an unusable answer, a file we cannot locate) still count.
PROVIDER_DOWN = re.compile(r"\b(http (401|402|403|429)\b|daily model spend cap|no OpenRouter key)")


def provider_down(reason: str | None) -> bool:
    """True when an `unknown` outcome / extract error was the provider or network, not the document."""
    return bool(reason) and bool(PROVIDER_DOWN.search(str(reason)))


class RawCreditsLockError(RuntimeError):
    """The cross-process raw-credits lock cannot be taken; the admin GET is not made."""


RAW_CREDITS_TTL_S = float(os.environ.get("CREDIT_DOC_VERIFY_RAW_CREDITS_TTL_S", str(6 * 3600)))
DEFAULT_PATH = os.environ.get("CREDIT_DOC_VERIFY_STORE", "/var/lib/hydra-credit-verify/doc-verify.sqlite")

SCHEMA = """
CREATE TABLE IF NOT EXISTS dv_steps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  proof_id TEXT NOT NULL,
  request_id TEXT NOT NULL DEFAULT '',   -- '<uuid>#<role>' as in the H3 verdicts; '' = whole document
  step TEXT NOT NULL,                    -- locate | text | extract | forensics | xc_dsp | xc_isrc | xc_label | xc_domain | xc_signatory | gate
  status TEXT NOT NULL,                  -- ok | positive | contradicts | weak | unknown | error | skipped
  detail_json TEXT NOT NULL,
  version TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS dv_steps_proof ON dv_steps(proof_id, request_id);
CREATE TABLE IF NOT EXISTS dv_outcomes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  proof_id TEXT NOT NULL,
  request_id TEXT NOT NULL,              -- credit request uuid
  role TEXT NOT NULL,
  user_id INTEGER,
  source_ref TEXT,
  h3_verdict TEXT,
  outcome TEXT NOT NULL,                 -- verified | contradicted | forged | unverifiable
  reason TEXT NOT NULL,
  need TEXT,                             -- stronger-proof code for unverifiable
  account_hold INTEGER NOT NULL DEFAULT 0,
  detail_json TEXT NOT NULL,
  version TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS dv_out_key ON dv_outcomes(proof_id, request_id, role, version);
CREATE INDEX IF NOT EXISTS dv_out_user ON dv_outcomes(user_id);
CREATE TABLE IF NOT EXISTS dv_llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  proof_id TEXT,
  model TEXT,
  outcome TEXT NOT NULL,                 -- ok | error | skipped | cached (dv_extract_cache, no call)
  reason TEXT,
  prompt_sha256 TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cost_usd REAL,
  latency_ms INTEGER
);
CREATE TABLE IF NOT EXISTS dv_state (k TEXT PRIMARY KEY, v TEXT NOT NULL);
-- The model's answer per exact prompt (extract.py): the same document text + facts asked again within the
-- TTL reuses the answer instead of a second call. Untruncated; only answers that validated are stored.
CREATE TABLE IF NOT EXISTS dv_extract_cache (prompt_sha256 TEXT PRIMARY KEY, at REAL NOT NULL, model TEXT NOT NULL,
  call_id INTEGER, answer_json TEXT NOT NULL);
-- F9 challenge codes (challenge.py): one active code per request, issued when h2 sends the per-need ask.
CREATE TABLE IF NOT EXISTS dv_challenges (id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL,
  user_id INTEGER, code TEXT NOT NULL UNIQUE, issued_at TEXT NOT NULL, expires_at TEXT NOT NULL,
  consumed_at TEXT, consumed_by TEXT);
CREATE INDEX IF NOT EXISTS dv_challenges_request ON dv_challenges(request_id);
-- Muso's stored raw credits per track, shared by every reader process (one admin GET per track per
-- TTL instead of one per document): an account's documents usually name the same tracks.
CREATE TABLE IF NOT EXISTS dv_raw_credits (track_id TEXT PRIMARY KEY, at TEXT NOT NULL, items_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS dv_lookup_cache (kind TEXT NOT NULL, key TEXT NOT NULL, at REAL NOT NULL, value_json TEXT NOT NULL,
  PRIMARY KEY (kind, key));
CREATE TABLE IF NOT EXISTS dv_archive_cache (domain TEXT PRIMARY KEY, at REAL NOT NULL, first_capture TEXT);
-- D2: a filing's candidate requests and claim keys as the last run saw them, UNTRUNCATED (dv_steps
-- detail is capped at 20,000 chars; a 40-request filing overflowed it and broke selection).
-- Claim keys of a filing the document does not name (fan-out cut, > FANOUT candidate requests):
-- recorded once, no pair row, finished.
CREATE TABLE IF NOT EXISTS dv_intake_unmatched (intake_id TEXT NOT NULL, version TEXT NOT NULL, at TEXT NOT NULL,
  keys_json TEXT NOT NULL, PRIMARY KEY (intake_id, version));
CREATE TABLE IF NOT EXISTS dv_intake_keys (intake_id TEXT NOT NULL, version TEXT NOT NULL, at TEXT NOT NULL,
  candidates_json TEXT NOT NULL, keys_json TEXT NOT NULL, PRIMARY KEY (intake_id, version));
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class DocVerifyStore:
    @classmethod
    def read_only(cls, path: str | None = None) -> "DocVerifyStore":
        """For reports (trays, lists, counts): mode=ro - never creates the file, runs no schema change, ALTER
        or carry-forward (QA #1470). Any write raises sqlite3.OperationalError."""
        self = cls.__new__(cls)
        self.path = path or DEFAULT_PATH
        if not os.path.exists(self.path):
            raise FileNotFoundError(f"doc-verify store not found: {self.path}")
        self.db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, timeout=60, check_same_thread=False)
        self.lock = threading.Lock()
        return self

    def __init__(self, path: str | None = None):
        self.path = path or DEFAULT_PATH
        d = os.path.dirname(self.path)
        if d:
            os.makedirs(d, exist_ok=True)
        fresh = not os.path.exists(self.path)
        self.db = sqlite3.connect(self.path, timeout=60, check_same_thread=False)
        if fresh:
            os.chmod(self.path, 0o600)
        if self.path != ":memory:":
            self.db.execute("PRAGMA journal_mode=WAL")      # parallel readers (run --workers) write concurrently
        self.db.executescript(SCHEMA)
        # D2 (2026-10-27): outcomes of documents filed in proof_intake are keyed by intake_id too.
        if "intake_id" not in {r[1] for r in self.db.execute("PRAGMA table_info(dv_outcomes)")}:
            self.db.execute("ALTER TABLE dv_outcomes ADD COLUMN intake_id TEXT")
            self.db.commit()
        self.db.execute("CREATE INDEX IF NOT EXISTS dv_out_intake ON dv_outcomes(intake_id)")
        self.lock = threading.Lock()
        if VERSION in CARRY:
            prev, reread, steps, *more = CARRY[VERSION]
            self.carry_forward(prev, VERSION, reread, steps, *(more or [None]))

    def carry_forward(self, prev: str, cur: str, reread: frozenset[str] | None,
                      steps: tuple[str, ...] = (), detail: tuple[str, tuple[str, ...]] | None = None) -> int:
        """A VERSION bump (proof-loop lead 075): copy the rows of every document whose standing `prev`
        outcomes include none of `reread` to `cur`, once, in one transaction (parallel readers open the
        store together). Copies keep their run, time and order, so the latest row stays the latest, and
        are marked detail.carried_from = {version, id}. A document whose `prev` run RAN one of `steps`
        (a dv_steps row with a status other than skipped) is re-read too. Every other document has no
        `cur` row and is re-read by the deployed reader. `detail=(step, names)`: a document whose `prev`
        `step` row's detail contains any of `names` (as a JSON string, e.g. a forensic signal name) is
        re-read too. `reread=None` carries nothing (a full re-read). Returns rows copied."""
        key = f"carried:{prev}->{cur}"
        doc = "coalesce(intake_id, proof_id)"
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                if self.db.execute("SELECT 1 FROM dv_state WHERE k=?", (key,)).fetchone():
                    self.db.rollback()
                    return 0
                n = 0
                if reread is not None:
                    marks = ",".join("?" * len(reread)) or "''"
                    smarks = ",".join("?" * len(steps)) or "''"
                    keep = (f"version=? AND {doc} NOT IN (SELECT {doc} FROM dv_outcomes WHERE id IN "
                            f"(SELECT MAX(id) FROM dv_outcomes WHERE version=? GROUP BY coalesce(intake_id, ''), "
                            f"proof_id, request_id, role) AND outcome IN ({marks})) "
                            f"AND proof_id NOT IN (SELECT proof_id FROM dv_steps WHERE version=? AND step IN ({smarks}) "
                            f"AND status <> 'skipped')")
                    args = [prev, prev, *sorted(reread), prev, *steps]
                    if detail and detail[1]:
                        likes = " OR ".join("instr(detail_json, ?) > 0" for _ in detail[1])
                        # ANY earlier version's step: a carried document has only the steps of the version
                        # that read it (dv-2 carried dv-1 documents without copying their steps)
                        keep += (" AND proof_id NOT IN (SELECT proof_id FROM dv_steps WHERE version<>? AND step=? "
                                 f"AND ({likes}))")
                        # the bare name: a finding ("h3_<name>", "<name>") or an H3 reason ("F2 <name>");
                        # a broader match only sends more documents back to the reader, never fewer
                        args += [cur, detail[0], *detail[1]]
                    n = self.db.execute(
                        "INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, source_ref, h3_verdict, "
                        "outcome, reason, need, account_hold, detail_json, version, intake_id) "
                        "SELECT run_id, at, proof_id, request_id, role, user_id, source_ref, h3_verdict, outcome, reason, "
                        "need, account_hold, CASE WHEN json_valid(detail_json) THEN json_set(detail_json, '$.carried_from', "
                        "json_object('version', version, 'id', id)) ELSE detail_json END, ?, intake_id "
                        f"FROM dv_outcomes WHERE {keep} ORDER BY id", [cur, *args]).rowcount
                    ids = "SELECT DISTINCT intake_id FROM dv_outcomes WHERE version=? AND intake_id IS NOT NULL"
                    for table, cols in (("dv_intake_keys", "at, candidates_json, keys_json"),
                                        ("dv_intake_unmatched", "at, keys_json")):
                        self.db.execute(f"INSERT OR IGNORE INTO {table} (intake_id, version, {cols}) "
                                        f"SELECT intake_id, ?, {cols} FROM {table} WHERE version=? AND intake_id IN "
                                        f"({ids})", (cur, prev, cur))
                self.db.execute("INSERT INTO dv_state (k, v) VALUES (?, ?)",
                                (key, json.dumps({"at": utcnow(), "rows": n, "reread": sorted(reread or []),
                                                  "reread_steps": list(steps),
                                                  "reread_detail": [detail[0], len(detail[1])] if detail else None})))
                self.db.commit()
                return n
            except BaseException:
                self.db.rollback()
                raise

    def awaiting_reread(self) -> int:
        """Documents with rows only under an older VERSION: read under a superseded rule, not yet re-read.
        Their old outcomes stand in no tray (latest_outcomes reads the current VERSION only)."""
        return self.db.execute(
            "SELECT count(DISTINCT coalesce(intake_id, proof_id)) FROM dv_outcomes WHERE version<>? AND "
            "coalesce(intake_id, proof_id) NOT IN (SELECT coalesce(intake_id, proof_id) FROM dv_outcomes WHERE version=?)",
            (VERSION, VERSION)).fetchone()[0]

    # -- state ---------------------------------------------------------------
    def get_state(self, k: str) -> str | None:
        row = self.db.execute("SELECT v FROM dv_state WHERE k=?", (k,)).fetchone()
        return row[0] if row else None

    def set_state_once(self, k: str, v: str) -> str:
        """Set `k` only if it is unset; return the value that stands."""
        with self.lock, self.db:
            self.db.execute("INSERT OR IGNORE INTO dv_state (k, v) VALUES (?, ?)", (k, v))
        return self.get_state(k) or v

    # -- writes --------------------------------------------------------------
    def step(self, run_id: str, proof_id: str, step: str, status: str, detail: dict[str, Any],
             request_id: str = "") -> None:
        with self.lock, self.db:
            self.db.execute("INSERT INTO dv_steps (run_id, at, proof_id, request_id, step, status, detail_json, version)"
                            " VALUES (?,?,?,?,?,?,?,?)",
                            (run_id, utcnow(), proof_id, request_id, step, status,
                             json.dumps(detail, default=str, ensure_ascii=False)[:20_000], VERSION))

    def outcome(self, run_id: str, *, proof_id: str, request_id: str, role: str, user_id: int | None,
                source_ref: str | None, h3_verdict: str | None, outcome: str, reason: str, need: str | None,
                account_hold: bool, detail: dict[str, Any], intake_id: str | None = None) -> None:
        with self.lock, self.db:
            self.db.execute(
                "INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, source_ref, h3_verdict,"
                " outcome, reason, need, account_hold, detail_json, version, intake_id)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, utcnow(), proof_id, request_id, role, user_id, source_ref, h3_verdict, outcome,
                 reason[:600], need, int(account_hold), json.dumps(detail, default=str, ensure_ascii=False)[:20_000],
                 VERSION, intake_id))

    def llm_call(self, row: dict[str, Any]) -> int:
        with self.lock, self.db:
            cur = self.db.execute("INSERT INTO dv_llm_calls (at, proof_id, model, outcome, reason, prompt_sha256,"
                                  " input_tokens, output_tokens, cost_usd, latency_ms) VALUES (?,?,?,?,?,?,?,?,?,?)",
                                  (utcnow(), row.get("proof_id"), row.get("model"), row["outcome"], row.get("reason"),
                                   row.get("prompt_sha256"), row.get("input_tokens"), row.get("output_tokens"),
                                   row.get("cost_usd"), row.get("latency_ms")))
            return int(cur.lastrowid)

    def cached_answer(self, prompt_sha256: str, model: str, ttl_s: float, now: float) -> tuple[Any, int | None, float] | None:
        """(answer, call id, age s) of a validated answer to this exact prompt by this model within `ttl_s`."""
        row = self.db.execute("SELECT at, call_id, answer_json FROM dv_extract_cache WHERE prompt_sha256=? AND model=?",
                              (prompt_sha256, model)).fetchone()
        if not row or not (now - float(row[0])) < ttl_s:
            return None
        try:
            return json.loads(row[2]), row[1], now - float(row[0])
        except (TypeError, ValueError):
            return None

    def cache_answer(self, prompt_sha256: str, model: str, call_id: int, answer: Any, now: float,
                     ttl_s: float = 24 * 3600) -> None:
        """Store a validated extraction payload (extract.cache_payload, never the raw model answer) and delete
        every row past its TTL, so nothing outlives the cache window (QA #1469)."""
        with self.lock, self.db:
            self.db.execute("DELETE FROM dv_extract_cache WHERE at < ?", (now - ttl_s,))
            self.db.execute("INSERT OR REPLACE INTO dv_extract_cache (prompt_sha256, at, model, call_id, answer_json) "
                            "VALUES (?,?,?,?,?)", (prompt_sha256, now, model, call_id,
                                                   json.dumps(answer, ensure_ascii=False, default=str)))

    def issue_challenge(self, request_id: str, user_id: int | None, now: Any = None) -> dict[str, Any]:
        """The request's active code (unexpired, unconsumed), or a new one. Never two active codes."""
        from . import challenge
        t = now or challenge.now_utc()
        stamp = t.strftime("%Y-%m-%dT%H:%M:%SZ")
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                row = self.db.execute("SELECT id, code, issued_at, expires_at FROM dv_challenges WHERE request_id=? AND "
                                      "consumed_at IS NULL AND expires_at > ? ORDER BY id DESC LIMIT 1",
                                      (request_id, stamp)).fetchone()
                if row:
                    self.db.commit()
                    return {"request_id": request_id, "id": row[0], "code": row[1], "issued_at": row[2],
                            "expires_at": row[3], "new": False}
                for _ in range(5):
                    code = challenge.new_code()
                    try:
                        cur = self.db.execute("INSERT INTO dv_challenges (request_id, user_id, code, issued_at, expires_at) "
                                              "VALUES (?,?,?,?,?)", (request_id, user_id, code, stamp,
                                                                     challenge.expiry(t).strftime("%Y-%m-%dT%H:%M:%SZ")))
                        break
                    except sqlite3.IntegrityError:
                        continue                      # a code already used, ever: draw again
                else:
                    raise RuntimeError("could not draw an unused challenge code")
                self.db.commit()
                return {"request_id": request_id, "id": cur.lastrowid, "code": code, "issued_at": stamp,
                        "expires_at": challenge.expiry(t).strftime("%Y-%m-%dT%H:%M:%SZ"), "new": True}
            except BaseException:
                self.db.rollback()
                raise

    def challenges(self, request_id: str) -> list[dict[str, Any]]:
        return [{"id": i, "user_id": u, "code": c, "issued_at": a, "expires_at": e, "consumed_at": k, "consumed_by": b}
                for i, u, c, a, e, k, b in self.db.execute(
                    "SELECT id, user_id, code, issued_at, expires_at, consumed_at, consumed_by FROM dv_challenges "
                    "WHERE request_id=? "
                    "ORDER BY id", (request_id,))]

    def void_challenge(self, request_id: str, code: str, reason: str = "held_send") -> dict[str, Any]:
        """Retire an issued code whose ask was NOT sent (h2 190: a hold between the gate's preflight and the send).
        Atomic: only this request's code, only while unconsumed; it becomes consumed_by 'void:<reason>', so it can
        never confirm a document and the next `issue` mints a fresh one. A code a document already used is never
        voided (that filing's F9 stands)."""
        why = "".join(ch for ch in str(reason or "held_send") if ch.isalnum() or ch in "_-")[:40] or "held_send"
        with self.lock, self.db:
            n = self.db.execute("UPDATE dv_challenges SET consumed_at=?, consumed_by=? WHERE request_id=? AND code=? "
                                "AND consumed_at IS NULL", (utcnow(), f"void:{why}", request_id, code)).rowcount
            row = self.db.execute("SELECT consumed_by FROM dv_challenges WHERE request_id=? AND code=?",
                                  (request_id, code)).fetchone()
        if n:
            return {"voided": True, "request_id": request_id, "code": code, "consumed_by": f"void:{why}"}
        return {"voided": False, "request_id": request_id, "code": code,
                "why": "no such code for this request" if row is None else f"already consumed by {row[0]}"}

    def consume_challenge(self, challenge_id: int, by: str) -> bool:
        """ATOMIC one-use claim (QA #1476): True when `by` holds the code after this call - it claimed it now, or it
        had already claimed it (the same filing's other roles). False when another filing claimed it first, also
        when two readers race (the conditional UPDATE lets exactly one win; the loser reads the winner back)."""
        with self.lock, self.db:
            self.db.execute("UPDATE dv_challenges SET consumed_at=?, consumed_by=? WHERE id=? AND consumed_at IS NULL",
                            (utcnow(), by, challenge_id))
            row = self.db.execute("SELECT consumed_by FROM dv_challenges WHERE id=?", (challenge_id,)).fetchone()
        return bool(row) and row[0] == by

    # -- reads ---------------------------------------------------------------
    def spent_today_usd(self) -> float:
        day = utcnow()[:10]
        row = self.db.execute("SELECT COALESCE(SUM(cost_usd), 0) FROM dv_llm_calls WHERE substr(at, 1, 10)=?",
                              (day,)).fetchone()
        return float(row[0] or 0)

    def done(self, proof_id: str, request_key: str) -> bool:
        """True when this (proof, '<uuid>#<role>') has a decided outcome under the
        current VERSION. An `unknown` (tooling) outcome is retried, up to
        MAX_UNKNOWN runs; the last one then stands."""
        rid, _, role = request_key.partition("#")
        rows = [o for o, why in self.db.execute("SELECT outcome, reason FROM dv_outcomes WHERE proof_id=? AND "
                                                "request_id=? AND role=? AND version=?", (proof_id, rid, role, VERSION))
                if not (o == "unknown" and provider_down(why))]          # a provider outage is not a try
        return any(o != "unknown" for o in rows) or len(rows) >= MAX_UNKNOWN

    def intake_finished_keys(self, intake_id: str) -> set[str]:
        """Claim keys '<request_id>#<role>' of one filing that need no more runs: a decided
        outcome (anything but `unknown`), or MAX_UNKNOWN unknown outcomes. Per claim, never
        per document (QA #1417): one verified claim does not end a sibling's retries."""
        done: set[str] = set(self.intake_unmatched(intake_id))
        unknown: dict[str, int] = {}
        runs: dict[str, bool] = {}            # run -> did it decide anything for this document?
        for rid, role, outcome, run, why in self.db.execute(
                "SELECT request_id, role, outcome, run_id, reason FROM dv_outcomes WHERE intake_id=? AND version=?",
                (intake_id, VERSION)):
            if outcome == "unknown" and provider_down(why):
                continue                       # a provider outage is not a try (2026-10-29 402 window)
            key = f"{rid}#{role}"
            runs[run] = runs.get(run, False) or outcome != "unknown"
            if outcome != "unknown":
                done.add(key)
            else:
                unknown[key] = unknown.get(key, 0) + 1
        if sum(1 for decided in runs.values() if not decided) >= MAX_UNKNOWN:
            # Per DOCUMENT (proof-loop lead 070): a document-level failure (H3 UNDETERMINED, an unreadable
            # file) gave nothing but `unknown` in MAX_UNKNOWN runs - every claim is finished, so a
            # 200-request account cannot re-read the document and its pairs again and again. Only keys
            # ATTEMPTED at least once are finished: a candidate added later is read before it settles (QA #1448).
            return done | set(unknown)
        return done | {k for k, n in unknown.items() if n >= MAX_UNKNOWN}

    def record_intake_unmatched(self, intake_id: str, keys: list[str]) -> None:
        with self.lock, self.db:
            have = self.intake_unmatched(intake_id)
            self.db.execute("INSERT OR REPLACE INTO dv_intake_unmatched (intake_id, version, at, keys_json) "
                            "VALUES (?,?,?,?)", (intake_id, VERSION, utcnow(), json.dumps(sorted(set(have) | set(keys)))))

    def intake_unmatched(self, intake_id: str) -> list[str]:
        row = self.db.execute("SELECT keys_json FROM dv_intake_unmatched WHERE intake_id=? AND version=?",
                              (intake_id, VERSION)).fetchone()
        try:
            return list(json.loads(row[0])) if row else []
        except (TypeError, ValueError):
            return []

    def record_intake_keys(self, intake_id: str, candidates: list[str], keys: list[str]) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO dv_intake_keys (intake_id, version, at, candidates_json, keys_json) "
                            "VALUES (?,?,?,?,?)", (intake_id, VERSION, utcnow(), json.dumps(sorted(candidates)),
                                                   json.dumps(keys)))

    def cached_lookup(self, kind: str, key: str, fetch: Any, *, ok: Any = lambda v: True, ttl_s: float = 24 * 3600,
                      now: Any = None) -> Any:
        """A public lookup (MusicBrainz issuer domains, ISRC release facts, artist search) through a 24 h cache
        shared by every reader (Fable 149: MusicBrainz 1/s host-wide is the reading bound). `fetch()` is called
        on a miss; its value is stored only when `ok(value)` (an answer carrying an error is asked again next time).
        A fetch that raises is never cached and propagates. Expired rows are deleted on write."""
        import time as _t
        t = _t.time() if now is None else now
        row = self.db.execute("SELECT at, value_json FROM dv_lookup_cache WHERE kind=? AND key=?", (kind, key)).fetchone()
        if row and t - float(row[0]) < ttl_s:
            try:
                return json.loads(row[1])
            except ValueError:
                pass
        value = fetch()
        if ok(value):
            with self.lock, self.db:
                self.db.execute("DELETE FROM dv_lookup_cache WHERE at < ?", (t - ttl_s,))
                self.db.execute("INSERT OR REPLACE INTO dv_lookup_cache (kind, key, at, value_json) VALUES (?,?,?,?)",
                                (kind, key, t, json.dumps(value, default=str)))
        return value

    def cached_first_capture(self, domain: str, fetch: Any, ttl_s: float = 24 * 3600, now: Any = None) -> str | None:
        """The web archive's first capture of `domain` ('YYYYMMDDhhmmss', or None when it has none) through a
        24 h cache shared by every reader (Fable 140). A fetch that raises is not cached and propagates."""
        import time as _t
        t = _t.time() if now is None else now
        row = self.db.execute("SELECT at, first_capture FROM dv_archive_cache WHERE domain=?", (domain,)).fetchone()
        if row and t - float(row[0]) < ttl_s:
            return row[1]
        first = fetch(domain)
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO dv_archive_cache (domain, at, first_capture) VALUES (?,?,?)",
                            (domain, t, first))
        return first

    def cached_raw_credits(self, track_id: str, fetch: Any, ttl_s: float = RAW_CREDITS_TTL_S,
                           now: Any = None) -> list[dict[str, Any]]:
        """`fetch(track_id)` through a cache shared by every reader process. A fetch that raises is
        not cached (the next document asks again); only a list of items is stored. The items are
        Muso's STORED capture either way - caching them changes no evidence class (a same-run
        Spotify/Tidal read is D5b's fresh capture, never this)."""
        import time as _t
        t = _t.time() if now is None else now
        hit = self._raw_credits_hit(track_id, t, ttl_s)
        if hit is not None:
            return hit
        # A miss: take this track's cross-process lock, check again (another reader may have just
        # fetched it), and only then fetch - one admin GET per track per TTL across all readers
        # (QA #1440). The lock is a flock, released by the kernel if the process dies.
        with self._track_lock(track_id):
            hit = self._raw_credits_hit(track_id, t if now is not None else _t.time(), ttl_s)
            if hit is not None:
                return hit
            return self._fetch_and_store(track_id, fetch, t)

    def _raw_credits_hit(self, track_id: str, t: float, ttl_s: float) -> list[dict[str, Any]] | None:
        row = self.db.execute("SELECT at, items_json FROM dv_raw_credits WHERE track_id=?", (track_id,)).fetchone()
        if row:
            try:
                if t - float(row[0]) < ttl_s:
                    return json.loads(row[1])
            except (TypeError, ValueError):
                pass
        return None

    def _track_lock(self, track_id: str):
        """An exclusive flock on one of 64 bucket files next to the store (bucket = sha256 of the
        track id). FAILS CLOSED (QA #1440): a lock that cannot be taken raises RawCreditsLockError and
        no fetch is made - the claim's xc_dsp records an error (`unknown`, retried), never an unlocked GET."""
        import contextlib
        import fcntl
        import hashlib

        @contextlib.contextmanager
        def held():
            d = os.path.join(os.path.dirname(os.path.abspath(self.path)), "raw-credits-locks")
            try:
                os.makedirs(d, mode=0o700, exist_ok=True)
                fd = os.open(os.path.join(d, f"{int(hashlib.sha256(track_id.encode()).hexdigest()[:4], 16) % 64}.lock"),
                             os.O_RDWR | os.O_CREAT, 0o600)
            except OSError as exc:
                raise RawCreditsLockError(f"raw-credits lock unusable under {d}: {type(exc).__name__}") from exc
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
        return held()

    def _fetch_and_store(self, track_id: str, fetch: Any, t: float) -> list[dict[str, Any]]:
        items = fetch(track_id)
        if isinstance(items, list):
            with self.lock, self.db:
                self.db.execute("INSERT OR REPLACE INTO dv_raw_credits (track_id, at, items_json) VALUES (?,?,?)",
                                (track_id, f"{t:.3f}", json.dumps(items, default=str)))
        return items

    def raw_credits_read_at(self, track_id: str) -> str | None:
        """When the admin GET that produced this track's cached raw credits ran (UTC), or None."""
        row = self.db.execute("SELECT at FROM dv_raw_credits WHERE track_id=?", (track_id,)).fetchone()
        try:
            return datetime.fromtimestamp(float(row[0]), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if row else None
        except (TypeError, ValueError):
            return None

    def intake_keys_recorded(self, intake_id: str) -> dict[str, Any] | None:
        """The last run's {candidates, keys} for a filing (None before its first run, or when
        only an unreadable record exists: the filing is then simply read again). Never raises on
        a stored value - selection must not stop on one filing."""
        row = self.db.execute("SELECT candidates_json, keys_json FROM dv_intake_keys WHERE intake_id=? AND version=?",
                              (intake_id, VERSION)).fetchone()
        try:
            if row:
                return {"candidates": json.loads(row[0]), "keys": json.loads(row[1])}
            old = self.db.execute("SELECT detail_json FROM dv_steps WHERE request_id=? AND step='intake_keys' "
                                  "AND version=? ORDER BY id DESC LIMIT 1", (f"intake:{intake_id}", VERSION)).fetchone()
            return json.loads(old[0]) if old else None
        except (ValueError, TypeError):
            return None

    def intake_carried_keys(self, intake_id: str) -> set[str]:
        """Claim keys of one filing whose STANDING row under the current VERSION was carried forward, never read:
        its run wrote no step of this VERSION for the document (carry_forward copies a row with its old run_id
        and `at`). Only keys the last run recorded as open count, so a request closed since never loops.
        Fable 134: such a row waits for a re-read under the current rule before any ask."""
        rec = self.intake_keys_recorded(intake_id)
        open_keys = set((rec or {}).get("keys") or [])
        if not open_keys:
            return set()
        rows = self.db.execute(
            "SELECT o.request_id, o.role FROM dv_outcomes o JOIN (SELECT MAX(id) id FROM dv_outcomes WHERE intake_id=? "
            "AND version=? GROUP BY proof_id, request_id, role) l USING(id) WHERE NOT EXISTS (SELECT 1 FROM dv_steps s "
            "WHERE s.proof_id=o.proof_id AND s.run_id=o.run_id AND s.version=?)", (intake_id, VERSION, VERSION))
        return {f"{rid}#{role}" for rid, role in rows} & open_keys

    def carried_remaining(self) -> dict[str, int]:
        """How much of the carried set is still unread under the current VERSION: `rows` / `filings` count only
        claims still OPEN (in the filing's last recorded keys, as intake_carried_keys does), so the number reaches
        0 when the re-read is done; `closed_rows` are carried claims whose request closed since (QA #1493: never
        re-read, so they must not look unfinished)."""
        rows = self.db.execute(
            "SELECT o.intake_id, o.request_id || '#' || o.role, k.keys_json FROM dv_outcomes o JOIN (SELECT MAX(id) id "
            "FROM dv_outcomes WHERE version=? GROUP BY coalesce(intake_id, ''), proof_id, request_id, role) l USING(id) "
            "LEFT JOIN dv_intake_keys k ON k.intake_id=o.intake_id AND k.version=? WHERE o.intake_id IS NOT NULL AND "
            "NOT EXISTS (SELECT 1 FROM dv_steps s WHERE s.proof_id=o.proof_id AND s.run_id=o.run_id AND s.version=?)",
            (VERSION, VERSION, VERSION)).fetchall()
        open_keys: dict[str, set[str]] = {}
        n_open, n_closed, filings = 0, 0, set()
        for iid, key, keys_json in rows:
            if iid not in open_keys:
                try:
                    open_keys[iid] = set(json.loads(keys_json or "[]"))
                except ValueError:
                    open_keys[iid] = set()
            if key in open_keys[iid]:
                n_open += 1
                filings.add(iid)
            else:
                n_closed += 1
        return {"rows": n_open, "filings": len(filings), "closed_rows": n_closed}

    def intake_settled(self, intake_id: str, candidates: list[str]) -> bool:
        """No Trino needed: the last run saw exactly these candidate requests and every
        claim key it found open is finished."""
        rec = self.intake_keys_recorded(intake_id)
        if rec is None or sorted(rec.get("candidates") or []) != sorted(candidates):
            return False
        return set(rec.get("keys") or []) <= self.intake_finished_keys(intake_id)

    LATEST = ("SELECT o.* FROM dv_outcomes o JOIN (SELECT proof_id, request_id, role, MAX(id) id FROM dv_outcomes "
              "WHERE version=? GROUP BY proof_id, request_id, role) l USING(id)")

    def latest_outcomes(self, user_id: int | None = None) -> list[sqlite3.Row]:
        """The outcome that stands per (proof, request, role) under the current
        VERSION: the latest row. Consumers read this, never an older row."""
        self.db.row_factory = sqlite3.Row
        try:
            sql, args = self.LATEST, [VERSION]
            if user_id is not None:
                sql, args = sql + " WHERE o.user_id=?", args + [user_id]
            return self.db.execute(sql, args).fetchall()
        finally:
            self.db.row_factory = None

    def supersede_verified(self, run_id: str, user_id: int, why: str) -> int:
        """An account hold invalidates every standing `verified` outcome of
        the account, whichever document came first: append an
        `unverifiable` / account_on_hold row over each (append-only, so the
        superseded row stays for the audit). Returns how many."""
        rows = [r for r in self.latest_outcomes(user_id) if r["outcome"] == "verified"]
        for r in rows:
            self.outcome(run_id, proof_id=r["proof_id"], request_id=r["request_id"], role=r["role"],
                         user_id=user_id, source_ref=r["source_ref"], h3_verdict=r["h3_verdict"],
                         outcome="unverifiable", reason=f"account hold: {why}; supersedes verified row {r['id']}",
                         need="account_on_hold", account_hold=False,
                         detail={"superseded_id": r["id"], "hold": why})
            self.step(run_id, r["proof_id"], "account_hold", "superseded",
                      {"superseded_id": r["id"], "hold": why}, f"{r['request_id']}#{r['role']}")
        return len(rows)

    def held_users(self) -> set[int]:
        return {r[0] for r in self.db.execute("SELECT DISTINCT user_id FROM dv_outcomes WHERE account_hold=1 "
                                              "AND user_id IS NOT NULL")}
