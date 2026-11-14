"""notify-chunks: how the notify tick walks its untold list, chunk by chunk, without ever abandoning a chunk.

`notify_tick.py` decides WHO is untold. This module decides what happens to each of them in one run, and it is the
part of the tick (`/opt/hydra/scripts/credit-notify-tick.py` on node-8, now `scripts/credit-notify-tick.py`) that
used to read:

    if aff < 10:
        log(f"chunk {i} only {aff} affirmed, skip"); continue

That line dropped the whole chunk: the users core's route had just affirmed were not told, and the others were never
looked at again in the run. Measured on node-8 2026-11-14T01:48Z: 5 untold, 2 affirmed, 0 sent, on every tick.

What happens to a chunk now. Each user in it ends the chunk in exactly one of four places:

  sent         core confirmed the notice (a live `sent` row in `decision_told`).
  unconfirmed  a live row exists and none of them is `sent` (the send errored, or was reserved and never answered).
               `notify_tick.already_told` never lists that user again; that rule is `decision_told`'s (one notice per
               group, an attempt is a reservation) and is unchanged here.
  carried      no live row. The user rides into the NEXT chunk of this run on top of that chunk's own `chunk` new
               users, with the reason recorded, and is still in the untold list of the next tick.
  waiting      no live row, and the chunk's dry run itself did not run (`dry_failed`). Nothing was learned about
               these users, so they are not merged into the next chunk - a list that cannot be read would make the
               next one unreadable too - and they are first in the next tick's list.

The affirmed users of a short chunk are told through `decision_told`'s own rung, which is NOT changed and not
lowered: `signed_subjects` wants `min(MIN_SIGNED_DRY, eligible)` affirmed users in the signed file, i.e. ten, "or
every user it tried, when the list had fewer eligible". So when a chunk's dry run affirms fewer than the rung needs,
the tick writes a list of exactly the affirmed users, dry-runs THAT list, and applies with that signed file. Every
send still has a signed dry run in which the route affirmed every user it was asked about. If the second dry run
affirms fewer again, the list is narrowed again; it shrinks on every round, so the loop ends.

Stops, each named, each as narrow as its cause:

  per user   the route refused the dry run (`route:<its outcome>`), `decision_told.plan` holds the user
             (`held:<hold>`), or the apply did not reach them (`not_applied`, `apply_failed`). Only that user waits.
  per chunk  `dry_failed`: the dry run did not run or wrote no readable report. Only that chunk's users wait, and
             the failure is recorded at the run level (`sender_failures`: the chunk, which call, its exit code).
  the run    `kill_file`, `day_cap`, `first_live_write_is_one_user`, `readback_required`: `decision_told` itself
             refuses any further live write, so the remaining chunks would be asked and refused the same way.
             And the caller's own switch (`halt`, the tick's kill file), looked at before every chunk.
             The users not yet asked are `not_reached`; they are untold and counted, never dropped.

A chunk whose sender call fails outright is a RUN-level failure, never a quiet zero: the dry run did not answer, or
the apply returned non-zero (the kill file's own exit code excluded, which is the named stop `kill_file`). The run
does not stop for it — the next chunk is still asked — but `sender_failures` carries every one of them, the status
line leads with `SENDER FAILED in chunk <n> (<call> rc <rc>)`, and the caller fails the run.

A READBACK stop is never rendered as "nothing to do". `ladder_state` reads the run the ladder wants read back from the
ledger (never from an environment variable): `decision_told.run` refuses a second live attempt until a caller names a
run whose send core confirmed, so a ledger already holding more than `FIRST_LIVE_LIMIT` apply attempts proves an
operator climbed that rung, and only then may this tick name a prior confirmed `sent` run itself. Without that proof
the tick certifies no read back of its own: the ladder admits exactly one live write, so a ledger with no attempt yet
has that one user told and then stops, and the caller fails the run: `status_line` names the stop, how many untold
users it blocked, and the run id a person has to read back with `credit-decision-told.py --readback-ok`.

A low affirmation count is none of these. There is no count of affirmed users below which a chunk is not applied.

Who was sent is read from the LEDGER after each apply, never from the apply's stdout: a send that timed out or
printed nothing still wrote its rows, and "could not read the answer" must not become "sent 0". A ledger that cannot
answer raises.

Known limit, stated rather than hidden: a carried user is asked again in every chunk of every tick. If
`chunk * max_chunks` users are refused persistently, a tick spends itself on them before it reaches anyone new.
On node-8 2026-11-14 that is 3 users against 75.
"""
from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path
from typing import Any, Callable, Iterable

from . import decision_told as dt
from .notify_tick import NotifyTickError

