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
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any

from . import VERSION

MAX_UNKNOWN = 3


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
  outcome TEXT NOT NULL,                 -- ok | error | skipped
  reason TEXT,
  prompt_sha256 TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cost_usd REAL,
  latency_ms INTEGER
);
CREATE TABLE IF NOT EXISTS dv_state (k TEXT PRIMARY KEY, v TEXT NOT NULL);
-- Muso's stored raw credits per track, shared by every reader process (one admin GET per track per
-- TTL instead of one per document): an account's documents usually name the same tracks.
CREATE TABLE IF NOT EXISTS dv_raw_credits (track_id TEXT PRIMARY KEY, at TEXT NOT NULL, items_json TEXT NOT NULL);
-- D2: a filing's candidate requests and claim keys as the last run saw them, UNTRUNCATED (dv_steps
-- detail is capped at 20,000 chars; a 40-request filing overflowed it and broke selection).
CREATE TABLE IF NOT EXISTS dv_intake_keys (intake_id TEXT NOT NULL, version TEXT NOT NULL, at TEXT NOT NULL,
  candidates_json TEXT NOT NULL, keys_json TEXT NOT NULL, PRIMARY KEY (intake_id, version));
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class DocVerifyStore:
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

    def llm_call(self, row: dict[str, Any]) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT INTO dv_llm_calls (at, proof_id, model, outcome, reason, prompt_sha256,"
                            " input_tokens, output_tokens, cost_usd, latency_ms) VALUES (?,?,?,?,?,?,?,?,?,?)",
                            (utcnow(), row.get("proof_id"), row.get("model"), row["outcome"], row.get("reason"),
                             row.get("prompt_sha256"), row.get("input_tokens"), row.get("output_tokens"),
                             row.get("cost_usd"), row.get("latency_ms")))

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
        rows = [r[0] for r in self.db.execute("SELECT outcome FROM dv_outcomes WHERE proof_id=? AND request_id=? "
                                              "AND role=? AND version=?", (proof_id, rid, role, VERSION))]
        return any(o != "unknown" for o in rows) or len(rows) >= MAX_UNKNOWN

    def intake_finished_keys(self, intake_id: str) -> set[str]:
        """Claim keys '<request_id>#<role>' of one filing that need no more runs: a decided
        outcome (anything but `unknown`), or MAX_UNKNOWN unknown outcomes. Per claim, never
        per document (QA #1417): one verified claim does not end a sibling's retries."""
        done: set[str] = set()
        unknown: dict[str, int] = {}
        for rid, role, outcome in self.db.execute(
                "SELECT request_id, role, outcome FROM dv_outcomes WHERE intake_id=? AND version=?", (intake_id, VERSION)):
            key = f"{rid}#{role}"
            if outcome != "unknown":
                done.add(key)
            else:
                unknown[key] = unknown.get(key, 0) + 1
        return done | {k for k, n in unknown.items() if n >= MAX_UNKNOWN}

    def record_intake_keys(self, intake_id: str, candidates: list[str], keys: list[str]) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO dv_intake_keys (intake_id, version, at, candidates_json, keys_json) "
                            "VALUES (?,?,?,?,?)", (intake_id, VERSION, utcnow(), json.dumps(sorted(candidates)),
                                                   json.dumps(keys)))

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
