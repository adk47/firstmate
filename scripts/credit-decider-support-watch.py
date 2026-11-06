#!/usr/bin/env python3
"""Page #clio_devops when the credit decider's SUPPORT-ONLY writer misbehaves.

Fable d2 [key=decider-support-arm] condition 4: "a paging alert ships in the same PR". A support
write is customer-facing (the user gets core's Knock "more info needed" and their credit moves to
user_verification_needed), so every way this arm can go wrong must reach a human, not a log:

  1. approve_written     an APPROVAL was written while the approve arm is off. This is the one
                         thing the whole scope exists to prevent: policy approve_arm = false, so
                         any `approved` outcome on an apply run is a violation, always.
  2. ask_ledger_gap      a support write landed but its ask could not be ledgered, so the tick's
                         own campaigns cannot see the user was asked (double-ask risk).
  3. support_write_error core refused/failed a support PUT (`error:` outcomes on an apply run).
  4. candidates_but_silent the queue had support candidates in the window and nothing was sent
                         while the arm was ARMED. Narrow on purpose: it only fires when
                         (a) the writer kill file is absent, (b) an enabled `--mode apply` cron
                         exists, and (c) the queue actually produced support decisions - an empty
                         queue is quiet, not broken (a DISABLED trigger is unscheduled, and an
                         unscheduled arm must never page).
  5. readback_owed       an apply run has owed a read-back for longer than the grace window, so
                         the next apply is refused and the arm is wedged.

DETECT-AND-PAGE ONLY. It never lifts a kill file, never writes a credit and never re-runs a batch.

Exit: 0 clean, 1 findings (paged), 2 cannot measure (the ledger is unreadable - never silently
"clean"). Deduped per finding key for DEDUPE_H by default.

Scheduled by /etc/cron.d/credit-decider-support-watch (installed via scripts/install-aux-units.sh).
Run by hand: python3 scripts/credit-decider-support-watch.py [--dry-run] [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LEDGER = Path(os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3"))
WRITER_KILL = Path(os.environ.get("CREDIT_TRUST_DECIDE_KILL_SWITCH", "/etc/hydra/credit-trust-decide.disabled"))
APPROVE_SWITCH = Path(os.environ.get("CREDIT_TRUST_DECIDE_APPROVE_DISABLED",
                                     "/etc/hydra/credit-trust-decide-approve.disabled"))
POLICY = Path(os.environ.get("CREDIT_TRUST_DECIDE_POLICY", str(ROOT / ".." / "policies" / "credit-trust-decide.json")))
CRON_JOBS = Path(os.environ.get("HYDRA_CRON_JOBS", str(ROOT / ".." / "cron-jobs.json")))
STATE = Path(os.environ.get("CREDIT_DECIDER_SUPPORT_WATCH_STATE",
                           "/var/lib/hydra/credit-review/decider-support-watch.state"))
SLACK_LIB = Path(os.environ.get("SLACK_NOTIFY_LIB", str(ROOT / "lib" / "slack-notify.sh")))
DEDUPE_H = float(os.environ.get("CREDIT_DECIDER_SUPPORT_WATCH_DEDUPE_H", "6"))
WINDOW_H = float(os.environ.get("CREDIT_DECIDER_SUPPORT_WATCH_WINDOW_H", "2"))
READBACK_GRACE_H = float(os.environ.get("CREDIT_DECIDER_SUPPORT_WATCH_READBACK_GRACE_H", "6"))
APPROVE_LOOKBACK_D = float(os.environ.get("CREDIT_DECIDER_SUPPORT_WATCH_APPROVE_LOOKBACK_D", "30"))
# When the SUPPORT-ONLY scope took effect. Approvals the decider wrote BEFORE this are not violations:
# the arm was legitimately armed then, and paging on that history would bury the one signal this alert
# exists for (measured on node-8 2026-11-04: 654 apply-mode approvals, the newest 2026-10-26T23:17:06Z,
# i.e. all before the 2026-10-30 judge-only cutover). Audit the backlog with --since. Overridable so a
# deploy that slips does not need a code change.
SUPPORT_ONLY_SINCE = os.environ.get("CREDIT_DECIDER_SUPPORT_WATCH_SINCE", "2026-11-05T00:00:00Z")


def utc(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ro(db_path: Path) -> sqlite3.Connection:
    """Read-only, and it must already exist: an absent ledger cannot be reported clean."""
    if not db_path.exists():
        raise FileNotFoundError(f"{db_path} does not exist")
    return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)


def _present(p: Path) -> bool:
    try:
        return p.exists()
    except OSError:
        return True   # unreadable: assume present (the closed direction) and say so


def approve_arm_on() -> tuple[bool, str]:
    """(may the writer approve?, why). Mirrors decide.approve_arm_off(): policy first, switch second."""
    try:
        doc = json.loads(POLICY.read_text(encoding="utf-8"))
        armed = bool(doc.get("approve_arm") is True)
    except Exception as exc:  # noqa: BLE001 - an unreadable policy is not an armed one
        return False, f"policy unreadable ({exc})"
    if not armed:
        return False, "policy approve_arm is not true"
    if _present(APPROVE_SWITCH):
        return False, f"switch present at {APPROVE_SWITCH}"
    return True, "armed"


def support_writer_on() -> tuple[bool, str]:
    """(may the SUPPORT arm write?, why).

    qa-review #1782 finding 2: the silence branch was gated on `approve_arm_on()`, which is FALSE whenever the
    shipped `approve_arm:false` policy is in force - so in exactly the configuration this PR ships, a stuck support
    writer with candidates and zero asks paged nobody. The two arms are separate axes: the support arm's
    authorization is the WRITER kill file plus an enabled `--mode apply` schedule. An unscheduled or killed arm is
    silent by design and must never page.
    """
    if _present(WRITER_KILL):
        return False, f"writer kill switch present at {WRITER_KILL}"
    if not apply_cron_scheduled():
        return False, "no enabled --mode apply cron (an unscheduled arm is silent, not broken)"
    return True, "support writer armed and scheduled"


def apply_cron_scheduled() -> bool:
    """True when cron-jobs.json carries an ENABLED `decide ... --mode apply` entry."""
    try:
        doc = json.loads(CRON_JOBS.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - unknown scheduling: treat as unscheduled (no false pages)
        return False
    jobs = doc.get("jobs") if isinstance(doc, dict) else doc
    for job in (jobs if isinstance(jobs, list) else (jobs or {}).values()):
        if not isinstance(job, dict) or job.get("enabled") is not True:
            continue
        argv = ((job.get("payload") or {}).get("argv") or [])
        flat = [str(a) for a in argv]
        if "--mode" in flat and flat[flat.index("--mode") + 1:][:1] == ["apply"] and "decide" in flat:
            return True
    return False


def findings(db: sqlite3.Connection, now: datetime, since: str | None = None) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    armed, why_arm = approve_arm_on()
    # 1. an approval written while the arm is off. Not "while the switch exists": the policy says
    #    false, so ANY approved outcome is out of scope, whatever the disk says.
    if not armed:
        # The floor is the LATER of the scope's start and the lookback window: this alert reads a
        # scope, not the arm's history.
        floor = max(since or SUPPORT_ONLY_SINCE, utc(now - timedelta(days=APPROVE_LOOKBACK_D))
                    if since is None else since or SUPPORT_ONLY_SINCE)
        rows = db.execute(
            "SELECT o.run_id, COUNT(*) FROM decision_outcomes o JOIN decisions d"
            " ON d.request_id = o.request_id AND d.run_id = o.run_id"
            " WHERE o.action = 'approve' AND o.outcome = 'approved' AND o.at >= ? AND d.mode = 'apply'"
            " GROUP BY o.run_id", (floor,)).fetchall()
        if rows:
            runs = ", ".join(f"{r[0]} ({r[1]})" for r in rows[:5])
            out.append({"key": "approve_written", "text": (
                f"credit decider SUPPORT-ONLY VIOLATION: {sum(r[1] for r in rows)} approval(s) written by "
                f"apply run(s) {runs} while the approve arm is off ({why_arm}). Expected 0 - nothing should "
                f"approve while this arm is support-only (window from {floor}). Audit those credits first; "
                "for the arm's history use --since")})
    # 2. a landed ask that could not be ledgered for the tick's gates.
    #
    # qa-review #1782 (r12) Important: this selected every historical error key unconditionally, so a gap the
    # read-back later RECONCILED paged every 6h forever - the alert told an operator to reconcile something that
    # already was. The read-back is the reconciliation, so a run whose read-back recorded ok:true has no gap left;
    # the write path now also clears the rows, and this filter covers rows written before that fix.
    try:
        gaps = db.execute("SELECT k, v FROM state WHERE k LIKE 'support-writer:ask-ledger-error:%'").fetchall()
    except sqlite3.Error:
        gaps = []
    reconciled: set[str] = set()
    for k, v in gaps:
        try:   # the run id comes from the row's own document, never from splitting the key
            run_id = str(json.loads(v).get("run_id") or "")
        except (TypeError, ValueError):
            run_id = ""
        if not run_id:
            continue
        row = db.execute("SELECT v FROM state WHERE k = ?", (f"support-writer:readback:{run_id}",)).fetchone()
        if not row:
            continue
        try:
            if json.loads(row[0]).get("ok") is True:
                reconciled.add(str(k))
        except (TypeError, ValueError):
            continue
    gaps = [g for g in gaps if str(g[0]) not in reconciled]
    if gaps:
        doc = []
        asks = 0
        for k, v in gaps[:5]:
            try:
                parsed = json.loads(v)
                doc.append(str(parsed.get("error", ""))[:120])
                asks += int(parsed.get("asks") or 1)
            except (TypeError, ValueError):
                doc.append(str(v)[:120])
                asks += 1
        out.append({"key": "ask_ledger_gap", "text": (
            f"credit decider: {len(gaps)} user(s) / {asks} ask(s) were sent but NOT ledgered for the tick's gates "
            f"(double-ask risk). First: {doc[0] if doc else 'n/a'}. The users affected can be mailed by a "
            "second campaign today; reconcile from the ledger before the next tick.")})
    # 3. support writes the server errored on.
    since24 = utc(now - timedelta(hours=24))
    errs = db.execute(
        "SELECT COUNT(*) FROM decision_outcomes o JOIN decisions d ON d.request_id = o.request_id"
        " AND d.run_id = o.run_id WHERE o.action = 'support' AND o.outcome LIKE 'error:%' AND o.at >= ?"
        " AND d.mode = 'apply'", (since24,)).fetchone()[0]
    if errs:
        out.append({"key": "support_write_error", "text": (
            f"credit decider: {errs} support write(s) ERRORED in the last 24h (an ask the user did not "
            "get, or a status we cannot prove). Check `credit-review.py explain <id>` for the rows.")})
    # 4. the support arm is on and scheduled, candidates existed, nothing sent. NOT gated on the approve arm:
    #    that arm is off by policy in the shipped configuration, so gating here made the alert unreachable.
    support_on, why_support = support_writer_on()
    if support_on:
        since = utc(now - timedelta(hours=WINDOW_H))
        cand = db.execute("SELECT COUNT(*) FROM decisions WHERE mode = 'apply' AND decision = 'support'"
                          " AND decided_at >= ?", (since,)).fetchone()[0]
        sent = db.execute(
            "SELECT COUNT(*) FROM decision_outcomes o JOIN decisions d ON d.request_id = o.request_id"
            " AND d.run_id = o.run_id WHERE o.action = 'support' AND o.outcome = 'user_verification_needed'"
            " AND o.at >= ? AND d.mode = 'apply'", (since,)).fetchone()[0]
        if cand and not sent:
            out.append({"key": "candidates_but_silent", "text": (
                f"credit decider: {cand} support candidate(s) in the last {WINDOW_H:g}h and ZERO asks sent, "
                f"while the support writer is on ({why_support}). Either every one was filtered (proof on file, "
                "already asked, the ask caps) - which the run line counts - or the writer is stuck.")})
    # 5. an apply path wedged behind an owed read-back.
    owed, failed = [], []
    for key, val in db.execute("SELECT k, v FROM state WHERE k LIKE 'support-writer:apply:%'").fetchall():
        run_id = str(key).split(":", 2)[-1]
        row = db.execute("SELECT v FROM state WHERE k = ?", (f"support-writer:readback:{run_id}",)).fetchone()
        if row:
            # qa-review #1782 finding 4: a read-back that did NOT confirm every row leaves the gate closed
            # (decide.run_readback records ok:false, pending_readback still refuses). Skipping on the mere
            # existence of the key hid a wedged apply path for as long as the failure persisted.
            try:
                doc = json.loads(row[0]) if isinstance(row[0], str) else {}
            except (TypeError, ValueError):
                doc = {}
            if isinstance(doc, dict) and doc.get("ok") is True:
                continue
            detail = str((doc or {}).get("error") or (doc or {}).get("reason") or "ok is not true")[:160]
            try:
                at = (doc or {}).get("at", "")
                age_h = (now - datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                         ).total_seconds() / 3600
            except (TypeError, ValueError):
                age_h = READBACK_GRACE_H + 1   # unreadable read-back age: report it rather than hide it
            if age_h >= READBACK_GRACE_H:
                failed.append(f"{run_id} ({detail})")
            continue
        try:
            at = json.loads(val).get("at", "")
            age_h = (now - datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                     ).total_seconds() / 3600
        except (TypeError, ValueError):
            age_h = READBACK_GRACE_H + 1   # unreadable age: report it rather than hide it
        if age_h >= READBACK_GRACE_H:
            owed.append(run_id)
    if owed:
        out.append({"key": "readback_owed", "text": (
            f"credit decider: apply run(s) {', '.join(owed[:5])} have owed a read-back for over "
            f"{READBACK_GRACE_H:g}h, so --mode apply is REFUSED until one is recorded. Run "
            f"`credit-review.py decide-readback --run <id>`.")})
    if failed:
        out.append({"key": "readback_failed", "text": (
            f"credit decider: apply run(s) {', '.join(failed[:5])} were read back and did NOT confirm every row "
            f"(over {READBACK_GRACE_H:g}h ago), so --mode apply is REFUSED. The rows that did not come back are "
            f"unknown, not approved: re-run `credit-review.py decide-readback --run <id>` once core answers.")})
    return out


def _state_load() -> dict[str, str]:
    try:
        doc = json.loads(STATE.read_text(encoding="utf-8"))
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def page(text: str) -> bool:
    """Page #clio_devops with real mentions (a literal @name pings nobody). True = delivered.

    qa-review #1782 finding 3: the return code used to be discarded and the dedupe stamp written anyway, so a Slack
    outage silenced the only alert for the condition for the whole dedupe window. The caller stamps ONLY a delivery
    that succeeded, so an undelivered page is retried on the next tick.
    """
    script = '. "$1"; slack_notify_critical "$2"'
    try:
        proc = subprocess.run(["bash", "-c", script, "--", str(SLACK_LIB), text], check=False, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"warning: page not delivered ({exc})", file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(f"warning: page not delivered (slack_notify_critical rc={proc.returncode})", file=sys.stderr)
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the pages, never send or record")
    ap.add_argument("--json", action="store_true", help="machine output")
    ap.add_argument("--since", help="audit: count approvals from this UTC stamp instead of SUPPORT_ONLY_SINCE")
    a = ap.parse_args(argv)
    now = datetime.now(timezone.utc)
    try:
        db = _ro(LEDGER)
    except (OSError, sqlite3.Error) as exc:
        msg = f"credit decider support watch CANNOT MEASURE: {exc}"
        if not a.dry_run:
            page(msg)
        print(json.dumps({"error": msg}) if a.json else msg)
        return 2
    try:
        found = findings(db, now, a.since)
    except sqlite3.Error as exc:
        msg = f"credit decider support watch CANNOT MEASURE (ledger read): {exc}"
        if not a.dry_run:
            page(msg)
        print(json.dumps({"error": msg}) if a.json else msg)
        return 2
    finally:
        db.close()
    state = _state_load()
    fresh = []
    for f in found:
        key = str(f["key"])
        last = state.get(key)
        if last:
            try:
                if now - datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) < timedelta(hours=DEDUPE_H):
                    continue
            except ValueError:
                pass   # unreadable stamp never suppresses a page
        fresh.append(f)
    if a.json:
        print(json.dumps({"at": utc(now), "found": found, "paged": [f["key"] for f in fresh]}, indent=1))
    elif not found:
        print(f"credit decider support watch: clean ({utc(now)})")
    undelivered = []
    for f in fresh:
        if a.dry_run:
            print(f"WOULD PAGE [{f['key']}]: {f['text']}")
            continue
        if not page(str(f["text"])):
            # NOT delivered: leave the key unstamped so the next tick tries again.
            undelivered.append(str(f["key"]))
            print(f"NOT PAGED [{f['key']}] (delivery failed, will retry): {f['text']}", file=sys.stderr)
            continue
        state[str(f["key"])] = utc(now)
        print(f"paged [{f['key']}]: {f['text']}")
    if state and not a.dry_run:
        try:
            STATE.parent.mkdir(parents=True, exist_ok=True)
            tmp = STATE.with_suffix(".tmp")
            tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
            os.replace(tmp, STATE)
        except OSError as exc:  # a page that went out is more important than the dedupe stamp
            print(f"warning: dedupe state not written ({exc})", file=sys.stderr)
    return 1 if (fresh or undelivered) else 0


if __name__ == "__main__":
    sys.exit(main())
