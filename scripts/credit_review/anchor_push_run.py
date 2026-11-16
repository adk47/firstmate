"""The scheduled anchors push: one run, one run record, and a reader that pairs the records with the scheduler's own.

`credit-anchors-push.py --pending --apply` is what the `credit-anchors-push` cron runs. It uploads every built
dsp-anchor/1 record that has not landed in core yet (anchor_upload.pending), in whole-request batches of at most
100 core rows (a request is never split; one over the cap is not posted and is reported as a convert error), and
appends ONE line per run to `<state dir>/runs.jsonl`: when it started and ended, its exit code and
what it pushed. It approves nothing and writes no credit status; core re-decides everything an anchor admits.

A run with nothing built and unlanded is a clean run that pushed 0 rows (`nothing_pending`): it posts nothing.
A run whose only outstanding records are exhausted (`deferred_exhausted`) is different: a built anchor is
unlanded. It exits 0 and records `retry_owed`, how many of those records this driver still owes core an upload
of. Inside an upload cooldown that is above 0 and the run is not a successful scheduled run; at 0 every exhausted
record is terminal (core refused it, or it failed before any POST) and the idle run counts (`counts_as_success`).

A record whose upload failed MAX_ERRORS times is exhausted and paged once. That is a cooldown: after
RETRY_COOLDOWN_S a run asks core one read-only question before it decides what is pending, and a core that answers
gets the record back with a new error budget in that same run (anchor_upload.cooled / grant_retry). A core that
does not answer changes nothing and pages nobody again.

Exit codes of a scheduled run:
  0  nothing was pending, every pending record landed, some landed and core refused the rest with a reason (recorded
     per request), a kill file stopped the run, or another run held the lock
  1  an upload failed, core's answer did not account for every submitted row, or a built record could not be
     converted: the run did not do its job

`scheduler_runs` reads the gateway's `cron_run_receipts` (read-only) for the job and pairs each finished receipt
with the run record written inside its window. The columns it reads were measured on node-8's
`/root/.openclaw-main/state/openclaw.sqlite` (openclaw 2026.8.35, 2026-11-15T16:16Z) and are re-verified on every
openclaw bump. The receipt is the scheduler's record that it started the job; the
run record is what that process did. Neither table says whether a start was the schedule or an operator's forced
`cron run`, so the reader also reports whether the start falls within five minutes after a minute the schedule
names (the measured gateway start latency; see `START_WINDOW_S`). It is evidence of a schedule, not a signature.
"""
from __future__ import annotations

import fcntl
import json
import os
import sqlite3
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import anchor_upload

SCHEMA = "anchors-push-run/1"
JOB_NAME = "credit-anchors-push"
STATE_DIR = os.environ.get("CREDIT_ANCHORS_PUSH_STATE", "/var/lib/hydra/credit-anchors-push")
GATEWAY_STATE_DB = "/root/.openclaw-main/state/openclaw.sqlite"
KILL_SWITCHES = (os.environ.get("CREDIT_ANCHORS_PUSH_KILL_SWITCH", "/etc/hydra/credit-anchors-push.disabled"),
                 os.environ.get("CREDIT_VERIFY_KILL_SWITCH", "/etc/hydra/credit-verify.disabled"))
MAX_REQUESTS = 200                    # per run; the rest wait for the next tick, oldest build first
START_WINDOW_S = 300                  # a scheduled start may land this long after its slot: 96.1% of 745 measured
                                      # gateway starts (node-8, 7 days to 2026-11-16T00:25Z) were within 300 s
LISTED_IDS = 200                      # request ids named on one run record
SUCCESS_OUTCOMES = ("pushed", "nothing_pending", "pushed_with_refusals")
IDLE_EXHAUSTED = "deferred_exhausted"    # an idle run that holds exhausted records: see counts_as_success
SLACK_LIB = Path(__file__).resolve().parent.parent / "lib" / "slack-notify.sh"


