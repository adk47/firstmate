"""Receipts from the proof intake (proof-loop-lead-fable-p1 [key=proof-loop-plan-1027] section 1 ACKNOWLEDGE;
firstmate verify-ask-wiring-h2 inbox 057 item 3).

The acknowledgement that a document arrived is triggered by a NEW `proof_intake` row (b1's filer writes
one per (user, document) into the stage-2 proof store), not by the Intercom thread heuristic. READ-ONLY:
this module reads proof_intake and the core replica and writes two runner lists; the sends go through
`credit-review.py uvn-status --campaign status-doc-received` (the gate, the ledger, the 7-day core-notice
gate, one per user ever), never from here.

Per user with a credit-subject intake row:
  - the note names the intake's candidate credit requests that are STILL pending on the replica
    (none -> skipped, counted 'nothing_pending'; no candidates at all -> 'no_candidate_request');
  - a user who OWES PROOF is decided with the steward's CLASS_SQL classes (r5 on #1416), on ANY of their
    pending requests: a user_verification_needed row (U), an unverified row whose IDP review_* rule fired
    (H2), or a held account (H1: fraud-lens account_holds.jsonl, or a hold-silent account-hold flag in the
    verify ledger). A user with none of these owes nothing else and goes on receipts-queued.json -> the
    approved `--wording queued` line ("... no need to send anything else");
  - a user who still owes proof goes on receipts-received.json -> the `--wording received` line (card R1:
    the queued line without "no need to send anything else"), SEND-LOCKED in the gate until the captain's
    yes. Captain 12:55Z: never "nothing else is needed" to anyone who still owes proof.
Paid first, then the earliest document. Claim-subject intake rows are not credit receipts (counted only).

  python3 receipts.py --out-dir DIR [--proof-store PATH] [--paying PATH]
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import verify_notify  # noqa: E402

PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"
DV_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
PAYING = "/var/lib/credit-trust/paying-users.json"
ACCOUNT_HOLDS = "/opt/firstmate/fraud-lens/out/account_holds.jsonl"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
# H2 (steward CLASS_SQL, status10k.py): an IDP review_* rule fired on the row (verificationdata.rule_risk_percent).
REVIEW_FIRED = "regexp_like(coalesce(json_format(json_extract(verificationdata, '$.rule_risk_percent')), ''), '\"review_[a-z_]+\":\\s*[1-9]')"
CHUNK = 400
# security-arch-fable-s1 bar (r5 on #1416): a receipt only for a filing whose account match is strong. An
# email-only (or unknown) match never triggers one: the account the note would go to may not be the sender.
STRONG_MATCH = ("professional_id", "authenticated_email", "session")
Query = Callable[[str], "list[list[str]]"]


class ReceiptsError(RuntimeError):
    pass


def intake_by_user(proof_store: str) -> tuple[dict[int, dict[str, Any]], Counter]:
    """{user_id: {request_ids: [...], first_received: str}} for credit-subject intake rows (read-only)."""
    counts: Counter = Counter()
    try:
        db = sqlite3.connect(f"file:{proof_store}?mode=ro", uri=True)
        rows = db.execute("SELECT user_id, subject, candidate_request_ids_json, received_at, matched_by, conversation_id, "
                          "intake_id FROM proof_intake ORDER BY received_at").fetchall()
    except sqlite3.Error as exc:
        raise ReceiptsError(f"proof_intake unreadable: {exc}") from exc
    out: dict[int, dict[str, Any]] = {}
    for uid, subject, cands, received, matched, conv, iid in rows:
        counts[f"intake_rows_{subject}"] += 1
        if subject != "credit":
            continue
        if (matched or "") not in STRONG_MATCH:
            counts["skip_weak_identity"] += 1
            continue
        try:
            raw = json.loads(cands or "[]")
        except ValueError as exc:
            raise ReceiptsError(f"proof_intake row for user {uid}: candidate ids are not JSON") from exc
        # QA on #1416: valid JSON of the wrong shape ("r-a" -> ['r','-','a'], an object -> its keys) must not
        # silently become 'nothing pending': only an array of non-empty strings is a candidate list.
        if not isinstance(raw, list) or not all(isinstance(x, str) and x.strip() for x in raw):
            raise ReceiptsError(f"proof_intake row for user {uid}: candidate ids must be a JSON array of request ids")
        ids = [x.strip().lower() for x in raw]
        u = out.setdefault(int(uid), {"request_ids": [], "first_received": str(received),
                                      "filing_conversation": str(conv or ""), "intake_ids": []})
        u["intake_ids"].append(str(iid))
        u["request_ids"] = list(dict.fromkeys(u["request_ids"] + ids))
        u["first_received"] = min(u["first_received"], str(received))
    return out, counts


def filing_classes(users: dict[int, dict[str, Any]], *, dv_store: str, proof_store: str) -> dict[int, bool] | None:
    """h2 [r1 filing-class producer] (r5 / QA #1554: an R1 states the filing's class): {user: filing_muso_ui} from the
    doc reader's latest artifact verdict on the user's OWN receipted intake rows (artifacts.filed_rows, read-only).
    True = any of them is a screenshot of Muso itself (SYS-001; the gate refuses that R1); False = EVERY one was read
    (its latest extract step ended 'ok' - an errored read is unread, QA #1602) and none is; a user with an unread filing is left out (unknown: the gate refuses r1_filing_class_unknown).
    None = the stores are unreadable (nobody gets the field: fail closed)."""
    from credit_verify import docverify  # noqa: PLC0415 - the doc reader's own version, classifier and row reader
    from credit_verify.docverify import artifacts  # noqa: PLC0415
    try:
        dv = sqlite3.connect(f"file:{dv_store}?mode=ro", uri=True)
        pdb = sqlite3.connect(f"file:{proof_store}?mode=ro", uri=True)
        # QA #1602: only the CURRENT reader version counts - an ok read under an older reader says nothing about the
        # class the current one would give (credit-doc-close reads the same way, version=VERSION)
        rows = artifacts.filed_rows(dv, pdb, frozenset(), version=docverify.VERSION)
        # QA #1602 (b1 548): a filing counts as READ only when its LATEST extract step ended ok - filed_rows counts an
        # errored extract as read, so an error (or no extract at all) is unread here: never stated false
        ext: dict[str, tuple[int, str]] = {}
        for sid, pid, st in dv.execute("SELECT id, proof_id, status FROM dv_steps WHERE step = 'extract' AND version = ? "
                                       "ORDER BY id", (docverify.VERSION,)):
            ext[str(pid)] = (int(sid), str(st or ""))
        # QA #1602: 'false' also needs a COMPLETED current-version ARTIFACT verdict for THAT extract - the latest artifact
        # step must come after the latest extract (an older artifact is a verdict on an earlier read; filed_rows would
        # fall back to it, or to the stored-data rules that cannot see a text-only Muso UI screenshot)
        art: dict[str, int] = {}
        for sid, pid in dv.execute("SELECT id, proof_id FROM dv_steps WHERE step = 'artifact' AND version = ? ORDER BY id",
                                   (docverify.VERSION,)):
            art[str(pid)] = int(sid)
        sha_of = {str(i): str(sha) for i, sha in pdb.execute("SELECT intake_id, file_sha256 FROM proof_intake")}
    except (sqlite3.Error, OSError, ValueError):
        return None
    def _read(r: dict[str, Any]) -> bool:
        sha = sha_of.get(str(r["intake_id"]), "")
        e = ext.get(sha)
        return bool(r["read"]) and e is not None and e[1] == "ok" and art.get(sha, -1) > e[0]
    by_intake = {str(r["intake_id"]): {**r, "read": _read(r)} for r in rows}
    out: dict[int, bool] = {}
    for uid, u in users.items():
        mine = [by_intake.get(i) or {"artifact": None, "read": False} for i in u.get("intake_ids") or []]
        if not mine:
            continue
        if any(r["artifact"] == artifacts.SYS_001 for r in mine):
            out[uid] = True
        elif all(r["read"] for r in mine):
            out[uid] = False
    return out


def pending_rows(user_ids: list[int], query: Query) -> dict[int, dict[str, tuple[str, bool]]]:
    """{user_id: {request_id: (status, review_rule_fired)}} for every pending (not approved/rejected, not
    deleted) request."""
    out: dict[int, dict[str, tuple[str, bool]]] = {u: {} for u in user_ids}
    for i in range(0, len(user_ids), CHUNK):
        lst = ",".join(map(str, user_ids[i:i + CHUNK]))
        for row in query("SELECT CAST(userid AS varchar), lower(CAST(id AS varchar)), status, "
                         f"CAST(CASE WHEN {REVIEW_FIRED} THEN 1 ELSE 0 END AS varchar) "
                         "FROM postgresql_core.public.credit_requests WHERE deletedat IS NULL "
                         f"AND status NOT IN ('approved', 'rejected') AND userid IN ({lst})"):
            if len(row) != 4 or not str(row[0]).isdigit() or row[3] not in ("0", "1"):
                raise ReceiptsError("unexpected replica row shape")
            out.setdefault(int(row[0]), {})[row[1]] = (row[2], row[3] == "1")
    return out


HOLDS_MAX_AGE_H = 72
HOLDS_FUTURE_SLACK_H = 5 / 60   # clock skew tolerated between the writer and this reader: 5 minutes


def held_accounts(holds_path: str, ledger_path: str, now: datetime | None = None) -> set[int]:
    """H1: accounts on fraud-lens's hold list or flagged account-hold by hold-silent. Unreadable, or a hold list
    older than HOLDS_MAX_AGE_H (s1 guard G8: a stale list could miss a new hold), = error: nothing is listed."""
    held: set[int] = set()
    try:
        age_h = ((now or datetime.now(timezone.utc)).timestamp() - os.path.getmtime(holds_path)) / 3600
        if age_h > HOLDS_MAX_AGE_H:
            raise ReceiptsError(f"G8: the account hold list is {age_h:.0f} h old (limit {HOLDS_MAX_AGE_H} h)")
        if age_h < -HOLDS_FUTURE_SLACK_H:
            # QA #1456: a FUTURE mtime has a negative age that never exceeds the limit, so a stale (or clock-skewed)
            # list would read as fresh. Its age is unknowable: stop.
            raise ReceiptsError(f"G8: the account hold list's mtime is {-age_h * 60:.0f} min in the future; its age is unknown")
        # [key=r8-release-row]: the ONE reader (latest row by at; a release only with the lens's current scan agreeing)
        from credit_review import comm_state  # noqa: PLC0415
        held |= {int(u) for u in comm_state.held_user_ids(holds_path=holds_path) if str(u).isdigit()}
        db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
        held |= {int(u) for (u,) in db.execute(
            "SELECT DISTINCT user_id FROM verify_refusal_holds WHERE flagged_at IS NOT NULL AND reason='account-hold' "
            "AND user_id IS NOT NULL") if str(u).isdigit()}
    except (OSError, ValueError, KeyError, sqlite3.Error, RuntimeError) as exc:
        if isinstance(exc, ReceiptsError):
            raise
        raise ReceiptsError(f"account holds unreadable: {exc}") from exc
    return held


def build(*, proof_store: str = PROOF_STORE, paying_path: str = PAYING, query: Query | None = None,
          now: datetime | None = None, holds_path: str = ACCOUNT_HOLDS, ledger_path: str = LEDGER,
          dv_store: str = DV_STORE) -> dict[str, Any]:
    """The two runner lists + counts. Raises ReceiptsError when an input is unreadable (nothing is listed)."""
    now = now or datetime.now(timezone.utc)
    users, counts = intake_by_user(proof_store)
    try:
        with open(paying_path, encoding="utf-8") as fh:
            paying = {int(x) for x in (json.load(fh).get("ids") or [])}
    except (OSError, ValueError) as exc:
        raise ReceiptsError(f"paying list unreadable: {exc}") from exc
    pend = pending_rows(sorted(users), query or verify_notify.trino) if users else {}
    held = held_accounts(holds_path, ledger_path) if users else set()
    fclass = filing_classes(users, dv_store=dv_store, proof_store=proof_store) if users else {}
    if fclass is None:
        counts["filing_class_unreadable"] += 1
        fclass = {}
    lists: dict[str, list[dict[str, Any]]] = {"queued": [], "received": []}
    for uid, u in users.items():
        rows = pend.get(uid, {})
        if not u["request_ids"]:
            counts["skip_no_candidate_request"] += 1
            continue
        note = [r for r in u["request_ids"] if r in rows]
        if not note:
            counts["skip_nothing_pending"] += 1
            continue
        why = ("uvn" if any(st == "user_verification_needed" for st, _ in rows.values()) else
               "review_hold" if any(st == "unverified" and fired for st, fired in rows.values()) else
               "account_hold" if uid in held else "")
        if why:
            counts[f"owes_{why}"] += 1
        key = "received" if why else "queued"
        row = {"user_id": str(uid), "paid": uid in paying, "skip": None, "request_ids": note,
               "first_received": u["first_received"], "filing_conversation": u["filing_conversation"]}
        if uid in fclass:
            row["filing_muso_ui"] = fclass[uid]
        counts[f"filing_class_{ {True: 'muso_ui', False: 'record'}.get(fclass.get(uid), 'unknown') }"] += 1
        lists[key].append(row)
        counts[f"list_{key}_{'paid' if uid in paying else 'free'}"] += 1
    stamp = now.isoformat(timespec="seconds")
    for k in lists:
        lists[k].sort(key=lambda x: (not x["paid"], x["first_received"]))
    return {"generated_at": stamp, "lists": lists, "counts": dict(counts)}


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="receipt lists from proof_intake (read-only)")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--proof-store", default=PROOF_STORE)
    ap.add_argument("--doc-verify-store", default=DV_STORE)
    ap.add_argument("--paying", default=PAYING)
    ap.add_argument("--account-holds", default=ACCOUNT_HOLDS)
    ap.add_argument("--ledger", default=LEDGER)
    a = ap.parse_args(argv)
    try:
        res = build(proof_store=a.proof_store, paying_path=a.paying, holds_path=a.account_holds, ledger_path=a.ledger,
                    dv_store=a.doc_verify_store)
    except (ReceiptsError, RuntimeError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    out = Path(a.out_dir)
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    for k, users in res["lists"].items():
        p = out / f"receipts-{k}.json"
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"generated_at": res["generated_at"], "users": users}, indent=1))
        os.replace(tmp, p)
    print(json.dumps({"generated_at": res["generated_at"], "counts": res["counts"]}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
