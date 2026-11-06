"""Rendering for sentinel-demote: digest, demotion page, mirror-PR body, parity report.

Everything here is a pure function of counts. Two content rules, both enforced by
tests: **no account names, no user/conversation ids** ever reach a Slack line or a PR
body (the reprojection rule from AGENTS.md's credit-verification section), and a
counter that could not be measured renders as `UNMEASURED`, never as `0`.
"""
from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Sequence

COUNTER_COLUMNS = (
    ("reverts_7d", "reverts"),
    ("manipulated_7d", "manip"),
    ("contradicted_7d", "contra"),
    ("complaints_7d", "compl"),
    ("audit_fails_7d", "audit"),
)

OVERDUE_PCT_DEFAULT = 5.0


def _fmt(v: Optional[float]) -> str:
    if v is None:
        return "UNMEASURED"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def _overdue_cell(counts: Dict[str, float]) -> str:
    if "day_rows" not in counts:
        return "UNMEASURED"
    total = counts.get("day_rows") or 0
    late = counts.get("overdue_rows") or 0
    if not total:
        return "n/a (0 rows)"
    return f"{100.0 * late / total:.1f}% ({_fmt(late)}/{_fmt(total)})"


def digest(rows: Sequence[Dict[str, Any]], counters, states: Dict[str, str], at: str) -> str:
    """The nightly digest: EVERY registered capability, its counters, its state."""
    lines: List[str] = []
    lines.append(f":satellite: *sentinel-demote digest* {at}")
    lines.append(f"window {counters.window_start} → {counters.window_end}")
    src = ", ".join(f"{s.name}={s.status}" for s in counters.sources) or "no sources configured"
    lines.append(f"sources: {src}")
    for s in counters.sources:
        if s.status != "ok":
            lines.append(f"  :grey_question: {s.name} {s.status}: {s.detail}")
    lines.append("")
    cap_w, state_w, col_w = 34, 7, 11
    header = (f"{'capability':{cap_w}} {'state':{state_w}} "
              + " ".join(f"{label:>{col_w}}" for _, label in COUNTER_COLUMNS)
              + f" {'overdue(us>due)':>22}")
    lines.append("```")
    lines.append(header)
    for row in rows:
        cap = str(row["id"])
        c = counters.of(cap)
        cells = " ".join(f"{_fmt(c.get(k)):>{col_w}}" for k, _ in COUNTER_COLUMNS)
        state = states.get(cap, "?")
        flag = ""
        if counters.blind_for(cap) and state in ("canary", "live"):
            flag = "  <= UNMEASURED TRIGGER"
        lines.append(f"{cap[:cap_w]:{cap_w}} {state:{state_w}} {cells} {_overdue_cell(c):>22}{flag}")
    lines.append("```")
    if counters.unattributed:
        bits = ", ".join(f"{k}={_fmt(v)}" for k, v in sorted(counters.unattributed.items()))
        lines.append(f"unattributed (no registry row claims them): {bits}")
    blind = {cap: b for cap, b in counters.blind.items() if b}
    if blind:
        lines.append("")
        lines.append("*Triggers that could not be measured* (a trigger with no source cannot fire; "
                     "it is not evidence of health):")
        for cap in sorted(blind):
            # dedupe: two rules can share one blind source (reverts_7d + audit_fail_any
            # both read the ACTION-AUDIT ledger) and repeating it reads as two problems.
            lines.append(f"  • `{cap}`: " + "; ".join(sorted(set(blind[cap].values()))))
    return "\n".join(lines)


def demotion_page(trips: Iterable["object"], at: str) -> str:
    """The #clio_devops page. Counts and capability ids only — never an account."""
    trips = list(trips)
    head = f":rotating_light: *sentinel-demote: {len(trips)} capability demoted* {at}"
    lines = [head]
    for t in trips:  # type: ignore[attr-defined]
        if getattr(t, "kill_ok", None) is False:
            kill_line = f"— :warning: kill file was NOT dropped (`{t.kill_file}`); the state flip still happened"
        elif getattr(t, "kill_ok", None) is None and not getattr(t, "kill_file", ""):
            kill_line = "— no kill file on this registry row: state flip only"
        else:
            kill_line = f"— kill file dropped: `{t.kill_file}`"
        lines.append(f"• `{t.capability_id}` {t.prev_state} → *{t.next_state}* {kill_line}")
        lines.append(f"    triggers: {', '.join(t.reason_text)}")
        lines.append(f"    counts (7 d): {_counts_text(t.counts)}")
    lines.append("")
    lines.append("Repo mirror PR opened so repo and host agree. Three independent stops: registry state, "
                 "kill file, the actor's own `approved` flag — any one stops it. Nothing was promoted; "
                 "promotion needs a Fable ruling (`demote.py promote --capability <id> --ruling <id>`).")
    return "\n".join(lines)

def _counts_text(counts: Dict[str, float]) -> str:
    bits = []
    for k, label in COUNTER_COLUMNS:
        if k in counts:
            bits.append(f"{label}={_fmt(counts[k])}")
    if "day_rows" in counts:
        bits.append(f"overdue={_overdue_cell(counts)}")
    return ", ".join(bits) if bits else "none measured"


