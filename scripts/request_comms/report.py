#!/usr/bin/env python3
"""`request-comms report`: is the promise being kept? Measured, never asserted.

Two numbers matter and both come from the ledger's own rows, not from a log grep:

  time-to-first-message   first_seen -> first `sent` for a request (p50 / p90 per type)
  max gap between messages the largest stretch a user heard nothing while their request was open

Plus the two honesty counters: **breaches** (an open request waiting on US with nothing sent for
more than the captain's 24 h) and the **48 h floor** (nothing sent for more than 48 h — the
number we actually promise). Breaches are counted from `observed` rows even while the driver is
still dark, so the report shows the size of the problem before anything is switched on.

`max_per_user_per_day` proves the one-message-per-user-per-day cap from the send rows: if it
ever reads above 1, the cap is broken and the report says so instead of quietly averaging.
"""
from __future__ import annotations

import json
import os
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

from . import routing
from .sources import Request
from .store import Store, iso, rows_to_dicts


def _pct(xs: list[float], p: float) -> float | None:
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    if len(xs) == 1:
        return round(float(xs[0]), 2)
    k = max(0, min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1)))))
    return round(float(xs[k]), 2)


def _first_seen(rows: Iterable[dict[str, Any]]) -> dict[str, str]:
    """request_ref -> the earliest timestamp we have for it (an `observed` row's created_at wins)."""
    out: dict[str, str] = {}
    for r in rows:
        ref = str(r["request_ref"])
        cand = str((r.get("detail") or {}).get("created_at") or r["at"])
        if ref not in out or cand < out[ref]:
            out[ref] = cand
    return out


