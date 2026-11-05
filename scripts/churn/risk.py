#!/usr/bin/env python3
"""risk.py: build /var/lib/hydra/churn/risk.json from the support-state store.

This is the PREVENT signal's published artifact (firstmate spec item 2, Fable
report 2026-11-03 section 4 item 1). It answers one question for every queue that
touches a paying user:

    is this user waiting on US right now, and how soon does their money renew?

Risk classes, exactly the spec's three:
  (a) customer_last       the customer spoke last more than 24 h ago
  (b) request_pending     an open credit/claim/ClickUp intake item > 48 h with no
                          status note, or proof filed with nothing sent after it
  (c) promise_no_followup we promised a follow-up and did not make one in 48 h

`told_to_wait` (T2: we spoke last on an open thread with a hold) is deliberately
NOT a risk class on its own: the spec's three are the ones a queue can act on, and
a user we told to wait is not being dropped. It stays in the store for the weekly
line and the 60-day baseline.

Two arrays, because two questions are asked of this file:

  users    paying users waiting on us NOW  (sorted renews-soonest first)
  churned  users who cancelled with an open issue, kept for
           thresholds.churned_paid_priority_days (R4: they stay paid-priority for
           30 d after the cancel, so they do not fall into the free segment the
           moment they cancel)

Fail-closed on stale or partial data: if either nightly sweep (paying or churned)
has not finished inside thresholds.risk_max_age_hours, or finished with source
errors (a failed Intercom search yields no threads, which is indistinguishable
from "nobody is waiting"), this exits non-zero and writes NOTHING. An old
risk.json is then refused by risk_reader.py as stale, so every queue keeps its own
order - the safe behavior. Publishing a fresh timestamp over stale rows would be
the one way an ordering signal could quietly move a wrong user to the head.

The file is written atomically (tmp + rename): a reader never sees half a file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from churn import stages                       # noqa: E402
from churn.store import Store                  # noqa: E402

POLICY = str(Path(__file__).resolve().parents[2] / "policies" / "churn-risk.json")
DEFAULT_KINDS = ("customer_last", "promise_no_followup", "request_pending", "proof_no_update")
DEFAULT_LANES = {"credits_not_approved": "credit-review", "proof_sent_no_update": "credit-review",
                 "merge_claim_stuck": "merge-queue", "billing_confusion": "refund-judge",
                 "analytics_stale_wrong": "analytics-followup", "login_access": "caroline-backlog",
                 "other": "caroline-backlog"}


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_to_ts(value: Any) -> float:
    return stages.iso_to_ts(value)


def load_policy(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        raise SystemExit(f"{path} is not a JSON object")
    return doc


def risk_kinds(policy: dict[str, Any]) -> set[str]:
    cfg = (policy.get("risk") or {}).get("kinds")
    if isinstance(cfg, list) and cfg:
        return {str(k) for k in cfg}
    return set(DEFAULT_KINDS)


def lanes(policy: dict[str, Any]) -> dict[str, str]:
    table = {k: v for k, v in (policy.get("lanes") or {}).items()
             if isinstance(v, str) and not k.startswith("_")}
    return table or dict(DEFAULT_LANES)


def risk_row(store_row: dict[str, Any], policy: dict[str, Any],
             kinds: set[str], lane_map: dict[str, str],
             now: float) -> dict[str, Any] | None:
    """A store row as a risk row, or None when it is not one of the risk classes."""
    row_kinds = [k for k in (store_row.get("kinds") or []) if k in kinds]
    if not row_kinds:
        return None
    cause = store_row.get("cause_class") or "other"
    renews = store_row.get("renews_at")
    renews_ts = iso_to_ts(renews)
    try:
        mrr = float(store_row.get("mrr_list") or 0.0)
    except (TypeError, ValueError):
        mrr = 0.0
    out = {
        "user_id": int(store_row["user_id"]),
        "tier": store_row.get("tier"),
        "class": cause,
        "kind": sorted(row_kinds),
        "lane": lane_map.get(cause, lane_map.get("other", "caroline-backlog")),
        "age_days": round(float(store_row.get("ball_days") or 0.0), 2),
        "ball_days": round(float(store_row.get("ball_days") or 0.0), 2),
        "mrr_list": round(mrr, 2),
        "plan": store_row.get("plan"),
        "renews_at": renews,
        "renews_in_days": round((renews_ts - now) / stages.DAY, 2) if renews_ts else None,
        "anchor": store_row.get("anchor"),
        "checked_at": store_row.get("checked_at"),
        "evidence": store_row.get("evidence_json") or [],
        "conv_ids": store_row.get("intercom_conv_ids") or [],
        "request_ids": store_row.get("open_request_ids") or [],
    }
    if store_row.get("churned_at"):
        out["churned_at"] = store_row["churned_at"]
        out["cancel_reason"] = store_row.get("cancel_reason")
    return out


def build(store: Store, policy: dict[str, Any], *, now: float | None = None,
          policy_path: str | None = None) -> dict[str, Any]:
    now = now if now is not None else time.time()
    th = stages.Thresholds.from_policy(policy)
    kinds = risk_kinds(policy)
    lane_map = lanes(policy)

    users: list[dict[str, Any]] = []
    for row in store.users(mode="paying"):
        r = risk_row(row, policy, kinds, lane_map, now)
        if r is not None:
            users.append(r)
    # renews-soonest first, then the biggest MRR: the reader's order, published
    users.sort(key=lambda r: (iso_to_ts(r.get("renews_at")) or 9_999_999_999.0, -(r.get("mrr_list") or 0)))

    churned: list[dict[str, Any]] = []
    for row in store.users(mode="churned"):
        churned_at = iso_to_ts(row.get("churned_at"))
        if not churned_at or (now - churned_at) / stages.DAY > th.churned_paid_priority_days:
            continue
        r = risk_row(row, policy, kinds, lane_map, now)
        if r is not None:
            r["churned_at"] = row.get("churned_at")
            churned.append(r)
    churned.sort(key=lambda r: iso_to_ts(r.get("churned_at")) or 0, reverse=True)

    by_kind: dict[str, int] = {}
    by_tier: dict[str, int] = {}
    by_lane: dict[str, int] = {}
    for r in users:
        for k in r["kind"]:
            by_kind[k] = by_kind.get(k, 0) + 1
        by_tier[str(r.get("tier"))] = by_tier.get(str(r.get("tier")), 0) + 1
        by_lane[str(r.get("lane"))] = by_lane.get(str(r.get("lane")), 0) + 1

    return {
        "generated_at": datetime.fromtimestamp(now, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "policy": {"path": policy_path or POLICY, "thresholds": (policy.get("thresholds") or {}),
                   "risk_kinds": sorted(kinds)},
        "counts": {"risk_users": len(users), "churned": len(churned),
                   "mrr_risk": round(sum(r.get("mrr_list") or 0 for r in users), 2),
                   "by_kind": by_kind, "by_tier": by_tier, "by_lane": by_lane},
        "users": users,
        "churned": churned,
    }


def run_age_hours(run: dict[str, Any] | None) -> float | None:
    if not run or not run.get("finished_at"):
        return None
    ts = iso_to_ts(run["finished_at"])
    if not ts:
        return None
    return (time.time() - ts) / 3600.0


def write_atomic(doc: dict[str, Any], path: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + f".tmp.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, sort_keys=False)
        fh.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, p)


def policy_digest(path: str) -> str:
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]
    except OSError:
        return ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="build the churn risk file")
    ap.add_argument("--policy", default=POLICY)
    ap.add_argument("--store", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--dry-run", action="store_true", help="build and print counts, write nothing")
    ap.add_argument("--allow-stale-store", action="store_true",
                    help="write even when the nightly sweep is older than risk_max_age_hours")
    ap.add_argument("--allow-errored-store", action="store_true",
                    help="write even when a nightly sweep finished with source errors")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    policy = load_policy(args.policy)
    th = stages.Thresholds.from_policy(policy)
    store_path = args.store or ((policy.get("store") or {}).get("support_state"))
    out_path = args.out or ((policy.get("store") or {}).get("risk"))
    store = Store(store_path, readonly=True)
    try:
        # BOTH sweeps feed this file, and both publisher guards are the same: the
        # churned array is whatever the last churned sweep wrote (rows are never
        # pruned), so a fresh generated_at over a churned sweep that never finished
        # or has gone stale would keep calling answered users churned-with-issue for
        # the whole 30-day window.
        runs = {mode: store.last_run(mode) for mode in ("paying", "churned")}
        ages = {mode: run_age_hours(runs[mode]) for mode in ("paying", "churned")}
        limit_h = float((policy.get("thresholds") or {}).get("risk_max_age_hours", 36))
        never_finished = [m for m in ("paying", "churned") if ages[m] is None]
        if never_finished:
            for mode in never_finished:
                print(f"risk: the {mode} sweep has never finished in {store_path}; not writing a risk file "
                      f"(every consumer keeps its own order)", file=sys.stderr)
            return 3
        stale = [m for m in ("paying", "churned") if ages[m] > limit_h]
        if stale and not args.allow_stale_store:
            for mode in stale:
                print(f"risk: the {mode} sweep is {ages[mode]:.1f}h old (max {limit_h:.0f}h); not writing a risk file. "
                      f"An old file is refused as stale by the reader, which is the safe state; a fresh "
                      f"timestamp over stale rows is not.", file=sys.stderr)
            return 4
        # A sweep that finished with source errors is a PARTIAL sweep: a failed Intercom
        # search yields zero threads, which looks exactly like "nobody is waiting", so a
        # fresh timestamp over it would silently drop every thread-based class.
        errored = [m for m in ("paying", "churned") if int((runs[m] or {}).get("errors") or 0) > 0]
        if errored and not args.allow_errored_store:
            for mode in errored:
                run = runs[mode] or {}
                print(f"risk: the {mode} sweep finished with {run.get('errors')} source error(s) "
                      f"({run.get('note') or 'no detail'}); not writing a risk file. A partial sweep is "
                      f"indistinguishable from 'nobody is waiting'; rerun it, or pass "
                      f"--allow-errored-store when the failed sources cannot change who is on the list.",
                      file=sys.stderr)
            return 5
        doc = build(store, policy, policy_path=args.policy)
    finally:
        store.close()

    doc["policy"]["sha256"] = policy_digest(args.policy)
    doc["store_age_hours"] = round(ages["paying"], 2)
    doc["churned_store_age_hours"] = round(ages["churned"], 2)
    if not args.dry_run:
        write_atomic(doc, out_path)
    if args.json:
        print(json.dumps(doc["counts"], sort_keys=True))
    else:
        c = doc["counts"]
        # no em dash here on purpose: this line is grepped by the tests and the cron log
        print(f"risk: {c['risk_users']} paying users waiting on us (${c['mrr_risk']} list MRR), "
              f"{c['churned']} churned-with-issue still paid-priority; kinds={c['by_kind']} "
              f"tiers={c['by_tier']}"
              + (" (dry-run: nothing written)" if args.dry_run else f" -> {out_path}"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
