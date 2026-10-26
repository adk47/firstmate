"""The live-DSP removal rule: nothing is hidden or removed without a live Spotify AND Tidal check.

Captain's standing rule, 2026-10-23 (firstmate 104/105/106), verbatim:
  11:50Z "tracks must be properly taken down in spotify or credits removed in spotify"
  11:53Z "and tidal - before hidden on muso"
  11:59Z "hidden on spotify or tidal means you cant play the track or credit is gone. i dont
         think they completely take it down"
A credit may be hidden OR removed on Muso only after a live check IN THE SAME RUN shows, on BOTH
Spotify and Tidal (every Tidal country agreeing; UNKNOWN never counts), that the track cannot be
played (greyed out / unavailable; the page may still exist) or that the person's credit in that
role family is gone from the track. Either DSP still listing them => the credit stays visible,
held for Ops (the Jan board). This is on top of every existing guard (citation, notice + restore,
24 h veto, exclusions, ...).

That check is core-backend's removal gate (core-backend #10765 develop / #10767 master: per-role
`credit` requests, Spotify/Tidal listing holds, every Tidal country, UNKNOWN never hides). It is
not on prod yet, so hydra's executors (take-back apply, the decider's revert) are wired to nothing
and refuse: `require()` raises before any read or write. Wiring the gate (file the pair, recheck
it in the run, execute only the roles the gate DECIDED in that check, record the gate request
id, check time and per-DSP state on the row, then markExecuted) is the follow-up once the gate is
live; it replaces this refusal and never bypasses it.
"""

from __future__ import annotations

RULE = ('captain 2026-10-23 11:50Z "tracks must be properly taken down in spotify or credits removed '
        'in spotify", 11:53Z "and tidal - before hidden on muso", 11:59Z "hidden on spotify or tidal '
        'means you cant play the track or credit is gone" (firstmate 104/105/106)')

# Set True only by the change that wires core's removal gate into the executors. Tests of the
# executor mechanics flip it on the module object. Nothing outside the code sets it, so there is
# no runtime switch that turns the rule off.
WIRED = False


class LiveDspGateRequired(SystemExit):
    """Raised before any hide/removal while the live Spotify+Tidal gate is not wired."""


def require(action: str) -> None:
    """Refuse `action` (a hide or a removal) unless the live Spotify+Tidal gate is wired."""
    if not WIRED:
        raise LiveDspGateRequired(
            f"live_dsp_gate_required: {action} refused. Nothing is hidden or removed until a live "
            f"Spotify AND Tidal check in the same run shows the track unplayable or the person no "
            f"longer credited in that role family (core-backend's removal gate, not live yet). "
            f"Rule: {RULE}. The credits stay visible; Ops (Jan board) holds them.")
