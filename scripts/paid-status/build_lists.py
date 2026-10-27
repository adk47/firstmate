#!/usr/bin/env python3
"""p2: classify output (cls/dry-run-*.json) + segments.json -> runner lists for the Intercom route
(list-{A,B,U}.json, the deployed uvn-status runner's format) and the email route (email-lists.json).
Ask-only users (1-9 big-track single-signal rows, Fable Ruling B) go on the ask list only, never A/B0. READ ONLY."""
import collections, glob, json
from datetime import datetime, timezone
D = __import__("os").environ["PWR_DIR"]  # the run dir (daily.sh sets it)
dry = sorted(glob.glob(f"{D}/cls/dry-run-*.json"))[-1]
seg = {r["user_id"]: r for r in json.load(open(f"{D}/segments.json"))}
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
CAMP = {"A_DOC": "status-doc-received", "B_TEAM": "status-team-review", "UVN_ASK": "uvn-status"}
intercom, email, moved = collections.defaultdict(list), collections.defaultdict(list), collections.Counter()
for r in sorted(json.load(open(dry)), key=lambda r: r.get("oldest_pending") or ""):  # oldest first (firstmate 008 f)
    s = seg[r["user_id"]]
    assert not (s["msg_hold"] or s["lens_held"] or s["cs_excluded"]), r["user_id"]
    cls = r["class"]
    if s["ask_only"] and cls != "UVN_ASK":
        moved[cls] += 1
        cls = "UVN_ASK"
    row = {"user_id": r["user_id"], "paid": __import__("os").environ.get("SEGMENT", "paid") == "paid", "skip": None, "request_ids": r["request_ids"], "class": cls}
    (email if (s["identity_hold"] or s["forbidden"]) else intercom)[cls].append(row)
# Every class list of this run is rewritten, absent ones removed (QA on #1384): the 00:30Z and 15:00Z runs
# share this dir, so a list left from an earlier run would otherwise be sent again.
for cls, short in (("A_DOC", "A"), ("B_TEAM", "B"), ("UVN_ASK", "U")):
    if cls not in intercom and __import__("os").path.exists(f"{D}/list-{short}.json"):
        __import__("os").remove(f"{D}/list-{short}.json")
for cls, users in intercom.items():
    json.dump({"generated_at": now, "source": "paid-wave-runner-p2 " + dry.rsplit("/", 1)[1], "campaign": cls, "users": users},
              open(f"{D}/list-{dict(A_DOC='A', B_TEAM='B', UVN_ASK='U')[cls]}.json", "w"), indent=1)
json.dump({CAMP[c]: [{"user_id": u["user_id"], "request_ids": u["request_ids"]} for u in us] for c, us in email.items()},
          open(f"{D}/email-lists.json", "w"), indent=1)
print({"intercom": {c: len(u) for c, u in intercom.items()}, "email": {c: len(u) for c, u in email.items()},
       "ask_only_moved_to_U": dict(moved)})
