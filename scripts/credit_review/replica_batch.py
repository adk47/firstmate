#!/usr/bin/env python3
"""One replica round trip for MANY statements, and the per-person read the send gate's helpers are answered from.

Why (measured on node-8 2026-11-12, docs/credit-verification/gate-replica-read.md): a `trino-query.sh` call costs
~2.06 s of which ~1.85 s is fixed (kubectl get pods + kubectl exec + the CLI's JVM) - `SELECT 1` costs the same as
a real read. The send gate asked the replica 5-6 separate questions about ONE person (core_notice 2, comm_state 4),
so a person cost 10.25 s of replica wall out of a 13.47 s gate call, against a 20 s read timeout. The fix is not a
longer timeout and not a lower bar: it is asking once.

Three parts, all read-only:

  read_many(statements, cmd=...)   every statement in ONE invocation of the wrapper. A sentinel row carrying a
                                   random nonce closes each statement's rows; the rows of a statement are parsed
                                   exactly as the single-statement readers parse them. Anything short of "every
                                   sentinel, in order, exit 0" raises BatchError: no partial answer is ever returned.

  bundle / load / answer           the answers keyed by the EXACT statement text, with the second they were read.
                                   A statement names its user id, so a bundle read for one person can never answer
                                   a question about another.

  `serve --live WRAPPER`           what scripts/replica-serve.sh runs: one statement on stdin, answered from the
                                   bundle named by $REPLICA_BATCH_FACTS when it holds that exact text, otherwise by
                                   BECOMING the real wrapper (exec) with the statement on stdin.

The bundle only ever makes a read FASTER. A missing, stale (> MAX_AGE_S), malformed or foreign bundle is ignored
and every statement is read live, exactly as before this file existed: no rule reads "the bundle says so".
"""
from __future__ import annotations

import csv
import io
import json
import secrets
import subprocess
import time
from typing import Any

# A bundle is the SAME gate call's read, seconds old. One older than this is not "right now" and is read again live.
MAX_AGE_S = 30
# A batch that has not answered by now is abandoned and every statement is read live: the read must never cost a
# gate call more than the round trips it replaces.
BATCH_TIMEOUT_S = 15
VERSION = 1
# where the gate tells replica-serve.sh its read is (a file in a root-only tmpfs directory, removed with the gate call)
FACTS_ENV = "REPLICA_BATCH_FACTS"


class BatchError(RuntimeError):
    """The batch did not run to the end, or its output cannot be split into statements with certainty."""


def batchable(sql: str) -> bool:
    """A statement that could end early or swallow the separator is never batched (it is read on its own)."""
    return bool(sql and sql.strip()) and ";" not in sql


def parse(lines: list[str]) -> list[list[str]]:
    """One statement's CSV rows - the same filter and reader every single-statement caller uses."""
    return list(csv.reader(io.StringIO("\n".join(ln for ln in lines if ln.startswith('"')))))


def _marker(nonce: str, i: int) -> str:
    return f"<<replica-batch {nonce} {i}>>"


def script(statements: list[str], nonce: str) -> str:
    """The statements, each followed by a SELECT of its own sentinel. The separator sits on its own line so a
    statement ending in a `--` comment cannot swallow it."""
    parts: list[str] = []
    for i, sql in enumerate(statements):
        parts.append(sql)
        parts.append(f"SELECT '{_marker(nonce, i)}'")
    return "\n;\n".join(parts)


def split(stdout: str, n: int, nonce: str) -> list[list[str]]:
    """stdout -> one list of lines per statement. Raises unless all n sentinels arrive, in order, with nothing after."""
    groups: list[list[str]] = []
    cur: list[str] = []
    for ln in stdout.splitlines():
        if len(groups) < n and ln == f'"{_marker(nonce, len(groups))}"':
            groups.append(cur)
            cur = []
        else:
            cur.append(ln)
    if len(groups) != n:
        raise BatchError(f"batch ended after {len(groups)} of {n} statement(s)")
    if any(ln.startswith('"') for ln in cur):
        raise BatchError("rows after the last statement")
    return groups


