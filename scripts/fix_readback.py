#!/usr/bin/env python3
"""fix_readback.py — mark a user message-eligible ONLY when the fix is Seen in the record.

Stage 2 of 3 (ruling R2). Every hour it re-reads the system of record for the routed tickets
that are DUE, and writes exactly two outcomes:

    seen        the fix happened AND the user was told, with the evidence the copy needs
    routed      unchanged: still nothing readable (the attempt is recorded, the ticket is not closed)

The third state, ``ineligible``, is written by the SEND stage when it can render no honest
message for a ticket that is already Seen - stage 2 never closes a ticket out.

The evidence it records is exactly what ``winback_fix_send.py`` renders from, so a Sealed ticket
is the ONLY input a message can come from - there is no second path to "eligible", by design.

**A routed ticket is re-read on a budget, not forever** (firstmate inbox 007). The wait before
attempt N is ``policy.readback.backoff_hours[N]`` hours after the previous attempt, the run takes
at most ``policy.readback.max_per_run`` tickets oldest-due-first, and only one run at a time holds
the ledger lock. After the last interval the ticket stays ``routed`` and is reported as
``readback_exhausted`` (::

    need firstmate: task readback_exhausted <n> tickets

) for the owning lane to drain - it never becomes ineligible for want of an answer.

    ./scripts/fix_readback.py --dry-run            # show the verdicts, write nothing
    ./scripts/fix_readback.py                       # apply verdicts
    ./scripts/fix_readback.py --limit 50 --verbose  # the top 50, with reasons

The stdout document is the redacted view (``readback.redact_staff_text``): the 0600 report holds
any staff-authored text verbatim, stdout never does, so the stream is safe to capture.

Exit codes: 0 read back (even if nothing is eligible yet, or another run held the lock), 1 the
ledger could not be opened, 3 a reader source is completely unavailable (every verdict was
"unreadable"): the run applied nothing, because a source outage must not look like "no fixes yet"
in the artifacts. A ticket whose own data is incomplete - "datagap" (no claiming row, a deleted
ClickUp task, a Stripe refund with no amount) or "undatable" (no start of wait to date a fix
against) - is NOT an outage: it spends an attempt of the budget, is reported in its own bucket,
and the ticket stays routed with the reason on the ledger.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterator, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))

from churn import cli, readback, tickets  # noqa: E402

_UNREADABLE_PREFIXES = ("unreadable", "reader error")
_UNDATABLE_PREFIX = "undatable"
_DATAGAP_PREFIX = "datagap"

#: A lock file exists (O_EXCL) before its payload is written. That gap is microseconds, so a
#: file with no readable identity is treated as in-flight rather than stale until it has been
#: unreadable for this long.
_LOCK_WRITE_GRACE_SECONDS = 60.0


def _boot_id() -> str:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        return ""


def _proc_start(pid: int) -> str | None:
    """Field 22 (start time) of ``/proc/<pid>/stat``: None when gone, "" when unreadable.

    A pid alone is not an identity - it is recycled - so the lock carries the start time too and
    a reused pid stops looking like the run that wrote the file.
    """
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except FileNotFoundError:
        return None
    except OSError:
        return ""
    tail = stat.rsplit(")", 1)[-1].split()
    return tail[19] if len(tail) > 19 else ""


def _read_lock(path: Path) -> dict:
    """The lock document, or {} when unreadable. Tolerates an old bare-pid file."""
    try:
        raw = path.read_text()
    except OSError:
        return {}
    try:
        doc = json.loads(raw)
    except ValueError:
        doc = None
    if isinstance(doc, dict):
        return doc
    try:
        return {"pid": int(str(raw).strip() or 0)}
    except ValueError:
        return {}


def _held_message(doc: Mapping[str, Any]) -> str:
    try:
        pid: Any = int(doc.get("pid") or 0)
    except (TypeError, ValueError):
        pid = "unknown"
    try:
        at = float(doc.get("at") or 0.0)
    except (TypeError, ValueError):
        at = 0.0
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)) if at else "unknown time"
    return f"another read-back is running (lock held by pid {pid} since {since})"


def _stale(path: Path, doc: Mapping[str, Any], *, now: float) -> bool:
    """Whether the lock's owner is provably gone - never merely "some check raised"."""
    try:
        pid = int(doc.get("pid") or 0)
    except (TypeError, ValueError):
        return True
    if pid <= 0:
        # No identity yet: another process may be between its create and its write. Only a lock
        # that has STAYED blank is stale - and a garbage file must not wedge the run for ever.
        try:
            age = now - path.stat().st_mtime
        except OSError:
            return False
        return age > _LOCK_WRITE_GRACE_SECONDS
    boot = str(doc.get("boot_id") or "")
    current_boot = _boot_id()
    if boot and current_boot and boot != current_boot:
        return True
    start = _proc_start(pid)
    if start is None:
        return True
    recorded = str(doc.get("start") or "")
    if recorded and start and recorded != start:
        return True
    # The owner's identity is intact: same boot, live pid, same start time. Age is NOT evidence
    # of death - a long run (or a hung one) still owns the ledger, and taking its lock over would
    # run two read-backs concurrently. Only proof the owner died makes a lock stale.
    return False


