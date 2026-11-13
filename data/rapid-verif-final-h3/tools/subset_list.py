#!/usr/bin/env python3
"""subset_list: a signed owing list holding only the named users, for a READ-ONLY --check-recipients run.

The outbound tick's check refuses a list whose facts header does not describe exactly the users it holds
(owing_proof.local_diffs). This takes a tick's own owing-uvn.json, keeps the users named by --users (one core user id
per line), and re-derives the header with the DEPLOYED owing_proof.facts_header - the same thing
owing_proof.class_list does for a one-class list. It reads one file and writes one file (--out, which must not be
under a tick's run directory). It sends nothing and is not a way to build a send list: the output names no approval
and was never checked by a tick.

    PYTHONPATH=/opt/hydra/scripts python3 subset_list.py --owing <tick>/owing-uvn.json --users ids.txt --out /tmp/x.json
"""
import argparse
import json
import os
import sys

from credit_review import owing_proof, verify_notify  # the DEPLOYED modules


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--owing", required=True)
    ap.add_argument("--users", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if "/h2-runs/sched/" in os.path.abspath(a.out):
        print("refusing to write inside a tick's run directory", file=sys.stderr)
        return 2
    want = {ln.strip() for ln in open(a.users, encoding="utf-8") if ln.strip()}
    src = json.load(open(a.owing, encoding="utf-8"))
    users = [u for u in src["users"] if str(u["user_id"]) in want]
    doc = {"generated_at": src["generated_at"], "replica_facts": owing_proof.facts_header(users), "users": users,
           "split_of": src.get("split_of"), "signed_on": verify_notify.deployed_head()}
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
    print(json.dumps({"wanted": len(want), "kept": len(users), "paid": sum(1 for u in users if u.get("paid")),
                      "not_on_this_list": len(want) - len(users), "generated_at": src["generated_at"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
