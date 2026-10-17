"""Labelled-set evaluation (Phase 0 shadow measurement).

Labels:
* known_bad  - approved requests of a confirmed fraud profile (stillfloo,
  94ad2ad2: 3,352 fake engineering/writing credits that Spotify, Tidal and
  MLC credit to other people);
* known_good - recent approved requests from other profiles that a trusted
  source (Spotify/Tidal/MLC/Jaxsta) credits to the claimant in the claimed
  role.

Two arms per model:
* ``full``  - the pipeline as deployed (catalog evidence + model);
* ``blind`` - the trusted catalog credits for the claimed role families are
  withheld from the deterministic layer and the model, which must decide from
  web search, identity and pattern signals alone. The full arm is partly
  circular (the labels come from the same catalog), so the blind arm is the
  honest measure of what the AI layer adds.
"""

from __future__ import annotations

import json
import random
from dataclasses import dataclass, field
from typing import Any

from .evidence import UNVERIFIABLE, Evidence
from .judge import Judge, JudgeResult
from .ledger import Ledger
from .runner import Config, RunStats, record, review_one

FLAG_AUDIT = {"SUSPECT", "CONTRADICTED"}


def blind(ev: Evidence) -> None:
    for r in ev.roles:
        r.status = UNVERIFIABLE
        r.trusted_for_profile = []
        r.trusted_for_others = []


@dataclass
class ArmResult:
    model: str
    arm: str
    mode: str
    rows: list[dict[str, Any]] = field(default_factory=list)
    stats: RunStats = field(default_factory=RunStats)

    def metrics(self) -> dict[str, Any]:
        bad = [r for r in self.rows if r["label"] == "known_bad"]
        good = [r for r in self.rows if r["label"] == "known_good"]
        out: dict[str, Any] = {"model": self.model, "arm": self.arm, "mode": self.mode,
                               "n_bad": len(bad), "n_good": len(good),
                               "model_calls": self.stats.model_calls, "cost_usd": round(self.stats.cost_usd, 4),
                               "model_errors": self.stats.errors,
                               "budget_stopped": self.stats.budget_stopped}
        if self.stats.model_calls:
            out["usd_per_1k_model_reviews"] = round(1000 * self.stats.cost_usd / self.stats.model_calls, 2)

        def pr(pos_set: set[str], positive_label: str) -> dict[str, Any]:
            flagged = [r for r in self.rows if r["verdict"] in pos_set]
            tp = sum(1 for r in flagged if r["label"] == positive_label)
            n_pos = sum(1 for r in self.rows if r["label"] == positive_label)
            return {"flagged": len(flagged), "tp": tp, "fp": len(flagged) - tp,
                    "precision": round(tp / len(flagged), 3) if flagged else None,
                    "recall": round(tp / n_pos, 3) if n_pos else None}

        if self.mode == "audit":
            out["flag_SUSPECT_or_CONTRADICTED_vs_bad"] = pr(FLAG_AUDIT, "known_bad")
            out["CONTRADICTED_vs_bad"] = pr({"CONTRADICTED"}, "known_bad")
            out["CONFIRMED_vs_good"] = pr({"CONFIRMED"}, "known_good")
        else:
            out["REJECT_vs_bad"] = pr({"REJECT-RECOMMENDED"}, "known_bad")
            out["APPROVE_vs_good"] = pr({"APPROVE-RECOMMENDED"}, "known_good")
            out["APPROVE_on_bad (must be 0)"] = sum(1 for r in bad if r["verdict"] == "APPROVE-RECOMMENDED")
        dist: dict[str, dict[str, int]] = {}
        for r in self.rows:
            dist.setdefault(r["label"], {}).setdefault(r["verdict"], 0)
            dist[r["label"]][r["verdict"]] += 1
        out["verdicts_by_label"] = dist
        raw: dict[str, dict[str, int]] = {}
        for r in self.rows:
            mv = r.get("model_verdict") or "-"
            raw.setdefault(r["label"], {}).setdefault(mv, 0)
            raw[r["label"]][mv] += 1
        out["raw_model_verdicts_by_label"] = raw
        return out