@contextlib.contextmanager
def _claim_mutex(path: Path) -> Iterator[None]:
    """Serialize the claim/takeover decision itself, not just the run.

    The O_EXCL create and the stale-lock rename are two steps. Without this, a contender that
    read a stale lock can rename a *new* live lock away and then restore it over a third
    contender's lock, leaving two runs holding the ledger. ``flock`` is released by the kernel
    when the holder dies, so a crashed contender cannot wedge the claim.
    """
    mutex = path.with_name(path.name + ".claim")
    mutex.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(mutex, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


@contextlib.contextmanager
def run_lock(path: Path) -> Iterator[bool]:
    """One read-back at a time on this ledger. Yields False when another run holds it.

    The claim is an O_EXCL create (0600) carrying the holder's identity: pid, that pid's start
    time, the boot id and the timestamp. A lock is stale only when that identity proves the
    owner is gone - a different boot, a pid that is gone, or a pid whose start time moved
    (recycled) - never merely because it is old - and it is taken over by RENAMING it aside, so
    only one contender can win. The whole claim runs under ``_claim_mutex``, so no contender can
    rename a lock another contender just created.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    claimed = False
    held_message = ""
    with _claim_mutex(path):
        while True:
            try:
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                holder = _read_lock(path)
                if not _stale(path, holder, now=time.time()):
                    held_message = _held_message(holder)
                    break
                moved = path.with_name(f"{path.name}.stale.{os.getpid()}.{time.time_ns()}")
                try:
                    os.rename(path, moved)
                except FileNotFoundError:
                    continue
                except OSError as exc:
                    held_message = f"{_held_message(holder)}: {exc}"
                    break
                cli.log(f"taking over stale read-back lock {path}: {_held_message(holder)}")
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(moved)
                continue
            payload = {"pid": os.getpid(), "start": _proc_start(os.getpid()) or "",
                       "boot_id": _boot_id(), "at": time.time()}
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(payload) + "\n")
            claimed = True
            break
    if not claimed:
        cli.log(held_message)
        yield False
        return
    try:
        if int(_read_lock(path).get("pid") or 0) != os.getpid():
            yield False
            return
        yield True
    finally:
        if int(_read_lock(path).get("pid") or 0) == os.getpid():
            with contextlib.suppress(FileNotFoundError):
                path.unlink()


def main(argv: list[str] | None = None) -> int:
    ap = cli.add_common(argparse.ArgumentParser(description="Read back whether routed fixes are Seen."))
    ap.add_argument("--dry-run", action="store_true", help="print verdicts; write nothing")
    ap.add_argument("--limit", type=int, default=0,
                    help="check at most N tickets (default: policy readback.max_per_run)")
    ap.add_argument("--verbose", action="store_true", help="print every verdict, not just the new ones")
    ap.add_argument("--ledger", default=None, help="credit-review ledger path (default: %s)" % readback.LEDGER_DEFAULT)
    args = ap.parse_args(argv)

    policy = cli.load_policy(args.policy)
    readback_cfg = cli.readback_config(policy)
    schedule = readback_cfg["backoff_hours"]
    limit = args.limit if args.limit and args.limit > 0 else readback_cfg["max_per_run"]
    state_dir = cli.state_dir(policy, args.state_dir)
    db_path = state_dir / "tickets.sqlite"
    if not db_path.exists():
        cli.log(f"no ledger at {db_path}: run scripts/route_fix.py first")
        return 1

    sources = readback.Sources(
        ledger=args.ledger or readback.LEDGER_DEFAULT,
        # The 'other' lane's answer threshold comes from the policy file, so editing the copy
        # contract really moves the gate (a constant here would read as enforcement and not be).
        min_reply_words=int(((policy.get("guards") or {}).get("human_reply_min_words")) or 40),
    )
    with run_lock(state_dir / "readback.lock") as held:
        if not held:
            cli.log("another read-back is running on this ledger: nothing to do")
            return 0
        return _run(db_path, state_dir, sources, schedule, limit, args)


def _run(db_path: Path, state_dir: Path, sources: "readback.Sources", schedule: tuple[float, ...],
         limit: int, args: argparse.Namespace) -> int:
    now = time.time()
    opened = unseen = unreadable = undatable = datagap = newly_exhausted = 0
    seen: list[dict] = []
    verdicts: list[dict] = []
    with tickets.TicketStore(db_path) as store:
        pending = store.pending_readback(schedule=schedule, now=now, limit=limit)
        opened = len(pending)
        for ticket in pending:
            verdict = readback.read(ticket, sources)
            if verdict.eligible:
                seen.append({"user_id": ticket.user_id, "lane": ticket.lane,
                             "cause": ticket.primary_class, **verdict.as_dict()})
                if not args.dry_run:
                    store.mark_seen(ticket.ticket_id, evidence=verdict.as_dict(), at=now)
                continue
            reason = verdict.reason
            if reason.startswith(_UNREADABLE_PREFIXES):
                # The source was down: that is no evidence about this ticket, so it does not
                # spend an attempt from the budget either.
                unreadable += 1
            else:
                exhausted_now = False
                if not args.dry_run:
                    # Only a CHANGED verdict writes an audit row; the attempt counter always moves.
                    exhausted_now = store.record_readback(
                        ticket.ticket_id, verdict="not-yet", schedule=schedule,
                        detail=verdict.as_dict(), at=now)
                if exhausted_now:
                    newly_exhausted += 1
                elif reason.startswith(_UNDATABLE_PREFIX):
                    undatable += 1
                elif reason.startswith(_DATAGAP_PREFIX):
                    datagap += 1
                else:
                    unseen += 1
            verdicts.append({"user_id": ticket.user_id, "lane": ticket.lane, "reason": reason})
        counts_after = store.state_counts() if not args.dry_run else {}
        routed_total = len(store.by_state(tickets.ROUTED))
        exhausted_total = len(store.exhausted_readback(schedule=schedule))

    doc = {
        "stage": "readback",
        "at": now,
        "dry_run": bool(args.dry_run),
        "limit": limit,
        "checked": opened,
        "seen": seen,
        "not_yet": unseen,
        "undatable": undatable,
        "datagap": datagap,
        "unreadable": unreadable,
        "readback_exhausted": newly_exhausted,
        "exhausted_total": exhausted_total,
        "still_routed": routed_total,
        "ledger_counts": counts_after,
    }
    if not args.dry_run:
        cli.write_report(doc, state=state_dir, name="readback")
    cli.emit(readback.redact_staff_text(doc))
    if args.verbose:
        for v in verdicts:
            print(f"  {v['user_id']:<10} {v['lane']:<15} {v['reason']}", file=sys.stderr)
    if newly_exhausted:
        print(f"need firstmate: task readback_exhausted {newly_exhausted} tickets", file=sys.stderr)
    cli.log(f"checked {opened} of {limit}: {len(seen)} now Seen, {unseen} still waiting, "
            f"{undatable} undatable, {datagap} datagap, {unreadable} unreadable, "
            f"{newly_exhausted} readback_exhausted")
    if opened and unreadable == opened:
        cli.log("every reader was unreadable: this run applied nothing (a source outage is not 'no fixes')")
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
