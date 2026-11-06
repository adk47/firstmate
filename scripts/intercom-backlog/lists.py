#!/usr/bin/env python3
"""intercom-backlog lists: render a triage file (triage.py) as markdown tables with NO PII:
conversation id, action, waiting age, paid flag, assignee. Read-only.

Every mode first applies the hand-read captain overrides through overrides.py, the same
loader send.py uses, so the captain list, the hold list and the sender always agree.

Usage: python3 lists.py <triage.jsonl>[,<triage.jsonl>...] captain|hold|actions|read [--overrides PATH]
  captain -> the captain's list (legal/privacy first, then billing; recent before tail; paid first)
  hold    -> every conversation that needs NEW wording (captain 23:30Z): held, ids only
  actions -> counts per band x action, plus the conversation ids of every recent (<=30 d) row
  read    -> operator terminal only (prints customer excerpts): never commit its output
"""
import argparse
import collections
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import overrides  # noqa: E402

# Routed elsewhere, so never on the hold list: gate rows (approved templates; p2 sends),
# ledger-today (already messaged today) and the captain's list.
ROUTED = ("gate-", "captain-", "ledger-today")


def load_rows(paths, ov):
    merged = {}
    for path in paths.split(","):
        with open(path) as f:
            for line in f:
                r = json.loads(line)
                merged[r["id"]] = r  # a later file wins per conversation id
    return overrides.apply(list(merged.values()), ov)


def captain(rows):
    cap = [r for r in rows if r["action"].startswith("captain-")]
    cap.sort(key=lambda r: (r["action"] not in ("captain-legal", "captain-privacy"),
                            r["band"] == "gt30d", not r.get("paid"), r["age_days"]))
    out = ["| conversation | topic | band | waiting (d) | paid | admin assignee |",
           "|---|---|---|---|---|---|"]
    for r in cap:
        out.append(f"| {r['id']} | {r['action'][8:]} | {r['band']} | {r['age_days']:.0f} | "
                   f"{'paid' if r.get('paid') else '-'} | {r.get('admin_assignee_id') or '-'} |")
    return out


def hold(rows):
    held = [r for r in rows if not r["action"].startswith(ROUTED)]
    by = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in sorted(held, key=lambda r: (not r.get("paid"), r["waiting_since"])):
        by[r["action"]][r["band"]].append(f"{r['id']}{'(paid)' if r.get('paid') else ''}")
    out = [f"Held: {len(held)} conversations.", ""]
    for a in sorted(by):
        out += [f"### {a} ({sum(len(v) for v in by[a].values())})", ""]
        for b in ("lt1d", "1-30d", "gt30d"):
            if by[a][b]:
                out.append(f"- **{b}** ({len(by[a][b])}): " + ", ".join(by[a][b]))
        out.append("")
    return out


def actions(rows):
    c = collections.Counter((r["band"], r["action"]) for r in rows)
    bands = ["lt1d", "1-30d", "gt30d"]
    out = ["| action | " + " | ".join(bands) + " | total |", "|---|" + "---|" * (len(bands) + 1)]
    for a in sorted({a for _, a in c}):
        n = [c[(b, a)] for b in bands]
        out.append(f"| {a} | " + " | ".join(map(str, n)) + f" | {sum(n)} |")
    return out


def read(rows):
    now = time.time()
    out = []
    for r in sorted(rows, key=lambda r: r["waiting_since"]):
        c = r.get("credits") or {}
        out.append(f"{r['id']} {(now - r['waiting_since']) / 3600:6.1f}h {r['action']:18} "
                   f"paid={int(bool(r.get('paid')))} assignee={r.get('admin_assignee_id')} "
                   f"pend={c.get('pending', 0)} uvn={c.get('uvn', 0)} claims={r.get('claims')} "
                   f"led={r.get('ledger_msgs')} | {r.get('excerpt', '')[:200]}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("triage")
    ap.add_argument("mode", choices=("captain", "hold", "actions", "read"))
    ap.add_argument("--overrides", default=overrides.DEFAULT_PATH)
    a = ap.parse_args()
    try:
        ov = overrides.load(a.overrides)
    except overrides.OverridesError as e:
        sys.exit(f"REFUSED: {e}")
    rows = load_rows(a.triage, ov)
    print("\n".join({"captain": captain, "hold": hold, "actions": actions, "read": read}[a.mode](rows)))


if __name__ == "__main__":
    main()