def run_arm(admin, ledger: Ledger, items: list[tuple[str, dict[str, Any]]], model: str, arm: str, mode: str,
            web: bool = True, web_engine: str | None = None, budget_usd: float = 20.0,
            use_model: bool = True, workers: int = 6, batch: bool = False,
            judge_factory: Any = None) -> ArmResult:
    from concurrent.futures import ThreadPoolExecutor

    from .evidence import EvidenceBuilder

    cfg = Config(mode=mode, phase="shadow", sample_rate=1.0, max_model_calls=10_000, budget_usd=budget_usd,
                 web=web, model=model, web_engine=web_engine)
    # judge_factory(model) supplies another backend with the same interface
    # (credit-trust's fetched-sources Codex judge, `--provider codex`).
    if not use_model:
        judge = None
    elif judge_factory is not None:
        judge = judge_factory(model)
    else:
        judge = Judge(model, web=web, web_engine=web_engine)
    res = ArmResult(model=model if use_model else "catalog-only", arm=arm, mode=mode)
    builder = EvidenceBuilder(admin, always_velocity=True)
    hook = blind if arm == "blind" else None

    import threading

    lock = threading.Lock()
    spend = {"spent": 0.0, "reserved": 0.0, "dearest": 0.0}

    def one(pair):
        """One row. Rows run in parallel, so the arm budget is shared: each
        row reserves the dearer of the per-call estimate and the dearest call
        seen so far before it may call the model (a per-row RunStats alone
        would let every row spend the whole budget)."""
        label, req = pair
        stats = RunStats()
        with lock:
            reserve = max(cfg.est_call_cost_usd, spend["dearest"])
            allowed = judge is not None and spend["spent"] + spend["reserved"] + reserve <= budget_usd
            if allowed:
                spend["reserved"] += reserve
        try:
            ev, d, j = review_one(req, builder, judge if allowed else None, cfg, stats, force_model=True,
                                  evidence_hook=hook)
        except Exception as exc:  # noqa: BLE001 - one bad row must not end the eval
            return label, None, None, None, stats, str(exc)
        finally:
            if allowed:
                with lock:
                    spend["reserved"] -= reserve
                    spend["spent"] += stats.cost_usd
                    spend["dearest"] = max(spend["dearest"], stats.max_call_cost)
        if judge is not None and not allowed:
            stats.budget_stopped = True
        return label, ev, d, j, stats, None

    def batched() -> list:
        """The production path: evidence for every row first, then the model
        once per profile unit (runner.judge_grouped), then the policy."""
        from .policy import combine, deterministic
        from .runner import judge_grouped
        built = []
        for label, req in items:
            try:
                ev = builder.build(req)
            except Exception as exc:  # noqa: BLE001
                built.append((label, None, str(exc)))
                continue
            if hook:
                hook(ev)
            built.append((label, ev, None))
        stats = RunStats()
        want = [ev for _l, ev, _e in built if ev is not None and deterministic(ev, mode).needs_model]
        judged, _late, _over = judge_grouped(judge, cfg, stats, want, budget=budget_usd)
        out = [(None, None, None, None, stats, None)]
        for label, ev, err in built:
            if ev is None:
                out.append((label, None, None, None, RunStats(), err))
                continue
            j = judged.get(ev.request_id)
            out.append((label, ev, combine(ev, mode, j), j, RunStats(), None))
        return out

    if batch:
        results = batched()
    else:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(one, items))
    for label, ev, d, j, stats, err in results:
        res.stats.model_calls += stats.model_calls
        res.stats.cost_usd += stats.cost_usd
        res.stats.errors += stats.errors + (1 if err else 0)
        res.stats.budget_stopped |= stats.budget_stopped
        if ev is None:
            continue
        cfg.phase = f"eval-{arm}"
        record(ledger, cfg, ev, d, j, label=label, mode="eval")
        res.rows.append({
            "label": label, "request_id": ev.request_id, "verdict": d.verdict, "basis": d.basis,
            "confidence": d.confidence, "big": ev.big_track, "pop": ev.track_popularity,
            "roles": ev.claimed_roles, "title": ev.track_title, "artists": ev.track_artists[:2],
            "deterministic": ev.deterministic_summary(),
            "model_verdict": j.verdict if j and j.ok else (f"ERR:{(j.error or '')[:60]}" if j else None),
            "model_conf": j.confidence if j else None, "cited": (j.cited_urls[:5] if j else []),
            "latency_s": round(j.latency_s, 1) if j else None, "reasons": d.reasons[:4],
        })
    return res


def pick(items: list[dict[str, Any]], n: int, seed: int = 7) -> list[dict[str, Any]]:
    rnd = random.Random(seed)
    items = list(items)
    rnd.shuffle(items)
    return items[:n]