CHUNK = 25
DRY_TIMEOUT_S = 900
APPLY_TIMEOUT_S = 1800
#: `credit-decision-told.py` exits 3 when its kill file is present
KILL_RC = 3
#: stops `decision_told.run` reports that refuse every further live write of this run
RUN_STOPS = frozenset({"kill_file", "day_cap", "first_live_write_is_one_user", "readback_required"})
#: the stops that mean "nothing is sent until a run is read back": the run FAILS, it does not pass as a quiet zero
READBACK_STOPS = frozenset({"first_live_write_is_one_user", "readback_required"})

#: (argv for credit-decision-told.py, timeout in seconds) -> (exit code, stdout)
Told = Callable[[list[str], int], "tuple[int, str]"]
#: user ids -> {user id: the outcomes of its live rows}
Outcomes = Callable[[list[int]], "dict[int, set[str]]"]
Log = Callable[[str], None]


def live_outcomes(db: sqlite3.Connection, user_ids: Iterable[int]) -> dict[int, set[str]]:
    """{user: outcomes of its live (`mode = 'apply'`) rows}. Unreadable raises: an unread ledger is not "nobody"."""
    ids = sorted({int(u) for u in user_ids})
    out: dict[int, set[str]] = {}
    try:
        for i in range(0, len(ids), 500):
            part = ids[i:i + 500]
            for uid, outcome in db.execute("SELECT user_id, outcome FROM decision_told WHERE mode = 'apply' "
                                           f"AND user_id IN ({','.join('?' * len(part))})", part):
                out.setdefault(int(uid), set()).add(str(outcome))
    except (sqlite3.Error, TypeError, ValueError) as exc:
        raise NotifyTickError(f"decision_told unreadable: {type(exc).__name__}: {exc}") from exc
    return out


def ladder_state(db: sqlite3.Connection) -> tuple[str, str]:
    """(the run this tick may name as read back, the run a person has to read back) - durable state, not a knob.

    `decision_told.run` never lets total apply attempts pass `FIRST_LIVE_LIMIT` unless the caller named a run whose
    live send core confirmed, so a ledger holding MORE apply attempts than that is proof the rung was climbed by an
    operator. Only then does the tick name a prior confirmed `sent` run itself; otherwise it certifies nothing and
    the ladder stops the run. The second element is the run to hand to `--readback-ok`: the newest confirmed send,
    else the newest live attempt (an attempt core never confirmed has to be looked at all the same).
    Unreadable raises, for the same reason `already_told` does."""
    try:
        tried = int(db.execute("SELECT count(*) FROM decision_told WHERE mode = 'apply' AND outcome = 'attempt'"
                               ).fetchone()[0])
        sent = db.execute("SELECT run_id FROM decision_told WHERE mode = 'apply' AND outcome = 'sent' "
                          "ORDER BY id DESC LIMIT 1").fetchone()
        latest = db.execute("SELECT run_id FROM decision_told WHERE mode = 'apply' ORDER BY id DESC LIMIT 1"
                            ).fetchone()
    except (sqlite3.Error, TypeError, ValueError) as exc:
        raise NotifyTickError(f"decision_told unreadable: {type(exc).__name__}: {exc}") from exc
    sent_run = str(sent[0]) if sent else ""
    latest_run = str(latest[0]) if latest else ""
    return (sent_run if tried > dt.FIRST_LIVE_LIMIT and sent_run else ""), (sent_run or latest_run)


def blocked_by_stop(summary: dict[str, Any]) -> int:
    """The untold users the run's stop kept from being told: those it held under that stop, plus the not reached."""
    why = f"stopped:{summary.get('stopped')}"
    return sum(1 for reason in summary["carried"].values() if reason == why) + int(summary["not_reached"])


def _uid(user: dict[str, Any]) -> int:
    return int(user["user_id"])


def _code(text: Any) -> str:
    """A reason code safe for a log line: the route's own word, lower-case, nothing else."""
    return re.sub(r"[^a-z0-9_]", "", str(text).lower())[:40]


def _refusal(result: dict[str, Any]) -> str:
    """Why the route did not affirm this user: its own `outcome` when it gave one, else `route:refused`."""
    rep = result.get("report")
    inner = rep.get("report") if isinstance(rep, dict) else None
    outcome = _code(inner.get("outcome") or "") if isinstance(inner, dict) else ""
    return f"route:{outcome}" if outcome and outcome != "would_send" else "route:refused"


def _refused_text(stdout: str) -> str:
    try:
        doc = json.loads(stdout)
    except ValueError:
        return ""
    return str(doc.get("refused") or "")[:200] if isinstance(doc, dict) else ""


def _tally(reasons: dict[int, str]) -> str:
    counts: dict[str, int] = {}
    for why in reasons.values():
        counts[why] = counts.get(why, 0) + 1
    return ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) or "none"


