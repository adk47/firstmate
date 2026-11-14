#!/usr/bin/env python3
"""credit-notify-tick: tell the users whose credits were approved through the precedent rule and never told.

Every run (`credit-notify-tick.timer` on node-8, every 20 minutes):
  1. reads `decision_told` for the users this path already tried (a killed run resumes);
  2. builds the untold list and takes those users out of it (`credit_review/notify_tick.py`);
  3. walks the list in chunks (`credit_review/notify_chunks.py`): dry run, tell every user the route affirmed,
     carry the others into the next chunk with the reason;
  4. writes the status line for the sentinel and the whole run's account to `notify-tick/last-run.json`.

It never abandons a chunk because few of its users were affirmed. The stops are named in `notify_chunks.py`.
The send itself, its ladder, its day cap and its kill file are `credit-decision-told.py`'s and are unchanged.

The ladder's read-back rung is read from the `decision_told` LEDGER, never from an environment variable: a ledger
with more apply attempts than `decision_told.FIRST_LIVE_LIMIT` proves an operator climbed the rung, and only then
does the tick name a prior confirmed send itself (`notify_chunks.ladder_state`). When the ladder refuses for want of
that read back, the run has FAILED: it exits non-zero, and the status line names the stop, the users it blocked and
the run id a person has to read back — read from the ledger AFTER the run, so a first-ever live run names the run
its own apply just wrote. "sent 0 this run" is never all the run says.

A chunk whose sender call fails outright is a run-level fact, not a quiet zero: `notify_chunks` records every such
failure in the run summary (`sender_failures`), the status line leads with `SENDER FAILED in chunk <n> (<call> rc
<rc>)`, and the run FAILS. The other chunks are still asked, and each user of the failed chunk keeps its own reason.

Kill file `/etc/hydra/credit-notify-tick.disabled` stops this tick alone, before it reads anything and again
before every chunk; `/etc/hydra/credit-decision-told.disabled` stops the sender for every caller.

Exit 0 = nothing left, or the run finished with no sender failure (a named stop or a kill file included). Exit 1 =
the list or the ledger could not be read, the run could not be measured, a chunk's dry run or apply failed outright,
or the ladder stopped it for want of a read-back run; the timer retries.

Reviewed baseline: deploy overwrites. node-8 carries a hand-written copy of this file that was never in git
(sha256 2e048c35cc06..., two hand patches 2026-11-11). This is its port, so the deploy's three-way check has no
baseline to compare the server's bytes with and must take the repository's.

Kept as the host has it, on purpose: the list comes from `/root/mklist2.js`, copied into a core-backend pod and run
there under a name derived from the statement's own sha, so a copy that fails can never leave an older revision to
run in its place. Replacing it with `notify_tick.build_list` is the open item that module's docstring names (its
statement's runtime on the replica is not measured) and is not part of this change.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import notify_chunks as nc  # noqa: E402
from credit_review import notify_tick as nt  # noqa: E402

SCRIPT = Path(__file__).resolve().parent / "credit-decision-told.py"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
WORK = Path("/var/lib/hydra/credit-review/notify-tick")
STATUS = Path("/var/lib/hydra/credit-review/notify-tick-status.txt")
LIST_JS = Path("/root/mklist2.js")
POD_JS = "/tmp/mklist2-{sha}.js"  # tmp-ok: a path inside the core-backend pod, where the host tick copies the query
#: this tick's own switch. Present = the tick reads nothing, asks nothing and sends nothing; it is looked at
#: again before every chunk. The sender keeps its own (`decision_told.KILL_FILE`), which stops every caller.
KILL_FILE = "/etc/hydra/credit-notify-tick.disabled"


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}", flush=True)


def _kubectl(args: list[str], timeout_s: int) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=timeout_s, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"kubectl did not run: {type(exc).__name__}")
        return None


def build_list() -> dict[str, Any] | None:
    """The class, read by the host's own query in a core-backend pod. None = it could not be read."""
    if not LIST_JS.exists():
        log(f"{LIST_JS} missing")
        return None
    pods = _kubectl(["-n", "muso-prod", "get", "pod", "-l", "app=core-backend-api", "--no-headers",
                     "-o", "custom-columns=:metadata.name"], 60)
    if pods is not None and pods.returncode != 0:
        log(f"pod lookup failed: {pods.stderr.strip()[:200]}")
        return None
    if pods is None or not pods.stdout.split():
        log("no core-backend pod")
        return None
    pod = pods.stdout.split()[0]
    remote = POD_JS.format(sha=hashlib.sha256(LIST_JS.read_bytes()).hexdigest()[:12])
    p = _kubectl(["cp", str(LIST_JS), f"muso-prod/{pod}:{remote}"], 120)
    if p is None or p.returncode != 0:
        log(f"list copy failed: {(p.stderr.strip() if p else '')[:200]}")
        return None
    r = _kubectl(["-n", "muso-prod", "exec", pod, "--", "node", remote], 300)
    if r is None or r.returncode != 0:
        log(f"list build failed: {(r.stderr if r else '')[:200]}")
        return None
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        log("list build failed: the pod's answer is not JSON")
        return None
    return doc if isinstance(doc, dict) else None


