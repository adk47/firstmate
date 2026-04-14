"""GHL adapter stub — wiring deferred until stage-ID lookup ships.

See docs/superpowers/specs/2026-04-14-cmo-outreach-sender-worker-design.md
§2 step 7 and worker.py TODO(outreach-sender).

The worker deliberately does NOT call advance_opportunity_stage today;
the human advances the opp manually via the runbook. This stub ensures
any accidental call raises immediately so the gap is visible.
"""
from __future__ import annotations


def advance_opportunity_stage(opp_id: str, stage_id: str) -> None:
    raise NotImplementedError(
        "GHL stage-ID lookup is not yet wired. "
        "Advance the opp manually — see RUNBOOK-outreach-sender-worker.md."
    )