def _ask(told: Told, work: Path, name: str, header: dict[str, Any], users: list[dict[str, Any]]
         ) -> tuple[Path, str, Path, int, str, dict[str, Any] | None]:
    """Write the list and dry-run it. -> (list, its sha, dry file, exit code, stdout, the report or None)."""
    lst, dry = work / f"{name}.json", work / f"{name}.dry.json"
    lst.write_text(json.dumps({**header, "users": users}))
    sha = dt.file_sha(lst.read_bytes())
    dry.unlink(missing_ok=True)        # an earlier tick's file must never be read as this dry run's answer
    rc, out = told(["dry", "--list", str(lst), "--list-sha", sha, "--limit", str(len(users)), "--out", str(dry)],
                   DRY_TIMEOUT_S)
    report = None
    if rc == 0:
        try:
            report = json.loads(dry.read_text())
        except (OSError, ValueError):
            report = None
        if not isinstance(report, dict) or not isinstance(report.get("results"), list):
            report = None
    return lst, sha, dry, rc, out, report


def _chunk(index: int, members: list[dict[str, Any]], header: dict[str, Any], *, told: Told, outcomes: Outcomes,
           work: Path, log: Log, readback: str, apply_limit: int) -> dict[str, Any]:
    """One chunk: dry run, narrow to the affirmed users while the rung is short, apply, read the ledger."""
    carried: dict[int, str] = {}
    waiting: dict[int, str] = {}
    res: dict[str, Any] = {"index": index, "asked": len(members), "affirmed": 0, "sent": [], "unconfirmed": [],
                           "carried": carried, "waiting": waiting, "stop": "", "sender_failures": []}
    current, rnd, signed = members, 0, None
    while True:
        name = f"c{index:03d}" if rnd == 0 else f"c{index:03d}.r{rnd}"
        lst, sha, dry, rc, out, report = _ask(told, work, name, header, current)
        if rc == KILL_RC:
            carried.update({_uid(u): "stopped:kill_file" for u in current})
            res["stop"] = "kill_file"
            return res
        if report is None:
            log(f"chunk {index} dry run did not answer (rc {rc}) {_refused_text(out)}".rstrip())
            res["sender_failures"].append({"chunk": index, "call": "dry", "rc": rc})
            waiting.update({_uid(u): "dry_failed" for u in current})
            return res
        by_user = {int(r["user_id"]): r for r in report["results"] if str(r.get("user_id", "")).isdigit()}
        affirmed = [u for u in current
                    if by_user.get(_uid(u), {}).get("outcome") == "dry_ok" and by_user[_uid(u)].get("accepted")]
        if rnd == 0:
            res["affirmed"] = len(affirmed)
        yes = {_uid(u) for u in affirmed}
        held = sorted(_code(k) for k in (report.get("held") or {}))
        for u in current:
            if _uid(u) in yes:
                continue
            got = by_user.get(_uid(u))
            carried[_uid(u)] = (_refusal(got) if got else
                                f"held:{held[0]}" if len(held) == 1 else "held_by_plan")
        if not affirmed:
            return res
        try:
            dt.signed_subjects(report)
        except dt.DecisionToldError:
            if len(affirmed) == len(current):
                raise
            log(f"chunk {index}: {len(affirmed)} affirmed of {len(current)} is under the signed-dry rung; "
                f"signing a dry run of those {len(affirmed)} alone")
            current, rnd = affirmed, rnd + 1
            continue
        signed = (lst, sha, dry, affirmed)
        break
    lst, sha, dry, affirmed = signed
    argv = ["apply", "--list", str(lst), "--list-sha", sha, "--signed", str(dry),
            "--limit", str(min(len(affirmed), apply_limit))]
    if readback:
        argv += ["--readback-ok", readback]
    rc, out = told(argv, APPLY_TIMEOUT_S)
    stop = "kill_file" if rc == KILL_RC else ""
    if rc == 0:
        try:
            said = json.loads(out).get("stopped") or ""
        except (ValueError, AttributeError):
            said = ""
        stop = "kill_file" if str(said).startswith("kill file") else _code(said)
    elif rc != KILL_RC:
        log(f"chunk {index} apply did not finish (rc {rc}) {_refused_text(out)}".rstrip())
        res["sender_failures"].append({"chunk": index, "call": "apply", "rc": rc})
    live = outcomes([_uid(u) for u in affirmed])
    for u in affirmed:
        got = live.get(_uid(u), set())
        if "sent" in got:
            res["sent"].append(_uid(u))
        elif got:
            res["unconfirmed"].append(_uid(u))
        else:
            carried[_uid(u)] = f"stopped:{stop}" if stop else "apply_failed" if rc != 0 else "not_applied"
    res["stop"] = stop if stop in RUN_STOPS else ""
    return res


