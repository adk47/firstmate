#!/usr/bin/env python3
"""Run scripts/credit_review/never_asked_digest.py over a read-only snapshot and print counts. Sends nothing.

The snapshot is a directory of files pulled read-only from the core replica and node-8 (they hold user and request
ids, so they are not committed). Each file, and the read that produced it, is listed in ../report.md under "How
these numbers were read":

  facts.csv           pending requests: id, userid, createdat, paid, core proofRequest marker, ...
  ledger.psv          verify_requests: request_id | message status | ...
  messages.psv        verify_messages: id | account_id | campaign | kind | status | message_type | day | reason | n
  proof-on-file.json  /var/lib/credit-trust/proof-on-file.json (entries + gmail_contacts_90d)
  dspcap.psv          dsp_captures: id | user_id | submitted_at | closed | reads | request_ids_json
  dsp.csv             pending requests carrying core's freshDspCapture: id, status, decidedAt, ...

  python3 data/never-asked-canary-r1/tools/audience_from_snapshot.py SNAPSHOT_DIR --now 2026-11-15T00:39:00Z

Only counts are printed: no user id and no request id reaches stdout.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import never_asked_digest as nad  # noqa: E402

CAPTURE_WINDOW = timedelta(minutes=100)     # dspverify/runner.py CLOSE_AFTER: past it a waiting reading is final
NEVER_AGAIN_STATUS = ("refused", "rejected")


def stamp(text: str) -> datetime:
    return datetime.fromisoformat(text.strip().replace("Z", "+00:00")).astimezone(timezone.utc)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot")
    ap.add_argument("--now", required=True, help="the instant the snapshot was read, e.g. 2026-11-15T00:39:00Z")
    ap.add_argument("--stop-list", default="", help="a JSON array of user ids to leave out")
    args = ap.parse_args()
    snap, now = Path(args.snapshot), stamp(args.now)

    with open(snap / "facts.csv", newline="") as fh:
        facts = [r for r in csv.reader(fh) if r and r[0] != "_col0"]
    pending = [nad.Pending(r[0], r[1], r[2], r[3] == "1", r[4] == "1") for r in facts]
    user_of = {r[0].lower(): r[1].strip() for r in facts}
    asked = {line.split("|", 1)[0] for line in open(snap / "ledger.psv") if line.strip()}
    if not pending or not asked:
        sys.exit("an empty read is not a measurement: nothing printed")

    told, other, never, no_account = set(), set(), set(), 0
    for line in open(snap / "messages.psv"):
        f = line.rstrip("\n").split("|")
        if len(f) < 5:
            continue
        account, campaign, status = f[1].strip(), f[2], f[4]
        if not account:
            no_account += status in NEVER_AGAIN_STATUS
            continue
        if status in NEVER_AGAIN_STATUS:
            never.add(account)
        elif status == "sent":
            (told if campaign == "uvn-status" else other).add(account)

    proof = json.loads((snap / "proof-on-file.json").read_text())
    documents = {str(e["user_id"]) for e in proof["entries"] if e.get("user_id") is not None}
    support = {str(u) for u in proof["gmail_contacts_90d"]["user_ids"]}

    in_flight = set()
    for line in open(snap / "dspcap.psv"):
        f = line.rstrip("\n").split("|", 5)
        if len(f) >= 4 and f[3] == "0":
            in_flight.add(f[1].strip())
    open_captures = len(in_flight)
    with open(snap / "dsp.csv", newline="") as fh:
        for r in csv.reader(fh):
            if len(r) < 3 or r[0] == "_col0" or not r[2]:
                continue
            try:
                fresh = now - stamp(r[2]) < CAPTURE_WINDOW
            except ValueError:
                continue
            if fresh and user_of.get(r[0].lower()):
                in_flight.add(user_of[r[0].lower()])

    stopped = nad.load_stop_list(args.stop_list) if args.stop_list else frozenset()
    aud = nad.build(pending, asked, nad.Holds(
        stopped=stopped, never_again=frozenset(never), document_on_file=frozenset(documents),
        told_by_us=frozenset(told), other_note=frozenset(other), support_contacted=frozenset(support),
        dsp_in_flight=frozenset(in_flight)))

    per_user = [d.user_id for d in aud.digests]
    if len(per_user) != len(set(per_user)):
        sys.exit("a customer has two digests: nothing printed")
    counts = aud.counts()
    counts["pending_requests"] = len(pending)
    for row in pending:     # the requests behind each left-out row: never-asked, not asked about by core
        why = aud.left_out.get(row.user_id.strip())
        if why and not row.core_asked and row.request_id.lower() not in asked:
            counts[f"left_out_{why}_requests"] = counts.get(f"left_out_{why}_requests", 0) + 1
    counts["customers_with_a_request_core_did_not_ask_about"] = len(aud.digests) + len(aud.left_out)
    counts["digests_free"] = counts["digests"] - counts["digests_paid"]
    counts["largest_digest_requests"] = max((len(d.request_ids) for d in aud.digests), default=0)
    counts["customers_with_an_open_dsp_capture"] = open_captures
    counts["customers_dsp_in_flight_any"] = len(in_flight)
    counts["refused_rows_with_no_account_id_not_applied"] = no_account
    decision = nad.decide(nad.read_canary({}), remaining=len(aud.digests))
    counts["canary_may_offer_now"] = decision.may_offer
    filled = nad.decide(nad.read_canary({d.user_id: "sent" for d in aud.digests}), remaining=0)
    counts["verdict_if_every_digest_were_sent_and_none_refused"] = f"{filled.verdict}:{filled.reason}"
    print(json.dumps(counts, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