def stratified_bad(requests: list[dict[str, Any]], n: int, seed: int = 7) -> list[dict[str, Any]]:
    """Half big-track, half the rest, so both populations are measured."""
    approved = [r for r in requests if r.get("status") == "approved"]
    big = [r for r in approved if (r.get("spotifyPopularity") or 0) >= 60]
    small = [r for r in approved if (r.get("spotifyPopularity") or 0) < 60]
    return pick(big, n - n // 2, seed) + pick(small, n // 2, seed)


def to_markdown(metrics: list[dict[str, Any]]) -> str:
    lines = ["| model | arm | mode | n bad/good | flag precision | flag recall | CONTRADICTED / REJECT precision | CONFIRMED / APPROVE precision | $/1k model reviews |",
             "|---|---|---|---|---|---|---|---|---|"]
    for m in metrics:
        if m["mode"] == "audit":
            f, c, g = m["flag_SUSPECT_or_CONTRADICTED_vs_bad"], m["CONTRADICTED_vs_bad"], m["CONFIRMED_vs_good"]
        else:
            f, c, g = m["REJECT_vs_bad"], m["REJECT_vs_bad"], m["APPROVE_vs_good"]
        lines.append(f"| {m['model']} | {m['arm']} | {m['mode']} | {m['n_bad']}/{m['n_good']} | {f['precision']} | {f['recall']} "
                     f"| {c['precision']} (recall {c['recall']}) | {g['precision']} (recall {g['recall']}) | {m.get('usd_per_1k_model_reviews')} |")
    return "\n".join(lines)


def dump(path: str, obj: Any) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=1, ensure_ascii=False, default=str)


def judge_from_record(j: dict[str, Any] | None) -> JudgeResult | None:
    if not j:
        return None
    return JudgeResult(ok=bool(j.get("ok")), verdict=j.get("verdict"), confidence=float(j.get("confidence") or 0),
                       identity_consistent=j.get("identity_consistent"), findings=list(j.get("findings") or []),
                       rationale=j.get("rationale") or "", cited_urls=list(j.get("cited_urls") or []),
                       model=j.get("model") or "", cost_usd=j.get("cost_usd"), error=j.get("error"))


def rescore(ledger_path: str, mode: str = "audit") -> dict[str, ArmResult]:
    """Re-apply the CURRENT policy to stored eval rows (no API or model calls).

    Rows are grouped by arm from the `phase` column (eval-full / eval-blind).
    Ledgers written before that column carried the arm hold the full arm's rows
    first, then the blind arm's, one row per labelled item each.
    """
    import sqlite3

    from .policy import combine, facts_from_record

    db = sqlite3.connect(ledger_path)
    db.row_factory = sqlite3.Row
    rows = db.execute("SELECT * FROM reviews WHERE mode='eval' ORDER BY id").fetchall()
    if rows and all(r["phase"] == "shadow" for r in rows):
        ids = []
        arms = []
        for r in rows:
            arm = "blind" if r["request_id"] in ids else "full"
            if arm == "full":
                ids.append(r["request_id"])
            arms.append(arm)
        # A blind-only ledger (one row per item) has no second pass.
        evidence0 = json.loads(rows[0]["evidence_json"])
        if "blind" not in arms and all(
            rr.get("status") == "UNVERIFIABLE" and not rr.get("trusted_for_others")
            for rr in evidence0.get("trusted_catalog_credits_by_role") or []):
            arms = ["blind"] * len(rows)
    else:
        arms = [str(r["phase"]).removeprefix("eval-") for r in rows]
    out: dict[str, ArmResult] = {}
    for r, arm in zip(rows, arms):
        ev = json.loads(r["evidence_json"])
        j = judge_from_record(json.loads(r["judge_json"]) if r["judge_json"] else None)
        f = facts_from_record(ev, r["status_at_review"] or "approved")
        d = combine(f, mode, j)
        res = out.setdefault(arm, ArmResult(model="catalog-only", arm=arm, mode=mode))
        if j and j.model and res.model == "catalog-only":
            res.model = j.model
        res.stats.model_calls += 1 if j else 0
        res.stats.cost_usd += (j.cost_usd or 0) if j else 0
        res.stats.errors += 1 if (j and not j.ok) else 0
        res.rows.append({"label": r["label"], "request_id": r["request_id"], "verdict": d.verdict, "basis": d.basis,
                         "big": bool(r["big_track"]), "pop": r["spotify_popularity"], "title": r["track_title"],
                         "model_verdict": (j.verdict if j and j.ok else ("ERR" if j else None)), "reasons": d.reasons[:3]})
    return out