def run(doc: dict[str, Any], *, told: Told, outcomes: Outcomes, work: Path, log: Log, chunk: int = CHUNK,
        max_chunks: int = 6, readback: str = "", halt: Callable[[], str] | None = None) -> dict[str, Any]:
    """Walk `doc["users"]` (the untold list, already ordered) in chunks of `chunk` new users plus everyone the
    previous chunk carried. Returns {untold, sent, unconfirmed, carried: {user: reason}, not_reached, stopped,
    chunks}; `untold == len(sent) + len(unconfirmed) + len(carried) + not_reached` or it raises."""
    users = list(doc["users"])
    header = {k: v for k, v in doc.items() if k != "users"}
    by_id = {_uid(u): u for u in users}
    queue, carried, waiting = list(users), {}, {}
    sent: list[int] = []
    unconfirmed: list[int] = []
    chunks: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    stopped = ""
    for index in range(max(0, max_chunks)):
        if not queue:
            break                      # only carried users are left, and they were asked a moment ago
        stopped = halt() if halt else ""
        if stopped:                    # the caller's own switch, looked at before every chunk
            log(f"run stopped before chunk {index}: {stopped}")
            break
        new, queue = queue[:max(1, chunk)], queue[max(1, chunk):]
        res = _chunk(index, [by_id[u] for u in carried] + new, header, told=told, outcomes=outcomes, work=work,
                     log=log, readback=readback, apply_limit=max(1, chunk))
        sent += res["sent"]
        unconfirmed += res["unconfirmed"]
        failures += res["sender_failures"]
        log(f"chunk {index}: asked {res['asked']} ({len(carried)} carried in, {len(new)} new), "
            f"affirmed {res['affirmed']}, sent {len(res['sent'])}, unconfirmed {len(res['unconfirmed'])}, "
            f"carried {len(res['carried'])} ({_tally(res['carried'])})"
            + (f", waiting {len(res['waiting'])} (dry_failed)" if res["waiting"] else ""))
        chunks.append({"index": index, "asked": res["asked"], "carried_in": len(carried), "new": len(new),
                       "affirmed": res["affirmed"], "sent": len(res["sent"]),
                       "unconfirmed": len(res["unconfirmed"]), "carried": len(res["carried"]),
                       "waiting": len(res["waiting"])})
        carried = res["carried"]
        waiting.update(res["waiting"])
        if res["stop"]:
            stopped = res["stop"]
            log(f"run stopped at chunk {index}: {stopped}")
            break
    left = {**waiting, **carried}
    out = {"untold": len(users), "sent": sorted(sent), "unconfirmed": sorted(unconfirmed),
           "carried": {str(k): left[k] for k in sorted(left)}, "not_reached": len(queue), "stopped": stopped,
           "chunks": chunks, "sender_failures": failures}
    if len(users) != len(sent) + len(unconfirmed) + len(left) + len(queue):
        raise NotifyTickError(f"the run does not account for every untold user: {json.dumps(out)[:300]}")
    return out


def _failed_text(summary: dict[str, Any]) -> str:
    return ", ".join(f"chunk {f['chunk']} ({f['call']} rc {f['rc']})" for f in summary["sender_failures"])


def status_line(summary: dict[str, Any], *, readback: str = "") -> str:
    """The sentinel's line. `still untold` is everyone with no live row: the carried and the not reached.

    A READBACK stop gets its own line: the run sent nothing because the ladder wants a run read back, and the line
    says so, how many users that blocked, and which run to read back. It never reads as a run with nothing to do.

    A sender call that failed outright is a run-level fact and leads the line: a chunk nothing could be sent in is
    never rendered as a quiet zero, whatever the rest of the run did."""
    head = f"SENDER FAILED in {_failed_text(summary)}; " if summary["sender_failures"] else ""
    if summary["stopped"] in READBACK_STOPS:
        return (f"notify-tick: {head}{summary['stopped']}, {blocked_by_stop(summary)} of {summary['untold']} untold "
                f"users blocked, sent {len(summary['sent'])} this run; read run {readback or 'unknown'} back with "
                f"credit-decision-told.py --readback-ok")
    left = len(summary["carried"]) + summary["not_reached"]
    line = (f"notify-tick: {head}sent {len(summary['sent'])} this run, {left} still untold "
            f"({len(summary['carried'])} carried, {summary['not_reached']} not reached)")
    if summary["unconfirmed"]:
        line += f"; {len(summary['unconfirmed'])} sent but not confirmed"
    if summary["stopped"]:
        line += f"; stopped: {summary['stopped']}"
    return line