def told(argv: list[str], timeout_s: int) -> tuple[int, str]:
    """Run credit-decision-told.py. A run that outlives its timeout is exit 124; its rows are in the ledger."""
    try:
        p = subprocess.run([sys.executable, str(SCRIPT), *argv], capture_output=True, text=True, timeout=timeout_s,
                           check=False)
    except subprocess.TimeoutExpired:
        return 124, ""
    if p.returncode != 0 and p.stderr.strip():
        log(f"credit-decision-told {argv[0]}: {p.stderr.strip()[-200:]}")
    return p.returncode, p.stdout


def _read(ledger: str, fn):
    db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True, timeout=30)
    try:
        return fn(db)
    finally:
        db.close()


def main(*, build=build_list, told=told, ledger: str = LEDGER, work: Path = WORK, status: Path = STATUS,
         max_chunks: int | None = None, chunk: int = nc.CHUNK, kill_file: str = KILL_FILE) -> int:
    """The keyword parameters are TEST SEAMS only; the __main__ entry never passes them. The one operator knob is
    the unit's NOTIFY_MAX_CHUNKS. The ladder's read-back run id is read from the ledger, never from the environment."""
    max_chunks = int(os.environ.get("NOTIFY_MAX_CHUNKS", "6")) if max_chunks is None else max_chunks
    work.mkdir(parents=True, exist_ok=True)
    if os.path.exists(kill_file):
        log(f"kill file {kill_file} present: nothing read, nothing sent")
        status.write_text(f"notify-tick: disabled by kill file {kill_file}\n")
        return 0
    try:
        tried, (readback, _) = _read(ledger, lambda db: (nt.already_told(db), nc.ladder_state(db)))
    except (nt.NotifyTickError, sqlite3.Error) as exc:
        log(f"ledger unreadable: {exc}")
        status.write_text("notify-tick: ledger unreadable\n")
        return 1
    doc = build()
    try:
        doc = nt.select(doc, tried) if doc is not None else None
    except (KeyError, TypeError, ValueError) as exc:
        log(f"list unreadable: {type(exc).__name__}: {exc}")
        doc = None
    if doc is None:
        status.write_text("notify-tick: list build failed\n")
        return 1
    users = doc["users"]
    if not users:
        status.write_text("notify-tick: nothing left to notify\n")
        log("nothing left")
        return 0
    log(f"{len(users)} users untold, up to {max_chunks} chunk(s) of {chunk} new users this run"
        + (f"; read back run {readback}" if readback else "; the ladder's read back is not climbed by this tick"))
    try:
        summary = nc.run(doc, told=told, outcomes=lambda ids: _read(ledger, lambda db: nc.live_outcomes(db, ids)),
                         work=work, log=log, chunk=chunk, max_chunks=max_chunks, readback=readback,
                         halt=lambda: "kill_file" if os.path.exists(kill_file) else "")
        (work / "last-run.json").write_text(json.dumps(summary, indent=1, sort_keys=True))
        wanted = _read(ledger, lambda db: nc.ladder_state(db))[1]
    except (nt.NotifyTickError, sqlite3.Error) as exc:
        log(f"run not measured: {exc}")
        status.write_text("notify-tick: run not measured (the ledger could not be read back)\n")
        return 1
    except BaseException as exc:
        log(f"run not measured: {type(exc).__name__}: {exc}")
        status.write_text(f"notify-tick: run not measured ({type(exc).__name__})\n")
        raise
    line = nc.status_line(summary, readback=wanted)
    status.write_text(line + "\n")
    log(line)
    return 1 if summary["stopped"] in nc.READBACK_STOPS or summary["sender_failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
