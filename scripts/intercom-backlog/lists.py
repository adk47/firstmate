#!/usr/bin/env python3
"""intercom-backlog lists: render a triage file (triage.py) as markdown tables with NO PII:
conversation id, action, waiting age, paid flag, assignee. Read-only.

Usage: python3 lists.py <triage.jsonl> captain|actions
  captain -> the captain's list (legal first, then billing; recent before tail; paid first)
  actions -> counts per band x action, plus the conversation ids of every recent (<=30 d) row
"""
import collections
import json
import sys


def main():
    # Several triage files may be given as a comma list; a later file wins per conversation id.
    merged = {}
    for path in sys.argv[1].split(","):
        for l in open(path):
            r = json.loads(l)
            merged[r["id"]] = r
    rows = list(merged.values())
    mode = sys.argv[2]
    if mode == "captain":
        cap = [r for r in rows if r["action"].startswith("captain-")]
        cap.sort(key=lambda r: (r["action"] != "captain-legal", r["band"] == "gt30d",
                                not r["paid"], r["age_days"]))
        print("| conversation | topic | band | waiting (d) | paid | admin assignee |")
        print("|---|---|---|---|---|---|")
        for r in cap:
            print(f"| {r['id']} | {r['action'][8:]} | {r['band']} | {r['age_days']:.0f} | "
                  f"{'paid' if r['paid'] else '-'} | {r['admin_assignee_id'] or '-'} |")
    elif mode == "hold":
        # Everything that needs NEW wording (captain 23:30Z: no new customer copy): held for
        # flows-verify-fable-v1. Gate rows (approved templates, p2 sends), ledger-today and the
        # captain's list are routed elsewhere and are not repeated here.
        routed = ("gate-", "captain-", "ledger-today")
        hold = [r for r in rows if not r["action"].startswith(routed)]
        by = collections.defaultdict(lambda: collections.defaultdict(list))
        for r in sorted(hold, key=lambda r: (not r.get("paid"), r["waiting_since"])):
            by[r["action"]][r["band"]].append(f"{r['id']}{'(paid)' if r.get('paid') else ''}")
        print(f"Held: {len(hold)} conversations.\n")
        for a in sorted(by):
            n = sum(len(v) for v in by[a].values())
            print(f"### {a} ({n})\n")
            for b in ("lt1d", "1-30d", "gt30d"):
                if by[a][b]:
                    print(f"- **{b}** ({len(by[a][b])}): " + ", ".join(by[a][b]))
            print()
    elif mode == "read":
        # Operator terminal only (prints the customer's first-message excerpt): never commit it.
        import time
        now = time.time()
        for r in sorted(rows, key=lambda r: r["waiting_since"]):
            c = r.get("credits") or {}
            print(f"{r['id']} {(now - r['waiting_since']) / 3600:6.1f}h {r['action']:18} "
                  f"paid={int(bool(r.get('paid')))} assignee={r['admin_assignee_id']} "
                  f"pend={c.get('pending', 0)} uvn={c.get('uvn', 0)} claims={r.get('claims')} "
                  f"led={r.get('ledger_msgs')} | {r['excerpt'][:200]}")
    elif mode == "actions":
        c = collections.Counter((r["band"], r["action"]) for r in rows)
        bands = ["lt1d", "1-30d", "gt30d"]
        acts = sorted({a for _, a in c})
        print("| action | " + " | ".join(bands) + " | total |")
        print("|---|" + "---|" * (len(bands) + 1))
        for a in acts:
            n = [c[(b, a)] for b in bands]
            print(f"| {a} | " + " | ".join(map(str, n)) + f" | {sum(n)} |")
        print()
        by = collections.defaultdict(list)
        for r in rows:
            if r["band"] != "gt30d":
                by[r["action"]].append(f"{r['id']}{'(paid)' if r['paid'] else ''}")
        for a in sorted(by):
            print(f"- **{a}** ({len(by[a])}): " + ", ".join(by[a]))


if __name__ == "__main__":
    main()
