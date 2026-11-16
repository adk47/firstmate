#!/usr/bin/env python3
"""bulk_asks.py - the first proof ask by email, released into the bulk send queue at a measured rate.

`bulk_queue.py` is the transport (durable, at most once per key, one in-pod exec per batch). It had no builder
and no rate. This module is both, for ONE stage: the first ask (`uvn-status`, send-gateway template
`credit_status_uvn_ask`). It writes no copy: the body is the reviewed template rendered with the fixed data in
`policies/bulk-asks.json`, so every person gets the same bytes; the copy gate is asked on every job's bytes and
an `observed` pass is a hold here, so only a signed approve sends.

  select    the scale drain's `ask` rows + measured account facts -> one ordered audience (never asked first,
            paid first). An unmeasured fact drops the person with a reason; it never reads as clear.
  release   each minute, the copy gate is asked on the exact bytes the jobs will send, and only an approved body
            releases anyone. Then the next N people in that order, each CLAIMED in the shared verify ledger first
            (`verify_ledger.claim`: one message per user per UTC day, the 7-day cooldown, the 90-day ask lock,
            one ask per request), and only a claimed person becomes a queue job.
  judge     N starts at the floor and doubles after a clean window. It goes to 0 (a hold) on a hard bounce,
            soft bounce or complaint rate over its bar, a paused or unreadable route, a ceiling refusal, an
            uncertain job, or a health read that does not count our own sends. A hold that clears restarts at
            the floor.
  derive    the ledger claim is the ONLY commit point. One idempotent pass reads this lane's `attempted` claims
            and makes the queue agree: a settled job finalizes its claim (sent / rejected), a jobless claim gets
            exactly one job on the approved bytes, and a claim the copy gate or the queue holds is given back
            (a `deferred` log, never a lock) after its queued job is cancelled. A kill at any step is finished by
            the next tick's pass: sent once, or offered again.

It ships UNARMED: `enabled: false`, no template pin, no approval on file. `run --apply` refuses until all three
are set, and the email ask itself is off by a recorded captain decision (scripts/paid-status/daily.sh, firstmate
024). `rehearse` takes no --db and no --ledger: it makes its own scratch files, with a fake provider.

Doc: docs/credit-verification/bulk-asks.md.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import resource
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import bulk_queue, verify_ledger  # noqa: E402

POLICY_PATH = ROOT / "policies" / "bulk-asks.json"
DEFAULT_RAMP_DB = "/var/lib/hydra/bulk-send-queue/asks-ramp.sqlite"
KILL_FILE = "/etc/hydra/bulk-asks.disabled"
TICK_S = 60.0
EXIT_REFUSED, EXIT_KILLED, EXIT_MEMORY, EXIT_HELD = 2, 3, 5, 4
#: A plan row the drain marks this way has a document on file: it is never asked for one.
PROOF_ON_FILE_REASON = "proof_on_file_undecided"
#: Every one of these must be PRESENT on an account row. A missing one is `unmeasured:<fact>`, never a pass.
ACCOUNT_FACTS = ("email", "email_confirmed", "email_owners", "hold", "proof_on_file", "asked_before", "paid")

SCHEMA = """
CREATE TABLE IF NOT EXISTS audience (
  rank INTEGER PRIMARY KEY, user_key TEXT NOT NULL UNIQUE, row_json TEXT NOT NULL,
  released_at REAL NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0, outcome TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS audience_open ON audience(released_at, rank);
CREATE TABLE IF NOT EXISTS samples (
  at REAL PRIMARY KEY, readable INTEGER NOT NULL, sent INTEGER NOT NULL, hard INTEGER NOT NULL,
  soft INTEGER NOT NULL, complained INTEGER NOT NULL, paused INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS ticks (
  at REAL PRIMARY KEY, rate INTEGER NOT NULL, state TEXT NOT NULL, reason TEXT NOT NULL,
  step_at REAL NOT NULL, released INTEGER NOT NULL, detail TEXT NOT NULL DEFAULT '{}');
"""


# ---------------------------------------------------------------------------------------------------- policy
def load_policy(path: str | os.PathLike | None = None) -> dict:
    return json.loads(Path(path or POLICY_PATH).read_text(encoding="utf-8"))


def armed(policy: dict, queue_policy: dict) -> str:
    """'' when a real release may run, else the first reason it may not. Every switch must be on."""
    if policy.get("enabled") is not True:
        return "policies/bulk-asks.json enabled is not true"
    why = bulk_queue._armed(queue_policy, "email")
    if why:
        return why
    stage, cls, key = str(policy.get("stage")), str(policy.get("message_class")), str(policy.get("template_key"))
    email = (queue_policy.get("routes") or {}).get("email") or {}
    if (queue_policy.get("stages") or {}).get(stage) != cls or (email.get("template_keys") or {}).get(cls) != key:
        return f"policies/bulk-send-queue.json does not map stage {stage} to {cls} and {key}"
    pin = str((email.get("template_sha256") or {}).get(key) or "")
    if not verify_ledger.TEMPLATE_SHA_RE.match(pin):
        return f"template {key} is not pinned in policies/bulk-send-queue.json"
    if pin != str(policy.get("template_sha256") or ""):
        return "the pin in bulk-asks.json is not the pin the queue sends under: the body on file is for another template"
    if not str(policy.get("body") or "").strip() or not str(policy.get("subject") or "").strip():
        return "bulk-asks.json has no rendered body and subject for the pinned template"
    ap = policy.get("approval") or {}
    for field in ("approved_by", "approval_ref", "approver_kind", "approval_id"):
        if not str(ap.get(field) or "").strip():
            return f"bulk-asks.json approval.{field} is empty: no recorded decision arms the email ask"
    try:  # the ledger's own rule for a stamp, asked here so a bad one refuses the run and not the first claim
        verify_ledger.approval_stamp(ap["approver_kind"], ap["approval_id"], pin, ap["approved_by"])
    except ValueError as exc:
        return f"bulk-asks.json approval is not a stamp the ledger takes: {exc}"
    return ""


# ------------------------------------------------------------------------------------------- the fixed body
TAG_RE = re.compile(r"\{%\s*(.*?)\s*%\}|\{\{\s*(.*?)\s*\}\}", re.S)
VAR_RE = re.compile(r"^event\.([a-z_]+)(?:\|default:'([^']*)')?$")


def render(source: str, data: dict) -> str:
    """The template's text for `data`. It knows `{% if event.x %}`, `{% else %}`, `{% endif %}` and
    `{{ event.x }}` with an optional `|default:'..'`, and raises on anything else: a construct it does not know
    is a body it cannot vouch for."""
    out: list[str] = []
    stack: list[bool] = []  # one entry per open `if`: is the branch being read the live one
    pos = 0
    for m in TAG_RE.finditer(source):
        if all(stack):
            out.append(source[pos:m.start()])
        pos = m.end()
        tag, var = m.group(1), m.group(2)
        if var is not None:
            v = VAR_RE.match(var)
            if not v:
                raise ValueError(f"unknown template variable: {var!r}")
            if all(stack):
                val = data.get(v.group(1))
                if val in (None, ""):
                    if v.group(2) is None:
                        raise ValueError(f"template needs event.{v.group(1)} and the fixed data has none")
                    val = v.group(2)
                out.append(str(val))
        elif tag.startswith("if "):
            cond = re.match(r"^if (not )?event\.([a-z_]+)$", tag)
            if not cond:
                raise ValueError(f"unknown template condition: {tag!r}")
            stack.append(bool(data.get(cond.group(2))) != bool(cond.group(1)))
        elif tag == "else" and stack:
            stack[-1] = not stack[-1]
        elif tag == "endif" and stack:
            stack.pop()
        else:
            raise ValueError(f"unknown template tag: {tag!r}")
    if stack:
        raise ValueError("unclosed {% if %}")
    return ("".join(out) + source[pos:]).strip() + "\n"


def pin(templates_dir: str | os.PathLike, policy: dict) -> dict:
    """What a PR that arms the ask records: the template's pin and its body and subject for the fixed data, read
    from a reviewed checkout of the gateway's `templates/`. It writes nothing."""
    from request_comms.channels import template_source_sha256

    root, key = Path(templates_dir), str(policy["template_key"])
    found = [k[key] for k in (json.loads((root / f).read_text(encoding="utf-8")).get("keys") or {}
                              for f in ("registry.json", "native.json")) if key in k]
    if len(found) != 1:
        raise ValueError(f"template {key}: {len(found)} entries, need exactly one")
    data = dict(policy.get("template_data") or {})
    return {"template_key": key, "template_sha256": template_source_sha256(root, key),
            "subject": render(str(found[0]["subject"]), data).strip(),
            "body": render((root / str(found[0]["text"])).read_text(encoding="utf-8"), data)}


# ------------------------------------------------------------------------------------------------ selection
def select(plan_rows: Iterable[dict], accounts: dict[str, dict], policy: dict) -> tuple[list[dict], dict]:
    """(the ordered audience, why everyone else was dropped). One row per user, the people `bulk_queue.load_people`
    takes. Order: never asked before paid-or-not, then paid, then user id, so two runs give the same bytes."""
    stage, body, subject = str(policy["stage"]), str(policy.get("body") or ""), str(policy.get("subject") or "")
    by_user: dict[str, list[str]] = {}
    dropped: dict[str, int] = {}
    on_file: set[str] = set()

    def drop(why: str, n: int = 1) -> None:
        dropped[why] = dropped.get(why, 0) + n

    for row in plan_rows:
        if row.get("outcome") != "ask":
            continue
        uid = str(row.get("user_id") if row.get("user_id") is not None else "").strip()
        if not uid:
            drop("no_user_id")
            continue
        if row.get("reason_code") == PROOF_ON_FILE_REASON:
            on_file.add(uid)
        by_user.setdefault(uid, []).append(str(row.get("request_id") or "").lower())

    people: list[tuple[tuple, dict]] = []
    for uid, ids in by_user.items():
        acct = accounts.get(uid)
        if acct is None:
            drop("unmeasured:account")
            continue
        missing = [f for f in ACCOUNT_FACTS if f not in acct or acct[f] is None]
        if missing:
            drop(f"unmeasured:{missing[0]}")
            continue
        email = str(acct["email"]).strip().lower()
        why = (f"hold:{acct['hold']}" if str(acct["hold"]) else
               "proof_on_file" if uid in on_file or acct["proof_on_file"] else
               "no_email" if not email else
               "email_unconfirmed" if acct["email_confirmed"] is not True else
               "email_shared" if int(acct["email_owners"]) != 1 else "")
        if why:
            drop(why.split(":")[0] if why.startswith("hold:") else why)
            continue
        asked, paid = bool(acct["asked_before"]), bool(acct["paid"])
        people.append(((asked, not paid, int(uid) if uid.isdigit() else 0, uid), {
            "user_key": email, "user_id": uid, "email": email, "email_confirmed": True, "stage": stage,
            "request_ids": sorted(set(ids)), "body": body, "subject": subject,
            "data": dict(policy.get("template_data") or {}), "copy_data": [],
            "paid": paid, "never_asked": not asked}))
    people.sort(key=lambda p: p[0])
    return [p for _, p in people], dict(sorted(dropped.items()))


# --------------------------------------------------------------------------------------------------- the ramp
@dataclass(frozen=True)
class Sample:
    """One read of the route's health: counters over the gateway's own window, so only a DIFFERENCE between two
    samples says anything about our sends."""
    at: float
    readable: bool
    sent: int = 0
    hard: int = 0
    soft: int = 0
    complained: int = 0
    paused: bool = False


#: Holds that a rate proved. The others clear as soon as their condition does.
RATE_HOLDS = ("hard_bounce", "complaint", "soft_bounce", "health_not_counting_our_sends")


@dataclass(frozen=True)
class Verdict:
    rate: int        # people to release in the coming minute; 0 is a hold
    state: str       # ramping | held
    reason: str
    step_at: float   # when this rate began


def judge(cfg: dict, rate: int, step_at: float, samples: list[Sample], queue: dict, now: float, *,
          held_for: str = "") -> Verdict:
    """The rate for the coming minute. Pure: the same inputs give the same answer.

    `samples` are in time order; `queue` is what the queue itself recorded: `uncertain` jobs, `blocked_until`
    (the route's not_before, raised when the gateway refuses a batch send), `sent_since_step` and
    `sent_before_lag` (sends this step, and those old enough for the health read to have counted them).
    `held_for` is the reason of the hold in force, if any: a hold on a RATE stands for `rate_hold_s`, because the
    sends that proved it stopped with the hold and the next sample would otherwise read as clean.
    """
    floor, top = int(cfg["floor_per_min"]), int(cfg["max_per_min"])
    last = samples[-1] if samples else None

    def hold(why: str) -> Verdict:
        return Verdict(0, "held", why, now if rate else step_at)

    if last is None or not last.readable:
        return hold("health_unreadable")
    if last.paused:
        return hold("route_paused")
    if float(queue.get("blocked_until") or 0) > now:
        return hold("route_refused_batch_send")
    if int(queue.get("uncertain") or 0) > 0:
        return hold(f"uncertain_jobs:{queue['uncertain']}")

    base = next((s for s in samples if s.readable and s.at >= step_at), last)
    d_sent = last.sent - base.sent
    judged = d_sent >= int(cfg["min_judged"])
    if judged:
        for name, bad, bar in (("hard_bounce", last.hard - base.hard, cfg["hard_bounce_max"]),
                               ("complaint", last.complained - base.complained, cfg["complaint_max"]),
                               ("soft_bounce", last.soft - base.soft, cfg["soft_bounce_max"])):
            if max(0, bad) / d_sent > float(bar):
                return hold(f"{name}:{max(0, bad)}/{d_sent}")
    counted = int(queue.get("sent_before_lag") or 0)
    if counted >= 2 * int(cfg["min_judged"]) and d_sent < 0.5 * counted:
        return hold(f"health_not_counting_our_sends:{d_sent}/{counted}")

    if rate <= 0:
        if held_for.split(":")[0] in RATE_HOLDS and now - step_at < float(cfg["rate_hold_s"]):
            return Verdict(0, "held", held_for, step_at)
        return Verdict(floor, "ramping", "start_at_floor", now)
    if rate >= top:
        return Verdict(top, "ramping", "at_max", step_at)
    window = float(cfg["window_s"])
    if now - step_at < window + float(cfg["health_lag_s"]):
        return Verdict(rate, "ramping", "window_open", step_at)
    if not judged:
        return Verdict(rate, "ramping", "window_unmeasured", step_at)
    if int(queue.get("sent_since_step") or 0) < 0.9 * rate * window / 60.0:
        return Verdict(rate, "ramping", "rate_not_reached", step_at)
    return Verdict(min(top, rate * int(cfg["factor"])), "ramping", "clean_window", now)


# ---------------------------------------------------------------------------------------------- ramp storage
def connect(path: str | os.PathLike, *, init: bool = False) -> sqlite3.Connection:
    if init:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    elif not Path(path).exists():
        raise FileNotFoundError(f"{path}: no ramp store (run `load` first)")
    db = sqlite3.connect(str(path), timeout=120, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout = 120000")
    if init:
        db.execute("PRAGMA journal_mode = WAL")
        db.executescript(SCHEMA)
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='audience'").fetchone():
        if "retry_at" not in {r[1] for r in db.execute("PRAGMA table_info(audience)")}:
            db.execute("ALTER TABLE audience ADD COLUMN retry_at REAL NOT NULL DEFAULT 0")
    # WAL with NORMAL keeps every commit across a killed process and loses the last ones only when the box
    # itself goes down. Nothing here is a commit point: the ledger claim is, and `derive` rebuilds the queue and
    # the audience from it, so a lost write here costs at most an offer made again (and refused by the ledger's
    # own one-a-day rule), never a duplicate and never a person blocked. FULL costs one fsync per person
    # released, which alone is seconds of a 1,000-a-minute tick.
    db.execute("PRAGMA synchronous = NORMAL")
    return db


def load_audience(rdb: sqlite3.Connection, people: Iterable[dict]) -> int:
    """Append people in the order given. A person already in the audience keeps their place and their outcome; the
    bytes a job sends are taken from this run's copy at release, so a stale row is never what leaves."""
    n = 0
    rdb.execute("BEGIN IMMEDIATE")
    rank = rdb.execute("SELECT COALESCE(MAX(rank), 0) FROM audience").fetchone()[0]
    for p in people:
        rank += 1
        n += rdb.execute(
            "INSERT INTO audience (rank, user_key, row_json) VALUES (?,?,?) ON CONFLICT (user_key) DO NOTHING",
            (rank, p["user_key"], json.dumps(p, sort_keys=True))).rowcount
    rdb.execute("COMMIT")
    return n


def queue_facts(qdb: sqlite3.Connection, stage: str, step_at: float, lag_s: float, now: float) -> dict:
    one = lambda sql, *a: qdb.execute(sql, a).fetchone()[0]  # noqa: E731
    sent = "SELECT COUNT(*) FROM jobs WHERE stage = ? AND state = 'sent' AND done_at >= ?"
    return {
        "uncertain": one("SELECT COUNT(*) FROM jobs WHERE stage = ? AND state = 'uncertain'", stage),
        "blocked_until": one("SELECT COALESCE(MAX(not_before), 0) FROM routes WHERE route = 'email'"),
        "sent_since_step": one(sent, stage, step_at),
        "sent_before_lag": one(sent + " AND done_at <= ?", stage, step_at, now - lag_s),
        "backlog": one("SELECT COUNT(*) FROM jobs WHERE stage = ? AND state IN ('queued','claimed','attempted')",
                       stage),
    }


Claim = Callable[[dict, float], tuple[int, str]]
Finalize = Callable[[int, str, str], None]


@dataclass(frozen=True)
class Lane:
    """This lane's side of the shared verify ledger, which is its ONE commit point.

    A person is this lane's the moment `claim` commits an `attempted` verify-ledger row carrying this lane's
    approval, and nothing else records that fact: there is no reservation, intent or note that has to agree with
    it. `attempted` lists those rows (`(message_row, user_key, claimed_at)`, oldest first); `finalize` writes a
    settled job's outcome on one; `give_back` turns a never-posted one into a `deferred` log (never a lock), so the
    person is reachable by every sender again."""
    claim: Claim
    attempted: Callable[[], list[tuple[int, str, float]]]
    finalize: Finalize
    give_back: Callable[[int, str], bool]


#: A claim result that closes this audience row: the ledger says the ask is done or the request is already
#: notified. Every other result is a deferral, offered again when its lock lapses.
TERMINAL_CLAIM_RESULTS = ("already_notified", "user_done")
#: Queue verdicts that end this stage for the person (nothing is owed); every other non-send verdict is a hold.
TERMINAL_SKIPS = ("already_told", "nothing_open", "stale_stage")
#: A job enqueued more than this before the claim was made belongs to an earlier claim, not to this one.
CLAIM_CLOCK_SLACK_S = 1.0


def retry_delay(why: str) -> float:
    """How long a deferral stands before the person is offered again: the ledger's own windows (the 7-day
    cooldown, the 90-day ask lock, the next UTC day for the daily cap) and a week for a channel that may clear."""
    result, _, reason = why.partition(":")
    if result == "recent":
        return 90 * 86400.0 if reason == "recently_asked" else 7 * 86400.0
    if result == "no_channel":
        return 7 * 86400.0
    return 86400.0


def _audience(rdb: sqlite3.Connection, user_key: str, *, now: float, outcome: str, retry_at: float = 0.0) -> None:
    rdb.execute("UPDATE audience SET released_at = ?, retry_at = ?, outcome = ? WHERE user_key = ?",
                (now, retry_at, outcome[:300], user_key))


def release(rdb: sqlite3.Connection, n: int, lane: Lane, *, now: float, copy: dict,
            retry_when: Callable[[dict, str, float], float] | None = None) -> dict:
    """Claim the next `n` people on the copy the gate approved this tick.

    The ledger claim is the only thing this commits that matters. The audience note written after it only says
    who was offered and on which bytes; it is never read as proof of a claim. Turning a claim into a job is
    `derive`'s, which reads the ledger itself, so a kill before the claim leaves nothing, and a kill after it
    leaves a claim the next `derive` finishes (or gives back)."""
    retry = retry_when or (lambda person, why, at: at + retry_delay(why))
    out: dict[str, Any] = {"offered": 0, "claimed": 0}
    rows = rdb.execute(
        "SELECT rank, user_key, row_json FROM audience "
        "WHERE released_at = 0 OR (retry_at > 0 AND retry_at <= ?) ORDER BY rank LIMIT ?",
        (now, max(0, n))).fetchall()
    t0, in_ledger = time.monotonic(), 0.0
    for r in rows:
        person = dict(json.loads(r["row_json"]), **copy)
        out["offered"] += 1
        t1 = time.monotonic()
        message_row, why = lane.claim(person, now)
        in_ledger += time.monotonic() - t1
        if not why:
            rdb.execute("UPDATE audience SET released_at = ?, retry_at = 0, outcome = 'claimed', row_json = ? "
                        "WHERE rank = ?", (now, json.dumps(person, sort_keys=True), r["rank"]))
            out["claimed"] += 1
            continue
        if why.split(":", 1)[0] in TERMINAL_CLAIM_RESULTS:
            _audience(rdb, r["user_key"], now=now, outcome=f"closed:{why}")
        else:
            _audience(rdb, r["user_key"], now=now, outcome=f"deferred:{why}", retry_at=retry(person, why, now))
        out[f"not_claimed:{why}"] = out.get(f"not_claimed:{why}", 0) + 1
    # Where the minute went: the ledger's claims are the part this module cannot make cheaper.
    out["ledger_ms"], out["total_ms"] = int(in_ledger * 1000), int((time.monotonic() - t0) * 1000)
    return out


def derive(rdb: sqlite3.Connection, qdb: sqlite3.Connection, stage: str, lane: Lane, *, now: float,
           copy: dict, held: str = "") -> dict:
    """The one pass that makes the queue and the audience agree with the ledger, from the ledger.

    For each of this lane's `attempted` claims, oldest first:

    - its job settled: the outcome is written on the claim (`sent`, `rejected`);
    - its job is queued behind a copy-gate hold: the job is cancelled, and only a job that WAS cancelled (no
      worker holds it) has its claim given back, so nothing ever leaves without the claim that recorded it;
    - its job is queued or in flight: the claim stays `attempted`;
    - it has no job: it is enqueued, once, on the copy the gate approved this tick, scoped to exactly these
      people, so a person with no live claim is never made a job; when the gate holds the copy now, when no
      audience row says who the person is, or when the queue's own decide refuses them, the claim is given back
      and the person offered again (a terminal skip closes them instead).

    A job made for an EARLIER claim (it was enqueued before this claim existed) never settles this one: the claim
    is given back. It reads only the ledger and the queue, so it is idempotent: running it twice, or after a kill
    at any point of `release`, of itself or of a worker, comes to the same state. There is no grace window,
    because nothing but this lane makes these claims and nothing it writes before a claim can be lost."""
    out = {"sent": 0, "rejected": 0, "given_back": 0, "queued": 0, "in_flight": 0, "closed": 0}

    def give(message_row: int, key: str, why: str, *, close: bool = False) -> None:
        if not lane.give_back(message_row, why):
            out["in_flight"] += 1  # not a never-posted claim any more: nothing here may touch it
            return
        out["given_back"] += 1
        if close:
            _audience(rdb, key, now=now, outcome=f"closed:{why}")
            out["closed"] += 1
        else:
            _audience(rdb, key, now=now, outcome=f"deferred:{why}", retry_at=now + 86400.0)

    jobless: list[tuple[int, str]] = []
    claims = lane.attempted()
    for message_row, key, claimed_at in claims:
        job = qdb.execute("SELECT state, reason, provider_id, enqueued_at FROM jobs WHERE user_key = ? AND stage = ?",
                          (key, stage)).fetchone()
        if job is None:
            jobless.append((message_row, key))
            continue
        state, reason = str(job[0]), str(job[1] or "")
        if float(job[3]) < claimed_at - CLAIM_CLOCK_SLACK_S:
            give(message_row, key, f"bulk-asks: an earlier job holds this stage ({state})", close=True)
        elif state == "sent":
            lane.finalize(message_row, "sent", f"send-gateway:{job[2]}")
            _audience(rdb, key, now=now, outcome="sent")
            out["sent"] += 1
        elif state == "rejected":
            lane.finalize(message_row, "rejected", f"bulk-queue: {reason}"[:300])
            _audience(rdb, key, now=now, outcome=f"rejected:{reason}")
            out["rejected"] += 1
        elif state == "queued" and reason.startswith(verify_ledger.COPY_HOLD_PREFIX):
            if bulk_queue.cancel_held(qdb, user_key=key, stage=stage, reason=reason, now=now):
                give(message_row, key, reason)
            else:
                out["in_flight"] += 1  # a worker took it first: it settles like any other job
        else:
            out["in_flight"] += 1
    if jobless:
        _enqueue_claims(rdb, qdb, stage, jobless, now=now, copy=copy, held=held, give=give, out=out)
    _repair_audience(rdb, qdb, stage, {key for _, key, _ in claims}, now=now, out=out)
    return out


def _enqueue_claims(rdb: sqlite3.Connection, qdb: sqlite3.Connection, stage: str, jobless: list[tuple[int, str]], *,
                    now: float, copy: dict, held: str, give: Callable[..., None], out: dict) -> None:
    """A live claim with no job gets exactly one, scoped to the people holding such a claim; one the gate or the
    queue will not let go is given back."""
    stored = {str(r["user_key"]): str(r["row_json"]) for r in rdb.execute(
        "SELECT user_key, row_json FROM audience WHERE user_key IN (SELECT value FROM json_each(?))",
        (json.dumps([k for _, k in jobless]),))}
    people, asked = [], []
    for message_row, key in jobless:
        if held:
            give(message_row, key, held)
        elif key not in stored:
            give(message_row, key, "bulk-asks: a claim no audience row names")
        else:
            people.append(dict(json.loads(stored[key]), **copy))
            asked.append((message_row, key))
    if people:
        bulk_queue.load_people(qdb, people, now=now)
        bulk_queue.decide(qdb, now=now)
        out["queued"] += int(bulk_queue.enqueue(qdb, now=now, only=[p["user_key"] for p in people])
                             .get("enqueued") or 0)
    for message_row, key in asked:
        if qdb.execute("SELECT 1 FROM jobs WHERE user_key = ? AND stage = ?", (key, stage)).fetchone():
            # A kill between the claim and its audience note leaves the row unreleased: say it is claimed, so the
            # next release does not offer a person who already holds a claim and a job.
            _audience(rdb, key, now=now, outcome="claimed")
            continue
        v = qdb.execute("SELECT verdict, reason FROM verdicts WHERE user_key = ? AND stage = ?",
                        (key, stage)).fetchone()
        verdict = f"{v[0]}:{v[1]}" if v else "no_verdict"
        give(message_row, key, f"bulk-queue: {verdict}"[:300],
             close=bool(v) and v[0] == "skip" and str(v[1]) in TERMINAL_SKIPS)


def _repair_audience(rdb: sqlite3.Connection, qdb: sqlite3.Connection, stage: str, live: set[str], *, now: float,
                     out: dict) -> None:
    """An audience row says `claimed` but the ledger holds no live claim for the person: a kill landed between a
    ledger write (a finalize or a give-back) and its audience note. The queue says which: a settled job is written
    down, and no job at all means the claim was given back, so the person is offered again. A job still on its way
    is left alone: its claim is what settles it."""
    for r in rdb.execute("SELECT user_key FROM audience WHERE outcome = 'claimed'").fetchall():
        key = str(r["user_key"])
        if key in live:
            continue
        job = qdb.execute("SELECT state, reason FROM jobs WHERE user_key = ? AND stage = ?", (key, stage)).fetchone()
        if job is None:
            _audience(rdb, key, now=now, outcome="deferred:claim_no_longer_live", retry_at=now + 86400.0)
            out["repaired"] = out.get("repaired", 0) + 1
        elif job[0] == "sent":
            _audience(rdb, key, now=now, outcome="sent")
        elif job[0] == "rejected":
            _audience(rdb, key, now=now, outcome=f"rejected:{job[1]}")


def tick(rdb: sqlite3.Connection, qdb: sqlite3.Connection, policy: dict, *, health: Callable[[], Sample],
         lane: Lane, now: float | None = None, retry_when: Callable[[dict, str, float], float] | None = None,
         precheck: Callable[[], tuple[str, dict]] | None = None) -> dict:
    """One minute of the ramp: sample, ask the copy gate, derive, judge, claim, derive.

    The sample comes first and the tick's clock is the sample's own: a send the sample counted happened before
    `now`, and one it did not count happened after it. Sampling after the settle (1,000 ledger writes at the
    top rate) stamped a late read with an early time, so the next minute saw no new sends against 400 the
    queue had made and held on `health_not_counting_our_sends` (scratch rehearsal, 2026-11-15).

    The copy gate is asked before anyone is claimed, so a held body claims nobody; the first `derive` settles
    and repairs what the last minute (or a kill) left, and the second turns this minute's claims into jobs."""
    cfg, stage = policy["ramp"], str(policy["stage"])
    s = health()
    now = s.at if now is None else now
    bulk_queue.recover(qdb, now=now)
    held, copy = precheck() if precheck is not None else ("", {})
    derived = derive(rdb, qdb, stage, lane, now=now, copy=copy, held=held)
    rdb.execute("INSERT OR REPLACE INTO samples (at, readable, sent, hard, soft, complained, paused) "
                "VALUES (?,?,?,?,?,?,?)", (now, int(s.readable), s.sent, s.hard, s.soft, s.complained, int(s.paused)))
    prev = rdb.execute("SELECT rate, step_at, state, reason FROM ticks ORDER BY at DESC LIMIT 1").fetchone()
    rate, step_at = (int(prev["rate"]), float(prev["step_at"])) if prev else (0, now)
    # A rate hold stands from when it was PROVED: an unreadable or paused sample in between does not erase it.
    held_for = next((str(r["reason"]) for r in rdb.execute(
        "SELECT reason FROM ticks WHERE at >= ? AND state = 'held' ORDER BY at DESC", (step_at,))
        if str(r["reason"]).split(":")[0] in RATE_HOLDS), "")
    samples = [Sample(r["at"], bool(r["readable"]), r["sent"], r["hard"], r["soft"], r["complained"],
                      bool(r["paused"]))
               for r in rdb.execute("SELECT * FROM samples WHERE at >= ? ORDER BY at", (step_at,))]
    facts = queue_facts(qdb, stage, step_at, float(cfg["health_lag_s"]), now)
    v = judge(cfg, rate, step_at, samples, facts, now, held_for=held_for)
    # Never queue more than the workers have sent: a backlog is not a rate, and a hold must not have a minute of
    # mail already on its way.
    n = max(0, v.rate - int(facts["backlog"]))
    rel: dict[str, Any] = {"offered": 0, "claimed": 0}
    fresh: dict[str, Any] = {}
    if n and held:
        rel["held"] = held
    elif n:
        rel = release(rdb, n, lane, now=now, copy=copy, retry_when=retry_when)
        fresh = derive(rdb, qdb, stage, lane, now=now, copy=copy)
        rel["queued"] = fresh["queued"]
    rdb.execute("INSERT OR REPLACE INTO ticks (at, rate, state, reason, step_at, released, detail) "
                "VALUES (?,?,?,?,?,?,?)", (now, v.rate, v.state, v.reason, v.step_at, rel["claimed"],
                                           json.dumps({"queue": facts, "release": rel, "derived": derived,
                                                       "fresh": fresh}, sort_keys=True)))
    left = rdb.execute("SELECT COUNT(*) FROM audience WHERE released_at = 0 OR (retry_at > 0 AND retry_at <= ?)",
                       (now,)).fetchone()[0]
    settled = sum(int(d.get(k, 0)) for d in (derived, fresh) for k in ("sent", "rejected", "given_back"))
    # The backlog this tick leaves behind, read AFTER its release: `facts` was read before it, so the tick that
    # queued the last people would report 0 and `run` would stop and kill the workers holding them.
    backlog = qdb.execute("SELECT COUNT(*) FROM jobs WHERE stage = ? AND state IN ('queued','claimed','attempted')",
                          (stage,)).fetchone()[0]
    return {"at": now, "rate": v.rate, "state": v.state, "reason": v.reason, "released": rel["claimed"],
            "release_hold": rel.get("held", ""), "audience_left": left, "backlog": backlog,
            "settled": settled, "ledger_ms": rel.get("ledger_ms", 0), "release_ms": rel.get("total_ms", 0)}


# ---------------------------------------------------------------------------------- the real ledger and health
def ledger_reserve(db: sqlite3.Connection, policy: dict) -> Claim:
    """The shared verify ledger's own claim. `uvn-status` is a status campaign, so `claim` applies the one ask
    per user, the 7-day cooldown, the 90-day ask lock and the per-request block inside its transaction."""
    ap, campaign = policy.get("approval") or {}, str(policy["message_class"])

    def reserve(person: dict, now: float) -> tuple[int, str]:
        when = datetime.fromtimestamp(now, timezone.utc)
        day, uid = when.strftime("%Y-%m-%d"), str(person["user_id"])
        # No read before the claim: claim() reads the per-day cap and every status rule inside its own transaction,
        # and a second read here would only double the time the shared ledger spends on each person.
        res = verify_ledger.claim(
            db, user_key=person["user_key"], day=day, request_ids=list(person["request_ids"]),
            message_type="email", approved_by=str(ap.get("approved_by") or ""),
            approval_ref=str(ap.get("approval_ref") or ""), campaign=campaign, now=when, user_id=uid,
            approver_kind=str(ap.get("approver_kind") or ""), approval_id=str(ap.get("approval_id") or ""),
            template_sha256=str(policy.get("template_sha256") or ""))
        if res.get("result") != "claimed":
            result = str(res.get("result") or "not_claimed")
            reason = str(res.get("reason") or "")
            return 0, f"{result}:{reason}" if reason else result
        return int(res["message_row"]), ""

    return reserve


class EnforcedCopyGate:
    """The copy gate with an `observed` pass held: this sender sends only bytes a reviewer signed an approve for,
    whatever mode the campaign's table says."""

    def __init__(self, gate: Any = None):
        self.gate = gate

    def require(self, campaign: str, body: str, **kw: Any) -> dict:
        gate = self.gate or bulk_queue._copy_gate()
        ans = gate.require(campaign, body, **kw)
        if ans.get("result") != "approved":
            raise gate.CopyHeld(f"observed_not_approved:{campaign}", str(ans.get("body_sha256") or ""))
        return ans


def copy_precheck(qpolicy: dict, policy: dict, gate: Any = None) -> Callable[[], tuple[str, dict]]:
    """`(why it may not leave, {})` or `('', copy)`: the copy is the policy's current one - body, subject and the
    template data the gateway renders the letter with - and `release` puts exactly it on everyone it releases.
    Asked BEFORE anyone is claimed, so a held body leaves no `attempted` ledger row behind."""
    cls, key = str(policy["message_class"]), str(policy["template_key"])
    email = (qpolicy.get("routes") or {}).get("email") or {}
    pin = str((email.get("template_sha256") or {}).get(key) or "").strip().lower()
    frame = f"email-template:{key}@{pin}" if key and pin else ""
    body, subject = str(policy.get("body") or ""), str(policy.get("subject") or "")
    copy = {"body": body, "subject": subject, "data": dict(policy.get("template_data") or {}),
            "copy_data": list(policy.get("copy_data") or [])}

    def check() -> tuple[str, dict]:
        if not frame:
            return f"copy_review_hold: email_template_unpinned:{key}", {}
        try:
            (gate or EnforcedCopyGate()).require(cls, body, subject=subject, copy=frame, data=())
        except Exception as exc:  # noqa: BLE001 - CopyHeld, or a gate that could not run: both hold
            text = str(exc)
            return (text[:300] if text.startswith("copy_review") else f"copy_review_hold: {type(exc).__name__}"), {}
        return "", copy

    return check


def _epoch(stamp: str) -> float:
    try:
        return datetime.strptime(str(stamp), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def ledger_attempted(db: sqlite3.Connection, policy: dict) -> Callable[[], list[tuple[int, str, float]]]:
    """This lane's own never-posted claims, oldest first: its campaign, email, and exactly its approval, so another
    sender's claim on the same campaign is never read as this lane's."""
    campaign = str(policy["message_class"])
    ap = policy.get("approval") or {}
    approver, ref = str(ap.get("approved_by") or ""), str(ap.get("approval_ref") or "")

    def attempted() -> list[tuple[int, str, float]]:
        rows = db.execute(
            "SELECT id, user_key, created_at FROM verify_messages WHERE campaign = ? AND message_type = 'email' "
            "AND status = 'attempted' AND approved_by = ? AND approval_ref = ? ORDER BY id",
            (campaign, approver, ref)).fetchall()
        return [(int(r["id"]), str(r["user_key"]), _epoch(r["created_at"])) for r in rows]

    return attempted


def ledger_give_back(db: sqlite3.Connection) -> Callable[[int, str], bool]:
    """Give a never-posted claim back: the row becomes a `deferred` log and its requests return, so the person is
    reachable by every sender again. A row that is no longer a never-posted claim is refused, never touched."""
    def give_back(message_row: int, why: str) -> bool:
        try:
            verify_ledger.give_back_claim(db, message_row=message_row, reason=why)
        except ValueError:
            return False
        return True

    return give_back


def ledger_lane(db: sqlite3.Connection, policy: dict, body_sha256: str) -> Lane:
    return Lane(claim=ledger_reserve(db, policy), attempted=ledger_attempted(db, policy),
                finalize=ledger_finalize(db, body_sha256), give_back=ledger_give_back(db))


def ledger_retry_when(db: sqlite3.Connection) -> Callable[[dict, str, float], float]:
    """Re-offer at the lock's actual expiry, read from the ledger, not at now + the window."""
    def retry_when(person: dict, why: str, now: float) -> float:
        result, _, reason = why.partition(":")
        if result == "recent":
            exp = verify_ledger.deferral_expiry(db, user_key=person["user_key"], reason=reason,
                                                user_id=str(person.get("user_id") or ""))
            if exp is not None and exp.timestamp() > now:
                return exp.timestamp()
        return now + retry_delay(why)
    return retry_when


def ledger_finalize(db: sqlite3.Connection, body_sha256: str) -> Finalize:
    def finalize(message_row: int, status: str, detail: str) -> None:
        # message_id stays empty on purpose: verify_ledger.awaiting_proof looks every one up in Intercom.
        verify_ledger.finalize(db, message_row=message_row, status=status, reason="" if status == "sent" else detail,
                               body_sha256=body_sha256, api_log=detail)

    return finalize


WARMUP_JS = r"""
const tok = (process.env.INTERNAL_TOKENS || '').split(',').map((s) => s.trim()).find((s) => s.startsWith('admin:'));
if (!tok) { console.log(JSON.stringify({ error: 'no admin caller token in the pod' })); process.exit(0); }
fetch(`http://127.0.0.1:${process.env.PORT || 3000}/v1/warmup`, { headers: { authorization: `Bearer ${tok.slice(6)}` } })
  .then(async (r) => console.log(JSON.stringify({ http: r.status, body: await r.json() })))
  .catch((e) => console.log(JSON.stringify({ error: String(e) })));
"""


def sample_of(answer: dict, route: str, now: float) -> Sample:
    """The gateway's `GET /v1/warmup` answer as a sample. Anything it does not say is unreadable, never zero."""
    try:
        h = answer["body"]["routes"][route]["health"]
        if answer.get("http") != 200 or h.get("unreadable"):
            return Sample(now, False)
        return Sample(now, True, int(h["sent"]), int(h["bounced"]), int(h["soft_bounced"]), int(h["complained"]),
                      bool(h["paused"]))
    except (KeyError, TypeError, ValueError):
        return Sample(now, False)


def gateway_health(route: str) -> Sample:
    """One read-only in-pod GET. A read that fails is an unreadable sample, which holds the ramp."""
    now = time.time()
    try:
        pod = subprocess.run(["kubectl", "-n", "messaging", "get", "pod", "-l", "app.kubernetes.io/name=send-gateway",
                              "--field-selector=status.phase=Running", "-o", "name"],
                             capture_output=True, text=True, timeout=30).stdout.split()
        if not pod:
            return Sample(now, False)
        p = subprocess.run(["kubectl", "-n", "messaging", "exec", "-i", pod[0], "--", "node", "-e", WARMUP_JS],
                           capture_output=True, text=True, timeout=30)
        return sample_of(json.loads(p.stdout.strip().splitlines()[-1]), route, now)
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return Sample(now, False)


# -------------------------------------------------------------------------------------------------- read-back
def minutes(qdb: sqlite3.Connection, stage: str) -> list[dict]:
    """Sent jobs per UTC minute, from the queue's own settled rows."""
    return [{"minute": datetime.fromtimestamp(r[0] * 60, timezone.utc).strftime("%Y-%m-%dT%H:%MZ"), "sent": r[1]}
            for r in qdb.execute("SELECT CAST(done_at / 60 AS INTEGER) m, COUNT(*) FROM jobs "
                                 "WHERE stage = ? AND state = 'sent' GROUP BY m ORDER BY m", (stage,))]


def ledger_minutes(ldb: sqlite3.Connection, campaign: str, since: str) -> list[dict]:
    """The same count at the shared ledger, per UTC minute: rows claimed in it (`created_at`) and rows the ledger
    recorded as sent in it (`sent_at`, written when the outcome is settled, so up to one tick after the send)."""
    out: dict[str, dict] = {}
    for col, name in (("created_at", "claimed"), ("sent_at", "sent")):
        for minute, n in ldb.execute(
                f"SELECT substr({col}, 1, 16), COUNT(*) FROM verify_messages WHERE campaign = ? AND "
                f"message_type = 'email' AND {col} >= ? AND (? = 'claimed' OR status = 'sent') GROUP BY 1",
                (campaign, since, name)):
            out.setdefault(minute, {"minute": minute + "Z", "claimed": 0, "sent": 0})[name] = n
    return [out[m] for m in sorted(out)]


def verify(rdb: sqlite3.Connection, qdb: sqlite3.Connection, ldb: sqlite3.Connection | None, policy: dict, *,
           since: str = "") -> dict:
    """Every count here must be 0. `ledger_*` are read only when the shared ledger is given, over the days
    from `since` on (a UTC stamp; empty is every day)."""
    stage, campaign = str(policy["stage"]), str(policy["message_class"])
    ap = policy.get("approval") or {}
    approver, ref = str(ap.get("approved_by") or ""), str(ap.get("approval_ref") or "")
    one = lambda db, sql, *a: db.execute(sql, a).fetchone()[0]  # noqa: E731
    rep = dict(bulk_queue.verify(qdb))
    if ldb is not None:
        lane = ldb.execute(
            "SELECT user_key, status FROM verify_messages WHERE campaign = ? AND message_type = 'email' "
            "AND approved_by = ? AND approval_ref = ?", (campaign, approver, ref)).fetchall()
        claimed = {str(r[0]) for r in lane}
        sent = {str(r[0]) for r in lane if r[1] == "sent"}
        attempted = [str(r[0]) for r in lane if r[1] == "attempted"]
        # No claim, no job: every job this stage holds was made for one of this lane's claims.
        rep["jobs_without_a_claim"] = sum(
            1 for (uk,) in qdb.execute("SELECT user_key FROM jobs WHERE stage = ?", (stage,)) if uk not in claimed)
        rep["sent_jobs_not_settled"] = sum(
            1 for (uk,) in qdb.execute("SELECT user_key FROM jobs WHERE stage = ? AND state = 'sent'", (stage,))
            if uk not in sent)
        rep["ledger_claims_with_no_job"] = sum(
            1 for uk in attempted
            if not qdb.execute("SELECT 1 FROM jobs WHERE user_key = ? AND stage = ?", (uk, stage)).fetchone())
        rep["ledger_users_messaged_twice_in_a_day"] = one(
            ldb, "SELECT COUNT(*) FROM (SELECT 1 FROM verify_messages WHERE status IN ('attempted','sent') "
                 "AND day >= substr(?, 1, 10) "
                 "GROUP BY user_key, day HAVING COUNT(*) > 1 AND SUM(campaign = ? AND message_type = 'email') > 0)",
            since, campaign)
        rep["ledger_requests_asked_twice"] = one(
            ldb, "SELECT COUNT(*) FROM (SELECT 1 FROM verify_messages m, json_each(m.request_ids_json) j "
                 "WHERE m.campaign = ? AND m.status IN ('attempted','sent') GROUP BY j.value HAVING COUNT(*) > 1 "
                 "AND MAX(m.created_at) >= ?)",
            campaign, since)
    return rep


# ----------------------------------------------------------------------------------------------------- workers
def rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0


def worker(queue_db: str, route: Any, worker_id: str, *, batch: int, memory_mb: float, kill_file: str,
           stop: Callable[[], bool] = lambda: False) -> int:
    """A long-lived queue worker with a memory cap it checks between batches, when it holds no claim. Past the
    cap it exits and the supervisor starts another. A hard cap is the unit's `MemoryMax`."""
    db = bulk_queue.connect(queue_db)
    while not stop():
        done = bulk_queue.work(db, route, worker_id, batch=batch, max_jobs=batch * 8, kill_file=kill_file)
        if done["killed"]:
            return EXIT_KILLED
        if rss_mb() > memory_mb:
            return EXIT_MEMORY
        if not done["claimed"]:
            time.sleep(0.5)
    return 0


def supervise(argv: list[str], n: int, *, stop: Callable[[], bool], poll_s: float = 1.0) -> dict:
    """Keep `n` workers alive until `stop()`. A worker that left over memory is replaced; one that left on the
    kill file is not, and one that REFUSED (the lane is no longer armed) stops the supervisor rather than being
    re-spawned every second."""
    procs = {i: subprocess.Popen(argv + ["--worker-id", f"a{i}.0"], stdout=subprocess.DEVNULL) for i in range(n)}
    restarts, killed, refused, gen = 0, False, False, 0
    while not stop() and not killed and not refused:
        time.sleep(poll_s)
        for i, p in list(procs.items()):
            rc = p.poll()
            if rc is None:
                continue
            if rc == EXIT_KILLED:
                killed = True
            elif rc == EXIT_REFUSED:
                refused = True
            else:
                gen, restarts = gen + 1, restarts + 1
                procs[i] = subprocess.Popen(argv + ["--worker-id", f"a{i}.{gen}"], stdout=subprocess.DEVNULL)
    for p in procs.values():
        p.terminate()
    for p in procs.values():
        p.wait()
    return {"workers": n, "restarts": restarts, "killed": killed, "refused": refused}


# ---------------------------------------------------------------------------------------------------- rehearsal
def _fake_health(provider_db: str, hard_from: int, hard_every: int) -> Callable[[], Sample]:
    """Health read from the fake provider's own delivery log. From delivery number `hard_from` on, every
    `hard_every`-th delivery is a hard bounce (0 = none)."""
    def read() -> Sample:
        db = sqlite3.connect(provider_db, timeout=120)
        n = db.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0]
        db.close()
        hard = (n - hard_from) // hard_every if hard_every and n > hard_from else 0
        return Sample(time.time(), True, n, hard, 0, 0, False)
    return read


#: Rehearsal people get user ids from here up, far above any Muso user id, so on a copy of the production ledger
#: no rehearsal claim can meet a real person's rows.
REHEARSAL_UID_BASE = 9_000_000_000


def copy_ledger(seed: str, dest: str) -> None:
    """An online backup of `seed`, opened read-only, into `dest`. The seed is never opened for writing."""
    src = sqlite3.connect(Path(seed).resolve().as_uri() + "?mode=ro", uri=True)
    dst = sqlite3.connect(dest)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()


#: Consecutive held ticks that end a rehearsal: a hold that does not clear is reported, never waited out.
HOLD_TICKS_MAX = 12


def rehearse(people: int, workers: int, *, tick_s: float, minutes_at_max: int, ramp: dict, latency_ms: float,
             bounce_from: int = 0, bounce_every: int = 0, seed_ledger: str = "", tmp_root: str | None = None,
             hold_ticks: int = HOLD_TICKS_MAX, health: Callable[[], Sample] | None = None,
             say: Callable[[dict], None] = lambda _: None) -> dict:
    """The whole path on scratch files: a real `verify_ledger` file, the real queue, real worker processes, a fake
    provider. Real time: a minute is `tick_s` seconds. Nothing leaves this box.

    `seed_ledger` starts the scratch ledger as a backup copy of that file (production's, for a measurement at its
    real size), so every claim reads the real tables. The copy is deleted with the rest; the seed is only read. A
    ramp that stays held for `hold_ticks` consecutive ticks ends the run with that reason in `stop_reason`."""
    tmp = tempfile.mkdtemp(prefix="bulk-asks-rehearsal-", dir=tmp_root)
    started = verify_ledger.stamp()
    try:
        qpath, rpath, prov = (os.path.join(tmp, f) for f in ("queue.sqlite", "ramp.sqlite", "provider.sqlite"))
        policy = {"stage": "ask", "message_class": "uvn-status", "template_key": "credit_status_uvn_ask",
                  "template_data": {}, "body": "rehearsal body\n", "subject": "rehearsal", "ramp": ramp,
                  "template_sha256": "0" * 64,
                  "approval": {"approved_by": "fable-ruling-0000-rehearsal", "approval_ref": "bulk_asks.py rehearse (scratch ledger)",
                               "approver_kind": verify_ledger.APPROVER_RULING,
                               "approval_id": "fable-ruling-0000-rehearsal"}}
        qpolicy = json.loads(json.dumps(bulk_queue.SCRATCH_POLICY))
        qpolicy["stages"] = {"ask": "uvn-status"}
        qdb, rdb = bulk_queue.connect(qpath, init=True), connect(rpath, init=True)
        bulk_queue.apply_policy(qdb, qpolicy)
        bulk_queue.FakeProvider(prov, init=True)
        lpath = os.path.join(tmp, "ledger.sqlite3")
        seeded: dict[str, Any] = {}
        if seed_ledger:
            t1 = time.time()
            copy_ledger(seed_ledger, lpath)
            seeded = {"seed": seed_ledger, "bytes": os.path.getsize(lpath), "copy_s": round(time.time() - t1, 1)}
        ldb = verify_ledger.connect(lpath)
        # production's ledger is WAL (node-8, 2026-11-16); a scratch file in rollback mode measures fsyncs, not this
        seeded["journal_mode"] = ldb.execute("PRAGMA journal_mode = WAL").fetchone()[0]
        seeded["verify_messages"] = ldb.execute("SELECT COUNT(*) FROM verify_messages").fetchone()[0]
        ids = range(REHEARSAL_UID_BASE + 1, REHEARSAL_UID_BASE + people + 1)
        plan = [{"outcome": "ask", "reason_code": "no_rule_matched", "user_id": i, "request_id": f"rehearsal-{i}"}
                for i in ids]
        accounts = {str(i): {"email": f"u{i}@example.invalid", "email_confirmed": True, "email_owners": 1,
                             "hold": "", "proof_on_file": False, "asked_before": i % 5 == 0, "paid": i % 7 == 0}
                    for i in ids}
        audience, dropped = select(plan, accounts, policy)
        load_audience(rdb, audience)
        argv = [sys.executable, str(Path(__file__).resolve()), "worker", "--queue-db", qpath, "--fake", prov,
                "--latency-ms", str(latency_ms), "--kill-file", os.path.join(tmp, "kill")]
        procs = [subprocess.Popen(argv + ["--worker-id", f"r{i}"], stdout=subprocess.DEVNULL) for i in range(workers)]
        health = health or _fake_health(prov, bounce_from, bounce_every)
        lane = ledger_lane(ldb, policy, "0" * 64)
        t0, at_max, held, stop, log = time.time(), 0, 0, "", []
        try:
            while at_max < minutes_at_max:
                start = time.time()
                t = tick(rdb, qdb, policy, health=health, lane=lane, retry_when=ledger_retry_when(ldb))
                t["tick_seconds"] = round(time.time() - start, 2)
                log.append(t)
                say(t)
                at_max += t["rate"] == int(ramp["max_per_min"])
                held = held + 1 if t["state"] == "held" else 0
                if t["audience_left"] == 0 or (t["state"] == "held" and bounce_every):
                    break
                if held >= hold_ticks:
                    stop = f"{t['reason']} (held {held} ticks, {len(log)} ticks run, {at_max} at max)"
                    break
                time.sleep(max(0.0, tick_s - (time.time() - start)))
            deadline = time.time() + 120
            while time.time() < deadline and queue_facts(qdb, "ask", 0, 0, time.time())["backlog"]:
                time.sleep(0.5)
        finally:
            for p in procs:
                p.terminate()
            for p in procs:
                p.wait()
        derive(rdb, qdb, "ask", lane, now=time.time(), copy={})
        fake = bulk_queue.FakeProvider(prov)
        return {"people": people, "dropped": dropped, "workers": workers, "tick_s": tick_s, "ramp": ramp,
                "started": started, "seeded": seeded, "stop_reason": stop,
                "seconds": round(time.time() - t0, 1), "ticks": log, "per_minute": minutes(qdb, "ask"),
                "ledger_per_minute": ledger_minutes(ldb, "uvn-status", started),
                "provider": fake.counts(), "jobs": bulk_queue.status(qdb)["jobs"],
                "verify": verify(rdb, qdb, ldb, policy, since=started)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------------------------------------- CLI
def _jsonl(path: str) -> Iterator[dict]:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                yield json.loads(line)


def rehearse_exit(rep: dict) -> int:
    """A rehearsal's exit code: 4 when a hold stopped it before the ramp got its minutes at max, 1 when it ran a
    self-check that is not all zeros or delivered a key twice, 0 otherwise."""
    if rep["stop_reason"]:
        return EXIT_HELD
    return 1 if any(rep["verify"].values()) or rep["provider"]["keys_delivered_twice"] else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--policy", default=str(POLICY_PATH))
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("pin", help="print the template pin, body and subject for the fixed data")
    s.add_argument("--templates-dir", required=True)
    s = sub.add_parser("select", help="plan + account facts -> the ordered audience (JSON lines)")
    s.add_argument("--plan", required=True)
    s.add_argument("--accounts", required=True, help="JSON lines, one per user id, every ACCOUNT_FACTS key")
    s.add_argument("--out", required=True)
    s = sub.add_parser("load", help="append an audience file to the ramp store")
    s.add_argument("--audience", required=True)
    s.add_argument("--ramp-db", default=DEFAULT_RAMP_DB)
    for name in ("run", "status", "verify", "minutes"):
        s = sub.add_parser(name)
        s.add_argument("--ramp-db", default=DEFAULT_RAMP_DB)
        s.add_argument("--queue-db", default=bulk_queue.DEFAULT_DB)
        s.add_argument("--ledger", default=verify_ledger.DEFAULT_PATH)
        if name == "run":
            s.add_argument("--apply", action="store_true")
            s.add_argument("--workers", type=int, default=8)
            s.add_argument("--memory-mb", type=float, default=256.0)
            s.add_argument("--kill-file", default=KILL_FILE)
    s = sub.add_parser("worker")
    s.add_argument("--queue-db", required=True)
    s.add_argument("--worker-id", default=f"a{os.getpid()}")
    s.add_argument("--batch", type=int, default=25)
    s.add_argument("--memory-mb", type=float, default=256.0)
    s.add_argument("--kill-file", default=KILL_FILE)
    s.add_argument("--fake", default="")
    s.add_argument("--latency-ms", type=float, default=0.0)
    s.add_argument("--apply", action="store_true")
    s = sub.add_parser("rehearse", help="scratch files and a fake provider only; takes no --db and no --ledger")
    s.add_argument("--people", type=int, default=40000)
    s.add_argument("--workers", type=int, default=8)
    s.add_argument("--tick-s", type=float, default=TICK_S)
    s.add_argument("--window-s", type=float, default=120.0)
    s.add_argument("--lag-s", type=float, default=30.0)
    s.add_argument("--minutes-at-max", type=int, default=10)
    s.add_argument("--latency-ms", type=float, default=2.0)
    s.add_argument("--bounce-from", type=int, default=0)
    s.add_argument("--bounce-every", type=int, default=0)
    s.add_argument("--seed-ledger", default="",
                   help="start the scratch ledger as a read-only backup of this file; the file is never written")
    s.add_argument("--tmp-root", default=None, help="where the scratch directory goes (a seeded copy is large)")
    a = ap.parse_args(argv)
    say = lambda obj: print(json.dumps(obj, sort_keys=True), flush=True)  # noqa: E731

    if a.cmd == "rehearse":
        ramp = dict(load_policy(a.policy)["ramp"], window_s=a.window_s, health_lag_s=a.lag_s)
        rep = rehearse(a.people, a.workers, tick_s=a.tick_s, minutes_at_max=a.minutes_at_max, ramp=ramp,
                       latency_ms=a.latency_ms, bounce_from=a.bounce_from, bounce_every=a.bounce_every,
                       seed_ledger=a.seed_ledger, tmp_root=a.tmp_root, say=lambda t: print(json.dumps(t, sort_keys=True), file=sys.stderr, flush=True))
        say(rep)
        return rehearse_exit(rep)
    policy = load_policy(a.policy)
    if a.cmd == "pin":
        say(pin(a.templates_dir, policy))
    elif a.cmd == "select":
        people, dropped = select(_jsonl(a.plan), {str(r["user_id"]): r for r in _jsonl(a.accounts)}, policy)
        Path(a.out).write_text("".join(json.dumps(p, sort_keys=True) + "\n" for p in people), encoding="utf-8")
        say({"audience": len(people), "never_asked": sum(p["never_asked"] for p in people),
             "paid": sum(p["paid"] for p in people), "dropped": dropped})
    elif a.cmd == "load":
        say({"loaded": load_audience(connect(a.ramp_db, init=True), _jsonl(a.audience))})
    elif a.cmd == "worker":
        if a.fake:
            route: Any = bulk_queue.FakeRoute("email", bulk_queue.FakeProvider(a.fake), latency_s=a.latency_ms / 1000)
        else:
            qpolicy = bulk_queue.load_policy()
            why = "pass --apply to send through the real route" if not a.apply else armed(policy, qpolicy)
            if why:
                print(f"REFUSED: {why}; nothing was claimed or sent", file=sys.stderr)
                return EXIT_REFUSED
            route = bulk_queue.EmailRoute(qpolicy, gate=EnforcedCopyGate())
        return worker(a.queue_db, route, a.worker_id, batch=a.batch, memory_mb=a.memory_mb, kill_file=a.kill_file)
    elif a.cmd == "run":
        qpolicy = bulk_queue.load_policy()
        why = "pass --apply to release people and send" if not a.apply else armed(policy, qpolicy)
        if why:
            print(f"REFUSED: {why}; nobody was claimed, queued or sent", file=sys.stderr)
            return EXIT_REFUSED
        rdb, qdb = connect(a.ramp_db), bulk_queue.connect(a.queue_db, init=True)
        bulk_queue.apply_policy(qdb, qpolicy)
        ldb = verify_ledger.connect(a.ledger)
        body_sha = __import__("hashlib").sha256(str(policy["body"]).encode()).hexdigest()
        killed = lambda: os.path.exists(a.kill_file) or os.path.exists(bulk_queue.KILL_FILE)  # noqa: E731
        import threading
        over, sup = threading.Event(), {}
        th = threading.Thread(target=lambda: sup.update(supervise(
            [sys.executable, str(Path(__file__).resolve()), "--policy", a.policy, "worker", "--queue-db", a.queue_db,
             "--apply", "--memory-mb", str(a.memory_mb), "--kill-file", a.kill_file], a.workers, stop=lambda: over.is_set() or killed())))
        th.start()
        lane, precheck = ledger_lane(ldb, policy, body_sha), copy_precheck(qpolicy, policy)
        try:
            while not killed() and not sup.get("refused"):
                start = time.time()
                t = tick(rdb, qdb, policy, health=lambda: gateway_health(str(policy["ramp"]["route"])), lane=lane,
                         retry_when=ledger_retry_when(ldb), precheck=precheck)
                say(t)
                if t["audience_left"] == 0 and t["backlog"] == 0:
                    break
                time.sleep(max(0.0, TICK_S - (time.time() - start)))
        finally:
            over.set()
            th.join()
            held, copy = precheck()
            derive(rdb, qdb, str(policy["stage"]), lane, now=time.time(), copy=copy, held=held)
        return EXIT_KILLED if killed() else 0
    else:
        rdb, qdb = connect(a.ramp_db), bulk_queue.connect(a.queue_db)
        stage = str(policy["stage"])
        if a.cmd == "status":
            last = rdb.execute("SELECT * FROM ticks ORDER BY at DESC LIMIT 1").fetchone()
            say({"last_tick": dict(last) if last else None, "jobs": bulk_queue.status(qdb)["jobs"],
                 "audience_left": rdb.execute(
                     "SELECT COUNT(*) FROM audience WHERE released_at = 0 OR (retry_at > 0 AND retry_at <= ?)",
                     (time.time(),)).fetchone()[0],
                 "outcomes": {r[0]: r[1] for r in rdb.execute(
                     "SELECT outcome, COUNT(*) FROM audience WHERE released_at > 0 GROUP BY outcome")}})
        elif a.cmd == "minutes":
            say({"queue": minutes(qdb, stage)})
        else:
            ldb = verify_ledger.connect_ro(a.ledger, must_exist=True)
            rep = verify(rdb, qdb, ldb, policy)
            say(rep)
            return 1 if any(rep.values()) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
