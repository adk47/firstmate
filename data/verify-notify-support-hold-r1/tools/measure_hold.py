#!/usr/bin/env python3
"""Before/after: how many accounts verify_notify holds for having emailed support@.

Ask-or-no (2026-11-15): the 90-day support@ list (`gmail_contacts_90d`, read through
`proof_parts.support_contacts`) held those users' notes for a human nobody worked. This tool
measures what the sender-side hold costs, on the PRODUCTION ledger and the PRODUCTION
proof-on-file export, in two steps so the admin API is read ONCE:

    # 1. one read (admin GETs only) -> the candidate rows, kept on the node, never in git
    python3 data/verify-notify-support-hold-r1/tools/measure_hold.py snapshot --out /tmp/hold-rows.json

    # 2. the same rows through a tree that still holds, and through this branch
    python3 data/verify-notify-support-hold-r1/tools/measure_hold.py counts \
        --snapshot /tmp/hold-rows.json --scripts /opt/hydra/scripts          # before (deployed)
    python3 data/verify-notify-support-hold-r1/tools/measure_hold.py counts \
        --snapshot /tmp/hold-rows.json --scripts ./scripts                   # after (this branch)

    # 3. what PR #1992 hands to this step, from the ledger alone (seconds, no admin call)
    python3 data/verify-notify-support-hold-r1/tools/measure_hold.py decider-hold

Read-only by construction: the ledger is opened `?mode=ro` and `credit_review.admin.AdminClient`
refuses anything but a GET. `snapshot` writes request/user/profile ids (customer data), so it
writes to the path you give it and nowhere else - keep it on node-8, never in the repository.

Run it on node-8 (the only host with both files), between ticks:

    cd /opt/hydra && set -a && . /etc/openclaw/main.env && set +a && python3 ... snapshot

A support@ contact is a user id in the proof export's `gmail_contacts_90d`. "Held" is measured
through three of the gates the live `verify_notify.run()` applies, in its order: `screen_live`
(the documents rule), `hold_affiliated` (org affiliation) and `hold_recently_asked` (the shared
90-day re-ask lock). `drop_documented` is NOT on that path (its only caller is `run_wave`), so
the `counts` counters never use it to call a credit held by the run. The identity and cap holds
`run()` applies after those three are not measured here.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from datetime import datetime, timezone

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
PROOF = "/var/lib/credit-trust/proof-on-file.json"
DEPLOYED_SCRIPTS = "/opt/hydra/scripts"
SINCE_HOURS = 168      # verify-notify's windowed default
NEVER_ASKED_DAYS = 30  # verify_notify.NEVER_ASKED_DAYS


def load(scripts: str):
    """Import credit_review from ONE tree (deployed, or this branch) and say which.

    The tree comes first; the deployed `/opt/hydra/scripts` stays on the path BEHIND it only so a
    second package (`lib`, `credit_review`'s sibling modules) is importable when the tree is a
    copy of `credit_review/` alone."""
    sys.path.insert(0, scripts)
    if DEPLOYED_SCRIPTS not in sys.path:
        sys.path.append(DEPLOYED_SCRIPTS)
    from credit_review import admin as admin_api  # noqa: PLC0415
    from credit_review import verify_notify  # noqa: PLC0415
    return admin_api, verify_notify


def open_ledger() -> sqlite3.Connection:
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row       # verify_ledger's readers index rows by name
    return db


def snapshot(admin_api, verify_notify, out: str) -> dict:
    started = time.time()
    db = open_ledger()
    try:
        wanted = verify_notify.candidates(db, run_id=None, since_hours=SINCE_HOURS,
                                          never_asked_days=NEVER_ASKED_DAYS)
    finally:
        db.close()
    print(f"candidates {len(wanted)} profiles {len({p for _, p, _ in wanted})}", flush=True)
    documented = verify_notify.load_proof_on_file(PROOF)
    print(f"proof_users {len(documented)} contacts {len(documented.support_contacts)}", flush=True)
    admin = admin_api.AdminClient()
    rows, missing, unbounded = verify_notify.reread(admin, wanted)
    print(f"admin_calls {admin.calls} rows {len(rows)} missing {len(missing)} "
          f"unbounded {len(unbounded)} elapsed_s {round(time.time() - started, 1)}", flush=True)
    doc = {"wanted": wanted, "rows": rows, "missing": sorted(missing), "unbounded": unbounded}
    with open(out, "w") as fh:
        json.dump(doc, fh, default=str)
    print(f"snapshot {out}")
    return doc


def counts(admin_api, verify_notify, snapshot_path: str) -> dict:
    with open(snapshot_path) as fh:
        rows = json.load(fh)["rows"]
    documented = verify_notify.load_proof_on_file(PROOF)
    listed = {rid for rid, req in rows.items() if verify_notify._user_id(req) in documented.support_contacts}
    listed_users = {verify_notify._user_id(req) for rid, req in rows.items() if rid in listed}
    report = verify_notify.Report()
    live = {rid: dict(req) for rid, req in rows.items()}
    closed, deferred = verify_notify.screen_live(live, documented, report)
    try:
        verdicts = verify_notify.affiliation.read(None)
    except (OSError, ValueError) as exc:
        return {"tree": verify_notify.__file__, "rows_read": len(rows),
                "halted": f"the org-affiliation verdicts cannot be read ({exc}); nothing is sent"}
    affiliated = verify_notify.hold_affiliated(live, verdicts, report)
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    db = verify_notify.verify_ledger.connect_ro(verify_notify.verify_ledger.DEFAULT_PATH)
    try:
        payloads = verify_notify.plan(live, report)
        payloads, recent = verify_notify.hold_recently_asked(db, payloads, rows, report, day=day)
    finally:
        db.close()
    askable = sorted({c["request_id"] for p in payloads for c in p["credits"] if c["request_id"] in listed})
    # A listed credit the support@ branch held that the documents gate would NOT have held: its
    # account has no proof-on-file entry at all. That is the population the branch silences on
    # its own - the one the report's headline is about. On a tree with the branch gone it is 0 by
    # construction, because nothing is then held for having emailed support@.
    held_only_for_support = sorted(
        rid for rid, _, _ in deferred
        if rid in listed and not documented.get(verify_notify._user_id(rows[rid])))
    return {
        "tree": verify_notify.__file__,
        "rows_read": len(rows),
        "contacts_in_export": len(documented.support_contacts),
        "listed_rows": len(listed),
        "listed_users": len(listed_users),
        # what the run reports today: accounts/credits held for having emailed support@
        # null = this tree has no such counter (the branch is gone), not "measured zero"
        "support_contact_users": getattr(report, "support_contact_users", None),
        "support_contact_credits": getattr(report, "support_contact_credits", None),
        # held by the support@ branch ALONE: the account's credits are removed and it has no
        # proof-on-file entry, so no other gate would have held them
        "held_only_for_support_contact_credits": len(held_only_for_support),
        "held_only_for_support_contact_users": len(
            {verify_notify._user_id(rows[rid]) for rid in held_only_for_support}),
        # the listed users' credits left in the plan after the three gates this tool applies
        # (`screen_live`, `hold_affiliated`, `hold_recently_asked`); `run()` also holds a payload
        # whose account has no professional id (`attach_identities`) and, over its cap with paying
        # status unknown, every payload that day - neither is measured here
        "listed_credits_still_askable": len(askable),
        "run_gates": {
            "closed_on_their_own_document": len(closed),
            "held_by_the_documents_gate": len(deferred),
            "held_by_affiliation": len(affiliated),
            "held_by_the_re_ask_lock": len(recent),
            "proof_on_file": report.proof_on_file,
            "documented_users": report.documented_users,
            "pending_doc_users": report.pending_doc_users,
        },
    }


def decider_hold(admin_api, verify_notify) -> dict:
    """What PR #1992 hands to the senders, from the ledger alone (no admin call).

    The decider still carries its own support@ hold on the newest decision row of some
    requests; #1992 moves those rows onto the ladder. Of the users that brings to this step,
    only the ones with NO document on file reach the support@ branch at all - the rest are
    excluded by the document gate, which stays."""
    db = open_ledger()
    try:
        rows = db.execute("""
            WITH newest AS (SELECT request_id, MAX(id) AS mid FROM decisions GROUP BY request_id)
            SELECT d.request_id AS rid, d.user_id AS uid, d.decision AS dec, d.reason AS reason
            FROM decisions d JOIN newest n ON d.id = n.mid
        """).fetchall()
    finally:
        db.close()
    documented = verify_notify.load_proof_on_file(PROOF)
    mark = "emailed support@ in the last 90 days"
    held = [r for r in rows if r["reason"] and mark in str(r["reason"])]
    no_doc = [r for r in held if str(r["uid"] or "") not in documented]
    return {
        "newest_decision_rows": len(rows),
        "decider_support_hold": {
            "rows": len(held), "requests": len({r["rid"] for r in held}),
            "users": len({str(r["uid"]) for r in held}),
            "by_decision": {d: sum(1 for r in held if r["dec"] == d) for d in sorted({r["dec"] for r in held})},
        },
        "no_document_on_file": {
            "rows": len(no_doc), "requests": len({r["rid"] for r in no_doc}),
            "users": len({str(r["uid"]) for r in no_doc}),
            "users_on_the_support_list": len({str(r["uid"]) for r in no_doc}
                                             & {str(u) for u in documented.support_contacts}),
        },
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("snapshot", help="one read of the ledger + admin API, rows to a file")
    s.add_argument("--out", required=True)
    s.add_argument("--scripts", default="/opt/hydra/scripts")
    c = sub.add_parser("counts", help="the hold counts for one tree, from a snapshot")
    c.add_argument("--snapshot", required=True)
    c.add_argument("--scripts", required=True)
    d = sub.add_parser("decider-hold", help="the population PR #1992 brings to this step (ledger only)")
    d.add_argument("--scripts", default="/opt/hydra/scripts")
    args = ap.parse_args(argv)
    admin_api, verify_notify = load(args.scripts)
    if args.cmd == "snapshot":
        snapshot(admin_api, verify_notify, args.out)
        return 0
    if args.cmd == "decider-hold":
        print(json.dumps(decider_hold(admin_api, verify_notify), indent=1))
        return 0
    print(json.dumps(counts(admin_api, verify_notify, args.snapshot), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
