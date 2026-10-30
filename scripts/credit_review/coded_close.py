"""The agreed coded-close / coded-decision columns of the decider ledger's `decisions` table
(data/doc-verify-build-b1/coded-close-row-shape.md, Fable [key=coded-close-store]). Additive and idempotent: every
coded writer (C3/C5/C8, the stale-velocity re-validate) calls ensure_columns before its first insert."""
from __future__ import annotations

import sqlite3

CODED_CLOSE_COLUMNS = (("reason_code", "TEXT"), ("rule_version", "TEXT"), ("expected_status", "TEXT"),
                       ("gate_state", "TEXT"), ("v9_anchor", "TEXT"), ("intake_ids", "TEXT"),
                       ("evidence_json", "TEXT"))


def ensure_columns(db: sqlite3.Connection) -> None:
    from credit_review import decide
    decide.ensure_schema(db)
    have = {r[1] for r in db.execute("PRAGMA table_info(decisions)")}
    for col, decl in CODED_CLOSE_COLUMNS:
        if col not in have:
            db.execute(f"ALTER TABLE decisions ADD COLUMN {col} {decl}")
    db.commit()
