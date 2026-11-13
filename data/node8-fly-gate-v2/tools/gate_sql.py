#!/usr/bin/env python3
"""Print, for the N slowest gate calls of a proc_sampler run, every replica statement in start order.

    gate_sql.py RUN.jsonl [--gates 2] [--width 1200]

Read-only on the sample file. It answers "which statements does ONE user cost, and who issues them".
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proc_sampler as ps  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--gates", type=int, default=2)
    ap.add_argument("--width", type=int, default=1200)
    a = ap.parse_args()
    rows = [json.loads(line) for line in open(a.path)]
    t0 = rows[0]["t0"]
    life = ps.lifetimes(rows[1:])

    def cmd_of(p: dict) -> str:
        return max(p["cmds"], key=len)

    def is_gate(p: dict) -> bool:
        return any("intercom-verify-request.sh" in c and " send " in c + " " for c in p["cmds"])

    def chain(pid: int) -> list[int]:
        out = []
        while pid in life:
            out.append(pid)
            pid = life[pid]["ppid"]
        return out

    gates = {pid: p for pid, p in life.items() if is_gate(p) and not any(is_gate(life[a]) for a in chain(p["ppid"]))}
    slow = sorted(gates, key=lambda g: gates[g]["last"] - gates[g]["first"], reverse=True)[: a.gates]
    for g in slow:
        gp = gates[g]
        print(f"=== gate pid={g} start=+{gp['first'] - t0:.1f}s wall={gp['last'] - gp['first']:.2f}s")
        kids = [p for pid, p in life.items() if g in chain(pid) and pid != g]
        for p in sorted(kids, key=lambda p: p["first"]):
            cmd = cmd_of(p)
            if "trino --execute" in cmd:
                helper = ""
                for anc in chain(p["ppid"]):
                    helper = ps._helper(cmd_of(life[anc]))
                    if helper:
                        break
                sql = " ".join(cmd.split("trino --execute", 1)[1].split())
                print(f"  +{p['first'] - gp['first']:6.2f}s {p['last'] - p['first']:5.2f}s [{helper or 'gate shell'}]\n      {sql[: a.width]}")
            elif ps._helper(cmd):
                print(f"  +{p['first'] - gp['first']:6.2f}s {p['last'] - p['first']:5.2f}s HELPER {ps._helper(cmd)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
