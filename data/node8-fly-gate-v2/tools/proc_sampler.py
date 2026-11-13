#!/usr/bin/env python3
"""Sample the process tree under one command and say where its wall time went.

node-8 has no strace/perf, and the per-user gate (`intercom-verify-request.sh`) is 4,000 lines of bash that
shells out to python helpers, `trino-query.sh` (kubectl exec), curl and jq. This runs a command, polls /proc
every INTERVAL seconds for its descendants, and writes one JSONL row per process seen:

    {"pid", "ppid", "first", "last", "cmd"}

`summarize` then attributes every leaf to the gate call (the `intercom-verify-request.sh` ancestor) it ran
under and prints seconds per gate call and seconds per class of child. Read-only: it never signals a process
and writes only its own --out file.

    proc_sampler.py run --out run.jsonl -- <command...>
    proc_sampler.py summarize run.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time

INTERVAL = 0.05
GATE = "intercom-verify-request.sh"


def _read(path: str) -> bytes:
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


def _children(pid: int) -> list[int]:
    """Direct children of every thread of `pid` (/proc/<pid>/task/<tid>/children): a walk of ONE tree, not of /proc.

    A whole-/proc scan on node-8 (a k8s node, thousands of processes) took longer than the processes being timed.
    """
    out: list[int] = []
    try:
        tids = os.listdir(f"/proc/{pid}/task")
    except OSError:
        return out
    for tid in tids:
        out.extend(int(x) for x in _read(f"/proc/{pid}/task/{tid}/children").split())
    return out


def _snapshot(root: int) -> dict[int, tuple[int, str]]:
    out: dict[int, tuple[int, str]] = {}
    stack = [(root, 0)]
    while stack:
        pid, ppid = stack.pop()
        if pid in out:
            continue
        cmd = _read(f"/proc/{pid}/cmdline").replace(b"\0", b" ").decode("utf-8", "replace").strip()
        out[pid] = (ppid, cmd)
        stack.extend((kid, pid) for kid in _children(pid))
    return out


def run(out_path: str, argv: list[str]) -> int:
    seen: dict[tuple[int, str], dict] = {}
    current: dict[int, dict] = {}
    t0 = time.time()
    proc = subprocess.Popen(argv)
    root = proc.pid
    while True:
        done = proc.poll() is not None
        now = time.time()
        snap = _snapshot(root)
        for pid, (ppid, cmd) in snap.items():
            if not cmd:
                continue
            # a pid changes identity at exec: key on (pid, cmd) so `bash` -> `kubectl` are two rows. k3s's kubectl
            # then MASKS its own argv down to "kubectl" (the SQL is gone from /proc after the first sample), so a
            # command that shrank to a prefix of the row this pid already had is the same process, not a new one.
            prev = current.get(pid)
            if prev is not None and prev["cmd"] != cmd and prev["full"].startswith(cmd):
                row = prev
            else:
                row = seen.setdefault((pid, cmd), {"pid": pid, "ppid": ppid, "first": now, "cmd": cmd[:1200],
                                                   "full": cmd})
            current[pid] = row
            row["last"] = now
        if done:
            break
        time.sleep(INTERVAL)
    with open(out_path, "w") as fh:
        fh.write(json.dumps({"meta": True, "t0": t0, "t1": time.time(), "rc": proc.returncode, "argv": argv,
                             "interval": INTERVAL}) + "\n")
        for row in sorted(seen.values(), key=lambda r: r["first"]):
            row.pop("full", None)
            fh.write(json.dumps(row) + "\n")
    return proc.returncode or 0


_SQL_TAG = re.compile(r"/\*\s*([a-z_0-9]+)\s*\*/")


def classify(cmd: str) -> str:
    """A coarse class for one process's command line."""
    if "kubectl" in cmd and " get pods" in cmd:
        return "trino:kubectl-get-pods"
    if "kubectl" in cmd and " exec " in cmd:
        return "trino:kubectl-exec"
    if "trino-query.sh" in cmd:
        return "trino:wrapper"
    if "curl" in cmd.split(" ", 1)[0]:
        return "curl"
    m = re.search(r"credit_review/([a-z_0-9]+)\.py(?:\s+(?:--db\s+\S+\s+)?(?:--readonly\s+)?([a-z-]+))?", cmd)
    if m:
        return f"py:{m.group(1)}" + (f" {m.group(2)}" if m.group(2) else "")
    m = re.search(r"outbound_copy/([a-z_0-9]+)\.py", cmd)
    if m:
        return f"py:outbound_copy/{m.group(1)}"
    if re.match(r"\S*python3?\b", cmd):
        return "py:inline"
    if re.match(r"\S*jq\b", cmd):
        return "jq"
    if GATE in cmd:
        return "gate:bash"
    head = cmd.split(" ", 1)[0].rsplit("/", 1)[-1]
    return f"other:{head or '?'}"