def page_critical(text: str) -> bool:
    """Page #clio_devops through scripts/lib/slack-notify.sh, the one place the on-call mentions live."""
    try:
        proc = subprocess.run(
            ["bash", "-c", '. "$1"; declare -F slack_notify_critical_status >/dev/null && '
                           'slack_notify_critical_status "$2"', "--", str(SLACK_LIB), text],
            capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


def _iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"


def killed(switches: tuple[str, ...] = KILL_SWITCHES) -> str | None:
    return next((p for p in switches if p and Path(p).exists()), None)


def invoked_by() -> dict[str, Any]:
    """A hint about what started this process (never the proof; the gateway's receipt is). No command line is
    recorded: a parent's argv can carry a secret."""
    try:
        comm = Path(f"/proc/{os.getppid()}/comm").read_text().strip()
    except OSError:
        comm = None
    try:
        tty = os.isatty(0)
    except OSError:
        tty = False
    return {"parent_comm": comm, "tty": tty, "gateway_child": bool(os.environ.get("OPENCLAW_SERVICE_KIND"))}


def batches(built: dict[str, dict[str, Any]], order: list[str]) -> tuple[list[list[str]], dict[str, str]]:
    """Whole requests packed into batches of at most MAX_RECORDS core rows, so one POST never carries half of a
    request's rows. Returns (batches, {request id: convert error})."""
    rows_by_rid: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    bad: dict[str, str] = {}
    for rid in order:
        if rid not in built:
            continue
        try:
            rows_by_rid[rid] = [(rid, core) for core in anchor_upload.to_core_records(built[rid]["record"])]
        except anchor_upload.ConvertError as exc:
            bad[rid] = str(exc)
    groups, oversized = anchor_upload.pack_requests(rows_by_rid, order)
    bad.update(oversized)
    return groups, bad


def run_pending(store: Any, *, apply: bool, max_requests: int = MAX_REQUESTS,
                poster: anchor_upload.Poster | None = None,
                page: Callable[[str], bool] | None = None,
                probe: Callable[[], bool] | None = None,
                now_s: Callable[[], float] = time.time) -> dict[str, Any]:
    """Upload what anchor_upload.pending names. Returns the run's report; `outcome` and `exit_code` are set here.

    Before deciding what is pending, a run that finds upload-exhausted records past their cooldown asks core ONE
    read (`probe`). Reachable: each gets a `retry_granted` row, a new error budget, and is retried in this run.
    Not reachable: they stay exhausted and nobody is paged again for them. A run with no such record makes no
    call at all, so a run with nothing built still touches nothing."""
    owed = anchor_upload.pending(store)
    eligible = anchor_upload.cooled(owed, now_s())
    core_probe, granted = None, []
    if eligible and apply:
        try:
            reachable = bool((probe or anchor_upload.admin_probe())())
        except Exception:  # noqa: BLE001 - a probe that cannot run is a core we could not reach
            reachable = False
        core_probe = "ok" if reachable else "failed"
        if reachable:
            anchor_upload.grant_retry(store, eligible, "retry-" + uuid.uuid4().hex[:10], owed)
            granted = sorted(eligible)
            owed = anchor_upload.pending(store)
    take = owed["pending"][:max(0, max_requests)]
    rep: dict[str, Any] = {"selection": "pending", "mode": "apply" if apply else "dry-run",
                           "built": owed["built"], "landed_before": owed["landed"], "pending": len(owed["pending"]),
                           "attempted": 0, "deferred": len(owed["pending"]) - len(take),
                           "exhausted": len(owed["exhausted"]), "exhausted_requests": sorted(owed["exhausted"])[:LISTED_IDS],
                           "exhausted_at": {rid: owed["exhausted_at"][rid]
                                            for rid in sorted(owed["exhausted_at"])[:LISTED_IDS]},
                           "retry_owed": len(anchor_upload.awaiting_retry(owed)),
                           "retry_eligible": len(eligible), "core_probe": core_probe,
                           "retry_granted": len(granted), "retry_granted_requests": granted[:LISTED_IDS],
                           "core_rows": 0, "written": 0, "written_requests": [], "refused": {}, "errors": 0,
                           "convert_errors": 0, "missing_results": 0, "duplicate_results": 0,
                           "unexpected_results": 0, "push_run_ids": [], "withdrawn": 0, "withdrawn_requests": []}
    if not take:
        # An exhausted record is reported whatever exhausted it; a run that only has those is not the run with no
        # work. Whether it counts for the scheduler reader is `counts_as_success`: `retry_owed` says how many of
        # them this driver still owes core an upload of.
        rep["outcome"] = IDLE_EXHAUSTED if owed["exhausted"] else "nothing_pending"
        rep["exit_code"] = 0
        return rep
    built = anchor_upload.latest_built(store, take)
    groups, bad = batches(built, take)
    rep["convert_errors"] = len(bad)
    if apply:
        run_id = "push-" + uuid.uuid4().hex[:10]
        for rid, why in bad.items():              # counted against MAX_ERRORS, so a broken record cannot loop for ever
            store.add_anchor(run_id, rid, "write_error", kind=built[rid]["kind"], reason=("convert: " + why)[:600],
                             ruling_id=built[rid]["ruling_id"], verdict_id=None)
    for group in groups:
        part = anchor_upload.push(store, group, apply=apply, poster=poster)
        rep["attempted"] += len(group)
        rep["core_rows"] += part["core_rows"]
        rep["written"] += part["written"]
        rep["written_requests"] += part["written_requests"]
        rep["written_requests"] = sorted(rep["written_requests"])[:LISTED_IDS]
        rep["errors"] += part["errors"]
        rep["withdrawn"] += len(part.get("missing_built", []))
        rep["withdrawn_requests"] += part.get("missing_built", [])
        rep["withdrawn_requests"] = sorted(rep["withdrawn_requests"])[:LISTED_IDS]
        for k in ("missing_results", "duplicate_results", "unexpected_results"):
            rep[k] += part[k]
        for reason, n in part["refused"].items():
            rep["refused"][reason] = rep["refused"].get(reason, 0) + n
        if part.get("run_id"):
            rep["push_run_ids"].append(part["run_id"])
        if part.get("stopped"):
            rep["stopped"] = part["stopped"]
        if part["errors"]:
            rep["stopped"] = part.get("stopped") or "upload failed"
            break                                  # never keep posting into a failing endpoint
    rep["written_requests"] = sorted(rep["written_requests"])[:LISTED_IDS]
    if apply:
        after = anchor_upload.pending(store)
        newly_exhausted = {rid: why for rid, why in after["exhausted"].items()
                           if rid in take and rid not in owed["exhausted"] and why.startswith("upload_failed_")}
        if newly_exhausted:
            msg = (f":no_entry: credit-anchors-push: {len(newly_exhausted)} built anchor record(s) exhausted after "
                   f"{anchor_upload.MAX_ERRORS} failed uploads: {', '.join(sorted(newly_exhausted)[:LISTED_IDS])}")
            rep["paged"] = bool((page or page_critical)(msg))
        # what the run LEFT exhausted, so the run that pages names the records it paged about
        rep["exhausted"] = len(after["exhausted"])
        rep["exhausted_requests"] = sorted(after["exhausted"])[:LISTED_IDS]
        rep["exhausted_at"] = {rid: after["exhausted_at"][rid] for rid in sorted(after["exhausted_at"])[:LISTED_IDS]}
        rep["retry_owed"] = len(anchor_upload.awaiting_retry(after))
    unaccounted = (rep["errors"] or rep["convert_errors"] or rep["missing_results"] or rep["duplicate_results"]
                   or rep["unexpected_results"])
    if not apply:
        rep["outcome"], rep["exit_code"] = "dry_run", 1 if rep["convert_errors"] else 0
    elif unaccounted:
        rep["outcome"], rep["exit_code"] = "failed", 1
    elif rep["refused"]:
        rep["outcome"] = "pushed_with_refusals" if rep["written"] else "refused_by_core"
        rep["exit_code"] = 0
    elif not rep["written"]:
        # A run is a push only when at least one row landed; a taken record withdrawn by a newer refused build
        # before its POST posted nothing.
        rep["outcome"] = IDLE_EXHAUSTED if rep["exhausted"] else "nothing_pending"
        rep["exit_code"] = 0
    else:
        rep["outcome"], rep["exit_code"] = "pushed", 0
    return rep


def append_record(record: dict[str, Any], state_dir: str | None = None) -> str:
    d = Path(state_dir or STATE_DIR)
    d.mkdir(parents=True, exist_ok=True)
    path = d / "runs.jsonl"
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    return str(path)


def scheduled_run(open_store: Callable[[], Any], *, apply: bool, max_requests: int = MAX_REQUESTS,
                  state_dir: str | None = None, switches: tuple[str, ...] | None = None,
                  poster: anchor_upload.Poster | None = None,
                  probe: Callable[[], bool] | None = None,
                  now_ms: Callable[[], int] = lambda: int(time.time() * 1000)) -> dict[str, Any]:
    """One run from start to its run record. Once the state directory is usable, every path out of here writes
    exactly one record, the failures too: a run that died without one would leave the previous run's line reading as
    the latest. An unusable state directory raises before any record exists."""
    d = Path(state_dir or STATE_DIR)
    d.mkdir(parents=True, exist_ok=True)
    started = now_ms()
    record: dict[str, Any] = {"schema": SCHEMA, "job": JOB_NAME, "run_id": "apr-" + uuid.uuid4().hex[:12],
                              "started_at": _iso(started), "started_at_ms": started, "pid": os.getpid(),
                              "invoked_by": invoked_by(), "selection": "pending",
                              "mode": "apply" if apply else "dry-run"}
    lock = open(d / "lock", "a+")
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            record.update({"outcome": "busy", "exit_code": 0, "note": "another anchors push holds the lock"})
        else:
            k = killed(KILL_SWITCHES if switches is None else switches)
            if k:
                record.update({"outcome": "killed", "exit_code": 0, "kill_file": k})
            else:
                try:
                    record.update(run_pending(open_store(), apply=apply, max_requests=max_requests, poster=poster,
                                              probe=probe, now_s=lambda: started / 1000))
                except Exception as exc:  # noqa: BLE001 - recorded, then the run fails
                    record.update({"outcome": "failed", "exit_code": 1,
                                   "error": f"{type(exc).__name__}: {str(exc)[:300]}"})
        finished = now_ms()
        record.update({"finished_at": _iso(finished), "finished_at_ms": finished})
        record["runs_file"] = append_record(record, str(d))
    finally:
        lock.close()
    return record


# -- the scheduler's side ------------------------------------------------------------------------------------------

class SchedulerUnreadable(RuntimeError):
    """The gateway's cron tables could not be read. Never the same as 'the job has not run'."""


def _minutes(expr: str) -> set[int] | None:
    """The minutes an `M * * * *` schedule names; None for any shape this reader does not measure."""
    parts = expr.split()
    if len(parts) != 5 or parts[1:] != ["*", "*", "*", "*"]:
        return None
    out: set[int] = set()
    for piece in parts[0].split(","):
        if piece == "*":
            out |= set(range(60))
        elif piece.startswith("*/") and piece[2:].isdigit() and int(piece[2:]) > 0:
            out |= set(range(0, 60, int(piece[2:])))
        elif piece.isdigit() and int(piece) < 60:
            out.add(int(piece))
        else:
            return None
    return out


def _start_window_s(minutes: set[int]) -> int:
    """The window a scheduled start may land in: START_WINDOW_S, but never reaching the next slot."""
    ordered = sorted(minutes)
    gaps = [b - a for a, b in zip(ordered, ordered[1:])] + [ordered[0] + 60 - ordered[-1]]
    return min(START_WINDOW_S, min(gaps) * 60 // 2)


def _start_delay_s(start: datetime, minutes: set[int]) -> float:
    """Seconds from the latest named slot at or before `start` (a start before a slot is judged against the
    previous one)."""
    total = start.minute * 60 + start.second + start.microsecond / 1_000_000
    latest = max((m for m in minutes if m * 60 <= total), default=max(minutes) - 60)
    return total - latest * 60


def read_records(state_dir: str | None = None) -> list[dict[str, Any]]:
    path = Path(state_dir or STATE_DIR) / "runs.jsonl"
    if not path.exists():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SchedulerUnreadable(f"{type(exc).__name__}: {exc}") from exc
    out = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue                    # a torn last line is not a run record
        if isinstance(row, dict) and row.get("schema") == SCHEMA:
            out.append(row)
    return out


def counts_as_success(rec: dict[str, Any]) -> bool:
    """Whether one run record is a successful scheduled run: applied, exit 0, and either a success outcome or an
    idle run whose every exhausted record is terminal (`deferred_exhausted` with `retry_owed` 0: core refused the
    record, or it failed before any POST - nothing a later run can do, firstmate 2026-11-15). An idle run inside
    an upload cooldown still owes core an anchor (`retry_owed` > 0) and never counts (QA on #2046); a record
    that does not carry the count never counts either."""
    if rec.get("mode") != "apply" or rec.get("exit_code") != 0:
        return False
    if rec.get("outcome") in SUCCESS_OUTCOMES:
        return True
    owed = rec.get("retry_owed")
    return rec.get("outcome") == IDLE_EXHAUSTED and isinstance(owed, int) and not isinstance(owed, bool) and owed == 0


def scheduler_runs(n: int = 2, *, state_db: str = GATEWAY_STATE_DB, state_dir: str | None = None,
                   job: str = JOB_NAME) -> dict[str, Any]:
    """The job's `n` newest FINISHED scheduler receipts, each with the run record written inside its window.
    `consecutive_ok` is true only when there are `n` of them and every one is an `ok` receipt started within five
    minutes after a minute the schedule names (`started_on_schedule`; the strict minute match is reported as
    `started_on_minute`, information only), paired with exactly one applied run record that exited 0 and pushed
    (rows landed, with or without core refusals) or had nothing built and unlanded. An idle run that holds exhausted records reports
    `deferred_exhausted`, never one of `SUCCESS_OUTCOMES`: it counts only when none of them is awaiting an upload
    retry (`counts_as_success`)."""
    if not Path(state_db).exists():
        raise SchedulerUnreadable(f"no gateway state db at {state_db}")
    try:
        db = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True, timeout=30)
        db.row_factory = sqlite3.Row
        try:
            jobs = db.execute("SELECT job_id, enabled, job_json FROM cron_jobs WHERE name=?", (job,)).fetchall()
            if not jobs:                # a readable store that holds no such job: not scheduled there, a measured no
                return {"job": job, "scheduled": False, "asked": n, "finished_receipts": 0,
                        "unfinished_receipts": 0, "consecutive_ok": False, "runs": []}
            if len(jobs) != 1:
                raise SchedulerUnreadable(f"{len(jobs)} cron jobs named {job!r} in the gateway store (expected 1)")
            job_id, enabled = jobs[0]["job_id"], bool(jobs[0]["enabled"])
            schedule = (json.loads(jobs[0]["job_json"] or "{}").get("schedule") or {})
            receipts = [dict(r) for r in db.execute(
                "SELECT receipt_id, status, started_at_ms, finished_at_ms, error_text FROM cron_run_receipts"
                " WHERE job_id=? AND finished_at_ms IS NOT NULL ORDER BY started_at_ms DESC LIMIT ?", (job_id, n))]
            running = db.execute("SELECT count(*) FROM cron_run_receipts WHERE job_id=? AND finished_at_ms IS NULL",
                                 (job_id,)).fetchone()[0]
        finally:
            db.close()
    except (sqlite3.Error, ValueError) as exc:
        raise SchedulerUnreadable(f"{type(exc).__name__}: {exc}") from exc
    expr = str(schedule.get("expr") or "")
    minutes = _minutes(expr) if schedule.get("kind") == "cron" and (schedule.get("tz") or "UTC") == "UTC" else None
    window = None if minutes is None else _start_window_s(minutes)
    records = read_records(state_dir)
    runs = []
    for r in receipts:
        start, end = int(r["started_at_ms"]), int(r["finished_at_ms"])
        inside = [x for x in records if start <= int(x.get("started_at_ms") or -1) <= end]
        started = datetime.fromtimestamp(start / 1000, timezone.utc)
        on_minute = None if minutes is None else started.minute in minutes
        delay = None if minutes is None else _start_delay_s(started, minutes)
        on_schedule = None if delay is None else delay <= window
        rec = inside[0] if len(inside) == 1 else None
        good = r["status"] == "ok" and on_schedule is True and rec is not None and counts_as_success(rec)
        runs.append({"receipt_id": r["receipt_id"], "scheduler_status": r["status"], "started_at": _iso(start),
                     "finished_at": _iso(end), "error": r["error_text"] or None,
                     "started_on_schedule": on_schedule, "started_on_minute": on_minute, "start_delay_s": delay,
                     "run_records_in_window": len(inside), "run_record": rec, "counts": good})
    return {"job": job, "scheduled": True, "job_id": job_id, "enabled": enabled, "schedule": schedule, "asked": n,
            "start_window_s": window, "finished_receipts": len(runs), "unfinished_receipts": running,
            "consecutive_ok": len(runs) == n and n > 0 and all(x["counts"] for x in runs), "runs": runs}
