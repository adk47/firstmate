#!/usr/bin/env python3
"""How uvn-status would class each row the score-approve dry run decided. READ-ONLY, no network.

    python3 ask_class_read.py <out.jsonl>          (run from the repository root)

Reads the dry run's decision log (its `row` and `gate` lines; the file carries customer names and
e-mails, so it is read in place and never committed) and runs the repository's own
`credit_review.uvn_status._no_ask_of` on the admin row each decision was made on. That is the
function the uvn-status ask uses to leave a request out: `approval_path` and `already_on_profile`
are never asked about (`uvn_status.NO_ASK`), `low_risk_asked` and '' keep the ask. Prints counts
per decision group only: no ids, no names.
"""
import collections
import json
import os
import sys
from pathlib import Path

ROOT = Path(os.environ["ASK_CLASS_REPO"]) if os.environ.get("ASK_CLASS_REPO") else Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import uvn_status  # noqa: E402


def reason_class(decision: str, reason: str) -> str:
    if decision == "approve":
        return "approve"
    why = reason.split("score approval not now: ", 1)[-1]
    for mark in ("proof on file", "Intercom conversation since the ask"):
        if "engaged user (" + mark in why:
            return "engaged: " + mark
    return why.split(" (")[0].split(":")[0][:60]


def main(path: str) -> int:
    rows, gates = {}, {}
    for line in open(path, encoding="utf-8"):
        o = json.loads(line)
        if o.get("k") == "row":
            rows[o["id"]] = o          # a later pass replaces an earlier one
        elif o.get("k") == "gate":
            gates[str(o["user"])] = o
    table: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for o in rows.values():
        live = o.get("live") or {}
        cls = uvn_status._no_ask_of(o.get("roles") or "", live.get("spotifyPopularity"),
                                    live.get("verificationData"), live.get("metadata"))
        group = reason_class(o["decision"], o.get("reason") or "")
        if group == "approve":
            g = gates.get(str(o["user"])) or {}
            green = g.get("band") == "green" and not (g.get("extra") or {}).get("watch")
            group = "approve: green at the gate" if green else "approve: not green at the gate (held by the rule)"
        table[group][cls or "(asked: no class)"] += 1
    print(json.dumps({"rows": len(rows), "never_asked_classes": list(uvn_status.NO_ASK),
                      "groups": {g: dict(c) for g, c in sorted(table.items(), key=lambda kv: -sum(kv[1].values()))}},
                     indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
