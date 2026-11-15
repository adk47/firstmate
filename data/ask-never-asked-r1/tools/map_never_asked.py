#!/usr/bin/env python3
"""Map the never-asked pending requests to one cell each: family, segment, stop, age band.

Reads the snapshot files this task pulled read-only on 2026-11-14 20:48Z into
data/ask-never-asked-r1/scratch/ (not committed: they hold request and user ids):
  pending.csv        core replica, status=user_verification_needed
  pending_facts.csv  paid flag and the core proofRequest marker per request
  sets.json          "none" = pending request ids with no verify_requests row
  owing.json         the builder's list of the 20:31Z tick (class per request)
  uvn_na_cause.json  newest uvn-status gate outcome per user, else the proof-on-file export
Prints a markdown table whose rows sum to len(sets["none"]). Sends nothing.
"""
import collections
import csv
import datetime
import json
import os
import re
import sys

S = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scratch")
NOW = datetime.datetime(2026, 11, 14, 20, 48)
BANDS = [(7, "0-7 d"), (30, "8-30 d"), (90, "31-90 d"), (180, "91-180 d"), (10**6, "over 180 d")]

STOPS = [  # (pattern in the recorded cause, stop, kind)
    ("documents_on_file", "document on file, no stage 2 verdict (`stage2_verdicts`)", "hold marker"),
    ("support_contacted", "`SUPPORT_CONTACTED_HOLD` (emailed support@ in 90 d)", "hold marker"),
    ("runner other", "runner hold, not recorded per user", "not determined"),
    ("c2_signed_only", "`c2_signed_only` (arming row `uvn-status:c2`)", "hold marker"),
    ("comm_state", "`HELD comm_state`", "hold marker"),
    ("messaged_7d", "`messaged_7d`", "7-day wait"),
    ("core_notice", "`core_notice_within_7d`", "7-day wait"),
    ("G5", "gate refusal `G5` (field carries a link or markup)", "hold marker"),
    ("gate_timeout", "gate call timed out", "unmeasured"),
    ("inapp_not_armed", "`inapp_not_armed`", "no channel"),
    ("no_channel", "`HELD no_channel`", "no channel"),
    ("Intercom", "Intercom identity refusal (`intercom-reconcile`)", "hold marker"),
    ("sanitis", "outbound sanitiser refusal", "hold marker"),
]


def stop_for(cause):
    for pat, stop, kind in STOPS:
        if pat in cause:
            return stop, kind
    return "other gate refusal: " + re.sub(r"\d+", "N", cause)[:40], "hold marker"


def band(created):
    d = (NOW - datetime.datetime.strptime(created[:19], "%Y-%m-%d %H:%M:%S")).days
    return next(name for top, name in BANDS if d <= top)


def main():
    none = set(json.load(open(os.path.join(S, "sets.json")))["none"])
    cls, seg = {}, {}
    for e in json.load(open(os.path.join(S, "owing.json")))["users"]:
        for r in e["request_ids"]:
            cls.setdefault(r.lower(), e["class"])
            seg.setdefault(r.lower(), "paid" if e["paid"] else "free")
    cause = json.load(open(os.path.join(S, "uvn_na_cause.json")))
    facts = {r[0].lower(): r for r in csv.reader(open(os.path.join(S, "pending_facts.csv")))}
    cells = collections.defaultdict(collections.Counter)
    total = 0
    for rid, uid, created, _upd, _prof in csv.reader(open(os.path.join(S, "pending.csv"))):
        rid = rid.lower()
        if rid not in none:
            continue
        total += 1
        f = facts.get(rid, [rid, uid, "0", "0", "", ""])
        s = seg.get(rid) or ("paid" if f[2] == "1" else "free")
        c = cls.get(rid)
        if c == "uvn_new_rows":
            key = ("`uvn-new-rows`", s, "copy lock `UVN_NEW_ROWS_COPY_APPROVED=0`; no tick family runs it", "copy lock")
        elif c == "uvn":
            stop, kind = stop_for((cause.get(uid) or ["", "runner other"])[1])
            key = ("`uvn-status`", s, stop, kind)
        elif c:
            key = (f"class `{c}`", s, "not an ask class", "not determined")
        elif not uid:
            key = ("none", s, "request has no `userid`", "no channel")
        elif f[3] == "1":
            key = ("none (core asked)", s, "core `proofRequest` notice already sent; not owed a ledger ask", "not a stop")
        else:
            key = ("none", s, "on no list", "not determined")
        cells[key][band(created)] += 1
    names = [n for _, n in BANDS]
    print("| family | segment | stop | kind | " + " | ".join(names) + " | requests |")
    print("|---|---|---|---|" + "---|" * (len(names) + 1))
    for key, c in sorted(cells.items(), key=lambda kv: (kv[0][0], kv[0][1], -sum(kv[1].values()))):
        print("| " + " | ".join(key) + " | " + " | ".join(f"{c[n]:,}" if c[n] else "" for n in names)
              + f" | {sum(c.values()):,} |")
    tot = collections.Counter()
    for c in cells.values():
        tot.update(c)
    print("| **total** | | | | " + " | ".join(f"{tot[n]:,}" for n in names) + f" | **{sum(tot.values()):,}** |")
    kinds = collections.Counter()
    for key, c in cells.items():
        kinds[key[3]] += sum(c.values())
    print("\nby kind of stop: " + "; ".join(f"{k} {v:,}" for k, v in kinds.most_common()))
    if total != len(none) or sum(tot.values()) != total:
        sys.exit(f"does not sum: {total} rows read, {len(none)} never-asked ids")


if __name__ == "__main__":
    main()
