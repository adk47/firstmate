#!/usr/bin/env python3
"""[key=doc-approval-doctrine] The two alerts Fable d2 gave the doc-verified T0/T1 class.

  * the decider approved **0 in 6 h while eligible > 0**
  * **dv-4 verified single-candidate documents with no approved_refs > 24 h**

and, while the class is in SHADOW, one **would-approve** line a day (users / requests under the
R22 caps: 50 users per UTC day, 5 requests per user per day, 10 per profile per day,
`paid_first_oldest`). The shadow number is what makes "shadow 24 h, then flip on the read" a
decision with a measurement behind it instead of a guess.

Both numbers come from `credit_review/doc_measure.py`, the SAME read-only pass the arming dry run
(`credit-review.py doc-approvals --dry-run`) uses. A monitor that reasons about eligibility
differently from the gates is the way a monitor lies, so there is exactly one measurement.

Both measure the class's THROUGHPUT, and both are gated on the class being ARMED
(registry entry `document_small_track` approved, kill switch absent). A dormant class is
supposed to approve nothing, so paging hourly about the work it deliberately is not
clearing is how a p3 alert becomes wallpaper; while dormant the same numbers go to the
cron log and nothing pages.

READ-ONLY by construction, like `dr-ai-healer.sh`'s posture: it approves nothing,
reverts nothing, arms nothing, writes no ledger row and sends nothing to a user. It
does not even run the provisional sweep (`doc-approvals --pull` is a human's command),
so a cron tick can never move a row between states.

A watchdog that cannot read its own inputs PAGES that it is blind, rather than reporting
"0 approvals, all fine" — a broken reader is not a healthy class, and silence must never be
ambiguous between "nothing to say" and "the watcher cannot see".

Usage:
    credit-decide-watchdog.py [--json] [--now 2026-11-04T18:00:00Z]

Exit: 0 = evaluated (alerts are in the output, not the exit code), 2 = bad --now.
The delivery half is scripts/credit-decide-watchdog.sh; cron entry
`credit-decide-watchdog-hourly`.
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
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import admin as admin_api  # noqa: E402
from credit_review import decide, doc_approve, doc_measure, ledger as _ledger  # noqa: E402
from credit_review.runner import log  # noqa: E402

#: The decider's OWN ledger default, imported rather than re-typed. QA #1766 r1 finding 3: this
#: module used to hardcode `/var/lib/hydra-credit-review/ledger.sqlite`, which is not a path the
#: decider has ever written. `_ro` returns None for a missing file, so a live class with real
#: approvals read as "0 approvals, no standing refs" and paged a false stall every hour.
LEDGER_DEFAULT = Path(_ledger.DEFAULT_PATH)

#: The 6 h window d2 named for the throughput alert.
ZERO_APPROVALS_WINDOW_HOURS = 6
#: The 24 h window d2 named for the unapproved-eligible-document alert.
STALE_ELIGIBLE_HOURS = 24


def _maintenance_active() -> bool:
    """True while a planned fleet maintenance window is open (`scripts/hydra-maintenance.sh`).

    A window stops the scheduled jobs on purpose, so "0 approvals in 6h" is the window talking, not
    a stalled decider - and paging through it is how a p3 alert becomes wallpaper. Fail-safe: any
    error means NOT in maintenance, so a broken helper can never silence the watchdog.
    """
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hydra-maintenance.sh")
    try:
        # Invoke via `bash <script>` (not the exec bit) so a lost +x on the helper cannot silently
        # stop this watchdog honoring the window.
        return subprocess.run(
            ["bash", helper, "is-active"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
        ).returncode == 0
    except Exception:  # noqa: BLE001 - fail-safe: any error => not in maintenance
        return False


def _parse_now(s: str | None) -> datetime:
    if not s:
        return datetime.now(timezone.utc)
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError as exc:
        raise SystemExit(f"credit-decide-watchdog: bad --now {s!r}: {exc}")


def _ro(path: Path) -> sqlite3.Connection | None:
    """Read-only connection, or None when the file does not exist. NEVER creates a file:
    a watchdog that creates the ledger it is auditing reports a healthy empty class."""
    if not path.exists():
        return None
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)


def _armed(registry: Path | None = None) -> tuple[bool, str]:
    """(armed, why). Both switches: the registry entry approved AND no kill switch."""
    kill = Path(os.environ.get("CREDIT_DOC_APPROVE_KILL_SWITCH", "/etc/hydra/doc-approve.disabled"))
    ok, why = decide.doc_class_approved(registry)
    if not ok:
        return False, f"dormant: {why}"
    if kill.exists():
        return False, f"dormant: kill switch {kill} present"
    return True, why


def _verdict_at(doc_store: Path, proof_store: Path) -> dict[str, str]:
    """request id -> the newest verdict instant, for the documents the class could act on.

    Only used to age a row for the 24 h alert; the eligibility question is answered by
    `doc_measure.measure`, never here.

    QA #1766 r3 finding 2: this used to return `{}` on a read failure, and the caller's
    `(verdict_at.get(rid) or "") <= cutoff` is then TRUE for every row - so a second read that
    failed after `measure` succeeded fabricated a 24 h stale alert with no age evidence at all.
    It RAISES; the caller reports BLIND.
    """
    out: dict[str, str] = {}
    for rid, docs in doc_approve.verified_docs(doc_store, proof_store).items():
        newest = max(docs, key=lambda d: d.verdict_at)
        out[rid] = newest.verdict_at or ""
    return out


# The states that mean "this class DID approve something". `released` is not one: the core write did
# not confirm, so the slot went back and nothing was approved. `indeterminate` is not one either
# (qa-review #1766 r6): the core write outcome is explicitly UNKNOWN, so counting it as a completed
# approval asserts a fact the system did not measure - and it suppresses the stall alert precisely
# when nobody knows whether the decider is working. `pulled` IS one: the decider approved and the
# pull sweep later reverted it, which is the decider running, not stalling.
APPROVED_STATES = ("provisional", "confirmed", "pulled")


def _approvals_since(db: sqlite3.Connection, since: str) -> int:
    """Approvals this class CONFIRMED since `since` (see `APPROVED_STATES`).

    QA #1766 r3 finding 4: a `doc_approvals` query error used to read as 0 approvals, which pages a
    false stall. It RAISES; the caller reports BLIND.
    """
    marks = ", ".join("?" * len(APPROVED_STATES))
    row = db.execute(f"SELECT COUNT(*) FROM doc_approvals WHERE approved_at >= ?"
                     f" AND state IN ({marks})", (since, *APPROVED_STATES)).fetchone()
    return int(row[0]) if row else 0


def _indeterminate_since(db: sqlite3.Connection, since: str) -> int:
    """Rows in the window whose core write outcome is UNKNOWN.

    Reported beside the approval count rather than folded into it (qa-review #1766 r6): an
    indeterminate row is neither a known approval nor a known non-approval, so the stall alert still
    fires on zero KNOWN approvals and says how many rows it could not account for.
    """
    row = db.execute("SELECT COUNT(*) FROM doc_approvals WHERE approved_at >= ?"
                     " AND state = 'indeterminate'", (since,)).fetchone()
    return int(row[0]) if row else 0


def _standing(db: sqlite3.Connection) -> set[str]:
    """Requests this class holds a standing ref for. RAISES on a query error (see `_approvals_since`)."""
    return {str(r[0]).lower() for r in db.execute(
        "SELECT request_id FROM doc_approvals WHERE state IN ('provisional', 'confirmed')")}


def evaluate(*, now: datetime | None = None, ledger: Path | None = None,
             doc_store: Path | None = None, proof_store: Path | None = None,
             registry: Path | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    ledger = ledger or LEDGER_DEFAULT
    doc_store = doc_store or Path(os.environ.get("CREDIT_DOC_VERIFY_STORE", doc_approve.DEFAULT_DOC_STORE))
    proof_store = proof_store or Path(os.environ.get("CREDIT_PROOF_STORE", doc_approve.DEFAULT_PROOF_STORE))
    armed, why = _armed(registry)

    # QA #1766 r1 finding 4 / r2 carried-forward: the eligible set is the DECIDER's, not a smaller
    # set of our own. `doc_measure.measure` is the same read-only pass the arming dry run uses, so
    # forensics, cross-check, same-release, role, doc-reuse, tier, account, hold, claimant and the
    # caps are all asked. A class whose documents all fail a later gate now reports zero eligible
    # rows and does NOT page a stalled decider, because zero approvals is the correct answer.
    unreadable = ""
    measured: dict = {"verdicts": {}, "would_approve": 0, "would_users": 0, "would_requests": 0,
                      "rolled_to_tomorrow": 0, "spent_users_today": 0, "spent_requests_today": 0,
                      "per_guard": {}, "rows": 0}
    approved_6h = 0
    indeterminate_6h = 0
    standing: set[str] = set()
    facts: dict = {}
    db = _ro(ledger)
    if db is None:
        # QA #1766 r2 finding 1: a missing ledger used to read as "0 approvals, no standing refs",
        # which pages a false stall and a false stale set. It is BLIND, and says so.
        unreadable = f"the decider ledger {ledger} is missing or unreadable"
    else:
        try:
            since6 = doc_approve.utc(now - timedelta(hours=ZERO_APPROVALS_WINDOW_HOURS))
            approved_6h = _approvals_since(db, since6)
            indeterminate_6h = _indeterminate_since(db, since6)
            standing = _standing(db)
            facts = doc_measure.rows(db)
            ages: dict = {}
            try:
                ages = doc_measure.core_ages(admin_api.AdminClient(), facts)
            except doc_measure.CoreCensusIncomplete as exc:
                unreadable = str(exc)
            except (admin_api.AdminError, OSError, sqlite3.Error) as exc:
                # QA #1766 r3 finding 5: this used to log and leave `ages={}`, so every row measured
                # `claimant_no_history`, `eligible` became 0 and the tick looked like a healthy quiet
                # one. A core outage is BLIND, not quiet.
                unreadable = f"core could not be read for account ages ({exc})"
            if not unreadable:
                measured = doc_measure.measure(db, doc_store=doc_store, proof_store=proof_store,
                                               now=now, ages=ages)
                if measured.get("unreadable"):
                    unreadable = measured["unreadable"]
        except doc_measure.LedgerUnreadable as exc:
            unreadable = str(exc)
        except doc_measure.PolicyUnreadable as exc:
            unreadable = str(exc)
        except sqlite3.Error as exc:
            unreadable = f"the decider ledger could not be read ({exc})"
        finally:
            db.close()

    # QA #1766 r3 finding 1: `would_approve` is PRE-cap. When every daily slot is already spent the
    # decider correctly approves nothing, so counting those rows as "approvable work" pages a stalled
    # decider for behaving correctly. `admitted` is the cap plan's answer: what the caps would let
    # through TODAY. The rolled rows are still reported, in the log line and in `shadow`.
    eligible = {str(rid).lower() for rid in (measured.get("admitted") or ())}
    verdict_at: dict[str, str] = {}
    if eligible and not unreadable:
        try:
            verdict_at = _verdict_at(doc_store, proof_store)
        except (OSError, sqlite3.Error, ValueError) as exc:
            # QA #1766 r3 finding 2: an empty map here makes every row look stale, which fabricates
            # the 24 h alert with no age evidence. BLIND instead.
            unreadable = f"the doc store could not be re-read for verdict ages ({exc})"
    shadow = {k: measured.get(k, 0) for k in
              ("would_users", "would_requests", "rolled_to_tomorrow", "spent_users_today",
               "spent_requests_today", "eligible_users")}
    shadow.update(_tier_split(measured, facts))

    stale = sorted(rid for rid in eligible
                   if rid not in standing
                   and (verdict_at.get(rid) or "") <= doc_approve.utc(
                       now - timedelta(hours=STALE_ELIGIBLE_HOURS)))

    alerts: list[dict] = []
    if armed and not unreadable:
        if eligible and approved_6h == 0:
            alerts.append({"key": "approved_0_in_6h",
                           "text": f":rotating_light: doc-verified T0/T1 class: *0 approvals in the last "
                                   f"{ZERO_APPROVALS_WINDOW_HOURS}h* while *{len(eligible)} request(s)* pass "
                                   "every row gate AND fit today's caps. The decider is not clearing the "
                                   "class."
                                   + (f" ({indeterminate_6h} row(s) in that window are INDETERMINATE:"
                                      " the core write outcome is unknown, so they are not counted as"
                                      " approvals.)" if indeterminate_6h else ""),
                           "eligible": len(eligible), "approved": approved_6h,
                           "indeterminate": indeterminate_6h})
        if stale:
            sample = ", ".join(stale[:5])
            alerts.append({"key": "verified_no_ref_over_24h",
                           "text": f":rotating_light: doc-verified T0/T1 class: *{len(stale)} dv-4 verified "
                                   f"single-candidate document(s) have had no approved_ref for over "
                                   f"{STALE_ELIGIBLE_HOURS}h*: {sample}"
                                   + (f" (+{len(stale) - 5} more)" if len(stale) > 5 else ""),
                           "stale": len(stale), "requests": stale[:50]})
    res = {"armed": armed, "why": why, "eligible": len(eligible), "approved_6h": approved_6h,
           "indeterminate_6h": indeterminate_6h,
           "rolled_to_tomorrow": measured.get("rolled_to_tomorrow", 0),
           "stale": len(stale), "unreadable": unreadable, "alerts": alerts,
           "eligible_users": len({(facts.get(rid) or {}).get("user_id") for rid in eligible}
                                 - {None}),
           "per_guard": measured.get("per_guard") or {}, "shadow": shadow}
    return res


def _tier_split(measured: dict, facts: dict) -> dict:
    """The tier split the shadow line SHOWS, so a reader can tell a zero from an unknown.

    `0` is falsy in Python, so a falsiness slip anywhere on the way to the tier gate would read a
    zero-popularity track as absent and route a whole cohort to the wrong tier with nothing in the
    output to show it. `tier_refused` counts every row `gate_tier` refused and
    `zero_popularity_refused` names the R22a D1 population inside it; `unknown` counts only rows whose
    popularity could not be read at all.

    QA #1766 r5 finding 1: the split is over the CAP-ADMITTED set, the same set the headline
    `would_requests`/`would_users` count. It used to count every pre-cap `would_approve` row, so with
    49 fleet slots already spent and two eligible T1 requests the line read "1 request would approve"
    beside "T1 2" - a tier diagnostic that contradicts its own headline, on the number an operator
    arms on. The pre-cap population is still reported, explicitly labelled, as `pre_cap_tiers`.
    """
    admitted = {str(rid).lower() for rid in (measured.get("admitted") or ())}
    tiers = {"T0": 0, "T1": 0, "unknown": 0}
    pre_cap = {"T0": 0, "T1": 0, "unknown": 0}
    refused = zero = 0
    for rid, verdict in (measured.get("verdicts") or {}).items():
        if verdict == "tier":
            refused += 1
            pop = (facts.get(rid) or {}).get("popularity")
            if isinstance(pop, int) and not isinstance(pop, bool) and pop <= 0:
                zero += 1
            continue
        if verdict != "would_approve":
            continue
        pop = (facts.get(rid) or {}).get("popularity")
        bucket = ("unknown" if not isinstance(pop, int) or isinstance(pop, bool)
                  else doc_approve.tier_of(pop))
        pre_cap[bucket] += 1
        if str(rid).lower() in admitted:
            tiers[bucket] += 1
    by_user: dict = {}
    for rid in admitted:
        uid = (facts.get(rid) or {}).get("user_id")
        if uid is not None:
            by_user[uid] = by_user.get(uid, 0) + 1
    return {"tiers": tiers, "pre_cap_tiers": pre_cap, "tier_refused": refused,
            "zero_popularity_refused": zero,
            "user_cap": doc_approve.DAILY_USER_CAP,
            "per_user_max": doc_approve.PER_USER_DAILY_MAX,
            "per_profile_max": doc_approve.PER_PROFILE_DAILY_MAX,
            "largest_user": max(by_user.values(), default=0)}


def render_shadow(res: dict) -> str:
    """ONE line a day while the class is in SHADOW - and silence the moment it is armed, because
    from then on the two throughput alerts are the measurement."""
    if res["unreadable"]:
        # QA #1766 r1 finding 6: a shadow report that cannot read its inputs is not a quiet day.
        return (f":rotating_light: doc-verified T0/T1 *SHADOW* could not be measured: "
                f"{res['unreadable']}. The would-approve number is UNKNOWN, not zero.")
    if res["armed"]:
        log("credit-decide-watchdog: class is ARMED - the shadow report stands down")
        return "NO_REPLY"
    sh = res["shadow"]
    tiers = sh.get("tiers") or {}
    pre = sh.get("pre_cap_tiers") or {}
    split = (f"T0 {tiers.get('T0', 0)}, T1 {tiers.get('T1', 0)}, "
             f"unreadable popularity {tiers.get('unknown', 0)}; "
             f"{sh.get('tier_refused', 0)} refused by the tier line, of which "
             f"{sh.get('zero_popularity_refused', 0)} at popularity 0")
    # QA #1766 r5 finding 1: the tier split above is the CAP-ADMITTED set, so it agrees with the
    # headline. The pre-cap population is named separately rather than silently dropped, because the
    # gap between the two IS the cap pressure an operator wants to see before arming.
    if pre != tiers:
        split += (f"; before today's caps: T0 {pre.get('T0', 0)}, T1 {pre.get('T1', 0)}, "
                  f"unreadable popularity {pre.get('unknown', 0)}")
    return (f":bar_chart: doc-verified T0/T1 *SHADOW* would approve today: *{sh['would_users']} user(s) / "
            f"{sh['would_requests']} request(s)* ({split}; R22 caps {sh['user_cap']} users/day, "
            f"{sh['per_user_max']}/user, {sh.get('per_profile_max', 10)}/profile; "
            f"{sh['rolled_to_tomorrow']} request(s) roll to tomorrow; "
            f"largest holder {sh['largest_user']}). The caps are simulated against today's ledger, so "
            "slots already spent count against the plan. A popularity of 0 is REFUSED by the tier line "
            "(R22a D1), never counted as a small track. Nothing is written while shadow is on.")


def render(res: dict) -> str:
    """One Slack line per firing alert, or NO_REPLY. A DORMANT class never pages the *throughput*
    alerts (it is supposed to approve nothing); an UNREADABLE one always does.

    QA #1766 r1 finding 6: an unreadable store used to return NO_REPLY and exit 0, so a missing or
    corrupt doc-verify/proof store after arming left every tick blind while the watcher looked
    quiet. Silence must never be ambiguous between "nothing to say" and "the watcher cannot see".
    """
    if res["unreadable"]:
        log(f"credit-decide-watchdog: {res['unreadable']} (nothing evaluated, PAGED)")
        return (f":rotating_light: the doc-verified T0/T1 watchdog is BLIND: {res['unreadable']}. "
                "Nothing was evaluated this tick, so a stalled class and a healthy one look "
                "identical. `python3 scripts/credit-decide-watchdog.py --json` on node-8.")
    if not res["armed"]:
        log(f"credit-decide-watchdog: {res['why']} - eligible {res['eligible']}, approved 6h "
            f"{res['approved_6h']}, sitting > {STALE_ELIGIBLE_HOURS}h {res['stale']}, "
            f"rolled to tomorrow {res.get('rolled_to_tomorrow', 0)} (not paged while dormant)")
        return "NO_REPLY"
    if not res["alerts"]:
        log(f"credit-decide-watchdog: ok - eligible {res['eligible']}, approved 6h {res['approved_6h']}, "
            f"indeterminate 6h {res.get('indeterminate_6h', 0)}, stale {res['stale']}, "
            f"rolled to tomorrow {res.get('rolled_to_tomorrow', 0)}")
        return "NO_REPLY"
    return "\n".join(a["text"] for a in res["alerts"])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="the evaluation as JSON (machine channel)")
    ap.add_argument("--now", default=None, help="ISO instant to evaluate at (tests, replays)")
    ap.add_argument("--ledger", default=None, help="the decider ledger sqlite")
    ap.add_argument("--doc-verify-store", default=None)
    ap.add_argument("--proof-store", default=None)
    ap.add_argument("--registry", default=None, help="policies/credit-approval-automation.json")
    ap.add_argument("--shadow-report", action="store_true",
                    help="one would-approve line (users/requests under the caps); NO_REPLY once armed")
    args = ap.parse_args(argv)
    now = _parse_now(args.now)
    if not args.json and _maintenance_active():
        # A planned window is not a stalled class. `--json` still evaluates, because a human asking
        # for the numbers during a window wants the numbers.
        log("credit-decide-watchdog: maintenance window is open - not evaluating, not paging")
        print("NO_REPLY")
        return 0
    res = evaluate(now=now,
                   ledger=Path(args.ledger) if args.ledger else None,
                   doc_store=Path(args.doc_verify_store) if args.doc_verify_store else None,
                   proof_store=Path(args.proof_store) if args.proof_store else None,
                   registry=Path(args.registry) if args.registry else None)
    if args.json:
        print(json.dumps(res, indent=2, sort_keys=True, default=str))
        return 0
    if args.shadow_report:
        print(render_shadow(res))
        return 0
    print(render(res))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:                       # noqa: BLE001 - a watchdog never dies quietly
        print(f"credit-decide-watchdog: FAILED {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