def read_many(statements: list[str], *, cmd: str, timeout: float = BATCH_TIMEOUT_S) -> list[list[list[str]]]:
    """Rows per statement, in order, from ONE invocation of `cmd` (trino-query.sh, SQL on stdin)."""
    if not statements:
        return []
    bad = [s for s in statements if not batchable(s)]
    if bad:
        raise BatchError("a statement that cannot be batched was handed to read_many")
    nonce = secrets.token_hex(16)
    try:
        p = subprocess.run([cmd], input=script(statements, nonce), capture_output=True, text=True, timeout=timeout,
                           check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise BatchError(f"replica batch did not run: {type(exc).__name__}") from exc
    if p.returncode != 0:
        raise BatchError(f"replica batch failed rc={p.returncode}: {p.stderr.strip()[-200:]}")
    try:
        return [parse(g) for g in split(p.stdout, len(statements), nonce)]
    except csv.Error as exc:
        raise BatchError(f"replica batch rows unreadable: {exc}") from exc


def bundle(statements: list[str], answers: list[list[list[str]]], read_at: float) -> dict[str, Any]:
    if len(statements) != len(answers):
        raise BatchError("one answer per statement")
    return {"replica_batch": VERSION, "read_at": float(read_at), "statements": [[s, a] for s, a in zip(statements, answers)]}


def dumps(b: dict[str, Any]) -> str:
    return json.dumps(b, separators=(",", ":"))


def load(text: str, *, now: float | None = None, max_age_s: float = MAX_AGE_S) -> dict[str, list[list[str]]] | None:
    """{statement text: rows} from a bundle, or None when it is not EXACTLY a fresh bundle of this version.
    None means "read live"; it is never an error and never a fact."""
    try:
        obj = json.loads(text)
    except (TypeError, ValueError):
        return None
    if not isinstance(obj, dict) or obj.get("replica_batch") != VERSION:
        return None
    read_at, stmts = obj.get("read_at"), obj.get("statements")
    if isinstance(read_at, bool) or not isinstance(read_at, (int, float)) or not isinstance(stmts, list):
        return None
    now = time.time() if now is None else now
    if not 0 <= now - read_at <= max_age_s:          # stale, or stamped in the future
        return None
    out: dict[str, list[list[str]]] = {}
    for item in stmts:
        if not (isinstance(item, list) and len(item) == 2 and isinstance(item[0], str) and isinstance(item[1], list)):
            return None
        sql, rows = item
        if not all(isinstance(r, list) and all(isinstance(c, str) for c in r) for r in rows):
            return None
        out[sql] = rows
    return out


def unique(statements: list[str]) -> list[str]:
    """Order kept, duplicates dropped, anything not batchable dropped (it is read live by whoever asks it)."""
    seen: set[str] = set()
    out: list[str] = []
    for s in statements:
        if batchable(s) and s not in seen:
            seen.add(s)
            out.append(s)
    return out


def write_csv(rows: list[list[str]], out: Any) -> None:
    """Rows as the replica CLI prints them (every field quoted, quotes doubled), so the single-statement readers -
    which keep only lines that start with a quote - parse them back to exactly these rows."""
    for r in rows:
        out.write(",".join('"' + c.replace('"', '""') + '"' for c in r) + "\n")


def round_trips(rows: list[list[str]]) -> bool:
    """True when write_csv -> the readers' parse gives these rows back. An empty row, or a cell holding a line break
    (the readers drop the continuation line), does not: such an answer is never served, it is read live."""
    buf = io.StringIO()
    write_csv(rows, buf)
    try:
        return parse(buf.getvalue().splitlines()) == rows
    except csv.Error:
        return False


def answer(facts_path: str, sql: str, *, now: float | None = None) -> list[list[str]] | None:
    """The rows the bundle at facts_path holds for this EXACT statement, or None (= ask the replica). None for a
    missing, unreadable, stale or malformed bundle, for a statement it does not hold, and for rows that would not
    read back identically."""
    if not facts_path:
        return None
    try:
        with open(facts_path, encoding="utf-8") as fh:
            facts = load(fh.read(), now=now)
    except (OSError, ValueError):
        return None
    if facts is None or sql not in facts or not round_trips(facts[sql]):
        return None
    return facts[sql]


def exec_live(live_cmd: str, sql: str) -> int:
    """Become the real wrapper with the statement on stdin: its output, its errors and its exit code are the
    caller's, byte for byte, and a caller that kills this process kills the wrapper (as before this file existed).
    Returns only when it could not start."""
    import os  # noqa: PLC0415
    import sys  # noqa: PLC0415
    data = sql.encode("utf-8")
    try:
        if len(data) > 32768:                    # more than a pipe is sure to hold without a reader: stay and feed it
            p = subprocess.run([live_cmd], input=data, check=False)
            return p.returncode if p.returncode >= 0 else 1
        r, w = os.pipe()
        os.write(w, data)
        os.close(w)
        os.dup2(r, 0)
        os.close(r)
        sys.stdout.flush()
        os.execv(live_cmd, [live_cmd])
    except OSError as exc:
        sys.stderr.write(f"replica-serve: the live wrapper did not run: {type(exc).__name__}\n")
    return 127


def _main(argv: list[str] | None = None) -> int:
    import argparse  # noqa: PLC0415
    import os  # noqa: PLC0415
    import sys  # noqa: PLC0415
    ap = argparse.ArgumentParser(description="answer one replica statement from the gate's read, or live")
    sub = ap.add_subparsers(dest="op", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--live", required=True, help="the real wrapper (replica-serve.sh passes the one beside it)")
    a = ap.parse_args(argv)
    sql = sys.stdin.read()
    rows = answer(os.environ.get(FACTS_ENV, ""), sql)
    if rows is None:
        return exec_live(a.live, sql)
    write_csv(rows, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
