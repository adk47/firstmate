"""Path (1) of the first awards (Fable [key=first-awards]): every V9 APPROVE becomes an ANCHORED approve tray.

V9 (the DSP evidence verifier, deterministic code) is the coded decider for these approvals: an APPROVE verdict
means its OWN same-run capture shows Spotify AND Tidal crediting the claimant's linked id on every claimed role.
This module turns those verdicts into:
  1. anchor records in the verifier store (dspverify runner.build_anchors - rebuilt from the packet, refused unless
     the packet re-verifies APPROVE), which credit-anchors-push.py uploads to core's credit_anchor_records;
  2. ONE executor approve tray per expected status, every row citing `coded_outcome = dsp_verdicts:<id>`; the L12
     executor re-checks that the verdict is still the request's latest self-captured APPROVE, the account gate, the
     watchlist and pop 1..59, and core's ANCHORED scope admits only on the uploaded server-side anchor set.
Nothing here writes a credit status. Order of operations (operator): build -> push dry -> push ONE row -> b1
verifies the read-back -> executor dry -> executor --apply --limit 1 -> the rest, <= 50/day (the approve cap).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

RULE_ID = "C4:anchored/v1"
APPROVABLE_FROM = ("unverified", "user_verification_needed")


@dataclass
class Candidate:
    verdict_id: int
    request_id: str
    user_id: int | None
    paid: bool | None


@dataclass
class FeedResult:
    candidates: int = 0
    skipped: dict[str, int] = field(default_factory=dict)
    built: list[Candidate] = field(default_factory=list)
    trays: dict[str, dict[str, Any]] = field(default_factory=dict)

    def skip(self, why: str) -> None:
        k = why.split(":")[0]
        self.skipped[k] = self.skipped.get(k, 0) + 1


def approve_candidates(con: Any) -> list[Candidate]:
    """The latest `verify`-run verdict per request that is APPROVE (provenance is re-checked by the caller through
    the executor's own dsp_verdict_outcomes, so the feed and the executor read one rule)."""
    q = ("SELECT v.id, lower(v.request_id), v.user_id, v.paid FROM dsp_verdicts v JOIN dsp_runs r ON r.run_id = v.run_id "
         "WHERE r.kind = 'verify' AND v.verdict = 'APPROVE' AND v.id = (SELECT max(w.id) FROM dsp_verdicts w "
         "JOIN dsp_runs q ON q.run_id = w.run_id WHERE lower(w.request_id) = lower(v.request_id) AND q.kind = 'verify') "
         "ORDER BY coalesce(v.paid, 0) DESC, v.id")
    return [Candidate(int(i), str(r), int(u) if u is not None else None, None if p is None else bool(p))
            for i, r, u, p in con.execute(q)]


def already_handled(audit_lines: Iterable[dict[str, Any]]) -> set[str]:
    """Requests the executor already reserved / wrote an approval for (never fed twice)."""
    return {str(d.get("request_id", "")).lower() for d in audit_lines
            if d.get("action") == "approve" and d.get("outcome") in ("reserved", "written", "not_moved")}


def feed(candidates: list[Candidate], *, outcomes: Callable[[list[str]], dict[str, dict[str, Any]]],
         facts: Callable[[list[str]], dict[str, Any]], build: Callable[[list[Candidate]], dict[str, str]],
         handled: set[str], limit: int) -> FeedResult:
    """Pick, build and tray up to `limit` candidates. Every guard fails closed."""
    res = FeedResult(candidates=len(candidates))
    ids = [f"dsp_verdicts:{c.verdict_id}" for c in candidates]
    oc = outcomes(ids) if ids else {}
    fx = facts([c.request_id for c in candidates]) if candidates else {}
    picked: list[tuple[Candidate, str]] = []
    for c in candidates:
        o = oc.get(f"dsp_verdicts:{c.verdict_id}")
        f = fx.get(c.request_id)
        if c.request_id in handled:
            res.skip("already_fed")
        elif o is None or o.get("decision") != "approve" or o.get("request_id") != c.request_id:
            res.skip("verdict_not_a_live_self_captured_approve")
        elif f is None or f.deleted or f.status not in APPROVABLE_FROM:
            res.skip(f"not_open:{getattr(f, 'status', None)}")
        elif c.user_id is not None and f.user_id != c.user_id:
            res.skip("user_mismatch")
        elif f.metadata_source == "client" or f.popularity is None or not 1 <= f.popularity < 60:
            res.skip("big_or_unknown_popularity")
        elif len(picked) >= limit:
            res.skip("over_limit_next_run")
        else:
            picked.append((c, f.status))
    built = build([c for c, _ in picked]) if picked else {}
    for c, status in picked:
        why = built.get(c.request_id, "unknown")
        if why != "built":
            res.skip(f"anchor_not_built:{why}")
            continue
        res.built.append(c)
        t = res.trays.setdefault(status, {
            "action": "approve", "expected_status": status, "order": "as_listed",
            "note": f"coded rule {RULE_ID}: V9 APPROVE verdicts (same-run Spotify+Tidal); never a hand list",
            "rows": []})
        t["rows"].append({"request_id": c.request_id, "user_id": fx[c.request_id].user_id,
                          "coded_outcome": f"dsp_verdicts:{c.verdict_id}", "ruling_id": f"dsp_verdicts-{c.verdict_id}",
                          "rule": RULE_ID, "paid": bool(c.paid),
                          "evidence": (f"V9 APPROVE (dsp_verdicts {c.verdict_id}): the verifier's own same-run capture "
                                       "shows Spotify and Tidal crediting the claimant's linked id on every role")})
    return res


def build_with_runner(store: Any, now: Any = None) -> Callable[[list[Candidate]], dict[str, str]]:
    """{request id: 'built' | refusal} via the verifier's own anchor builder (rebuilt from its packet)."""
    from credit_verify.dspverify import runner

    def build(cands: list[Candidate]) -> dict[str, str]:
        tray = {"action": "approve", "rows": [{"request_id": c.request_id, "ruling_id": f"dsp_verdicts-{c.verdict_id}"}
                                              for c in cands]}
        _st, out = runner.build_anchors(store, tray, now=now)
        return {str(o["request_id"]).lower(): ("built" if o.get("outcome") == "built" else
                                               f"refused:{str(o.get('reason'))[:80]}") for o in out}
    return build


def dumps(doc: dict[str, Any]) -> str:
    return json.dumps(doc, indent=1, ensure_ascii=False)
