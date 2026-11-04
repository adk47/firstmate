"""Coded profile PROPOSALS in the decider ledger (Fable [key=profile-link-anchor] 178 / p1 179, 2026-10-30).

A proposal is NOT a decision: it never approves, closes, links or merges anything, and the executor never reads
this table (it admits `decisions:<id>` / `dv_outcomes:<id>` only). It is the shadow input of the core merge
verifier (verifySelfMerge family, C7) and of verifier-eval-v1's labels.

  kind merge_candidate  the claimant's PRESENTED profile is unlinked on a DSP while the contributor id credited on
                        the track under the claimant's exact name is held by ANOTHER Muso profile (a duplicate
                        profile). class `candidate`: the linked profile is unclaimed or claimed only by the same
                        account (an owner-confirmed merge, surviving profile = the linked one); class `contested`:
                        claimed by another account -> tray, never automatic.
  kind link_proposal    (reserved for the true link cases; not written by this module yet)

Append-only and shadow-only by trigger, and ONE row per (kind, source_ref, contributor_id): the decider and the
merge verifier count rows, so a double insert would double-count a candidate forever (the triggers make it
unremovable). The uniqueness is a database constraint, not a read-then-write check - two overlapping --apply runs
both read an absent pair, so only the constraint can stop the second insert.
"""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS proposals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  kind TEXT NOT NULL,                  -- merge_candidate | link_proposal
  class TEXT NOT NULL,                 -- candidate | contested
  mode TEXT NOT NULL DEFAULT 'shadow',
  rule_version TEXT NOT NULL,
  request_id TEXT NOT NULL,
  user_id INTEGER,
  profile_presented TEXT NOT NULL,
  profile_linked TEXT,                 -- the Muso profile already holding the contributor id (merge_candidate)
  dsp TEXT NOT NULL,                   -- spotify | tidal
  contributor_id TEXT NOT NULL,        -- the raw DSP id ('spotify:...')
  contributor_name TEXT,
  claimed_by TEXT NOT NULL,            -- JSON {presented: [{user_id, status}], linked: [...]}
  evidence TEXT NOT NULL,              -- JSON: tracks, roles, capture tag/time, verdict id, packet sha
  source_ref TEXT NOT NULL,            -- 'dsp_verdicts:<id>'
  reason TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS proposals_req ON proposals(request_id);
CREATE INDEX IF NOT EXISTS proposals_src ON proposals(source_ref);
CREATE TRIGGER IF NOT EXISTS proposals_no_update BEFORE UPDATE ON proposals
BEGIN SELECT RAISE(ABORT, 'proposals is append-only'); END;
CREATE TRIGGER IF NOT EXISTS proposals_no_delete BEFORE DELETE ON proposals
BEGIN SELECT RAISE(ABORT, 'proposals is append-only'); END;
CREATE TRIGGER IF NOT EXISTS proposals_shadow_only BEFORE INSERT ON proposals WHEN NEW.mode != 'shadow'
BEGIN SELECT RAISE(ABORT, 'proposals is shadow-only'); END;
"""


def utc(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


# ONE row per proposed fact. Created separately from SCHEMA so a ledger that already holds duplicates fails with a
# remedy instead of a bare "UNIQUE constraint failed" - and never silently runs without the constraint.
ONCE = "CREATE UNIQUE INDEX IF NOT EXISTS proposals_once ON proposals(kind, source_ref, contributor_id)"
ONCE_COLUMNS = ("kind", "source_ref", "contributor_id")


def ensure(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)
    try:
        db.execute(ONCE)
    except sqlite3.IntegrityError as exc:                     # the index cannot be built: the ledger has duplicates
        raise RuntimeError(
            "proposals already holds duplicate (kind, source_ref, contributor_id) rows, so the one-row-per-fact "
            "index cannot be created: %s. Inspect with SELECT kind, source_ref, contributor_id, count(*) FROM "
            "proposals GROUP BY 1,2,3 HAVING count(*) > 1 - the table is append-only by trigger, so collapsing the "
            "duplicates is a human decision (a named human's session), never an automatic delete." % exc) from exc


def written_sources(db: sqlite3.Connection, kind: str) -> set[tuple[str, str]]:
    """(source_ref, contributor_id) already proposed: a verdict is proposed once per contributor id."""
    return {(r[0], r[1]) for r in db.execute("SELECT source_ref, contributor_id FROM proposals WHERE kind=?", (kind,))}


def add(db: sqlite3.Connection, run_id: str, row: dict[str, Any], *, decided_at: str) -> int:
    """Insert one proposal; returns 1 when it was written and 0 when the same fact was already there.

    The conflict clause is the write-side half of the guarantee: a caller that lost a race with an overlapping run
    (both read the pair as absent) must not abort the whole run and must not double count - it inserts nothing."""
    cur = db.execute(
        "INSERT INTO proposals (run_id, decided_at, kind, class, mode, rule_version, request_id, user_id, "
        "profile_presented, profile_linked, dsp, contributor_id, contributor_name, claimed_by, evidence, source_ref, "
        "reason) VALUES (?,?,?,?, 'shadow', ?,?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(kind, source_ref, contributor_id) DO NOTHING",
        (run_id, decided_at, row["kind"], row["class"], row["rule_version"], row["request_id"], row.get("user_id"),
         row["profile_presented"], row.get("profile_linked"), row["dsp"], row["contributor_id"],
         row.get("contributor_name"), json.dumps(row["claimed_by"], sort_keys=True),
         json.dumps(row["evidence"], sort_keys=True, default=str), row["source_ref"], row["reason"]))
    return cur.rowcount if cur.rowcount in (0, 1) else 1      # sqlite may report -1 when the conflict clause fired
