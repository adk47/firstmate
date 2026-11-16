#!/usr/bin/env python3
"""The send gate's per-PERSON replica read: what core_notice and comm_state will ask the replica about one user,
asked in ONE round trip. READ-ONLY. It decides nothing and holds nobody.

Measured on node-8 2026-11-12 (docs/credit-verification/gate-replica-read.md): the gate asked the replica 5-6
separate questions per person at ~2.06 s each (~1.85 s of it fixed start-up cost per question), 10.25 s of a
13.47 s gate call, and the calls that crossed the 20 s read timeout were what tripped the unmeasured bar. The bar
and the timeout are right; six round trips for one person was the defect.

    gate_facts.py read --campaign C --copy K --user-id N --request-ids a,b [--reply-due PART]
        stdout: the bundle (credit_review/replica_batch.py) - each statement's exact text with its rows, and the
                second it was read. exit 0.
        any failure (replica down, a statement that errors, output that cannot be split): NOTHING on stdout, exit 2.

The gate then runs the two helpers UNCHANGED with scripts/replica-serve.sh as their replica command: it answers a
statement whose exact text is in the bundle and runs the real trino-query.sh for any other. So this file cannot
change an answer (a read that fails or never answers costs time: replica_batch.BATCH_TIMEOUT_S at most):

  * no bundle, a failed read here, a stale one (replica_batch.MAX_AGE_S) -> every statement is read live, as before;
  * a statement this file did not predict (or predicted with one byte different) -> that statement is read live;
  * nothing is evaluated here: the rules stay in core_notice.reasons_by_user and comm_state.check, on the same rows.

WHY THE STATEMENT TEXTS OF THOSE TWO HELPERS ARE WRITTEN OUT HERE instead of being imported from them: the helpers
are deliberately not touched by this change (node-8 ran hand-edited copies of both on 2026-11-12, and a deploy stops
on a file whose server copy matches neither side), so the text lives in two places. test_gate_facts.py runs the real
helper functions against a recording replica and fails when either asks a statement this file does not list; until
that test is fixed, a drifted statement costs one live round trip and nothing else. The fraud lens and the
approval-path read are imported (fraud_lens.Lens.statements, uvn_status.uvn_requests_sql): one text, one place.

The batch always goes to the trino-query.sh beside this tree (found from this file's own location, never from the
caller's environment). Our own stores (ledger, proof, doc-verify) and Intercom are never in the bundle.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from credit_review import replica_batch  # noqa: E402

REPLICA = str(SCRIPTS / "trino-query.sh")
# comm_state.POLICIES, read here without importing comm_state (same variable, same default)
POLICIES = os.environ.get("COMM_STATE_POLICIES", "/opt/hydra/policies")
# comm_state.REVIEW_FIRED / RECEIPT / nothing_else(), copied: pinned equal by test_gate_facts.py
REVIEW_FIRED = r'"review_[a-z_]+":\s*[1-9]'
RECEIPT = "status-doc-received"


def nothing_else(campaign: str, copy: str) -> bool:
    return campaign in ("status-team-review", "claim-status") or (campaign == RECEIPT and copy in ("docrecv", "docrecvq"))


# --- core_notice.reasons_by_user([uid]) -----------------------------------------------------------------------------
# The gate passes core_notice --window-hours 24 for proof-need-ask (its RECONTACT_S; pinned to
# verify_ledger.RECONTACT_HOURS by test_verify_ledger_proof_need.py) and the module's default for everyone else. The
# claim read's lookback follows the window (QA on #2132), so the statement text does too.
NEED_ASK_WINDOW = ("proof-need-ask", 24)


def core_notice_statements(uid: int, campaign: str = "") -> list[str]:
    from datetime import timedelta  # noqa: PLC0415

    from credit_review import core_notice  # noqa: PLC0415
    window = timedelta(hours=NEED_ASK_WINDOW[1]) if campaign == NEED_ASK_WINDOW[0] else core_notice.WINDOW
    return core_notice.statements(str(int(uid)), window)


# --- comm_state.core_facts(uid, keys) -------------------------------------------------------------------------------
def core_facts_statements(uid: int, keys: list[str]) -> list[str]:
    out = ["SELECT lower(CAST(id AS varchar)), status, "
           "coalesce(json_extract_scalar(metadata, '$.approvedNotice.noticeSentAt'), ''), "
           "coalesce(json_extract_scalar(metadata, '$.proofRequest.noticeSentAt'), ''), "
           "CAST(createdat AS varchar) "
           f"FROM postgresql_core.public.credit_requests WHERE userid = {int(uid)} AND deletedat IS NULL"]
    claims = [k.split("-", 1)[1] for k in keys if k.startswith("claim-") and k.split("-", 1)[1].isdigit()]
    if claims:
        out.append("SELECT CAST(id AS varchar), status FROM postgresql_core.public.claiming "
                   f"WHERE userid = {int(uid)} AND id IN ({','.join(claims)})")
    return out


# --- comm_state.fraud_facts(uid): the production lens exactly as R8 builds it ---------------------------------------
def lens_statements(uid: int) -> list[str]:
    from credit_review import fraud_lens  # noqa: PLC0415
    try:
        lens = fraud_lens.default_lens(lambda sql: [], watchlist_path=os.path.join(POLICIES, "fraud-watchlist.json"),
                                       holds_path=os.path.join(POLICIES, "fraud-lens-holds.json"))
    except (ValueError, OSError, KeyError):
        return []                      # fraud_facts() raises Unknown for the same reason, at the check
    return lens.statements([int(uid)])


# --- comm_state.owes_proof(uid) -------------------------------------------------------------------------------------
def owes_statements(uid: int) -> list[str]:
    """owes_proof's replica reads, the approval-path one included (asked only when it could lift a UVN reason; having
    it ready costs no extra round trip). The doc-verify follow-up read depends on our own store and stays live."""
    from credit_review import uvn_status  # noqa: PLC0415
    return [("SELECT status, CAST(regexp_like(coalesce(json_format(CAST(verificationdata AS json)), ''), "
             f"'{REVIEW_FIRED}') AS varchar) FROM postgresql_core.public.credit_requests "
             f"WHERE userid = {int(uid)} AND deletedat IS NULL AND status IN ('user_verification_needed', 'unverified')"),
            ("SELECT CAST(count_if(CAST(json_extract(verificationdata, '$.proof_required') AS boolean) "
             "AND json_extract(metadata, '$.reviewStage') IS NULL) AS varchar), "
             "CAST(count_if(json_extract(metadata, '$.freshDspCapture') IS NOT NULL) AS varchar) "
             "FROM postgresql_core.public.credit_requests /* proof_required_owed */ "
             f"WHERE userid = {int(uid)} AND deletedat IS NULL AND status IN ('unverified', 'processing')"),
            uvn_status.uvn_requests_sql([int(uid)], ("user_verification_needed",))]


def comm_state_statements(campaign: str, copy: str, uid: int, keys: list[str], reply_due_part: str = "") -> list[str]:
    """Following comm_state.check()'s own branches. A reply-due answer's own reads (the trigger, the reply-ref facts)
    and a "nothing is needed" line found in a rendered body are rare and stay live."""
    if nothing_else(campaign, copy) and not reply_due_part:
        return owes_statements(uid)
    out = core_facts_statements(uid, keys) + lens_statements(uid)
    if reply_due_part:
        out += owes_statements(uid)
    return out


def plan(campaign: str, copy: str, uid: int, keys: list[str], reply_due_part: str = "") -> list[str]:
    """Every statement of this gate call, each once. A reply-due answer skips the core-notice cooldown in the gate,
    so its statements are not read."""
    stmts = [] if reply_due_part else core_notice_statements(uid, campaign)
    return replica_batch.unique(stmts + comm_state_statements(campaign, copy, uid, keys, reply_due_part))


def read(campaign: str, copy: str, uid: int, keys: list[str], reply_due_part: str = "", *, cmd: str = REPLICA) -> dict:
    stmts = plan(campaign, copy, uid, keys, reply_due_part)
    read_at = time.time()                       # stamped BEFORE the read: the bundle is never younger than it claims
    return replica_batch.bundle(stmts, replica_batch.read_many(stmts, cmd=cmd), read_at)


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="the send gate's per-person replica read (read-only)")
    sub = ap.add_subparsers(dest="op", required=True)
    r = sub.add_parser("read")
    r.add_argument("--campaign", required=True)
    r.add_argument("--copy", default="")
    r.add_argument("--user-id", required=True)
    r.add_argument("--request-ids", default="")
    r.add_argument("--reply-due", default="")
    a = ap.parse_args(argv)
    if not str(a.user_id).isdigit():
        print("gate_facts: no Muso user id", file=sys.stderr)
        return 2
    try:
        out = read(a.campaign, a.copy, int(a.user_id), [k for k in a.request_ids.split(",") if k], a.reply_due)
    except Exception as exc:  # noqa: BLE001 - whatever went wrong, the gate reads live; this helper never decides
        print(f"gate_facts: no bundle ({type(exc).__name__}: {str(exc)[:200]})", file=sys.stderr)
        return 2
    sys.stdout.write(replica_batch.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