def sql_shape(cmd: str) -> str:
    """Which table and which caller a `kubectl exec ... trino --execute <SQL>` is, without the ids."""
    sql = cmd.split("--execute", 1)[-1]
    tag = _SQL_TAG.search(sql)
    tables = sorted(set(re.findall(r"postgresql_\w+\.public\.(\w+)|hive\.\"?[\w-]+\"?\.(\w+)", sql)))
    names = ",".join(sorted({a or b for a, b in tables})) or "?"
    cols = "meta" if "json_extract" in sql or "regexp_like" in sql else "plain"
    return f"{names}[{cols}{'/' + tag.group(1) if tag else ''}]"


def lifetimes(rows: list[dict]) -> dict[int, dict]:
    """One entry per PID: an exec (bash -> kubectl) and k3s kubectl masking its argv are the same process."""
    out: dict[int, dict] = {}
    for r in rows:
        d = out.setdefault(r["pid"], {"pid": r["pid"], "ppid": r["ppid"], "first": r["first"], "last": r["last"],
                                      "cmds": []})
        d["first"], d["last"] = min(d["first"], r["first"]), max(d["last"], r["last"])
        d["cmds"].append(r["cmd"])
    return out


def _helper(cmd: str) -> str:
    m = re.search(r"credit_review/([a-z_0-9]+)\.py(?:\s+(?:--db\s+\S+\s+)?(?:--readonly\s+)?([a-z-]+))?", cmd)
    if m:
        return m.group(1) + (f" {m.group(2)}" if m.group(2) else "")
    m = re.search(r"outbound_copy/([a-z_0-9]+)\.py", cmd)
    return f"outbound_copy/{m.group(1)}" if m else ""