def build(store_path: str, *, days: int = 7, now: float | None = None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc).timestamp()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    # A MISSING ledger is not an EMPTY one. `Store()` creates the file and its parent, so pointing
    # `report` at a deleted or mistyped path used to return zero rows, `chain_intact: true`, no
    # problems and exit 0 — a clean bill of health for evidence that is gone. Refuse instead: the
    # report's whole job is to prove the promise from the ledger, and it cannot prove anything from
    # a file it just made.
    missing = store_path != ":memory:" and not os.path.exists(store_path)
    if missing:
        all_rows: list[dict[str, Any]] = []
        sent = capped = observed = held = would = []
        chain: list[int] = []
    else:
        s = Store(store_path)
        try:
            all_rows = rows_to_dicts(s.rows())
            sent = [r for r in all_rows if r["outcome"] == "sent" and str(r["at"]) >= since]
            # The CAP proof answers a different question from "how many messages did we confirm".
            # The live counter (`Store.sent_today`) counts `sent` AND `uncertain`, because an
            # uncertain provider answer may have delivered and the honest reading of "how many
            # messages did this person get today" includes it. Proving the cap from `sent` alone
            # under-counts: one uncertain credit update plus one sent claim update for the same
            # person on one UTC day read as 1 with no problem reported, while two may have arrived.
            capped = [r for r in all_rows
                      if r["outcome"] in ("sent", "uncertain") and str(r["at"]) >= since]
            observed = [r for r in all_rows if r["outcome"] == "observed" and str(r["at"]) >= since]
            held = [r for r in all_rows if r["outcome"] == "held" and str(r["at"]) >= since]
            would = [r for r in all_rows if r["outcome"] == "would_send" and str(r["at"]) >= since]
            chain = s.verify()
        finally:
            s.close()

    first_seen = _first_seen([r for r in all_rows if str(r["at"]) >= since] or all_rows)
    types = sorted({str(r["request_type"]) for r in all_rows} | set(routing.__dict__.get("OTHER_SENDER", {}) or {})
                   | {"credit", "claim", "merge", "erasure", "refund"})
    # `chain_intact` is a claim about a chain we READ. With no ledger there is no chain to call
    # intact, so it is False, not vacuously True.
    out: dict[str, Any] = {"window_days": days, "ledger_rows": len(all_rows),
                           "chain_intact": not chain and not missing,
                           "chain_broken_ids": chain[:10], "types": {}, "problems": []}
    if missing:
        out["missing_ledger"] = True
        out["problems"].append(
            f"no ledger at {store_path}: nothing to measure (a missing ledger is not an empty one)")

    per_type: dict[str, dict[str, Any]] = {}
    for typ in types:
        rows = [r for r in all_rows if str(r["request_type"]) == typ and str(r["at"]) >= since]
        t_sent = [r for r in rows if r["outcome"] == "sent"]
        # Only a WHOLE-request stop retires the promise. A stop on one state says nothing about the
        # next one, so a partially stopped request is still owed its 48 h floor and still belongs in
        # the breach counts (the driver reminds it; the report has to measure it).
        stopped_refs = {str(r["request_ref"]) for r in all_rows
                        if r["outcome"] == "stopped" and not str(r["state"] or "")}
        by_ref: dict[str, list[float]] = defaultdict(list)
        for r in t_sent:
            at = iso(str(r["at"]))
            if at:
                by_ref[str(r["request_ref"])].append(at.timestamp())
        ttfm: list[float] = []
        for ref, times in by_ref.items():
            start = iso(first_seen.get(ref, ""))
            if start:
                ttfm.append(max(0.0, (min(times) - start.timestamp()) / 3600.0))
        # The FLOOR is a per-request promise, so the headline stat must be per request too: pooling
        # every interval lets one 49 h lapse hide among a thousand 1 h ones and report a p90 of 1 h
        # while every request in the sample breached.
        gaps: list[float] = []          # every interval (kept for the mean and the tail)
        max_gaps: list[float] = []      # one number per request: how long THAT request went quiet
        for ref, times in by_ref.items():
            times.sort()
            per = [(b - a) / 3600.0 for a, b in zip(times, times[1:])]
            gaps.extend(per)
            if per:
                max_gaps.append(max(per))
        # Silence right now, per open request we can still see.
        silence: list[float] = []
        breach = {"target": 0, "floor": 0}
        last_obs: dict[str, dict[str, Any]] = {}
        for r in rows:
            last_obs[str(r["request_ref"])] = r
        last_told: dict[str, str] = {}
        for r in t_sent:
            last_told[str(r["request_ref"])] = max(last_told.get(str(r["request_ref"]), ""), str(r["at"]))
        # A human `stop` retires the 48 h promise for that request: counting it as a breach would
        # page forever about a silence an operator asked for. It is still visible below as `stopped`.
        for ref, r in last_obs.items():
            if ref in stopped_refs:
                continue
            if str(r["outcome"]) == "held" and str(r.get("line_key", "")).startswith("other_sender"):
                continue
            # The FIRST time we saw this request, never the latest row's detail: a later `held` row
            # carries no `created_at`, and reading one there made an unsent, held request look like
            # a request with no silence to measure (silent=None, breach=0) — the report would claim
            # the 48 h floor was met while the person heard nothing for days.
            req = Request(typ, ref.split(":", 1)[-1], str(r["user_id"]), str(r["state"]),
                          str(r["waiting_on"] or "us"),
                          str(first_seen.get(ref) or (r.get("detail") or {}).get("created_at") or ""),
                          "", str(r["state"]) == "decided")
            told_at = last_told.get(ref, "")
            start = iso(told_at or req.created_at)
            # A `decided` request is TERMINAL: it is no longer owed updates, so its age is not
            # silence. Counting it let a claim closed and messaged 24 h ago report
            # `silent_now_hours_max: 24.0` with no open claims at all, and dominate the headline
            # with a number that implies an open request went quiet. `routing.breach` already
            # excludes terminal rows; this is the same rule for the silence stat.
            if start and not req.terminal:
                silence.append(max(0.0, (now - start.timestamp()) / 3600.0))
            kind = routing.breach(req, last_told_at=told_at, now=now)
            if kind:
                breach[kind] += 1
        per_type[typ] = {
            "requests": len({str(r["request_ref"]) for r in rows}),
            "messages": len(t_sent),
            "would_send": len([r for r in rows if r["outcome"] == "would_send"]),
            "held": len([r for r in rows if r["outcome"] == "held"]),
            "stopped": len({str(r["request_ref"]) for r in rows if r["outcome"] == "stopped"}),
            "ttfm_hours_p50": _pct(ttfm, 50), "ttfm_hours_p90": _pct(ttfm, 90),
            # `max_gap_hours_*` is over each request's maximum gap (the promise); the interval
            # distribution stays available as `interval_hours_p*`.
            "max_gap_hours_p50": _pct(max_gaps, 50), "max_gap_hours_p90": _pct(max_gaps, 90),
            "max_gap_hours_worst": round(max(max_gaps), 1) if max_gaps else None,
            "interval_hours_p50": _pct(gaps, 50), "interval_hours_p90": _pct(gaps, 90),
            "silent_now_hours_max": round(max(silence), 1) if silence else None,
            "breach_over_24h": breach["target"] + breach["floor"], "breach_over_48h": breach["floor"],
        }
    out["types"] = per_type

    # One SEND, not one ledger row: a digest writes a row per member (the "we told them" bookkeeping
    # has to cover every request in it), so counting rows reported a two-request digest as two
    # messages and a false breach of the one-per-user-per-day cap.
    per_user_day: dict[tuple[str, str], set[str]] = defaultdict(set)
    for r in capped:
        # The provider's own message id is the event when we have it (every digest member carries
        # the same one). A provider timeout answers `uncertain` with NO message id, so the driver
        # also records the idempotency key it used — the message EVENT — on every member. Without
        # that fallback one two-request digest read as two messages and reported a false cap
        # breach. Only a row with neither is its own event.
        d = r.get("detail") or {}
        ev = str(d.get("provider_ref") or d.get("event_id") or "")
        # The cap is per PERSON, so the proof has to normalise the way the cap does: an
        # erasure row keyed by `A@Example.com` and a credit row for the same account are one
        # person, and a raw-id key reports two.
        uid = str(r["user_id"] or "")
        cap = f"email:{uid.lower()}" if "@" in uid else uid
        per_user_day[(cap, str(r["at"])[:10])].add(ev or f"row:{r.get('id')}")
    out["max_per_user_per_day"] = max((len(v) for v in per_user_day.values()), default=0)
    if out["max_per_user_per_day"] > 1:
        out["problems"].append("the one-message-per-user-per-day cap was exceeded (see sent rows)")
    if chain:
        out["problems"].append(f"ledger sha256 chain is broken at ids {chain[:5]}")

    reasons: dict[str, int] = defaultdict(int)
    for r in held:
        reasons[str(r.get("line_key") or "?")] += 1
    out["held_reasons"] = dict(sorted(reasons.items(), key=lambda kv: -kv[1]))
    out["pending_would_send"] = len({str(r["request_ref"]) for r in would})
    out["observed_requests"] = len({str(r["request_ref"]) for r in observed})
    return out


