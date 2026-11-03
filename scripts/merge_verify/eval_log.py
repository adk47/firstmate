"""Shadow log in verifier-eval-v1's recorded-log format (docs/credit-verification/verifier-eval.md):
one JSONL row per ticket (`<ticket>`) and per duplicate (`<ticket>:<loser 8-hex>`), verdict
`eligible` | `refused:<SLUG>` | `queued_review` | `UNKNOWN`. Drop it in
/var/lib/hydra/verifier-eval/inbox/merges/merge-verify.jsonl and the nightly board scores it."""
from __future__ import annotations

import json
from typing import Any, Iterable

from .rules import TicketVerdict


def _v(verdict: str) -> str:
    if verdict == "eligible" or verdict.startswith("refused:"):
        return verdict
    if verdict == "unknown":
        return "UNKNOWN"
    return "queued_review"


def rows(judged: Iterable[tuple[dict, TicketVerdict]]) -> list[dict[str, Any]]:
    """judged = [(facts, verdict)]. A ticket-level verdict (no per-duplicate rows) is written for
    every named duplicate too, so pair-keyed eval items are covered."""
    out = []
    for facts, v in judged:
        out.append({"id": v.ticket, "verdict": _v(v.verdict), "reasons": [v.verdict, *v.reasons][:5],
                    "rule_version": v.rule_version, "fresh_read": v.fresh_read})
        for lv in v.losers:
            out.append({"id": f"{v.ticket}:{lv.loser[:8]}", "verdict": _v(lv.verdict),
                        "reasons": [lv.verdict, *lv.reasons][:5], "rule_version": v.rule_version, "fresh_read": v.fresh_read})
        if not v.losers:
            for d in facts.get("dups") or []:
                out.append({"id": f"{v.ticket}:{str(d)[:8]}", "verdict": _v(v.verdict), "reasons": [v.verdict, *v.reasons][:5],
                            "rule_version": v.rule_version, "fresh_read": v.fresh_read})
    return out


def write(path: str, judged: Iterable[tuple[dict, TicketVerdict]]) -> int:
    rs = rows(judged)
    with open(path, "w", encoding="utf-8") as f:
        for r in rs:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    return len(rs)
