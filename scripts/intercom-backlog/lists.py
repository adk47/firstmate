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
    rows = [json.loads(l) for l in open(sys.argv[1])]
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