def render(got: dict[str, Any]) -> str:
    ln = [f"request-comms report — last {got['window_days']} d "
          f"({got['ledger_rows']} ledger rows, chain {'intact' if got['chain_intact'] else 'BROKEN'})", ""]
    hdr = (f"{'type':8} {'open':>5} {'sent':>5} {'dry':>4} {'held':>5} "
           f"{'ttfm p50':>9} {'ttfm p90':>9} {'gap p50':>8} {'gap p90':>8} {'silent':>7} {'>24h':>5} {'>48h':>5}")
    ln.append(hdr)
    ln.append("-" * len(hdr))
    for typ, m in got["types"].items():
        def f(v: Any) -> str:
            return "-" if v is None else f"{v:g}"
        ln.append(f"{typ:8} {m['requests']:5d} {m['messages']:5d} {m['would_send']:4d} {m['held']:5d} "
                  f"{f(m['ttfm_hours_p50']):>9} {f(m['ttfm_hours_p90']):>9} {f(m['max_gap_hours_p50']):>8} "
                  f"{f(m['max_gap_hours_p90']):>8} {f(m['silent_now_hours_max']):>7} "
                  f"{m['breach_over_24h']:5d} {m['breach_over_48h']:5d}")
    ln += ["", f"messages per user per day (max): {got['max_per_user_per_day']} (cap is 1)",
           f"requests with a pending would-send: {got['pending_would_send']}",
           f"observed requests in window: {got['observed_requests']}"]
    if got["held_reasons"]:
        ln.append("held, by reason:")
        ln += [f"  {k}: {v}" for k, v in list(got["held_reasons"].items())[:12]]
    if got["problems"]:
        ln += ["", "PROBLEMS:"] + [f"  - {p}" for p in got["problems"]]
    return "\n".join(ln)


def render_tick(summary: dict[str, Any]) -> str:
    c = summary.get("counts") or {}
    ln = [f"request-comms tick {summary['at']} — {summary['mode']}",
          "sources: " + ", ".join(
              f"{s['name']}={s['status']}({s['count']}"
              + (f", {s['stale_open']} open outside the {summary.get('open_days', 30)} d window"
                 if s.get("stale_open", -1) >= 0 else "")
              + ")" for s in summary.get("sources", [])),
          f"requests={c.get('requests', 0)} due={c.get('due', 0)} planned={c.get('planned', 0)} "
          f"sent={c.get('sent', 0)} would_send={c.get('would_send', 0)} held_new={c.get('held_new', 0)} "
          f"observed_new={c.get('observed_new', 0)}"]
    br = c.get("breaches") or {}
    ln.append(f"breaches: over_24h={br.get('target', 0)} over_48h={br.get('floor', 0)}")
    for d in summary.get("disabled_sources") or []:
        ln.append(f"lane off (by design, not a failure): {d['name']} — {d['reason']}")
    for e in summary.get("would_send", [])[:10]:
        ln.append(f"  would send {e['line']} on {e['channel']} for {e['request']}")
    for e in summary.get("sent", [])[:20]:
        ln.append(f"  {e.get('status')} {e['line']} on {e['channel']} for {e['request']}"
                  + (f" ({e['reason']})" if e.get("reason") else ""))
    for p in summary.get("problems", []):
        ln.append(f"PROBLEM: {p}")
    return "\n".join(ln)


def write_snapshot(summary: dict[str, Any], report_dir: str) -> str:
    """Keep the machine copy of every tick (the timer's journal is not a data source)."""
    try:
        os.makedirs(report_dir, mode=0o700, exist_ok=True)
        path = os.path.join(report_dir, f"tick-{str(summary.get('at') or 'unknown').replace(':', '')}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2, sort_keys=True)
        return path
    except OSError:
        return ""
