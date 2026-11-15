"""Passive timing of the tick's OWN proof-need-ask check: attach to it, start nothing, add no replica or Intercom load.

Read-only. Runs on node-8 from stdin (run_attach.sh prepends `SRC`, the base64 source of
data/node8-fly-gate-v2/tools/proc_sampler.py, whose classify / lifetimes / summarize are reused unchanged). It waits
for the check the tick starts (`need_asks.py send --segment <seg> ... --check-recipients`) under the tick's pid, polls
/proc for that one process tree every 50 ms until it exits, and prints AGGREGATES only.

Command lines can carry secrets: the sampled rows live in memory (a memfd handed to summarize) and are never written
to a disk or printed. The only words of a command line that reach stdout are the helper names and SQL shapes
proc_sampler.summarize already prints, and the `--need <code>` of a gate call.

usage (through run_attach.sh):  python3 -I - <tick pid> [segment=paid] [wait_minutes=120]
"""
import base64
import json
import os
import re
import sys
import time
import types

ps = types.ModuleType("proc_sampler")
exec(compile(base64.b64decode(SRC["proc_sampler"]).decode(), "<proc_sampler.py>", "exec"), ps.__dict__)  # noqa: F821

tick = int(sys.argv[1])
seg = sys.argv[2] if len(sys.argv) > 2 else "paid"
wait_s = 60 * int(sys.argv[3] if len(sys.argv) > 3 else 120)


def stamp(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def is_check(cmd):
    return ("need_asks.py" in cmd and " send " in f" {cmd} " and f"--segment {seg}" in cmd
            and "--check-recipients" in cmd)


print(f"{stamp()} waiting for the {seg} proof-need-ask check under tick pid {tick}", flush=True)
root, deadline = None, time.time() + wait_s
while root is None:
    snap = ps._snapshot(tick)
    if tick not in snap and not os.path.exists(f"/proc/{tick}"):
        print(f"{stamp()} the tick exited before its {seg} check started; nothing sampled")
        sys.exit(3)
    hits = {pid for pid, (_pp, cmd) in snap.items() if is_check(cmd)}
    top = [pid for pid in hits if snap[pid][0] not in hits]
    if top:
        root = top[0]
        break
    if time.time() > deadline:
        print(f"{stamp()} no {seg} check within {wait_s // 60} min; nothing sampled")
        sys.exit(4)
    time.sleep(0.5)

seen, current, t0 = {}, {}, time.time()
while True:
    now = time.time()
    snap = ps._snapshot(root)
    for pid, (ppid, cmd) in snap.items():
        if not cmd:
            continue
        prev = current.get(pid)                       # same identity rule as proc_sampler.run (exec, masked argv)
        if prev is not None and prev["cmd"] != cmd and prev["full"].startswith(cmd):
            row = prev
        else:
            row = seen.setdefault((pid, cmd), {"pid": pid, "ppid": ppid, "first": now, "cmd": cmd[:1200], "full": cmd})
        current[pid] = row
        row["last"] = now
    if not os.path.exists(f"/proc/{root}"):
        break
    time.sleep(ps.INTERVAL)
t1 = time.time()
rows = sorted(seen.values(), key=lambda r: r["first"])
for r in rows:
    r.pop("full", None)
print(f"{stamp()} sampled the {seg} check {stamp(t0)} -> {stamp(t1)} ({t1 - t0:.0f}s wall, attached up to 0.5s late); "
      f"{len(rows)} process rows", flush=True)

# ---- what proc_sampler.summarize does not say: is the gate asked in parallel, and what runs outside it -----------
life = ps.lifetimes(rows)


def is_gate(d):
    return any(ps.GATE in c and "trino-query" not in c for c in d["cmds"])


def chain(d):
    out, cur, guard = [], life.get(d["ppid"]), {d["pid"]}
    while cur and cur["pid"] not in guard:
        guard.add(cur["pid"])
        out.append(cur)
        cur = life.get(cur["ppid"])
    return out


tops = sorted((d for d in life.values() if is_gate(d) and not any(is_gate(a) for a in chain(d))),
              key=lambda d: d["first"])
need_of = {}
for d in life.values():
    owner = next((a["pid"] for a in reversed([d] + chain(d)) if is_gate(a)), None)
    for c in d["cmds"]:
        m = re.search(r"--need[ =]([a-z_]+)", c)
        if owner and m:
            need_of.setdefault(owner, m.group(1))
print(f"gate calls (top-level {ps.GATE}): {len(tops)}")
if tops:
    spans = [(d["first"], d["last"] + ps.INTERVAL) for d in tops]
    print(f"  before the first gate call {spans[0][0] - t0:.1f}s; after the last {t1 - max(e for _s, e in spans):.1f}s")
    edges = sorted({t0, t1, *[x for s in spans for x in s]})
    conc = {}
    for a, b in zip(edges, edges[1:]):
        k = sum(1 for s, e in spans if s <= a and e >= b)
        conc[k] = conc.get(k, 0.0) + (b - a)
    print("  wall seconds with k gate calls alive: " + ", ".join(f"{k}: {v:.1f}s" for k, v in sorted(conc.items())))
    by_need = {}
    for d in tops:
        n = need_of.get(d["pid"], "need not seen")
        by_need.setdefault(n, []).append(d["last"] - d["first"] + ps.INTERVAL)
    for n, v in sorted(by_need.items()):
        print(f"  {n}: {len(v)} calls, {sum(v):.1f}s summed, mean {sum(v) / len(v):.1f}s, max {max(v):.1f}s")
    print("  each call, start offset / seconds / other calls alive at its start / need:")
    for d in tops:
        alive = sum(1 for o in tops if o is not d and o["first"] <= d["first"] < o["last"] + ps.INTERVAL)
        print(f"    +{d['first'] - t0:6.1f}s {d['last'] - d['first'] + ps.INTERVAL:5.1f}s  {alive}  "
              f"{need_of.get(d['pid'], '-')}")

fd = os.memfd_create("hni-rows")
with os.fdopen(fd, "w", closefd=False) as fh:
    fh.write(json.dumps({"meta": True, "t0": t0, "t1": t1, "rc": 0, "argv": ["attached"], "interval": ps.INTERVAL}) + "\n")
    for r in rows:
        fh.write(json.dumps(r) + "\n")
print("---- proc_sampler.summarize ----", flush=True)
ps.summarize(f"/proc/self/fd/{fd}")