def mirror_pr_body(trips: Iterable["object"], at: str, registry_path: str) -> str:
    """The PR body that mirrors a host demotion into the repo registry."""
    trips = list(trips)
    lines = [
        "## sentinel-demote: mirror a HOST demotion into the repo registry",
        "",
        f"`sentinel-demote` tripped on {at} and flipped the **runtime** state in "
        "`/var/lib/hydra/sentinel/registry-state.json` (the host stopped the capability "
        "within seconds). This PR makes the repo agree, so the switch does not silently "
        "revert on the next deploy — the 2026-10-27 \"a switch in one place is not a switch\" lesson.",
        "",
        "| capability | was | now | triggers | counts (7 d) | kill file |",
        "|---|---|---|---|---|---|",
    ]
    for t in trips:  # type: ignore[attr-defined]
        lines.append(
            f"| `{t.capability_id}` | {t.prev_state} | **{t.next_state}** | "
            f"{', '.join(t.reason_text)} | {_counts_text(t.counts)} | `{t.kill_file}` |"
        )
    lines += [
        "",
        "### What this PR does NOT do",
        f"- It does not touch the actor's own flag in `policies/credit-approval-automation.json`. "
        "That is the third independent stop and it stays exactly as it is.",
        "- It does not promote anything. Demotion is one step only (live → canary, canary → shadow); "
        "re-promotion is a separate PR carrying a Fable ruling id and the parity report from "
        "`scripts/sentinel/demote.py promote --capability <id> --ruling <id>` "
        "(`rollout.since` + `rollout.approval_ref` are required by `scripts/check-sentinel-registry.py`).",
        "- It does not remove the kill file. A human removes it after the ruling.",
        "",
        "Three independent stops per capability: registry state, kill file, and the actor's own flag — "
        "any one of them stops it. This PR moves the first one; the page on the host moved the second.",
        "",
        f"Registry: `{registry_path}`. Counters are 7-day aggregates; no account names.",
        "",
        "### Reviewer checklist",
        "- [ ] the trigger counts in the row below match the digest for these capabilities",
        "- [ ] the kill file named in the row exists on node-8",
        "- [ ] `rollout.since` is the demotion date (not the original promotion date)",
    ]
    return "\n".join(lines)


def parity_report(*, capability_id: str, ruling: Optional[str], rollout: Dict[str, Any],
                  gates: Dict[str, Any], at: str) -> str:
    """`demote.py promote` output. Renders the evidence; NEVER changes state."""
    lines = [
        f"# sentinel parity report — `{capability_id}`",
        f"_rendered {at}; this command never changes any state._",
        "",
        f"- rollout.since: `{rollout.get('since') or 'MISSING'}`",
        f"- rollout.approval_ref (Fable ruling): `{ruling or rollout.get('approval_ref') or 'MISSING'}`",
        "",
        "| gate | requirement | measured | verdict |",
        "|---|---|---|---|",
    ]
    for name, g in gates.items():
        verdict = "PASS" if g.get("pass") else "BLOCK"
        lines.append(f"| {name} | {g.get('requirement')} | {g.get('measured')} | **{verdict}** |")
    blocked = [n for n, g in gates.items() if not g.get("pass")]
    lines.append("")
    if blocked:
        lines.append(f"**PROMOTION BLOCKED** — {len(blocked)} gate(s) not met: {', '.join(blocked)}.")
        lines.append("Nothing was changed. Re-run after the evidence exists; promotion is a PR with a "
                     "Fable ruling id, never a runtime write.")
    else:
        lines.append("**ALL GATES PASS** — hand this report to Fable with the ruling id, then open the PR "
                     "that flips `rollout.state`. This command does not flip it.")
    return "\n".join(lines)


def proposal_markdown(*, slug: str, week: str, cluster: Dict[str, Any], proposed_row: Dict[str, Any],
                      generated_at: str) -> str:
    """A weekly proposal file: what, how often, who, guards, blast radius, forced type."""
    forced = proposed_row.get("action", {}).get("type") == "handoff" and cluster.get("forced_handoff")
    lines = [
        f"# Sentinel proposal — {cluster.get('name') or slug} ({week})",
        "",
        f"_generated {generated_at} by `scripts/sentinel/demote.py propose` from de-identified evaluation "
        "features only: class, sub_class, requested action, counts. No customer text, no ids. "
        "A field that is not a bare code token is dropped, not quoted._",
        "",
        "## What is being asked for",
        f"- class: `{cluster.get('class')}` · sub_class: `{cluster.get('sub_class')}`",
        "- requested action: " + (f"`{cluster['requested_action']}`" if cluster.get("requested_action")
                                  else "_not published — the caller's value was not a bare code_"),
        f"- volume: **{cluster.get('count_30d', 0)} requests / 30 d**",
        f"- nearest existing capability: `{cluster.get('nearest_capability') or 'none'}`",
        "",
        "## Why it is unhandled today",
        cluster.get("why") or "rows land as `unhandled` / `handoff` — a human does each one by hand.",
        "",
        "## Proposed registry row (state: shadow)",
        "```json",
        _json(proposed_row),
        "```",
        "",
        "## Guards that would apply",
        "Every row names `band_allows` plus the guards below. A guard is a pure function with a"
        " fixture; it must exist and pass before this row leaves `shadow` — a proposal is a"
        " request for a capability, not a claim that its guards are built.",
    ]
    for g in proposed_row.get("guards") or []:
        lines.append(f"- `{g}`")
    lines += [
        "",
        "## Blast radius (proposed)",
        "```json",
        _json(proposed_row.get("blast_radius") or {}),
        "```",
        "",
    ]
    if forced:
        lines.append(
            "> **Forced to `handoff` by code.** This class is money / legal / credentials / "
            "irreversible, so no proposal in it can ever become an actor (request-sentinel-fable-s1 §2.6.3)."
        )
        lines.append("")
    lines += [
        "## Next",
        "1. Fable rules: extend shadow / canary (modulo 10, caps halved) / close with a reason.",
        "2. Nothing promotes from this file. A PR with the ruling id flips `rollout.state`.",
    ]
    return "\n".join(lines)


def _json(obj: Any) -> str:
    import json
    return json.dumps(obj, indent=2, sort_keys=True)
