#!/usr/bin/env python3
"""The reviewer-host half of the outbound copy gate: fetch the bodies node-8 is holding, review them, write the
signed verdicts back.

node-8 (the sender) cannot reach the reviewer model and does not hold the signing key, on purpose: it can verify a
verdict and it cannot mint one. So the review is PULLED from the host that can do both:

    1. ssh <sender> gate.py export-pending          the held bodies, one JSON line each
    2. gate.py review  (this tree, this host)       reviewer model + rubric -> signed statements
    3. ssh <sender> gate.py import-verdicts         node-8 stores only what the pinned key signed

This script sends nothing and decides nothing about a request. If the reviewer or the link is down, the bodies stay
held on node-8 and the next run picks them up; nothing is ever approved by default.

    review_pull.py --remote 'ssh -J root@JUMP root@10.0.0.8' --key ~/.config/muso/outbound-copy-reviewer/id_ed25519

Exit codes: 0 the round completed (including "nothing was waiting"), 1 some bodies are still unreviewed (reviewer
unavailable or unanswered), 2 the round could not run (link down, the two hosts enforce different rubrics, bad key).
Standard library only.
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "gate.py"
REMOTE_GATE = "/opt/hydra/scripts/outbound_copy/gate.py"
NAME_RE = re.compile(r"^[0-9a-f]{64}\.[0-9a-f]{16}\.json$")
SSH_TIMEOUT_S = 120


class PullError(Exception):
    pass


def remote(prefix: list[str], remote_gate: str, args: list[str], stdin: str = "") -> str:
    """Run `python3 -I <remote_gate> <args>` on the sender. An empty prefix runs it on this host (tests)."""
    inner = ["/usr/bin/python3", "-I", remote_gate, *args]
    argv = [*prefix, " ".join(shlex.quote(a) for a in inner)] if prefix else [sys.executable, "-I", remote_gate, *args]
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=SSH_TIMEOUT_S, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PullError(f"the sender could not be reached: {exc}") from exc
    if p.returncode != 0:
        raise PullError(f"the sender's gate answered rc={p.returncode}: {(p.stderr or p.stdout).strip()[:300]}")
    return p.stdout


def local(args: list[str]) -> str:
    p = subprocess.run([sys.executable, "-I", str(GATE), *args], capture_output=True, text=True, check=False)
    if p.returncode != 0:
        raise PullError(f"this host's gate answered rc={p.returncode}: {(p.stderr or p.stdout).strip()[:300]}")
    return p.stdout


def pull_once(prefix: list[str], remote_gate: str, remote_store: str, key: Path, reviewer_cmd: str = "",
              limit: int = 0) -> tuple[int, dict]:
    store_args = ["--store", remote_store] if remote_store else []
    # the two hosts must enforce the same rules, or every verdict signed here is void there and the queue never drains
    theirs, ours = remote(prefix, remote_gate, ["rubric-sha256"]).strip(), local(["rubric-sha256"]).strip()
    if theirs != ours:
        raise PullError(f"rubric mismatch: the sender enforces {theirs[:16]} and this host {ours[:16]}; "
                        "deploy the same policies/outbound-copy-rubric.md to both before reviewing")
    lines = [ln for ln in remote(prefix, remote_gate, ["export-pending", *store_args]).splitlines() if ln.strip()]
    out: dict = {"waiting": len(lines), "skipped_bad_line": 0}
    if not lines:
        return 0, {**out, "review": {}, "import": {"stored": 0, "rejected": 0}}
    work = Path(tempfile.mkdtemp(prefix="ocg-pull-"))
    try:
        (work / "pending").mkdir()
        for ln in lines:
            try:
                row = json.loads(ln)
                name, request = row["name"], row["request"]
                if not NAME_RE.match(name) or not isinstance(request, str):
                    raise ValueError(name)
            except (ValueError, KeyError, TypeError):
                out["skipped_bad_line"] += 1
                continue
            (work / "pending" / name).write_text(request, encoding="utf-8")
        args = ["review", "--pending-dir", str(work / "pending"), "--out-dir", str(work / "out"), "--key", str(key)]
        if reviewer_cmd:
            args += ["--reviewer-cmd", reviewer_cmd]
        if limit:
            args += ["--limit", str(limit)]
        out["review"] = json.loads(local(args).strip().splitlines()[-1])
        rows = []
        for f in sorted((work / "out" / "verdicts").glob("*.json")) if (work / "out" / "verdicts").is_dir() else []:
            sig = Path(str(f) + ".sig")
            if sig.is_file():
                rows.append(json.dumps({"statement": f.read_text(encoding="ascii"),
                                        "signature": sig.read_text(encoding="ascii")}))
        out["import"] = {"stored": 0, "rejected": 0}
        if rows:
            out["import"] = json.loads(
                remote(prefix, remote_gate, ["import-verdicts", *store_args], stdin="\n".join(rows) + "\n")
                .strip().splitlines()[-1])
        # the reviewer's raw answers are the evidence behind each verdict's response_sha256: keep them
        if (work / "out" / "responses").is_dir():
            keep = Path.home() / ".local" / "state" / "muso" / "outbound-copy-review" / "responses"
            keep.mkdir(parents=True, exist_ok=True)
            for f in (work / "out" / "responses").glob("*.txt"):
                shutil.copy2(f, keep / f.name)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    rv = out["review"]
    left = rv.get("reviewer_unavailable", 0) + rv.get("unanswered", 0) + out["import"].get("rejected", 0)
    return (1 if left else 0), out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--remote", default="", help="the command prefix that reaches the sender, e.g. 'ssh -J root@jump "
                                                 "root@10.0.0.8' (empty: the sender's gate is on this host)")
    ap.add_argument("--remote-gate", default=REMOTE_GATE)
    ap.add_argument("--remote-store", default="", help="default: the sender gate's own default store")
    ap.add_argument("--key", required=True, help="the reviewer's signing key (never copied to the sender)")
    ap.add_argument("--reviewer-cmd", default="", help="tests only: a stand-in reviewer; it can never approve a send")
    ap.add_argument("--limit", type=int, default=0, help="review at most N bodies this round")
    a = ap.parse_args(argv)
    try:
        if not Path(a.key).is_file():
            raise PullError(f"signing key not found: {a.key}")
        rc, out = pull_once(shlex.split(a.remote), a.remote_gate, a.remote_store, Path(a.key), a.reviewer_cmd, a.limit)
    except (PullError, ValueError, OSError) as exc:
        print(json.dumps({"result": "error", "reason": str(exc)[:400]}))
        return 2
    print(json.dumps({"result": "ok" if rc == 0 else "incomplete", **out}, sort_keys=True))
    return rc


if __name__ == "__main__":
    sys.exit(main())
