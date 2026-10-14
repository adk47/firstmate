"""Orchestration for the auditor, the reviewer, the digest and the metrics."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from . import admin as admin_api
from .evidence import Evidence, EvidenceBuilder, parse_ts
from .judge import PROMPT_VERSION, Judge, JudgeResult
from .ledger import Ledger
from .policy import (
    A_CONTRADICTED,
    A_SUSPECT,
    R_HUMAN,
    R_REJECT,
    Decision,
    approver_identity_alert,
    combine,
    deterministic,
)

REQUEST_URL = "https://credits.muso.ai/credit-request/{id}"
# The audit window reaches back to the previous successful run minus this
# overlap, so runs that failed (admin API down) leave no unaudited gap.
AUDIT_OVERLAP = timedelta(minutes=15)
# A gap older than this (kill switch or outage for days) is alerted, not
# scanned, so one run stays small enough to finish inside the cron timeout.
AUDIT_MAX_LOOKBACK = timedelta(hours=24)
AUDIT_CHUNK = 100
# Wall-clock budget for one audit run, well inside the cron's 2400s timeout:
# no new chunk starts after it, so alerts are always printed.
AUDIT_DEADLINE_S = 1800.0


# Operational log. The crons are openclaw command crons, which post stdout AND
# stderr to Slack ("stdout: NO_REPLY / stderr: [credit-review] ..." on
# 2026-10-14), so a cron run must write nothing to stderr: a quiet run posts
# exactly NO_REPLY (silent), a run with something to act on posts only its
# alert lines. Progress goes to this file; stderr only on an interactive terminal.
LOG_PATH = os.environ.get("CREDIT_REVIEW_LOG", "/var/lib/hydra/credit-review/run.log")
LOG_MAX_BYTES = 5 * 1024 * 1024


def log(msg: str) -> bool:
    """Append msg to the run log; False when the log could not be written."""
    line = f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} [credit-review] {msg}"
    if sys.stderr.isatty():
        print(line, file=sys.stderr)
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        os.makedirs(os.path.dirname(LOG_PATH) or ".", exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        return False  # a log we cannot write never turns into Slack noise
    return True


def plain_line(value: Any) -> str:
    """Untrusted text (a profile name) as one plain line: control characters and
    line breaks become spaces, so it can never split or spoof an alert line."""
    return " ".join("".join(c if c.isprintable() else " " for c in str(value)).split())


def sampled(request_id: str, rate: float) -> bool:
    """Stable per-request sampling (same answer on every run)."""
    if rate >= 1.0:
        return True
    if rate <= 0.0:
        return False
    h = int(hashlib.sha256(request_id.encode()).hexdigest()[:8], 16)
    return (h / 0xFFFFFFFF) < rate


@dataclass
class RunStats:
    scanned: int = 0
    skipped_seen: int = 0
    reviewed: int = 0
    model_calls: int = 0
    cost_usd: float = 0.0
    verdicts: dict[str, int] = field(default_factory=dict)
    big: int = 0
    errors: int = 0
    budget_stopped: bool = False
    max_call_cost: float = 0.0      # dearest single model call (seeded from the ledger)

    def charge(self, cost: float | None) -> None:
        c = float(cost or 0.0)
        self.model_calls += 1
        self.cost_usd += c
        self.max_call_cost = max(self.max_call_cost, c)

    def affordable_calls(self, budget: float, est_call_cost: float) -> int:
        """How many more model calls fit in `budget`, reserving the dearer of
        the configured per-call estimate and the dearest call seen this run."""
        per_call = max(est_call_cost, self.max_call_cost, 1e-9)
        left = budget - self.cost_usd
        if left <= 0:
            return 0
        return int(left // per_call)

    def bump(self, verdict: str) -> None:
        self.verdicts[verdict] = self.verdicts.get(verdict, 0) + 1

    def line(self) -> str:
        vs = " ".join(f"{k}={v}" for k, v in sorted(self.verdicts.items()))
        return (f"scanned={self.scanned} seen={self.skipped_seen} reviewed={self.reviewed} big={self.big} "
                f"model_calls={self.model_calls} cost_usd={self.cost_usd:.4f} errors={self.errors} "
                f"budget_stopped={self.budget_stopped} {vs}")


@dataclass
class Config:
    mode: str                       # audit | review
    phase: str = "live"             # audit: live ; review: shadow | advise
    sample_rate: float = 0.10       # non-big model-check rate (big = 100%)
    max_model_calls: int = 300
    budget_usd: float = 3.0
    web: bool = True
    model: str | None = None
    web_engine: str | None = None
    # Per-call reservation for budget checks before a call's real cost is
    # known. Measured grok-4.3 + web search: $0.022-0.033 per call.
    est_call_cost_usd: float = 0.05


def review_one(request: dict[str, Any], builder: EvidenceBuilder, judge: Judge | None, cfg: Config,
               stats: RunStats, *, force_model: bool = False,
               evidence_hook: Callable[[Evidence], None] | None = None) -> tuple[Evidence, Decision, JudgeResult | None]:
    ev = builder.build(request)
    if evidence_hook:
        evidence_hook(ev)
    base = deterministic(ev, cfg.mode)
    judged: JudgeResult | None = None
    want_model = base.needs_model and (force_model or ev.big_track or sampled(ev.request_id, cfg.sample_rate))
    if want_model and judge is not None:
        if (stats.model_calls >= cfg.max_model_calls
                or stats.affordable_calls(cfg.budget_usd, cfg.est_call_cost_usd) < 1):
            stats.budget_stopped = True
        else:
            judged = judge.judge(cfg.mode, ev.for_model())
            stats.charge(judged.cost_usd)
            if not judged.ok:
                stats.errors += 1
    decision = combine(ev, cfg.mode, judged)
    return ev, decision, judged


def record(ledger: Ledger, cfg: Config, ev: Evidence, d: Decision, j: JudgeResult | None,
           approver_alert: str | None = None, label: str | None = None, mode: str | None = None) -> int:
    return ledger.record({
        "request_id": ev.request_id, "mode": mode or cfg.mode, "phase": cfg.phase,
        "verdict": d.verdict, "confidence": d.confidence, "basis": d.basis, "big_track": ev.big_track,
        "profile_id": ev.profile_id, "track_id": ev.track_id, "track_title": ev.track_title,
        "claimed_roles": ev.claimed_roles, "spotify_popularity": ev.track_popularity,
        "approved_at": ev.approved_at, "status_at_review": ev.status, "approver_alert": approver_alert,
        "model": j.model if j else None, "cost_usd": j.cost_usd if j else None,
        "prompt_version": PROMPT_VERSION, "reasons_json": d.reasons,
        "evidence_json": ev.for_model() | {"deterministic": ev.deterministic_summary(), "errors": ev.errors,
                                           "claimant_domains": ev.claimant_domains,
                                           "claimant_names": ev.claimant_names},
        "judge_json": j.as_dict() if j else None, "label": label,
    })


def fetch_approved_window(admin: admin_api.Admin, since: datetime,
                          page_size: int = 200) -> list[dict[str, Any]]:
    """Approved requests whose updatedAt (≈ approval time) is after `since`.

    The list is updatedAt DESC, so every page back to `since` is read: a page
    cap would drop the OLDEST approvals of the window, which the next run's
    window no longer reaches (QA on hydra#1142). `since` is at most
    AUDIT_MAX_LOOKBACK back, which bounds the scan."""
    out: list[dict[str, Any]] = []
    page = 1
    while True:
        items = admin_api.list_requests(admin, status="approved", limit=page_size, page=page)
        for it in items:
            ts = parse_ts(it.get("updatedAt"))
            if ts is not None and ts >= since:
                out.append(it)
        last = parse_ts(items[-1].get("updatedAt")) if items else None
        if len(items) < page_size or (last is not None and last < since):
            return out
        page += 1


def one_line(ev: Evidence, d: Decision) -> str:
    who = ev.profile.name if ev.profile else ev.profile_id
    artists = ", ".join(ev.track_artists[:2])
    why = d.reasons[0] if d.reasons else d.basis
    return (f'"{ev.track_title}" ({artists}, pop {ev.track_popularity}) - {who} - '
            f'{"/".join(ev.claimed_roles)} - {why[:220]} - {REQUEST_URL.format(id=ev.request_id)}')


def _iso(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def _day_start(now: datetime) -> str:
    return now.strftime("%Y-%m-%dT00:00:00Z")


def run_audit(admin: admin_api.Admin, ledger: Ledger, judge: Judge | None, cfg: Config, *,
              window_min: int, now: datetime | None = None,
              daily_budget_usd: float | None = None, workers: int = 6,
              deadline_s: float = AUDIT_DEADLINE_S) -> tuple[list[str], RunStats]:
    """APPROVAL AUDITOR. Returns (alert lines for Slack, stats).

    The window reaches back to the previous successful run (minus an overlap),
    at most AUDIT_MAX_LOOKBACK; an older gap is alerted, never dropped
    silently. Approvals are processed oldest first in chunks of AUDIT_CHUNK.
    Per chunk, pass 1 builds catalog evidence (parallel, admin GETs only) and
    pass 2 sends the undecided big tracks to the model; every other row is
    recorded as soon as its chunk ends. Undecided non-big rows in the stable
    sample are judged only after every chunk, with what is left of the budget,
    so big tracks get the budget first across the whole run. Model calls stop
    at the per-run cap, the per-run budget, or what is left of the daily
    budget. No chunk starts unless the longest chunk so far still fits before
    ``deadline_s`` (well inside the cron timeout), and no model call starts
    after it (calls run one at a time), so the run returns and prints its
    alerts; an early stop advances ``audit_last_run`` only to the last finished chunk and alerts.
    A big track whose model check the deadline cut is not recorded (its
    chunk does not advance the watermark), so the next run checks it;
    sampled rows left unjudged for time are recorded and reported in a NOTE.
    """
    from concurrent.futures import ThreadPoolExecutor

    stop_at = time.monotonic() + deadline_s
    now = now or datetime.now(timezone.utc)
    since = now - timedelta(minutes=window_min)
    last_run = parse_ts(ledger.get_state("audit_last_run"))
    if last_run is not None and last_run - AUDIT_OVERLAP < since:
        since = last_run - AUDIT_OVERLAP
    alerts: list[str] = []
    floor = now - AUDIT_MAX_LOOKBACK
    if since < floor:
        gap_min = int((floor - since).total_seconds() // 60)
        alerts.append(f"CREDIT-AUDIT ALERT: {gap_min} minutes not audited - approvals updated between "
                      f"{_iso(since)} and {_iso(floor)} are older than the "
                      f"{int(AUDIT_MAX_LOOKBACK.total_seconds() // 3600)}h lookback (previous successful run "
                      f"{_iso(last_run) if last_run else 'never'}).")
        since = floor
    window_txt = f"{int((now - since).total_seconds() // 60)}m"
    stats = RunStats()
    stats.max_call_cost = ledger.dearest_call_since(_iso(now - timedelta(days=7)))
    rows = fetch_approved_window(admin, since)
    stats.scanned = len(rows)
    budget = cfg.budget_usd
    if daily_budget_usd is not None:
        spent_today, _ = ledger.cost_since(_day_start(now))
        budget = max(0.0, min(budget, daily_budget_usd - spent_today))
    builder = EvidenceBuilder(admin, now=now, prior_contradicted=ledger.contradicted_by_profile())
    todo = []
    queued: set[str] = set()
    # Approvals whose raw credits could not be read on an earlier run are
    # retried from their snapshot, even after they leave the window.
    for req in ledger.evidence_retries("audit"):
        rid = str(req.get("id"))
        if ledger.reviewed(rid, "audit"):
            ledger.clear_evidence_failure(rid, "audit")
            continue
        queued.add(rid)
        todo.append((req, None))
    for req in sorted(rows, key=lambda r: parse_ts(r.get("updatedAt"))):
        rid = str(req.get("id"))
        if ledger.reviewed(rid, "audit"):
            stats.skipped_seen += 1
            ledger.clear_evidence_failure(rid, "audit")
        elif rid not in queued:
            queued.add(rid)
            todo.append((req, parse_ts(req.get("updatedAt"))))

    def build(item):
        req, _ts = item
        try:
            return req, builder.build(req), None
        except admin_api.AdminError as exc:
            return req, None, str(exc)

    late = 0
    over_budget = 0

    def judge_batch(want: list[Evidence]) -> dict[str, JudgeResult]:
        # One model call in flight at a time: a call's cost is only known
        # after it returns, so each call is launched against the spend so far
        # and a run can overshoot its cap by at most one call (QA on
        # hydra#1142: parallel calls sized on an earlier cheap call overspent).
        nonlocal late, over_budget
        judged: dict[str, JudgeResult] = {}
        for i, ev in enumerate(want if judge is not None else []):
            if time.monotonic() >= stop_at:
                late += len(want) - i
                break
            if (stats.model_calls >= cfg.max_model_calls
                    or stats.affordable_calls(budget, cfg.est_call_cost_usd) < 1):
                stats.budget_stopped = True
                over_budget += len(want) - i
                break
            res = judge.judge(cfg.mode, ev.for_model())
            judged[ev.request_id] = res
            stats.charge(res.cost_usd)
            if not res.ok:
                stats.errors += 1
        return judged

    unknown_approvals: list[str] = []
    forbidden: list[str] = []
    evidence_failed: list[str] = []

    def finish(req: dict[str, Any], ev: Evidence, j: JudgeResult | None) -> None:
        rid = ev.request_id
        approver_alert = approver_identity_alert(req)
        d = combine(ev, cfg.mode, j)
        stats.reviewed += 1
        stats.big += 1 if ev.big_track else 0
        stats.bump(d.verdict)
        row_id = record(ledger, cfg, ev, d, j, approver_alert=approver_alert)
        ledger.clear_evidence_failure(rid, "audit")
        if approver_alert:
            (unknown_approvals if "validator declined" in approver_alert else forbidden).append(rid)
        if d.verdict == A_CONTRADICTED:
            fresh = ledger.queue_rereview(rid, d.verdict, "; ".join(d.reasons)[:500])
            if fresh and ev.big_track:
                alerts.append("CREDIT-AUDIT ALERT: CONTRADICTED on big track - " + one_line(ev, d))
                ledger.mark_alerted(row_id)

    deferred: list[tuple[dict[str, Any], Evidence]] = []
    done = 0
    held = 0
    mark: datetime | None = None
    longest = 0.0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for start in range(0, len(todo), AUDIT_CHUNK):
            began = time.monotonic()
            if start and began + longest >= stop_at:
                break
            chunk = todo[start:start + AUDIT_CHUNK]
            built = list(pool.map(build, chunk))
            want = []
            for req, ev, err in built:
                if ev is None:
                    stats.errors += 1
                    log(f"evidence failed for {req.get('id')}: {err}")
                    # Not recorded as reviewed: parked and retried on every run, and
                    # alerted once on its first failure.
                    if ledger.note_evidence_failure(req, "audit", err or "evidence failed"):
                        evidence_failed.append(str(req.get("id")))
                    continue
                if deterministic(ev, cfg.mode).needs_model and (ev.big_track or sampled(ev.request_id, cfg.sample_rate)):
                    want.append(ev)
            big = [e for e in want if e.big_track]
            big.sort(key=lambda e: -(e.track_popularity or 0))
            late_before = late
            judged = judge_batch(big)
            cut = {e.request_id for e in big if e.request_id not in judged} if late > late_before else set()
            late -= len(cut)
            later = {e.request_id for e in want if not e.big_track}
            for req, ev, _err in built:
                if ev is None or ev.request_id in cut:
                    continue
                if ev.request_id in later:
                    deferred.append((req, ev))
                else:
                    finish(req, ev, judged.get(ev.request_id))
            done = start + len(chunk)
            if cut:
                held = len(cut)
                break
            mark = max([ts for _req, ts in chunk if ts is not None] + ([mark] if mark else []), default=None)
            longest = max(longest, time.monotonic() - began)
        judged = judge_batch([ev for _req, ev in deferred])
        for req, ev in deferred:
            finish(req, ev, judged.get(ev.request_id))
    if forbidden:
        alerts.append(f"CREDIT-AUDIT ALERT: {len(forbidden)} approval(s) by a forbidden or unknown approver identity - "
                      f"{', '.join(forbidden[:10])}")
    if unknown_approvals:
        alerts.append(f"CREDIT-AUDIT ALERT: {len(unknown_approvals)} approval(s) of validator-DECLINED requests with "
                      f"no recorded approver (admin queue) in the last {window_txt} - first: "
                      f"{', '.join(unknown_approvals[:5])}")
    if evidence_failed:
        parked, oldest = ledger.evidence_retry_count("audit")
        alerts.append(f"CREDIT-AUDIT ALERT: {len(evidence_failed)} approval(s) could NOT be audited - the trusted "
                      f"raw credits were unreadable; not marked reviewed, retried every run "
                      f"({parked} parked, oldest since {oldest}) - {', '.join(evidence_failed[:5])}")
    if stats.budget_stopped:
        alerts.append(f"CREDIT-AUDIT NOTE: model budget reached this run (${stats.cost_usd:.2f}); "
                      f"{over_budget} sampled/big approval(s) were catalog-checked only.")
    if late:
        alerts.append(f"CREDIT-AUDIT NOTE: {late} sampled/big approval(s) were catalog-checked only: "
                      f"deadline reached ({int(deadline_s)}s).")
    if done < len(todo) or held:
        cut_txt = f", including {held} big track(s) whose model check the deadline cut" if held else ""
        alerts.append(f"CREDIT-AUDIT ALERT: the audit stopped at its {int(deadline_s)}s deadline with "
                      f"{len(todo) - done + held} of {len(todo)} approval(s) in the window not yet audited{cut_txt}; "
                      f"the next run continues from {_iso(mark) if mark else 'the same window'}.")
        if mark is not None:
            ledger.set_state("audit_last_run", _iso(mark))
    else:
        ledger.set_state("audit_last_run", _iso(now))
    return alerts, stats


def run_review(admin: admin_api.Admin, ledger: Ledger, judge: Judge | None, cfg: Config, *,
               limit: int, sample_approved: int, now: datetime | None = None,
               page_size: int = 200, max_pages: int = 25) -> tuple[list[str], RunStats]:
    """PRE-APPROVAL REVIEWER over HELD (status=unverified) requests, plus a
    shadow sample of recent approvals. Advisory only: writes no status."""
    if cfg.phase not in ("shadow", "advise"):
        raise ValueError("review phase must be shadow or advise (phase 2 auto-approve is the captain's call and is not implemented)")
    now = now or datetime.now(timezone.utc)
    stats = RunStats()
    stats.max_call_cost = ledger.dearest_call_since((now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))

    def unseen(status: str, want: int, keep: Callable[[dict[str, Any]], bool]) -> list[dict[str, Any]]:
        """Page until `want` not-yet-reviewed rows are collected or the queue
        ends (QA on hydra#1142: filtering one page left row limit+1 unreviewed
        forever)."""
        out: list[dict[str, Any]] = []
        for page in range(1, max_pages + 1):
            items = admin_api.list_requests(admin, status=status, limit=page_size, page=page)
            out += [r for r in items if keep(r) and not ledger.reviewed(str(r.get("id")), "review")]
            if len(out) >= want or len(items) < page_size:
                break
        return out[:want]

    batch = unseen("unverified", limit, lambda r: True)
    if sample_approved > 0:
        batch += unseen("approved", sample_approved, lambda r: sampled(str(r.get("id")), 0.5))
    stats.scanned = len(batch)
    builder = EvidenceBuilder(admin, now=now, prior_contradicted=ledger.contradicted_by_profile())
    cards: list[str] = []
    for req in batch:
        try:
            ev, d, j = review_one(req, builder, judge, cfg, stats, force_model=True)
        except admin_api.AdminError as exc:
            stats.errors += 1
            log(f"evidence failed for {req.get('id')}: {exc}")
            continue
        stats.reviewed += 1
        stats.big += 1 if ev.big_track else 0
        stats.bump(d.verdict)
        record(ledger, cfg, ev, d, j)
        if cfg.phase == "advise" and d.verdict in (R_REJECT, R_HUMAN) and ev.status == "unverified":
            cards.append(f"AI REVIEW {d.verdict} ({d.confidence:.2f}): " + one_line(ev, d))
    return cards, stats


# Per-profile burst alert (firstmate 035, 2026-10-14): one profile filed 421
# requests in under 2h and the validator approved 35 of them; the audit marked 25
# SUSPECT in one hour and raised NO alert, because row alerts fire only for a
# CONTRADICTED big track. A burst is judged on the ledger, across runs.
BURST_WINDOW = timedelta(hours=2)
BURST_FLAGGED_MIN = 10      # SUSPECT or CONTRADICTED approvals for one profile in the window
BURST_APPROVALS_MIN = 20    # approvals of any verdict for one profile in the window
BURST_MAX_LOOKBACK = timedelta(hours=24)
BURST_STATE = "burst_last_check"
PROFILE_URL = "https://credits.muso.ai/profile/{id}"


def _worst_burst(events: list[tuple[datetime, bool, bool]],
                 after: datetime) -> tuple[int, int, datetime, int, datetime] | None:
    """Over every BURST_WINDOW ending at an approval later than ``after``, the
    window meeting a threshold with the most flagged (then most) approvals.
    Events are (approved_at, flagged, parked); returns (flagged, approvals,
    window end, parked, end of the latest window meeting a threshold)."""
    best: tuple[int, int, datetime, int] | None = None
    latest: datetime | None = None
    lo = 0
    flagged = 0
    parked = 0
    for hi, (t, f, p) in enumerate(events):
        flagged += f
        parked += p
        while events[lo][0] < t - BURST_WINDOW:
            flagged -= events[lo][1]
            parked -= events[lo][2]
            lo += 1
        if t <= after:
            continue
        n = hi - lo + 1
        if flagged >= BURST_FLAGGED_MIN or n >= BURST_APPROVALS_MIN:
            latest = t
            if best is None or (flagged, n) > best[:2]:
                best = (flagged, n, t, parked)
    return (*best, latest) if best and latest else None


def profile_burst_alerts(ledger: Ledger, now: datetime | None = None) -> list[str]:
    """One CREDIT-AUDIT ALERT per profile with >= BURST_FLAGGED_MIN
    SUSPECT/CONTRADICTED approvals or >= BURST_APPROVALS_MIN approvals within
    any BURST_WINDOW that ends after the previous check (at most
    BURST_MAX_LOOKBACK back), so approvals a catch-up run records late, or a
    burst split across two hourly runs, still alert. Each request counts once
    (its latest audit verdict). Approvals parked because their evidence could
    not be read count as approvals, never as flagged, and the check never moves
    past the earliest of them parked within BURST_MAX_LOOKBACK, so their windows
    are judged again once they are recorded. A profile is alerted again only for
    a window holding an approval newer than every approval already alerted."""
    now = now or datetime.now(timezone.utc)
    prev = parse_ts(ledger.get_state(BURST_STATE)) or now - BURST_WINDOW
    prev = max(prev, now - BURST_MAX_LOOKBACK)
    rows = ledger.db.execute(
        "SELECT r.profile_id, r.verdict, r.evidence_json, COALESCE(r.approved_at, r.reviewed_at) ts FROM reviews r "
        "JOIN (SELECT request_id, MAX(id) mid FROM reviews WHERE mode='audit' GROUP BY request_id) l ON r.id = l.mid "
        "WHERE COALESCE(r.approved_at, r.reviewed_at) >= ? AND COALESCE(r.approved_at, r.reviewed_at) <= ? "
        "AND r.profile_id IS NOT NULL",
        (_iso(prev - BURST_WINDOW - timedelta(seconds=1)), _iso(now) + "~")).fetchall()  # "~" sorts after any fraction/Z
    per: dict[str, dict[str, Any]] = {}
    resume = now

    def add(pid: str, ts: Any, flagged: bool, parked: bool, name: Any) -> None:
        at = parse_ts(ts)
        if at is None or at > now or at < prev - BURST_WINDOW:
            return
        p = per.setdefault(pid, {"events": [], "name": None})
        p["events"].append((at, flagged, parked))
        if not p["name"] and name:
            p["name"] = str(name)

    for r in rows:
        try:
            name = (json.loads(r["evidence_json"] or "{}").get("claim") or {}).get("person_or_profile_name")
        except ValueError:
            name = None
        add(r["profile_id"], r["ts"], r["verdict"] in (A_SUSPECT, A_CONTRADICTED), False, name)
    for r in ledger.db.execute(
            "SELECT request_json, first_failed_at FROM evidence_retry WHERE mode='audit' AND request_id NOT IN "
            "(SELECT request_id FROM reviews WHERE mode='audit')").fetchall():
        try:
            req = json.loads(r["request_json"])
        except ValueError:
            continue
        if not isinstance(req, dict):
            continue
        parked_at = parse_ts(req.get("updatedAt"))
        parked_since = parse_ts(r["first_failed_at"])
        if parked_at is not None and parked_since is not None and parked_since >= now - BURST_MAX_LOOKBACK:
            resume = min(resume, parked_at - timedelta(seconds=1))
        if not req.get("profileId"):
            continue
        prof = req.get("profile") if isinstance(req.get("profile"), dict) else {}
        add(str(req["profileId"]), req.get("updatedAt"), False, True, prof.get("name"))
    bursts = []
    for pid, p in per.items():
        through = parse_ts(ledger.get_state(f"burst_alerted_through:{pid}"))
        worst = _worst_burst(sorted(p["events"]), max(prev, through) if through else prev)
        if worst:
            bursts.append((pid, p["name"], *worst))
    out: list[str] = []
    for pid, name, flagged, approvals, end, parked, latest in sorted(bursts, key=lambda b: (-b[3], b[0])):
        ledger.set_state(f"burst_alerted_through:{pid}", latest.isoformat())
        who = plain_line(name or "") or "unnamed profile"
        out.append(f"CREDIT-AUDIT ALERT: burst of approvals on one profile - {who} ({plain_line(pid)}): "
                   f"{approvals} approval(s) within {int(BURST_WINDOW.total_seconds() // 3600)}h "
                   f"(up to {_iso(end)}), {flagged} of them SUSPECT or CONTRADICTED"
                   f"{f', {parked} not yet auditable' if parked else ''}. Nothing was changed; "
                   f"a human should review this profile's recent approvals. {PROFILE_URL.format(id=plain_line(pid))}")
    ledger.set_state(BURST_STATE, _iso(max(resume, now - BURST_MAX_LOOKBACK)))
    return out


def render_digest(ledger: Ledger, now: datetime | None = None, hours: int = 24) -> str:
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = ledger.since(since, "audit")
    parked, oldest = ledger.evidence_retry_count("audit")
    if not rows and not parked:
        return "NO_REPLY"
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    flagged = [r for r in rows if r["verdict"] in (A_SUSPECT, A_CONTRADICTED)]
    flagged.sort(key=lambda r: (r["verdict"] != A_CONTRADICTED, -(r["big_track"] or 0), -(r["spotify_popularity"] or 0)))
    cost, calls = ledger.cost_since(since)
    approver = sum(1 for r in rows if r["approver_alert"])
    lines = [f"*Credit approval audit - last {hours}h*",
             f"Audited {len(rows)} approvals: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())),
             f"Approvals without a recorded/allowed approver: {approver}",
             f"Model checks: {calls}, cost ${cost:.2f}"]
    if parked:
        lines.append(f"NOT YET AUDITED: {parked} approval(s) whose trusted raw credits could not be read "
                     f"(retried every run; oldest since {oldest})")
    if flagged:
        lines.append(f"*SUSPECT / CONTRADICTED ({len(flagged)})* - read-only; queued for human re-review:")
        for r in flagged[:40]:
            reasons = json.loads(r["reasons_json"] or "[]")
            why = (reasons[0] if reasons else r["basis"])[:160]
            lines.append(f"- {r['verdict']} {'BIG ' if r['big_track'] else ''}\"{r['track_title']}\" "
                         f"(pop {r['spotify_popularity']}) {r['claimed_roles']} - {why} - "
                         f"{REQUEST_URL.format(id=r['request_id'])}")
        if len(flagged) > 40:
            lines.append(f"- and {len(flagged) - 40} more (ledger: /var/lib/hydra/credit-review/ledger.sqlite3)")
    return "\n".join(lines)


def render_metrics(admin: admin_api.Admin | None, ledger: Ledger, now: datetime | None = None, days: int = 7) -> str:
    """Weekly precision report.

    Precision proxy on live traffic: of the requests flagged SUSPECT or
    CONTRADICTED 7-14 days ago, how many are no longer approved today (a human
    removed or reverted them). That is a lower bound, since unreviewed flags
    count as not confirmed. The labelled-set precision from the last
    ``credit-review.py eval`` run is reported next to it.
    """
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = ledger.since(since, "audit")
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    cost, calls = ledger.cost_since(since)
    lines = [f"*Credit approval audit - weekly metrics ({days}d)*",
             f"Audited {len(rows)}: " + (", ".join(f"{k} {v}" for k, v in sorted(counts.items())) or "none"),
             f"Model checks {calls}, cost ${cost:.2f}" + (f" (${1000 * cost / calls:.2f} per 1k model checks)" if calls else "")]
    older = ledger.db.execute(
        "SELECT request_id, profile_id, verdict FROM reviews WHERE mode='audit' AND verdict IN (?,?) "
        "AND reviewed_at >= ? AND reviewed_at < ?",
        (A_SUSPECT, A_CONTRADICTED, (now - timedelta(days=2 * days)).strftime("%Y-%m-%dT%H:%M:%SZ"), since)).fetchall()
    if admin is not None and older:
        by_profile: dict[str, set[str]] = {}
        for r in older:
            by_profile.setdefault(r["profile_id"], set()).add(r["request_id"])
        still: set[str] = set()
        unknown: set[str] = set()
        profiles = list(by_profile.items())
        for i, (pid, ids) in enumerate(profiles):
            if i >= 200:
                unknown |= ids  # not read this run: neither kept nor removed
                continue
            try:
                complete = False
                for page in range(1, 11):
                    items = admin_api.list_requests(admin, status="approved", limit=500, page=page, profile_ids=[pid])
                    still |= {str(it.get("id")) for it in items} & ids
                    if len(items) < 500:
                        complete = True
                        break
                if not complete:
                    unknown |= ids - still  # list not fully read: cannot call these removed
            except admin_api.AdminError:
                unknown |= ids
        flagged_all = {r["request_id"] for r in older}
        acted = flagged_all - still - unknown
        for v in (A_CONTRADICTED, A_SUSPECT):
            flagged = {r["request_id"] for r in older if r["verdict"] == v}
            known = flagged - unknown
            if flagged:
                n = len(flagged & acted)
                pct = f"{100 * n / len(known):.0f}%" if known else "n/a"
                lines.append(f"{v} flagged {days}-{2 * days}d ago: {len(flagged)} ({len(flagged & unknown)} not checkable "
                             f"this run), since removed/reverted by a human: {n} of {len(known)} checked "
                             f"({pct}, lower-bound precision)")
    ev = ledger.get_state("eval_summary")
    if ev:
        lines.append("Labelled-set precision (last eval): " + ev)
    return "\n".join(lines)
