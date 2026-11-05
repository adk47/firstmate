#!/usr/bin/env python3
"""cancel_alert.py: find the cancellations that had an open support issue, and say
who to route them to. Run hourly by scripts/churn/cancel_with_open_issue.sh.

Two moments are watched, because they are different chances to save the user:

  cancel       the subscription went to cancelled since the last watermark
               (core replica, status='cancelled')
  request      a live subscription has autoRenew=false, i.e. the customer asked to
               cancel and the period has not ended yet (Stripe's
               `customer.subscription.updated` / cancel_at_period_end=true, which
               the billing webhook writes into the replica; up to ~23 days of
               runway in which a fix can still land)

Then it joins them to the risk state, the spec's item 4:

    paying user cancelled with an open {class} issue ({age} d, ${mrr}): route -> {lane}

The join order, most to least authoritative:
  1. the support-state store row (the nightly sweep's measurement)
  2. risk.json (the published artifact, if the store row was dropped)
  3. an on-demand classification (bounded by alert.on_demand_max per run), so a
     cancel that lands before the next nightly sweep is not invisible

A candidate that could NOT be classified (the join raised, the Intercom read failed
and returned nothing, or the on-demand budget was spent) is reported as
`unclassified`, never as "no open issue": `commit` then
stops the watermark at the oldest such event, so the next run reads it again
instead of advancing past a page nobody sent.

A `customer_service` / `low_quality` cancel survey on a risk-flagged user pages
IMMEDIATELY (it is the customer telling us support is why they left, in their own
words). A survey on a user we do NOT flag is logged, not paged: the page exists to
route work, and there is no work to route.

Dedup is per user for alert.dedup_days, so the request page and the cancel page are
one page, and a re-subscribe-then-cancel does not re-page the same stale issue.

This module NEVER contacts the customer. It pages the ops channel and writes the
lane's intake row; that is all.

Usage:
    cancel_alert.py --alerts             JSON on stdout: {watermark, alerts[], skipped[]}
    cancel_alert.py --commit FILE        record watermark + sent + intake after the posts
    cancel_alert.py --status             what it would do, without touching anything
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from churn import risk_reader, sources as src_mod, stages   # noqa: E402
from churn.store import Store, utcnow                       # noqa: E402

POLICY = str(Path(__file__).resolve().parents[2] / "policies" / "churn-risk.json")
ALERT_KINDS = {"customer_last", "promise_no_followup", "request_pending", "proof_no_update"}
DEFAULT_SURVEY = ("customer_service", "low_quality")
# a cancel followed by nothing for this long is not news any more; a watermark older
# than this is treated as "start from here" so the first run of a new install does
# not page a month of history
COLD_START_HOURS = 6.0


class ClassifyFailed(RuntimeError):
    """One candidate could not be classified: not the same answer as "no open issue"."""


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}] {msg}", file=sys.stderr, flush=True)


def load_policy(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"policy {path} unreadable: {exc}")
    if not isinstance(doc, dict):
        raise SystemExit(f"{path} is not a JSON object")
    return doc


def store_paths(policy: dict[str, Any]) -> dict[str, str]:
    st = policy.get("store") or {}
    base = st.get("dir") or "/var/lib/hydra/churn"
    return {
        "support_state": st.get("support_state") or f"{base}/support-state.sqlite",
        "risk": st.get("risk") or f"{base}/risk.json",
        "intake": st.get("intake") or f"{base}/intake.jsonl",
        "watermark": st.get("cancel_watermark") or f"{base}/cancel-alert.watermark",
        "sent": st.get("cancel_sent") or f"{base}/cancel-alert.sent.json",
    }


def read_json_file(path: str, default: Any) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_watermark(path: str, now: float) -> float:
    try:
        text = Path(path).read_text(encoding="utf-8").strip()
        ts = stages.iso_to_ts(text)
    except OSError:
        ts = 0.0
    if not ts or (now - ts) > 30 * stages.DAY:
        return now - COLD_START_HOURS * 3600
    return ts


def sent_rows(path: str) -> dict[str, str]:
    doc = read_json_file(path, {})
    if not isinstance(doc, dict):
        return {}
    return {str(k): str(v) for k, v in doc.items() if v}


def within_dedup(sent: dict[str, str], user_id: int, now: float, dedup_days: float) -> bool:
    at = stages.iso_to_ts(sent.get(str(user_id)))
    return bool(at) and (now - at) / stages.DAY < dedup_days


def intake_seen(path: str) -> set[tuple[str, str]]:
    out: set[tuple[str, str]] = set()
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get("user_id") is not None:
                    out.add((str(row.get("user_id")), str(row.get("tag") or "")))
    except OSError:
        pass
    return out


def gauge(store: Store | None, risk: risk_reader.Risk, uid: int) -> dict[str, Any] | None:
    """The open issue for this user, from wherever the freshest answer lives."""
    if store is not None:
        try:
            row = store.user(uid)
        except Exception:  # noqa: BLE001
            row = None
        if row:
            kinds = set(row.get("kinds") or [])
            if row.get("tier") and (kinds & ALERT_KINDS):
                return {"source": "store", "tier": row.get("tier"),
                        "class": row.get("cause_class") or "other",
                        "kind": sorted(kinds & ALERT_KINDS),
                        "age_days": round(float(row.get("ball_days") or 0), 2),
                        "mrr_list": float(row.get("mrr_list") or 0),
                        "renews_at": row.get("renews_at"),
                        "lane": risk.lane(uid), "conv_ids": row.get("intercom_conv_ids") or [],
                        "evidence": row.get("evidence_json") or []}
            # a store row with no open issue is NOT a veto: risk.json is published from a
            # whole sweep and can be fresher than a row written by a narrower run
    row = risk.row(uid) or risk.churned_row(uid)
    if row:
        return {"source": "risk.json", "tier": row.get("tier"), "class": row.get("class") or "other",
                "kind": row.get("kind") or [], "age_days": float(row.get("age_days") or 0),
                "mrr_list": float(row.get("mrr_list") or 0), "renews_at": row.get("renews_at"),
                "lane": row.get("lane"), "conv_ids": row.get("conv_ids") or [],
                "evidence": row.get("evidence") or []}
    return None


def lane_for(policy: dict[str, Any], cause: str, risk: risk_reader.Risk, uid: int) -> str:
    table = {k: v for k, v in (policy.get("lanes") or {}).items() if isinstance(v, str)}
    return risk.lane(uid) or table.get(cause) or table.get("other") or "caroline-backlog"


def text_for(policy: dict[str, Any], gauge_row: dict[str, Any], uid: int, kind: str,
             survey: str | None) -> str:
    tmpl = ((policy.get("slack") or {}).get("alert_line")
            or "paying user cancelled with an open {class} issue ({age}d, ${mrr}): route -> {lane} "
               "(user {user_id}, {tier}{extra})")
    extra = ""
    if kind == "request":
        extra = ", cancel scheduled"
    if survey:
        extra += f", survey={survey}"
    return tmpl.format(**{"class": gauge_row["class"]},
                       age=f"{gauge_row['age_days']:.0f}",
                       mrr=f"{gauge_row['mrr_list']:.2f}",
                       lane=gauge_row["lane"], user_id=uid,
                       tier=gauge_row.get("tier") or "T?", extra=extra)


def read_tick_tasks(src: src_mod.Sources, *, enabled: bool = True) -> dict[str, Any]:
    """The open ClickUp intake list, read ONCE for this tick.

    The on-demand path may classify up to `alert.on_demand_max` cancellers per hour, and
    the intake list is ~14,100 tasks / ~141 pages: reading it per canceller is exactly
    the fleet walk the typed contact lookup removed. Reading it once per tick and
    matching each canceller against that snapshot keeps ClickUp-only tickets visible
    (they are ~134 of the measured churned-with-issue users) at one walk per hour.

    A FAILED read returns ok=False and is never silently treated as "no open task":
    callers record the reason instead of answering "no open issue" (firstmate
    2026-11-04, key nm-review5-clickup-on-demand).
    """
    if not enabled:
        return {"ok": False, "why": "clickup reads are disabled for this run", "tasks": []}
    try:
        return {"ok": True, "tasks": src.clickup_tasks()}
    except Exception as exc:  # noqa: BLE001
        why = f"{type(exc).__name__}: {exc}"
        src.errors.append(f"clickup intake read failed ({why})")
        log(f"clickup intake read failed ({why}); on-demand classification cannot see tickets")
        return {"ok": False, "why": why, "tasks": []}


def collect(*, policy: dict[str, Any], now: float | None = None, on_demand: bool = True,
            sources: src_mod.Sources | None = None, store: Store | None = None,
            clickup: bool = True) -> dict[str, Any]:
    """Everything the shell wrapper needs, and nothing written."""
    now = now if now is not None else time.time()
    paths = store_paths(policy)
    th = stages.Thresholds.from_policy(policy)
    alert_cfg = policy.get("alert") or {}
    dedup_days = float(alert_cfg.get("dedup_days", 30))
    on_demand_max = int(alert_cfg.get("on_demand_max", 25))
    surveys = tuple((policy.get("survey_immediate") or DEFAULT_SURVEY))

    watermark = read_watermark(paths["watermark"], now)
    sent = sent_rows(paths["sent"])
    # the caller's policy names the risk file; never fall back to the process default
    # path here (the 2026-11-04 canary ran the alert against the wrong path exactly this way)
    risk = risk_reader.default(policy=policy, path=paths["risk"])
    src = sources or src_mod.Sources()
    own_store = store is None
    st = store
    if st is None:
        try:
            st = Store(paths["support_state"], readonly=True)
        except Exception as exc:  # noqa: BLE001
            log(f"store unreadable ({exc}); falling back to risk.json only")
            st = None

    alerts: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    unclassified: list[dict[str, Any]] = []
    resume_at = 0.0        # the oldest event we could not decide: the watermark stops here
    on_demand_used = 0
    try:
        events: list[tuple[str, dict[str, Any]]] = []
        try:
            for row in src.cancelled_since(watermark):
                events.append(("cancel", row))
        except src_mod.SourceError as exc:
            log(f"cancelled read failed: {exc}")
            raise
        try:
            for row in src.cancel_requests():
                events.append(("request", row))
        except src_mod.SourceError as exc:
            log(f"cancel-request read failed ({exc}); continuing with cancels only")
            src.errors.append(str(exc))

        # one ClickUp walk per tick, not per canceller, and only if one is needed
        tick_tasks: dict[str, Any] | None = None

        seen: set[int] = set()
        for kind, row in events:
            uid = int(row["user_id"])
            if uid in seen:
                continue
            seen.add(uid)
            if within_dedup(sent, uid, now, dedup_days):
                skipped.append({"user_id": uid, "why": "already paged inside the dedup window"})
                continue
            g = gauge(st, risk, uid)
            failed: str | None = None
            if g is None and on_demand:
                if on_demand_used >= on_demand_max:
                    failed = f"on-demand budget spent ({on_demand_max} this run)"
                else:
                    on_demand_used += 1
                    if tick_tasks is None:
                        tick_tasks = read_tick_tasks(src, enabled=clickup)
                    try:
                        g = classify_on_demand(uid, policy, th, sources=src,
                                               tick_tasks=tick_tasks, plan=row.get("plan"))
                    except ClassifyFailed as exc:
                        failed = str(exc)
            if g is None:
                if failed:
                    log(f"{kind} for user {uid} could not be classified: {failed}")
                    unclassified.append({"user_id": uid, "event": kind, "why": failed})
                    at = stages.iso_to_ts(row.get("cancelled_at") or row.get("requested_at"))
                    if kind == "cancel" and at:
                        resume_at = at if not resume_at else min(resume_at, at)
                else:
                    skipped.append({"user_id": uid, "why": f"no open issue ({kind})"})
                continue
            survey_raw = str(row.get("feedback") or "").strip().lower()
            survey = survey_raw if survey_raw in surveys else None
            if survey and not survey_raw:
                survey = None
            g["lane"] = lane_for(policy, g["class"], risk, uid)
            alerts.append({
                "user_id": uid, "event": kind, "class": g["class"], "tier": g.get("tier"),
                "age_days": g.get("age_days"), "mrr_list": g.get("mrr_list"),
                "renews_at": g.get("renews_at"), "lane": g["lane"], "survey": survey,
                "issue_source": g.get("source"), "kinds": g.get("kind") or [],
                "evidence": (g.get("evidence") or [])[:3],
                "plan": row.get("plan"), "service": row.get("service") or None,
                "cancel_reason": row.get("reason") or None,
                "cancelled_at": row.get("cancelled_at") or row.get("requested_at") or None,
                "text": text_for(policy, g, uid, kind, survey),
                "tag": f"churned:{datetime.fromtimestamp(now, tz=timezone.utc).strftime('%Y-%m-%d')}",
            })
    finally:
        if own_store and st is not None:
            st.close()

    # a survey page first (it is the customer saying why in their own words), then
    # the biggest list MRR, so a $49 Business cancel is triaged before a $12.50 one
    alerts.sort(key=lambda a: (a["survey"] is None, -(a["mrr_list"] or 0)))
    # everything up to resume_at was decided; the unclassified events before `now` were not,
    # so the next run starts there (their already-posted neighbours are deduped by `sent`)
    watermark_out = min(now, resume_at) if resume_at else now
    return {"watermark": datetime.fromtimestamp(watermark, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "watermark_out": datetime.fromtimestamp(watermark_out, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "now": datetime.fromtimestamp(now, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "alerts": alerts, "skipped": skipped[:50], "unclassified": unclassified,
            "on_demand_used": on_demand_used,
            "risk_applies": risk.applies(), "risk_why": risk.why,
            "errors": list(src.errors)}


def classify_on_demand(uid: int, policy: dict[str, Any], t: stages.Thresholds, *,
                       sources: src_mod.Sources | None = None,
                       ic: Any = None,
                       tick_tasks: dict[str, Any] | None = None,
                       plan: str | None = None) -> dict[str, Any] | None:
    """Classify one canceller the nightly sweep has not seen (bounded per run).

    Returns None only for a real "no open issue"; every failure it can see raises
    ClassifyFailed, because the caller must not record a failure as a clean answer. An
    Intercom read that errored and came back with no thread at all is one of those
    failures: intercom.py records transport errors on the client instead of raising, so
    "nothing is waiting" and "we read nothing" would otherwise be the same row.
    """
    try:
        from churn import intercom as ic_mod, support_state
    except Exception as exc:  # noqa: BLE001
        raise ClassifyFailed(f"the churn modules are unimportable ({exc})") from exc
    try:
        store = Store(store_paths(policy)["support_state"], readonly=True)
    except Exception as exc:  # noqa: BLE001
        raise ClassifyFailed(f"support store unreadable ({exc})") from exc
    if ic is None:
        try:
            ic = ic_mod.Intercom(workers=4, max_seconds=90, conv_budget=40)
        except Exception as exc:  # noqa: BLE001
            log(f"on-demand {uid}: no Intercom ({exc}); replica-only classification")
    try:
        row = support_state.sweep_user(uid=uid, store=store,
                                       sources=sources or src_mod.Sources(), ic=ic,
                                       t=t, now=time.time(), policy=policy, write=False,
                                       tick_tasks=tick_tasks, plan=plan)
    except Exception as exc:  # noqa: BLE001
        raise ClassifyFailed(f"classification failed ({exc})") from exc
    finally:
        store.close()
    read = row.get("intercom") or {}
    if read.get("errors") and not read.get("threads"):
        raise ClassifyFailed("the Intercom read failed and returned no thread at all "
                            f"({read['errors'][0]})")
    clickup = str(row.get("clickup") or "")
    if clickup not in ("read", "not-read"):
        # a ClickUp-only ticket is ~40% of the measured churned-with-issue users, so a
        # read we could not perform must not render as "no open issue" (a clean answer)
        raise ClassifyFailed(f"the ClickUp intake list could not be read ({clickup})")
    kinds = set(row.get("kinds") or [])
    if not row.get("tier") or not (kinds & ALERT_KINDS):
        return None
    return {"source": "on-demand", "tier": row.get("tier"), "class": row.get("cause_class") or "other",
            "kind": sorted(kinds & ALERT_KINDS), "age_days": float(row.get("ball_days") or 0),
            "mrr_list": float(row.get("mrr_list") or 0), "renews_at": row.get("renews_at"),
            "lane": None, "conv_ids": row.get("intercom_conv_ids") or [],
            "evidence": row.get("evidence") or []}


def commit(paths: dict[str, str], doc: dict[str, Any]) -> dict[str, Any]:
    """Record the watermark, the per-user sent rows, and the lane intake rows.

    Called by the wrapper ONLY after every post for this run confirmed delivery, so
    a Slack failure re-tries next hour instead of silently swallowing the page.
    """
    alerts = doc.get("alerts") or []
    written = 0
    Path(paths["intake"]).parent.mkdir(parents=True, exist_ok=True)
    seen = intake_seen(paths["intake"]) if alerts else set()
    with open(paths["intake"], "a", encoding="utf-8") as fh:
        for a in alerts:
            key = (str(a["user_id"]), str(a["tag"]))
            if key in seen:
                continue
            seen.add(key)
            fh.write(json.dumps({"at": utcnow(), "user_id": a["user_id"], "lane": a["lane"],
                                 "tag": a["tag"], "class": a["class"], "tier": a.get("tier"),
                                 "age_days": a.get("age_days"), "mrr_list": a.get("mrr_list"),
                                 "renews_at": a.get("renews_at"), "event": a.get("event"),
                                 "survey": a.get("survey"), "text": a.get("text")},
                                sort_keys=True) + "\n")
            written += 1
    sent = sent_rows(paths["sent"])
    for a in alerts:
        sent[str(a["user_id"])] = doc.get("now") or utcnow()
    try:
        doc_dir = Path(paths["sent"]).parent
        doc_dir.mkdir(parents=True, exist_ok=True)
        tmp = str(doc_dir / f".sent.json.tmp.{os.getpid()}")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(sent, fh, indent=0, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, paths["sent"])
        wm = doc.get("watermark_out") or doc.get("now") or utcnow()
        Path(paths["watermark"]).write_text(wm + "\n", encoding="utf-8")
    except OSError as exc:
        log(f"could not record the watermark/sent rows: {exc}")
        return {"intake_rows": written, "sent": len(sent), "error": str(exc)}
    return {"intake_rows": written, "sent": len(sent)}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="cancellations that had an open support issue")
    ap.add_argument("--policy", default=POLICY)
    ap.add_argument("--alerts", action="store_true", help="print the alerts as JSON (writes nothing)")
    ap.add_argument("--commit", metavar="FILE", help="record the run after the posts succeeded")
    ap.add_argument("--status", action="store_true", help="summarize without paging")
    ap.add_argument("--no-on-demand", action="store_true")
    ap.add_argument("--no-clickup", action="store_true",
                    help="do not read the ClickUp intake list for on-demand classification")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    policy = load_policy(args.policy)

    if args.commit:
        try:
            with open(args.commit, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            print(f"cancel_alert: cannot read {args.commit}: {exc}", file=sys.stderr)
            return 2
        out = commit(store_paths(policy), doc)
        print(json.dumps(out, sort_keys=True))
        return 0 if not out.get("error") else 1

    doc = collect(policy=policy, on_demand=not args.no_on_demand,
                  clickup=not args.no_clickup)
    if args.status:
        print(json.dumps({k: doc[k] for k in ("watermark", "watermark_out", "now", "risk_applies",
                                             "risk_why", "errors")}
                         | {"alerts": len(doc["alerts"]), "skipped": len(doc["skipped"]),
                            "unclassified": len(doc["unclassified"])},
                         indent=1, sort_keys=True))
        return 0
    print(json.dumps(doc, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
