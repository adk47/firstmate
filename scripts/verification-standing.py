#!/usr/bin/env python3
"""One page that answers where verifications stand. Stdlib only, read-only, one screen.

    scripts/verification-standing.py            the page
    scripts/verification-standing.py --json     the same cells, each with its source and age
    scripts/verification-standing.py --strict   exit 3 when any cell on the page is unmeasured or stale
    scripts/verification-standing.py --save DIR write DIR/latest.txt and DIR/latest.json; exit 3 when a cell
                                                that has a writer is unmeasured or stale (the timer's form)

Per request family (credits, claims): open, decided 24h, told 24h, median age, oldest age,
last successful send, days to zero. `median age` is the median age of an OPEN REQUEST, one
sample per request; the per-user figure (each user's oldest open request) is printed on its
own line, labelled. Under each family, one line per send family the outbound policy
lists for it (policies/credit-verify-outbound.json `groups`) plus the decision notices.
Then the credit requests' five tracking numbers: OURS, sent_this_tick, applied_1h,
decisions_per_intake, held_evidence_unbounded.

It reads DURABLE STATE ONLY and never the replica, the admin API, Intercom or Slack:

  open, decided 24h, ages   the population snapshot scripts/verification-queue-report.py
                            already writes (last.json). That job is the one population read;
                            this page starts no second one. Its `age.median_h` is the median
                            over open requests; `age.oldest_per_user_median_h` is the
                            per-user figure. A snapshot written before the per-request read
                            existed carries no `median_h`, and the cell is unmeasured.
  told 24h, last send       the verify ledger, opened `mode=ro`: `verify_messages` rows with
                            status `sent`, and `decision_told` rows `apply`/`sent`.
  the families              the outbound policy file.
  OURS                      the snapshot's `ours` block: pending credit requests with no
                            delivered ask, joined by request id by the snapshot's writer.
  sent_this_tick            the newest tick's own apply records under the sender's output root
                            ($tag-apply.json / $tag-check.json), and the ledger's `sent` rows
                            for the campaigns those records name in the same window.
  applied_1h                the ledger: requests with a `decision_outcomes` row `approved` in
                            the last hour, whatever its evidence kind. A precedent approval is
                            one of them once its decision row is in the ledger.
  decisions_per_intake      the ledger's `decisions` rows in the hour before the snapshot,
                            over the snapshot's `intake_1h` (requests created in that hour).
                            Far above 1 means the same requests are being decided again.
  held_evidence_unbounded   unmeasured: no writer records `reason=evidence_unbounded` on a
                            ledger row yet. TODO: the verify-live hold
                            (`scripts/credit_review/verify_notify.py` `hold_unbounded`) must
                            record it before this cell can carry a number.

Rules this file keeps (docs/credit-verification/verification-standing.md):

* "I could not read it" is `unmeasured` with the reason, never 0 and never blank. A snapshot
  whose own run recorded an error for a family leaves that family unmeasured: the writer
  saves an empty population as 0 open, and 0 open is the one number this page must not invent.
* A number is printed with its age. A snapshot older than SNAPSHOT_MAX_AGE_H is marked `~`
  on every cell it feeds, and the page says why when the writer's stop file is present.
* Units are users. A tell reaches a user, so days to zero = open USERS / users told per day
  (the 7-day mean). Dividing open requests by users told overstates it about twelve-fold
  (101,373 open credit requests were 8,270 users on 2026-11-14).
  Requests are printed on their own line, labelled. Decided 24h is the users with a request
  approved plus the users with one declined; the snapshot counts each outcome's users apart,
  so when both are non-zero a user in both is counted twice and the cell prints `<=`.
* Days to zero is the time until every open user has been told once at the measured rate.
  It is not the time until every request is closed: an ask leaves the request open, with the
  wait on the user. No tells in 7 days prints `no tells 7d`, not a number.
* It writes nothing but the two files `--save` names. A missing ledger is not created.
* It runs on a timer, not by hand: `verification-standing.timer` (scripts/install-aux-units.sh)
  runs `--save` twice an hour, and a cell that has a writer and is unmeasured or stale fails
  the unit, which pages. A cell in NO_WRITER_YET cannot fail it: nothing can produce it yet.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import textwrap
import urllib.parse
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
SNAPSHOT = os.environ.get("VQR_STATE", "/var/lib/hydra/verification-queue-report/last.json")
SNAPSHOT_KILL = os.environ.get("VQR_KILL_SWITCH", "/etc/hydra/verification-queue-report.disabled")
POLICY = os.environ.get("CVO_POLICY", os.path.join(ROOT, "policies", "credit-verify-outbound.json"))

# The snapshot's writer runs every 30 minutes; four missed runs is stale.
SNAPSHOT_MAX_AGE_H = 2.0
RATE_DAYS = 7
OUT_ROOT = os.environ.get("CVO_OUT_ROOT", "/root/h2-runs/sched")
TICK_STAMP = re.compile(r"^\d{8}T\d{4}Z$")
TICK_HARD_S = 6900      # the sender's own deadline: a tick cannot send after it
MAX_LINES = 30      # one screen
MAX_COLS = 112

# (page name, the policy `groups` key, the snapshot section, the snapshot error prefixes that
# mean the population / the 24h flow was not read on that run).
FAMILIES = (
    ("credits", "credit", "credits", ("credits:",), ("credit flow",)),
    ("claims", "claim", "claims", ("claims:",), ("claim flow",)),
)
# Decision notices are told from their own table, not a campaign; they belong to credits.
NOTICES = "decision notices"
NOTICES_FAMILY = "credits"
# Whose move it is, by snapshot bucket. The same two tuples as scripts/verification-queue-report.py
# AWAITING_US / AWAITING_USER (a test holds them equal); every other bucket is on hold.
AWAITING_US = ("untouched", "not_told", "docs_in", "human")
AWAITING_USER = ("told",)
WAITING = ("waiting_us", "waiting_user", "on_hold")
WAITING_LABELS = (("waiting_us", "waiting on us"), ("waiting_user", "waiting on the user"),
                  ("on_hold", "on hold"))
# The credit requests' tracking numbers, in the order the page prints them.
TRACKING = ("ours", "sent_this_tick", "applied_1h", "decisions_per_intake", "held_evidence_unbounded")
TRACKING_ERRORS = ("ours", "intake")    # the snapshot writer's error prefixes for its two tracking reads
# The snapshot writer's reads that decide which bucket a user lands in (told / docs_in / watch).
# An error from one of these means the buckets were not classified cleanly; any other error
# (merges, slack, a median read, the tracking reads) says nothing about the bucketing.
BUCKET_ERRORS = ("ledger", "proof feed", "watchlist")
# One line on the page; the operator doc says which writer is missing and why.
HELD_UNMEASURED = "no writer records reason=evidence_unbounded on a held credit"
NOT_RECORDED = "the snapshot's writer did not record it"
# Reasons that mean "no job writes this number yet". The timer does not fail on them: a unit
# that can never succeed pages once and is then ignored, which hides the cells that can break.
NO_WRITER_YET = (HELD_UNMEASURED,)

USAGE = __doc__.split("\n\n")[1]


class Unmeasured(Exception):
    """A source could not be read. Carries the reason that is printed."""


def parse_ts(value) -> datetime | None:
    """The ledger and the snapshot hold five spellings of a UTC time; None when unreadable."""
    if not value or not isinstance(value, str):
        return None
    v = value.strip().replace(" UTC", "+00:00")
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    v = re.sub(r"([+-]\d{2})$", r"\1:00", v).replace(" ", "T", 1)
    try:
        t = datetime.fromisoformat(v)
    except ValueError:
        return None
    return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


# A stored time the page cannot read is not a row that did not happen. A count that leaves such
# a row out is lower than the truth by an unknown amount, so the cell it feeds is unmeasured.
# DATED is what SQL can check: a time that does not start with a day cannot be put in a window.
DATED = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*"


def undated_why(what: str, counts: dict[str, int]) -> str:
    return f"{what} with no readable time: " + ", ".join(
        f"{name} {k}" for name, k in sorted(counts.items()))


def read_policy(path: str) -> dict[str, list[str] | None]:
    """The send families of each policy group. A group that is not a list of family names
    is None, never an empty list: with no names, every send of that family would go
    uncounted and its row would read `told 0`, `last send never`."""
    try:
        with open(path, encoding="utf-8") as f:
            groups = json.load(f).get("groups")
    except (OSError, ValueError) as e:
        raise Unmeasured(f"policy {path}: {type(e).__name__}") from e
    if not isinstance(groups, dict):
        raise Unmeasured(f"policy {path}: no `groups`")
    return {g: list(fams) if isinstance(fams, list) and all(isinstance(x, str) and x for x in fams)
            else None for g, fams in groups.items()}


def family_senders(groups, group: str, path: str) -> list[str]:
    """The families `group` sends, or Unmeasured when the policy does not say."""
    if group not in groups:
        raise Unmeasured(f"policy {path}: no `{group}` group")
    if groups[group] is None:
        raise Unmeasured(f"policy {path}: the `{group}` group is not a list of send family names")
    if not groups[group]:
        raise Unmeasured(f"policy {path}: the `{group}` group lists no send family")
    return list(groups[group])


def read_snapshot(path: str) -> tuple[dict, datetime]:
    try:
        with open(path, encoding="utf-8") as f:
            snap = json.load(f)
    except FileNotFoundError as e:
        raise Unmeasured(f"no snapshot at {path}") from e
    except (OSError, ValueError) as e:
        raise Unmeasured(f"snapshot {path}: {type(e).__name__}") from e
    at = parse_ts(snap.get("at")) if isinstance(snap, dict) else None
    if at is None:
        raise Unmeasured(f"snapshot {path}: no readable `at`")
    return snap, at


def read_tells(path: str) -> tuple[list[tuple[str, str, datetime]], dict[str, int]]:
    """Every successful send the ledger holds: (family, user, when), and per family the rows left
    out because their time is unreadable. Read-only; a missing ledger is an error, not a new file."""
    if not os.path.isfile(path):
        raise Unmeasured(f"no ledger at {path}")
    try:
        db = sqlite3.connect(f"file:{urllib.parse.quote(path)}?mode=ro", uri=True, timeout=30)
        try:
            db.execute("PRAGMA query_only = 1")
            # A sent row from before `sent_at` existed is dated by `created_at`, which is never
            # later than the send. `updated_at` is not a send time: a later proof tag moves it.
            notes = db.execute(
                "SELECT campaign, account_id, user_key, coalesce(sent_at, created_at) "
                "FROM verify_messages WHERE status = 'sent'").fetchall()
            notices = db.execute(
                "SELECT user_id, at FROM decision_told WHERE mode = 'apply' AND outcome = 'sent'"
            ).fetchall()
        finally:
            db.close()
    except sqlite3.Error as e:
        raise Unmeasured(f"ledger {path}: {e}") from e
    # One person, one key: a row that carries only the email is joined to the account id another
    # of that person's rows carries, so two families telling one user count one user.
    account = {str(k): str(a) for _, a, k, _ in notes if a not in (None, "") and k}
    out, undated = [], {}
    for campaign, acct, key, when in notes:
        t = parse_ts(when)
        if t is None:
            undated[str(campaign)] = undated.get(str(campaign), 0) + 1
            continue
        user = str(acct) if acct not in (None, "") else account.get(str(key), str(key))
        out.append((str(campaign), user, t))
    for user, when in notices:
        t = parse_ts(when)
        if t is None:
            undated[NOTICES] = undated.get(NOTICES, 0) + 1
            continue
        out.append((NOTICES, str(user), t))
    return out, undated


def tell_stats(tells, names, now: datetime) -> dict:
    """Users told in the last 24 h, the 7-day mean of users told per day, and the last send."""
    mine = [(u, t) for fam, u, t in tells if fam in names and t <= now]
    day = timedelta(days=1)
    per_day = [len({u for u, t in mine if now - (k + 1) * day < t <= now - k * day})
               for k in range(RATE_DAYS)]
    return {"told_24h": per_day[0], "per_day": sum(per_day) / RATE_DAYS,
            "told_7d": sum(per_day), "last": max((t for _, t in mine), default=None)}


def read_hour(path: str, now: datetime, until: datetime | None) -> dict:
    """What the ledger recorded in an hour. `approved`: the requests with an `approved` outcome
    in the hour to `now`, whatever its evidence kind. `decisions`: decision rows in the hour to
    `until` (the snapshot's time). `approved_undated` / `decisions_undated`: the rows whose time
    cannot be read, which could be in either hour."""
    if not os.path.isfile(path):
        raise Unmeasured(f"no ledger at {path}")
    hour = timedelta(hours=1)

    def day(t: datetime) -> str:    # a prefix every spelling of a UTC time shares; the hour is cut below
        return t.strftime("%Y-%m-%d")

    def split(raws, end: datetime) -> tuple[list, int]:
        """The values inside the hour to `end`, and how many have no readable time."""
        times = [(raw, parse_ts(raw[-1])) for raw in raws]
        return ([raw for raw, t in times if t is not None and end - hour < t <= end],
                sum(1 for _, t in times if t is None))

    try:
        db = sqlite3.connect(f"file:{urllib.parse.quote(path)}?mode=ro", uri=True, timeout=30)
        try:
            db.execute("PRAGMA query_only = 1")
            outcomes = db.execute(
                "SELECT request_id, at FROM decision_outcomes "
                "WHERE outcome = 'approved' AND (at >= ? OR at IS NULL OR at NOT GLOB ?)",
                (day(now - hour), DATED)).fetchall()
            decided = [] if until is None else db.execute(
                "SELECT decided_at FROM decisions WHERE (decided_at >= ? AND decided_at < ?) "
                "OR decided_at IS NULL OR decided_at NOT GLOB ?",
                (day(until - hour), day(until + timedelta(days=1)), DATED)).fetchall()
        finally:
            db.close()
    except sqlite3.Error as e:
        raise Unmeasured(f"ledger {path}: {e}") from e
    approved, approved_undated = split(outcomes, now)
    made, made_undated = ([], 0) if until is None else split(decided, until)
    return {"approved": len({str(rid) for rid, _ in approved}), "approved_undated": approved_undated,
            "decisions": None if until is None else len(made), "decisions_undated": made_undated}


def read_tick(root: str, now: datetime) -> tuple[datetime, set[str], datetime]:
    """The newest tick's own records: its stamp, the campaigns its apply files name, and the end
    of its span (now, capped at its stamp plus its hard deadline)."""
    try:
        names = sorted(n for n in os.listdir(root) if TICK_STAMP.match(n))
    except OSError as e:
        raise Unmeasured(f"no sender output at {root} ({type(e).__name__})") from e
    if not names:
        raise Unmeasured(f"no tick under {root}")
    stamp = names[-1]
    try:
        at = datetime.strptime(stamp, "%Y%m%dT%H%MZ").replace(tzinfo=timezone.utc)
    except ValueError as e:
        raise Unmeasured(f"tick {stamp} under {root} has no readable stamp") from e
    if at > now:
        raise Unmeasured(f"tick {stamp} under {root} is dated after now")
    tick = os.path.join(root, stamp)
    try:
        files = sorted(n for n in os.listdir(tick) if n.endswith(("-apply.json", "-check.json")))
    except OSError as e:
        raise Unmeasured(f"tick {stamp} under {root}: {type(e).__name__}") from e
    applies = [n for n in files if n.endswith("-apply.json")]
    if not applies:
        raise Unmeasured(f"tick {stamp} under {root} recorded no apply")
    campaigns: set[str] = set()
    for name in applies:
        try:
            with open(os.path.join(tick, name), encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError) as e:
            raise Unmeasured(f"tick {stamp} {name}: {type(e).__name__}") from e
        sent = rec.get("sent") if isinstance(rec, dict) else None
        if not isinstance(sent, list):
            raise Unmeasured(f"tick {stamp} {name}: no sent list")
        campaigns |= {str(s["campaign"]) for s in sent if isinstance(s, dict) and s.get("campaign")}
    return at, campaigns, min(now, at + timedelta(seconds=TICK_HARD_S))


def read_sent(path: str, at: datetime, end: datetime, campaigns: set[str]) -> int:
    """The ledger's `sent` rows in the tick's span, for the campaigns the tick's apply files name."""
    if not os.path.isfile(path):
        raise Unmeasured(f"no ledger at {path}")
    try:
        db = sqlite3.connect(f"file:{urllib.parse.quote(path)}?mode=ro", uri=True, timeout=30)
        try:
            db.execute("PRAGMA query_only = 1")
            rows = db.execute(
                "SELECT campaign, coalesce(sent_at, created_at) FROM verify_messages "
                "WHERE status = 'sent' AND (coalesce(sent_at, created_at) >= ? "
                "OR coalesce(sent_at, created_at) IS NULL OR coalesce(sent_at, created_at) NOT GLOB ?)",
                (at.strftime("%Y-%m-%d"), DATED)).fetchall()
        finally:
            db.close()
    except sqlite3.Error as e:
        raise Unmeasured(f"ledger {path}: {e}") from e
    mine = [(str(campaign), parse_ts(raw)) for campaign, raw in rows if str(campaign) in campaigns]
    undated: dict[str, int] = {}
    for campaign, t in mine:
        if t is None:
            undated[campaign] = undated.get(campaign, 0) + 1
    if undated:     # such a row could be this tick's send
        raise Unmeasured(undated_why("sent rows", undated))
    return sum(1 for _, t in mine if at <= t < end)


def whole(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def snapshot_block(snap, snap_why, key: str, fields: tuple) -> tuple[dict | None, str]:
    """One of the snapshot's tracking blocks, or None and why it cannot be read."""
    if snap is None:
        return None, snap_why
    prefix = key.split("_")[0]
    failed = next((str(e) for e in snap.get("errors") or [] if str(e).split(":")[0] == prefix), None)
    if failed:
        return None, f"the snapshot's own run could not read it ({failed[:60]})"
    got = snap.get(key)
    if not isinstance(got, dict) or not all(whole(got.get(f)) for f in fields):
        return None, NOT_RECORDED
    return got, ""


def tracking(snap, snap_at, stale: bool, snap_why, ledger: str, out_root: str, now: datetime) -> dict:
    """The credit requests' five tracking numbers, each a cell or `unmeasured` with its reason."""
    out = {}
    gap, why = snapshot_block(snap, snap_why, "ours", ("pending", "ours", "never_asked"))
    out["ours"] = unmeasured(why) if gap is None else dict(
        cell(gap["ours"], stale=stale), pending=gap["pending"], never_asked=gap["never_asked"])

    try:
        tick_at, campaigns, tick_end_at = read_tick(out_root, now)
        out["sent_this_tick"] = dict(
            cell(read_sent(ledger, tick_at, tick_end_at, campaigns),
                 stale=(now - tick_at).total_seconds() / 3600 > SNAPSHOT_MAX_AGE_H),
            at=tick_at.strftime("%Y-%m-%dT%H:%M:%SZ"))
    except Unmeasured as e:
        out["sent_this_tick"] = unmeasured(str(e))

    intake, why = snapshot_block(snap, snap_why, "intake_1h", ("requests",))
    out["decisions_per_intake"] = unmeasured(why)
    try:
        hour = read_hour(ledger, now, snap_at)
        out["applied_1h"] = cell(hour["approved"]) if not hour["approved_undated"] else unmeasured(
            undated_why("ledger rows", {"approved outcomes": hour["approved_undated"]}))
        if intake is not None and hour["decisions_undated"]:
            out["decisions_per_intake"] = unmeasured(
                undated_why("ledger rows", {"decisions": hour["decisions_undated"]}))
        elif intake is not None:
            made, new = hour["decisions"], intake["requests"]
            out["decisions_per_intake"] = dict(cell(round(made / new, 1) if new else None, stale=stale),
                                               decisions=made, intake=new)
    except Unmeasured as e:
        out["applied_1h"] = unmeasured(str(e))
        if intake is not None:
            out["decisions_per_intake"] = unmeasured(str(e))
    out["held_evidence_unbounded"] = unmeasured(HELD_UNMEASURED)
    return out


def cell(value, *, stale=False):
    return {"value": value, "stale": bool(stale)}


def unmeasured(reason: str):
    return {"unmeasured": reason}


def population(snap: dict, section: str, pop_err, flow_err, stale: bool) -> dict:
    """open / decided 24h / ages for one family, from the snapshot. Each is a cell."""
    # an error of the writer's two tracking reads says nothing about the tables
    errors = [str(e) for e in (snap.get("errors") or []) if str(e).split(":")[0] not in TRACKING_ERRORS]
    sec = snap.get(section)
    failed = next((e for e in errors if e.startswith(pop_err)), None)
    if failed or not isinstance(sec, dict) or "open_users" not in sec:
        why = unmeasured(f"the snapshot did not read {section}" + (f" ({failed[:60]})" if failed else ""))
        out = {k: why for k in ("open", "open_rows", "median_h", "oldest_per_user_median_h",
                                "oldest_h", *WAITING)}
    else:
        buckets = sec.get("buckets") or {}
        age = sec.get("age") or {}
        oldest = age.get("oldest_h")
        if oldest is None:
            oldest = max((b["oldest_h"] for b in buckets.values() if b.get("oldest_h")), default=None)
        out = {"open": cell(int(sec["open_users"]), stale=stale),
               "open_rows": cell(int(sec.get("open_rows") or 0), stale=stale),
               "oldest_h": cell(oldest, stale=stale),
               "oldest_per_user_median_h": (
                   unmeasured(NOT_RECORDED)
                   if "oldest_per_user_median_h" not in age else
                   cell(age["oldest_per_user_median_h"], stale=stale)),
               "median_h": (unmeasured(NOT_RECORDED)
                            if "median_h" not in age else
                            unmeasured("no open request in the snapshot has a readable time")
                            if age["median_h"] is None and int(sec["open_rows"] or 0) else
                            cell(age["median_h"], stale=stale))}
        # whose move it is: only meaningful when the run classified every bucket cleanly
        bucket_failed = next((e for e in errors if e.split(":")[0] in BUCKET_ERRORS), None)
        if bucket_failed or not set(AWAITING_US + AWAITING_USER) <= set(buckets):
            out.update({k: unmeasured("the snapshot's buckets were not classified cleanly") for k in WAITING})
        else:
            us, user = (sum(int(buckets[b].get("users") or 0) for b in names)
                        for names in (AWAITING_US, AWAITING_USER))
            out.update({"waiting_us": cell(us, stale=stale), "waiting_user": cell(user, stale=stale),
                        "on_hold": cell(sum(int(v.get("users") or 0) for b, v in buckets.items()
                                            if b not in AWAITING_US + AWAITING_USER), stale=stale)})
    flow = sec.get("flow") if isinstance(sec, dict) else None
    flow_failed = next((e for e in errors if e.startswith(flow_err)), None)
    if flow_failed or not isinstance(flow, dict) or not {"approved", "declined"} <= set(flow):
        out["decided_24h"] = out["decided_rows"] = unmeasured(
            f"the snapshot did not read the {section} 24 h flow")
    else:
        users = [int(flow[k].get("users") or 0) for k in ("approved", "declined")]
        out["decided_24h"] = dict(cell(sum(users), stale=stale), at_most=all(users))
        out["decided_rows"] = cell(sum(int(flow[k].get("rows") or 0) for k in ("approved", "declined")),
                                   stale=stale)
    return out


def days_to_zero(open_cell: dict, rate) -> dict:
    if "unmeasured" in open_cell:
        return unmeasured("open is unmeasured")
    if rate is None:
        return unmeasured("told is unmeasured")
    if open_cell["value"] == 0:
        return cell(0.0, stale=open_cell["stale"])
    if rate <= 0:
        return {"value": None, "stale": open_cell["stale"], "no_tells": True}
    return cell(open_cell["value"] / rate, stale=open_cell["stale"])


def build(*, ledger: str = None, snapshot: str = None, policy: str = None, kill: str = None,
          out_root: str = None, now: datetime = None) -> dict:
    now = now or datetime.now(timezone.utc)
    ledger, snapshot = ledger or LEDGER, snapshot or SNAPSHOT
    policy, kill, out_root = policy or POLICY, kill or SNAPSHOT_KILL, out_root or OUT_ROOT
    page = {"at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "families": [], "notes": [],
            "sources": {"ledger": ledger, "snapshot": snapshot, "policy": policy, "out_root": out_root}}

    try:
        groups = read_policy(policy)
    except Unmeasured as e:
        groups, page["policy_unmeasured"] = None, str(e)
    try:
        snap, snap_at = read_snapshot(snapshot)
        if snap_at > now:
            raise Unmeasured(f"snapshot {snapshot} is dated after now")
        age_h = (now - snap_at).total_seconds() / 3600
        stale = age_h > SNAPSHOT_MAX_AGE_H
        page["snapshot"] = {"at": snap_at.strftime("%Y-%m-%dT%H:%M:%SZ"), "age_h": round(age_h, 2),
                            "stale": stale, "writer_stopped": os.path.exists(kill), "kill": kill}
    except Unmeasured as e:
        snap, snap_at, stale = None, None, False
        page["snapshot"] = {"unmeasured": str(e)}
    page["tracking"] = tracking(snap, snap_at, stale, page["snapshot"].get("unmeasured"), ledger, out_root, now)
    try:
        tells, undated = read_tells(ledger)
    except Unmeasured as e:
        tells, undated = None, {}
        page["ledger_unmeasured"] = str(e)

    listed = {NOTICES}
    for name, group, section, pop_err, flow_err in FAMILIES:
        fam = {"family": name}
        if snap is None:
            why = unmeasured(page["snapshot"]["unmeasured"])
            fam.update({k: why for k in ("open", "open_rows", "decided_24h", "decided_rows", "median_h",
                                         "oldest_per_user_median_h", "oldest_h", *WAITING)})
        else:
            fam.update(population(snap, section, pop_err, flow_err, stale))
        senders, policy_why = None, page.get("policy_unmeasured")
        if groups is not None:
            try:
                senders = family_senders(groups, group, policy)
            except Unmeasured as e:
                policy_why = str(e)
        if senders is not None and name == NOTICES_FAMILY:
            senders.append(NOTICES)
        listed |= set(senders or [])
        lost = {s: undated[s] for s in senders or () if s in undated}
        if tells is None or senders is None or lost:
            # a sent row with no readable time may be a user told today: no count, not a lower one
            why = unmeasured(page.get("ledger_unmeasured") or (policy_why if senders is None else None)
                             or undated_why("sent rows", lost))
            fam.update({"told_24h": why, "last_send": why, "per_day": why, "senders": []})
            fam["days_to_zero"] = days_to_zero(fam["open"], None)
        else:
            s = tell_stats(tells, set(senders), now)
            fam.update({"told_24h": cell(s["told_24h"]), "per_day": cell(round(s["per_day"], 2)),
                        "last_send": cell(s["last"].strftime("%Y-%m-%dT%H:%M:%SZ") if s["last"] else None),
                        "days_to_zero": days_to_zero(fam["open"], s["per_day"]), "senders": []})
            for sender in senders:
                x = tell_stats(tells, {sender}, now)
                fam["senders"].append({
                    "family": sender, "told_24h": x["told_24h"], "told_7d": x["told_7d"],
                    "last_send": x["last"].strftime("%Y-%m-%dT%H:%M:%SZ") if x["last"] else None})
        page["families"].append(fam)
    # A policy group with no row here would be a family nobody is shown: say so on the page.
    for group in sorted(set(groups or ()) - {g for _, g, *_ in FAMILIES}):
        page["notes"].append(f"policy group `{group}` has no row on this page")

    # A sender the policy does not list still told somebody: name it rather than hide it.
    if tells is not None:
        if lost := {k: v for k, v in undated.items() if k not in listed}:
            page["notes"].append(undated_why("sent rows outside these families", lost) + "; not counted")
        other = {}
        for fam, user, t in tells:
            if fam not in listed and now - timedelta(days=1) < t <= now:
                other.setdefault(fam, set()).add(user)
        page["other_24h"] = {k: len(v) for k, v in sorted(other.items())}
    return page


def n(v) -> str:
    return f"{v:,}"


def age_words(hours) -> str:
    if hours is None:
        return "-"
    return f"{hours:.0f}h" if hours < 48 else f"{hours / 24:,.0f}d"


def since(ts: str, now: datetime) -> str:
    t = parse_ts(ts)
    mins = int((now - t).total_seconds() // 60)
    if mins < 60:
        return f"{mins}m"
    if mins < 48 * 60:
        return f"{mins // 60}h{mins % 60:02d}m"
    return f"{mins // 1440}d{(mins % 1440) // 60}h"


def send_words(ts, now: datetime) -> str:
    if not ts:
        return "never"
    return f"{parse_ts(ts).strftime('%m-%d %H:%MZ')} ({since(ts, now)})"


def show(c: dict, fmt) -> str:
    if "unmeasured" in c:
        return "unmeasured"
    if c.get("no_tells"):
        return f"no tells {RATE_DAYS}d" + ("~" if c["stale"] else "")
    return ("<=" if c.get("at_most") else "") + fmt(c["value"]) + ("~" if c.get("stale") else "")


# Every column holds the word `unmeasured` with a space before it.
COLS = (("family", -21), ("open users", 11), ("decided 24h", 12), ("told 24h", 11), ("median age", 11),
        ("oldest age", 11), ("last successful send", 22), ("days to zero", 13))


def row(values) -> str:
    return "".join(f"{v:<{-w}}" if w < 0 else f"{v:>{w}}" for v, (_, w) in zip(values, COLS)).rstrip()


def render(page: dict) -> str:
    now = parse_ts(page["at"])
    L = [f"VERIFICATIONS - where they stand    {now.strftime('%Y-%m-%d %H:%MZ')}",
         row([name for name, _ in COLS])]
    why: dict[str, list[str]] = {}
    for fam in page["families"]:
        cells = (("open users", fam["open"], n), ("decided 24h", fam["decided_24h"], n),
                 ("told 24h", fam["told_24h"], n), ("median age", fam["median_h"], age_words),
                 ("oldest age", fam["oldest_h"], age_words),
                 ("last send", fam["last_send"], lambda v: send_words(v, now)),
                 ("days to zero", fam["days_to_zero"], lambda v: f"{v:,.1f}d" if v < 10 else f"{v:,.0f}d"))
        L.append(row([fam["family"]] + [show(c, fmt) for _, c, fmt in cells]))
        for label, c, _ in cells:
            if "unmeasured" in c:
                why.setdefault(c["unmeasured"], []).append(f"{fam['family']} {label}")
        for key, label in WAITING_LABELS:
            if "unmeasured" in fam[key]:
                why.setdefault(fam[key]["unmeasured"], []).append(f"{fam['family']} {label}")
        dark = []
        for s in fam["senders"]:
            if s["told_7d"]:
                L.append(row([f"  {s['family']}", "", "", n(s["told_24h"]), "", "",
                              send_words(s["last_send"], now), ""]))
            else:
                dark.append(f"{s['family']} ({send_words(s['last_send'], now).split(' (')[0]})")
        if dark:
            L.append(f"  no send in {RATE_DAYS} days: " + ", ".join(dark))
    t = page["tracking"]
    for key in TRACKING:
        if "unmeasured" in t[key]:
            why.setdefault(t[key]["unmeasured"], []).append(key if key != "ours" else "OURS")
    gap = "OURS " + show(t["ours"], n)
    if "value" in t["ours"]:
        gap += (f" of {n(t['ours']['pending'])} pending have no delivered ask "
                f"({n(t['ours']['never_asked'])} with no ask row of any campaign)")
    L.append(f"credit requests: {gap}")
    sent = "sent_this_tick " + show(t["sent_this_tick"], n)
    if "value" in t["sent_this_tick"]:
        sent += f" (tick {send_words(t['sent_this_tick']['at'], now)})"
    applied = "applied_1h " + show(t["applied_1h"], n)
    per = t["decisions_per_intake"]
    ratio = "decisions_per_intake " + (
        "unmeasured" if "unmeasured" in per else
        ("no intake" if per["value"] is None else f"{per['value']:,.1f}") + ("~" if per["stale"] else "")
        + f" ({n(per['decisions'])} decisions / {n(per['intake'])} created)")
    held = t["held_evidence_unbounded"]
    held_txt = "held_evidence_unbounded " + show(held, n)
    L.append(f"  {sent}; {applied}")
    L.append(f"  {ratio}; {held_txt}")
    if page.get("other_24h"):
        L.append("told 24h by senders outside these families: "
                 + ", ".join(f"{k} {n(v)}" for k, v in page["other_24h"].items()))
    reqs = [f"{f['family']} {show(f['open_rows'], n)} open, {show(f['decided_rows'], n)} decided 24h"
            for f in page["families"] if "value" in f["open_rows"] and "value" in f["decided_rows"]]
    if reqs:
        L.append("the columns count users. requests: " + "; ".join(reqs))
    per_user = [f"{f['family']} {show(f['oldest_per_user_median_h'], age_words)}"
                for f in page["families"] if "value" in f["oldest_per_user_median_h"]]
    if per_user:
        L.append("median age is per open request; per user's oldest request: " + ", ".join(per_user))
    split = [f"{f['family']} " + " / ".join(show(f[k], n) for k in WAITING)
             for f in page["families"] if all(k in f for k in WAITING)]
    if split:
        L.append("users waiting on us / on the user / on hold: " + ", ".join(split))
    rates = [f"{f['family']} {f['per_day']['value']:,.1f}" for f in page["families"] if "value" in f["per_day"]]
    L.append(f"days to zero = open users / users told per day ({RATE_DAYS}-day mean"
             + (": " + ", ".join(rates) if rates else "") + "); told once, not closed")
    snap = page["snapshot"]
    if "unmeasured" not in snap:
        line = f"open, decided, ages: snapshot {parse_ts(snap['at']).strftime('%m-%d %H:%MZ')}, {since(snap['at'], now)} old"
        if snap["stale"]:
            line = "~ " + line + f" (limit {SNAPSHOT_MAX_AGE_H:.0f}h)"
            if snap["writer_stopped"]:
                line += f"; its writer is stopped by {snap['kill']}"
        L.append(line + ". told, last send: the verify ledger, read now.")
    for reason, cells in why.items():
        L.append(f"unmeasured, not zero - {', '.join(cells)}: {reason}")
    L.extend(f"note: {x}" for x in page["notes"])
    return "\n".join(part for line in L for part in (
        textwrap.wrap(line, MAX_COLS, subsequent_indent="    ", break_long_words=False,
                      break_on_hyphens=False) or [""]))


# A second figure from the same read as the cell it is named with: measured or unmeasured
# together, so naming both only makes the failure longer. Anything not listed here is scanned.
SAME_READ = {"open_rows": "open", "decided_rows": "decided_24h", "per_day": "told_24h"}


def broken_cells(page: dict) -> list[tuple[str, str]]:
    """(cell, why) for every cell on the page that is unmeasured or stale. It walks the cells
    a family row actually carries, not a list of names kept beside them: a list left the
    waiting cells out, so the timer passed with `waiting on us` unmeasured."""
    cells = [(f"{f['family']} {k}", c) for f in page["families"] for k, c in f.items()
             if isinstance(c, dict) and k not in SAME_READ]
    cells += list(page["tracking"].items())
    return [(name, c["unmeasured"] if "unmeasured" in c else "stale") for name, c in cells
            if "unmeasured" in c or c.get("stale")]


def incomplete(page: dict) -> bool:
    return bool(broken_cells(page))


def grouped(names: list[str]) -> str:
    """`credits open, median_h; claims open; ours`: each family named once, to keep a failure
    inside the journal tail the pager sends."""
    by: dict[str, list[str]] = {}
    for name in names:
        family, _, key = name.rpartition(" ")
        by.setdefault(family, []).append(key)
    return "; ".join((family + " " if family else "") + ", ".join(keys) for family, keys in by.items())


def save(page: dict, directory: str) -> None:
    """Write the page and its cells, each by rename, so a reader never sees half a file."""
    os.makedirs(directory, exist_ok=True)
    for name, body in (("latest.txt", render(page) + "\n"),
                       ("latest.json", json.dumps(page, indent=2, sort_keys=True) + "\n")):
        tmp = os.path.join(directory, f".{name}.{os.getpid()}.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(body)
        os.replace(tmp, os.path.join(directory, name))


def main(argv: list[str]) -> int:
    args = argv[1:]
    if set(args) & {"-h", "--help"}:
        print(USAGE)
        return 0
    directory = None
    if "--save" in args:
        i = args.index("--save")
        if i + 1 >= len(args) or args[i + 1].startswith("-"):
            print(f"verification-standing: --save needs a directory\n{USAGE}", file=sys.stderr)
            return 2
        directory = args[i + 1]
        del args[i:i + 2]
    unknown = [a for a in args if a not in ("--json", "--strict")]
    if unknown:
        print(f"verification-standing: unknown argument {unknown[0]}\n{USAGE}", file=sys.stderr)
        return 2
    page = build()
    print(json.dumps(page, indent=2, sort_keys=True) if "--json" in args else render(page))
    broken = broken_cells(page)
    if directory is not None:
        try:
            save(page, directory)
        except OSError as e:
            print(f"verification-standing: could not save the page in {directory}: {e}", file=sys.stderr)
            return 1
        # One line per reason: the unit's failure page is the last 12 journal lines.
        owed: dict[str, list[str]] = {}
        for name, why in broken:
            if why not in NO_WRITER_YET:
                owed.setdefault("stale" if why == "stale" else f"unmeasured ({why})", []).append(name)
        for why, names in owed.items():
            print(f"verification-standing: {why}: {grouped(names)}", file=sys.stderr)
        stopped = page["snapshot"].get("writer_stopped")
        if owed and stopped:
            print(f"verification-standing: the snapshot's writer is stopped by {page['snapshot']['kill']}",
                  file=sys.stderr)
        if owed:
            return 3
    return 3 if "--strict" in args and broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