def summarize(path: str) -> None:
    rows = [json.loads(line) for line in open(path)]
    meta, rows = rows[0], rows[1:]
    step = meta["interval"]
    life = lifetimes(rows)

    def is_trino(d: dict) -> bool:
        return any("trino-query.sh" in c for c in d["cmds"])

    def is_gate(d: dict) -> bool:
        return any(GATE in c and "trino-query" not in c for c in d["cmds"])

    def ancestors(d: dict):
        seen_pids = {d["pid"]}
        cur = life.get(d["ppid"])
        while cur and cur["pid"] not in seen_pids:
            seen_pids.add(cur["pid"])
            yield cur
            cur = life.get(cur["ppid"])

    def gate_of(d: dict) -> int | None:
        """The TOP gate shell this process ran under (the gate forks subshells with its own command line)."""
        top = d["pid"] if is_gate(d) else None
        for a in ancestors(d):
            if is_gate(a):
                top = a["pid"]
        return top

    gates: dict[int, dict] = {}
    plan_trino: list[tuple[float, str]] = []
    for d in life.values():
        dur = d["last"] - d["first"] + step
        g = gate_of(d)
        anc = list(ancestors(d))
        if is_trino(d):
            if any(is_trino(a) for a in anc):
                continue                                  # the wrapper's own children (get pods, sed, $(...))
            sql = next((c for c in d["cmds"] if "--execute" in c), "")
            shape = sql_shape(sql) if sql else "?[not sampled]"
            if g is None:
                plan_trino.append((dur, shape))
                continue
            owner = next((h for a in anc for c in a["cmds"] if (h := _helper(c))), "gate (bash)")
            G = gates.setdefault(g, {"trino": [], "curl": [], "helpers": {}})
            G["trino"].append((dur, shape, owner))
            continue
        if g is None or d["pid"] == g:
            continue
        G = gates.setdefault(g, {"trino": [], "curl": [], "helpers": {}})
        first = d["cmds"][0]
        if any(c.split(" ", 1)[0].endswith("curl") for c in d["cmds"]):
            G["curl"].append(dur)
        elif (h := next((x for c in d["cmds"] if (x := _helper(c))), "")) and not any(_helper(c) for a in anc for c in a["cmds"]):
            G["helpers"].setdefault(h, []).append(dur)
        del first
    for g, G in gates.items():
        G["wall"] = life[g]["last"] - life[g]["first"] + step
    n = len(gates)
    print(f"run: {meta['t1'] - meta['t0']:.1f}s wall, rc={meta['rc']}, {n} gate call(s) (one per user)")
    if plan_trino:
        print(f"audience/plan read (outside any gate call): {len(plan_trino)} trino invocation(s), "
              f"{sum(x for x, _ in plan_trino):.1f}s")
    if not n:
        return
    walls = sorted(G["wall"] for G in gates.values())

    def pct(xs: list[float], p: float) -> float:
        return xs[min(len(xs) - 1, int(p * len(xs)))]

    total = sum(walls)
    print(f"gate call wall, s per user: mean {statistics.mean(walls):.2f}  p50 {pct(walls, .5):.2f}  "
          f"p90 {pct(walls, .9):.2f}  max {walls[-1]:.2f}  sum {total:.1f}")
    print(f"gate calls at/over the 20s read timeout: {sum(1 for w in walls if w >= 19.9)}   over 10s: "
          f"{sum(1 for w in walls if w >= 10)}")
    ntr = sorted(len(G["trino"]) for G in gates.values())
    tr = [x for G in gates.values() for x in G["trino"]]
    tsum = sum(x[0] for x in tr)
    print(f"trino invocations per user: mean {statistics.mean(ntr):.2f}  p50 {pct(ntr, .5)}  max {ntr[-1]}  "
          f"total {len(tr)}")
    if tr:
        print(f"trino wall: {tsum:.1f}s = {100 * tsum / total:.1f}% of gate wall; {tsum / len(tr):.2f}s per invocation; "
              f"{tsum / n:.2f}s per user")
    cs = [x for G in gates.values() for x in G["curl"]]
    print(f"curl (Intercom): {len(cs)} call(s), {sum(cs):.1f}s = {100 * sum(cs) / total:.1f}% of gate wall; "
          f"{sum(cs) / n:.2f}s per user")
    rest = total - tsum - sum(cs)
    print(f"everything else (bash, jq, python start-up, sqlite): {rest:.1f}s = {100 * rest / total:.1f}%; "
          f"{rest / n:.2f}s per user")
    print("\ntrino by the helper that asked (wall includes kubectl get pods + kubectl exec + the CLI's JVM):")
    by: dict[tuple[str, str], list[float]] = {}
    for dur, shape, owner in tr:
        by.setdefault((owner, shape), []).append(dur)
    for (owner, shape), durs in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        print(f"  {owner:22s} {shape:44s} n={len(durs):4d} per-user={len(durs) / n:5.2f} "
              f"mean={sum(durs) / len(durs):.2f}s sum={sum(durs):7.1f}s")
    print("\nhelper wall (includes the trino and Intercom it waits on):")
    hp: dict[str, list[float]] = {}
    for G in gates.values():
        for h, durs in G["helpers"].items():
            hp.setdefault(h, []).extend(durs)
    for h, durs in sorted(hp.items(), key=lambda kv: -sum(kv[1])):
        print(f"  {h:34s} n={len(durs):4d} mean={sum(durs) / len(durs):6.2f}s sum={sum(durs):7.1f}s "
              f"({100 * sum(durs) / total:.1f}% of gate wall)")
    print("\nper user, slowest first (wall s, trino invocations, trino s):")
    for G in sorted(gates.values(), key=lambda G: -G["wall"])[:12]:
        print(f"  {G['wall']:6.2f}s  trino n={len(G['trino']):2d} {sum(x[0] for x in G['trino']):6.2f}s  "
              f"curl n={len(G['curl']):2d} {sum(G['curl']):5.2f}s")


def timeline(path: str, only: str) -> None:
    """Every sampled process in start order: offset, wall seconds, class, and the SQL shape or the command."""
    rows = [json.loads(line) for line in open(path)]
    meta = rows[0]
    for r in rows[1:]:
        cls = classify(r["cmd"])
        if only and only not in cls and only not in r["cmd"]:
            continue
        what = sql_shape(r["cmd"]) if cls == "trino:kubectl-exec" else r["cmd"][:160]
        print(f"{r['first'] - meta['t0']:8.1f} {r['last'] - r['first']:7.2f}s pid={r['pid']} ppid={r['ppid']} {cls:24s} {what}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--out", required=True)
    r.add_argument("argv", nargs=argparse.REMAINDER)
    s = sub.add_parser("summarize")
    s.add_argument("path")
    t = sub.add_parser("timeline")
    t.add_argument("path")
    t.add_argument("--only", default="")
    a = ap.parse_args()
    if a.cmd == "run":
        argv = a.argv[1:] if a.argv[:1] == ["--"] else a.argv
        if not argv:
            ap.error("run needs a command after --")
        return run(a.out, argv)
    if a.cmd == "timeline":
        timeline(a.path, a.only)
        return 0
    summarize(a.path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
