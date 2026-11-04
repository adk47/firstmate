#!/usr/bin/env python3
"""Model-chain watchdog: page when the user-request path is running on the
FALLBACK tier, and when it has no tier left.

Captain 2026-11-03: the subscription is the primary tier and OpenRouter
deepseek-v4.1-flash-1017 is the fallback. That only helps if somebody notices
the moment the subscription stops serving: a fleet that quietly runs on the
fallback for a week is the 2026-07-27 codex-outage shape again (fleet rode
openrouter ~2h before anyone saw it), and a chain that runs out of tiers means
user requests were ANSWERED BY NOBODY.

Two alarms, both over a rolling window (default 1h):

  * FALLBACK SHARE > 20%  — the subscription is not serving. Denominator is
    every user-path model call that produced an answer, plus every chain that
    ran out of tiers (nobody answered); the DeepSeek tier and "nobody" both
    count as fallback pressure.
  * BOTH TIERS FAILED     — at least one chain exhausted, or an agent turn's
    fallback list reached `next=none`. Pages immediately.

Sources (both read-only):
  1. The scripted-path ledger (``lib/model_chain.py``): one JSONL row per
     attempt per user-request script.
  2. The gateway journal: openclaw's ``[model-fallback/decision]`` records
     carry ``requested=`` (the tier-1 model) and ``candidate=`` (what actually
     served), so an agent turn's tier is recoverable without guessing.

Usage:
  python3 scripts/model-chain-watchdog.py --check     # print the report only
  python3 scripts/model-chain-watchdog.py --alert     # post to Slack on breach
  python3 scripts/model-chain-watchdog.py --canary    # read-only deploy canary
                                                      # (+15/+60 tier counts)

Exit: 0 clean (healthy, unhealthy-but-reported, or alerted) · 1 usage/config ·
      2 source or delivery error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

from lib.model_chain import (  # noqa: E402
    CHAIN_EXHAUSTED, LEDGER_PATH, TIER_FALLBACK, TIER_SUBSCRIPTION, AccountingUnavailable, fallback_share,
    read_calls, tier_counts,
)

DEFAULT_SLACK_CHANNEL = "C0ADV2W76G4"  # #clio_devops
SLACK_LIB = SCRIPTS / "lib" / "slack-notify.sh"
STATE_PATH = Path(os.environ.get("MODEL_CHAIN_WATCHDOG_STATE", "/var/lib/hydra/model-chain/watchdog-state.json"))

# openclaw's fallback classifier record, e.g.
#   [model-fallback/decision] model fallback decision: decision=candidate_succeeded \
#     requested=openai/gpt-6-sol candidate=openrouter/deepseek/deepseek-v4.1-flash-1017 reason=unknown next=none
_DECISION_RE = re.compile(r"\[model-fallback/decision\]")
_FIELD_RE = re.compile(r"\b(decision|requested|candidate|reason|next)=(\S+)")
# The INSTALLED unit names (verified on node-8: `systemctl list-units "openclaw*"`
# shows openclaw-gateway-main.service / openclaw-gateway-edge.service). The
# template spelling openclaw-gateway@main reads NOTHING, which would have made
# every agent-turn fallback invisible - the exact silent-health failure this
# watchdog exists to prevent.
GATEWAYS = tuple(os.environ.get("MODEL_CHAIN_GATEWAY_UNITS", "openclaw-gateway-main,openclaw-gateway-edge")
                 .split(","))

FALLBACK_SHARE_THRESHOLD = float(os.environ.get("MODEL_CHAIN_FALLBACK_SHARE_THRESHOLD", "0.20"))
MIN_CALLS_TO_JUDGE = int(os.environ.get("MODEL_CHAIN_MIN_CALLS", "5"))
# Agent-side fallbacks are an ABSOLUTE count, never a share: the installed runner
# logs `[model-fallback/decision]` only when a fallback decision happened (a
# first-choice success logs nothing), and the codex/OAuth transport logs no
# `[model-fetch]` line at all. So agent rows can prove an outage but can never be
# the denominator of a percentage (QA 2026-11-03).
AGENT_FALLBACK_MIN = int(os.environ.get("MODEL_CHAIN_AGENT_FALLBACK_MIN", "3"))
REPEAT_MINUTES = int(os.environ.get("MODEL_CHAIN_ALERT_REPEAT_MIN", "360"))


# ── sources ──────────────────────────────────────────────────────────────────
def agent_rows(since_epoch: float, *, units: tuple[str, ...] = GATEWAYS) -> tuple[list[dict[str, str]], bool]:
    """openclaw fallback decisions from the gateway journals since `since_epoch`,
    plus whether the journal was actually readable.

    The flag matters as much as the rows: an unreadable journal returns zero
    decisions, and merging zero agents with a quiet scripted hour used to read as
    a healthy fleet. "I could not look" must never be the same answer as "nothing
    happened" (QA 2026-11-03)."""
    argv = ["journalctl", "--no-pager", "-o", "cat", "--since", f"@{int(since_epoch)}"]
    for u in units:
        argv += ["-u", u]
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return [], False
    if proc.returncode != 0:
        # journalctl exits 1 when no unit matched / the journal is unreadable: we
        # cannot tell a quiet fleet from a blind one, so say so.
        return [], False
    rows: list[dict[str, str]] = []
    for line in (proc.stdout or "").splitlines():
        if not _DECISION_RE.search(line):
            continue
        row = dict(_FIELD_RE.findall(line))
        if row.get("decision") == "model fallback decision":  # defensively skip a mis-split
            continue
        rows.append(row)
    return rows, True


def unit_inventory() -> set[str]:
    """Every unit name systemd knows, or an EMPTY set when it cannot tell us.

    An empty set is "unknown", never "nothing exists": a failed or empty
    `systemctl list-unit-files` (a rename in flight, a wedged systemd, a
    container) must not read as a healthy fleet (QA 2026-11-03)."""
    try:
        proc = subprocess.run(["systemctl", "list-unit-files", "--no-legend", "--no-pager"],
                              capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    if proc.returncode != 0:
        return set()
    return {line.split()[0].split(".")[0] for line in (proc.stdout or "").splitlines() if line.strip()}


def missing_units(units: tuple[str, ...] = GATEWAYS) -> list[str]:
    """Which of `units` does not exist on this host.

    `journalctl -u <name that does not exist>` exits 0 and prints nothing, so a
    renamed unit is indistinguishable from a quiet fleet - the exact shape of the
    2026-11-03 finding (the template spelling matched no unit for months). This
    asks systemd directly."""
    known = unit_inventory()
    if not known:
        return []
    return [u for u in units if u not in known]


def agent_counts(rows: list[dict[str, str]]) -> dict[str, int]:
    """Served agent turns per tier, plus turns whose whole chain died."""
    out = {TIER_SUBSCRIPTION: 0, TIER_FALLBACK: 0, CHAIN_EXHAUSTED: 0}
    for row in rows:
        decision = row.get("decision")
        requested, candidate = row.get("requested"), row.get("candidate")
        if decision == "candidate_succeeded" and candidate and candidate != "none":
            if candidate == requested:
                out[TIER_SUBSCRIPTION] += 1
            else:
                out[TIER_FALLBACK] += 1
        elif decision == "candidate_failed" and row.get("next") in (None, "none"):
            out[CHAIN_EXHAUSTED] += 1
    out["served"] = out[TIER_SUBSCRIPTION] + out[TIER_FALLBACK]
    return out


def merge(*counts: dict[str, int]) -> dict[str, int]:
    out = {TIER_SUBSCRIPTION: 0, TIER_FALLBACK: 0, CHAIN_EXHAUSTED: 0}
    for c in counts:
        for k in out:
            out[k] += int(c.get(k) or 0)
    out["served"] = out[TIER_SUBSCRIPTION] + out[TIER_FALLBACK]
    return out


def assess(since_epoch: float, *, ledger: str = LEDGER_PATH, units: tuple[str, ...] = GATEWAYS,
           include_agents: bool = True) -> dict:
    # strict=True matters: read_calls() answers [] for an unreadable ledger, and an
    # empty scripted side merged with a quiet agent side reads as healthy while every
    # fallback is invisible. "I could not read it" is a source failure, not zero
    # (QA 2026-11-03).
    ledger_note = ""
    try:
        scripted_rows = read_calls(ledger, since_epoch, strict=True)
        ledger_source_ok = True
    except AccountingUnavailable as exc:
        scripted_rows, ledger_source_ok, ledger_note = [], False, f"usage ledger: {exc}"
    scripted = tier_counts(scripted_rows)
    agents_note = ""
    if include_agents:
        agent_raw, journal_ok = agent_rows(since_epoch, units=units)
        agents = agent_counts(agent_raw)
        inventory = unit_inventory()
        missing = [u for u in units if u not in inventory] if inventory else []
        # ANY missing configured unit makes the count partial, i.e. unknown.
        agents_source_ok = journal_ok and not missing
        if not agents_source_ok:
            agents_note = ("journal unreadable" if not journal_ok
                           else f"no such unit: {', '.join(missing)}")
        elif not inventory:
            # systemctl could not answer, so "the unit exists" is unproven and
            # `journalctl -u <stale name>` exits 0 with no rows: that is a blind
            # source, not a quiet fleet (QA 2026-11-03).
            agents_source_ok = False
            agents_note = "systemd unit inventory unverifiable (systemctl list-unit-files failed or empty)"
    else:
        agents, agents_source_ok = {TIER_SUBSCRIPTION: 0, TIER_FALLBACK: 0, CHAIN_EXHAUSTED: 0, "served": 0}, True
    total = merge(scripted, agents)
    # Share from the SCRIPTED ledger ONLY: those paths record every attempt, so the
    # denominator is real. Agent rows are decision-only (see AGENT_FALLBACK_MIN), so
    # folding them in made 1,000 ordinary turns + 5 DeepSeek fallbacks read as 100%
    # (QA 2026-11-03).
    share, denom = fallback_share(scripted_rows)
    return {
        "scripted": scripted, "agents": agents, "total": total,
        # Named so nobody re-derives a percentage from it later.
        "agents_counts_complete": False,
        "fallback_share": round(share, 4), "denominator": denom,
        "ledger_source_ok": ledger_source_ok, "ledger_source_note": ledger_note,
        "agents_source_ok": agents_source_ok, "agents_source_note": agents_note,
        # A blind agent source makes the share unknowable, not healthy: report it
        # and page it, never "below the minimum" quiet.
        "judged": agents_source_ok and ledger_source_ok and denom >= MIN_CALLS_TO_JUDGE,
        "fallback_breach": agents_source_ok and ledger_source_ok and denom >= MIN_CALLS_TO_JUDGE
        and share > FALLBACK_SHARE_THRESHOLD,
        "agent_fallback_breach": agents_source_ok and agents[TIER_FALLBACK] >= AGENT_FALLBACK_MIN,
        "chain_dead": total[CHAIN_EXHAUSTED] > 0,
    }


# ── delivery ─────────────────────────────────────────────────────────────────
def slack_post_critical(msg: str) -> bool:
    """Post through scripts/lib/slack-notify.sh so the on-call <@UID> mentions
    and the delivery guards live in ONE place (a literal @name pings nobody)."""
    if not SLACK_LIB.exists():
        print(f"ERROR: {SLACK_LIB} missing", file=sys.stderr)
        return False
    env = {**os.environ, "MODEL_CHAIN_WATCHDOG_MSG": msg}
    if os.environ.get("MODEL_CHAIN_WATCHDOG_CHANNEL"):
        env["SLACK_CHANNEL"] = os.environ["MODEL_CHAIN_WATCHDOG_CHANNEL"]
    else:
        env.setdefault("SLACK_CHANNEL", DEFAULT_SLACK_CHANNEL)
    try:
        proc = subprocess.run(
            ["bash", "-c", 'source "$1" && slack_notify_critical "$MODEL_CHAIN_WATCHDOG_MSG"', "bash",
             str(SLACK_LIB)],
            env=env, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: slack-notify failed: {exc}", file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(f"ERROR: slack-notify rc={proc.returncode}: {(proc.stderr or '')[-300:]}", file=sys.stderr)
        return False
    return True


def maintenance_active() -> bool:
    """True iff a planned maintenance window is active (scripts/hydra-maintenance.sh
    is-active). Delegates to the sibling helper, which sources
    lib/maintenance-flag.sh, so the expiry/malformed logic lives in ONE place.

    This watchdog pages on model-chain health, and a fleet window stops the very
    codex subscription tier it counts - so without this guard a planned window
    looks exactly like a codex outage and pages #clio_devops. Any failure to
    resolve or run the helper returns False: a broken guard must never silence
    the watchdog (scripts/tests/maintenance-guard-drift.bats enforces the shape).
    """
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hydra-maintenance.sh")
    try:
        return subprocess.run(
            ["bash", helper, "is-active"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False,
        ).returncode == 0
    except Exception:  # noqa: BLE001 - fail-safe: any error => not in maintenance
        return False


def _state() -> dict:
    try:
        with open(STATE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _save_state(state: dict) -> None:
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=1), encoding="utf-8")
        tmp.replace(STATE_PATH)
    except OSError as exc:
        print(f"WARN: could not write watchdog state: {exc}", file=sys.stderr)


def _should_page(state: dict, key: str, now: float) -> bool:
    last = state.get(key)
    if not isinstance(last, (int, float)):
        return True
    return (now - float(last)) >= REPEAT_MINUTES * 60


def _mark_page(state: dict, key: str, now: float) -> None:
    state[key] = int(now)


# ── report ───────────────────────────────────────────────────────────────────
def _epoch(value: str) -> float:
    """Epoch seconds from an epoch string or an ISO8601 instant (Z allowed)."""
    text = str(value).strip()
    try:
        return float(text)
    except ValueError:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def render(a: dict, window_h: float) -> str:
    t, s, g = a["total"], a["scripted"], a["agents"]
    lines = [
        f"model-chain window {window_h:g}h (all sources): "
        f"subscription={t[TIER_SUBSCRIPTION]} fallback={t[TIER_FALLBACK]} "
        f"chain_exhausted={t[CHAIN_EXHAUSTED]}",
        # Share is scripted-only, so it is labelled with ITS denominator and reads
        # n/a (never a percentage) below the minimum sample.
        (f"  scripted: subscription={s[TIER_SUBSCRIPTION]} fallback={s[TIER_FALLBACK]} "
         f"exhausted={s[CHAIN_EXHAUSTED]} share={int(a['fallback_share'] * 100)}% "
         f"(n={a['denominator']}, min {MIN_CALLS_TO_JUDGE})") if a["judged"] else
        (f"  scripted: subscription={s[TIER_SUBSCRIPTION]} fallback={s[TIER_FALLBACK]} "
         f"exhausted={s[CHAIN_EXHAUSTED]} share=n/a (n={a['denominator']}, "
         f"min {MIN_CALLS_TO_JUDGE} not met)"),
        f"  agents:   fallback_events={g[TIER_FALLBACK]} exhausted={g[CHAIN_EXHAUSTED]} "
        f"(absolute, min {AGENT_FALLBACK_MIN}; decision-only rows — the runner logs "
        "nothing for a first-choice success, so this is never a share)",
    ]
    if s.get("capability"):
        lines.append(f"  capability-only fallbacks: {s['capability']} (the subscription cannot do "
                     "these requests at all — headless web search — so they are NOT outage "
                     "pressure and are excluded from the share)")
    if not a["ledger_source_ok"]:
        lines.append(f"  USAGE LEDGER UNREADABLE ({a.get('ledger_source_note')}) — scripted-path "
                     "counts are unknown, not zero")
    if not a["agents_source_ok"]:
        lines.append(f"  AGENT SOURCE UNKNOWN ({a.get('agents_source_note') or 'unreadable'}) — agent-turn "
                     "counts are unknown, not zero (a blind source is not health)")
    elif not a["judged"] and not a["chain_dead"]:
        lines.append("  below the minimum call count — not judged (silence here is not health)")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Model-chain tier watchdog")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="print the report only (default)")
    mode.add_argument("--alert", action="store_true", help="post to Slack on breach")
    mode.add_argument("--canary", action="store_true",
                      help="read-only deploy canary: per-tier counts over the +15m and +60m windows")
    ap.add_argument("--window-hours", type=float, default=1.0)
    ap.add_argument("--ledger", default=LEDGER_PATH, help=f"usage ledger (default {LEDGER_PATH})")
    ap.add_argument("--no-agents", action="store_true", help="scripted paths only (no gateway journal)")
    ap.add_argument("--at", default=None, help="evaluate as-if at this instant (epoch or ISO8601)")
    args = ap.parse_args(argv)

    try:
        now = _epoch(args.at) if args.at else dt.datetime.now(dt.timezone.utc).timestamp()
    except (TypeError, ValueError):
        print(f"ERROR: bad --at value {args.at!r}", file=sys.stderr)
        return 1

    if args.canary:
        # The deploy canary reads twice, +15m and +60m, and counts tiers. Both
        # windows are computed from the SAME read, so one run answers both and
        # nothing is written anywhere.
        report = {}
        for label, hours in (("last_15m", 0.25), ("last_60m", 1.0)):
            a = assess(now - hours * 3600, ledger=args.ledger, include_agents=not args.no_agents)
            report[label] = a
            print(f"# {label}", file=sys.stderr)
            print(render(a, hours), file=sys.stderr)
        print(json.dumps(report))
        return 0

    a = assess(now - args.window_hours * 3600, ledger=args.ledger, include_agents=not args.no_agents)
    print(json.dumps(a))
    print(render(a, args.window_hours), file=sys.stderr)

    if maintenance_active():
        # A planned fleet window stops the codex subscription tier, which is the
        # loudest thing this watchdog counts: page nothing, but SAY so (and never
        # report health, because nothing was measured).
        print("# maintenance window active (scripts/hydra-maintenance.sh is-active) — "
              "paging suppressed; this run proves nothing about model-chain health", file=sys.stderr)
        return 0

    breaches: list[tuple[str, str]] = []
    if not a["ledger_source_ok"]:
        breaches.append(("ledger_unreadable",
            ":warning: *Model-chain watchdog cannot read the usage ledger* — "
            f"`{a.get('ledger_source_note')}`. Scripted-path (credit review, credit trust, "
            "doc-verify, Caroline) tier counts are UNKNOWN, not zero. Every one of those "
            "paths could be on the metered fallback and this watchdog would not see it. "
            "Check the ledger path/permissions on the gateway host. Do not read this as health."))
    if not a["agents_source_ok"]:
        breaches.append(("agents_source_unreadable",
            ":warning: *Model-chain watchdog cannot read the agent journals* — "
            f"`journalctl -u {' -u '.join(GATEWAYS)}` ({a.get('agents_source_note') or 'unreadable'}) in the last "
            f"{args.window_hours:g}h, so agent-turn tier counts are UNKNOWN (not zero). "
            "Every agent turn could be on the DeepSeek fallback and this watchdog would "
            "not see it. Check journald access/retention on the gateway host; the scripted "
            "paths are still measured. The bearer of this page must not read it as health."))
    if a["chain_dead"]:
        breaches.append(("chain_dead", 
            ":rotating_light: *Model chain EXHAUSTED on the user path* — a user request got no "
            f"model answer at all in the last {args.window_hours:g}h "
            f"({a['total'][CHAIN_EXHAUSTED]} call(s) reached the end of the chain: subscription "
            f"`openai/gpt-6-sol` AND the fallback tier `{TIER_FALLBACK}` both failed). "
            "These paths DEFER, never guess — the queue will drain when a tier recovers. "
            "Check `scripts/lib/ensure-codex-auth.sh --check` and the OpenRouter key."))
    if a["fallback_breach"]:
        breaches.append(("fallback_share",
            ":warning: *User-path model chain is on the FALLBACK tier* — "
            f"{int(a['fallback_share'] * 100)}% of {a['denominator']} user-path model calls in the "
            f"last {args.window_hours:g}h were NOT served by the subscription "
            f"(threshold {int(FALLBACK_SHARE_THRESHOLD * 100)}%). That means the Codex/ChatGPT "
            "subscription quota is out (or its auth is dead), so every credit, claim, merge, "
            "refund, support and proof request is being answered by OpenRouter DeepSeek "
            f"(`{TIER_FALLBACK}`). Counts: subscription={a['total'][TIER_SUBSCRIPTION]} "
            f"fallback={a['total'][TIER_FALLBACK]} exhausted={a['total'][CHAIN_EXHAUSTED]}."))
    if a["agent_fallback_breach"]:
        breaches.append(("agent_fallback",
            ":warning: *Agent turns are falling back off the subscription* — "
            f"{a['agents'][TIER_FALLBACK]} agent-turn fallback event(s) in the last "
            f"{args.window_hours:g}h (absolute threshold {AGENT_FALLBACK_MIN}; this is a COUNT, "
            "not a share: the runner logs a decision only when a fallback happened, so there "
            "is no primary-success denominator on this side). Some agent turn reached the "
            f"`{TIER_FALLBACK}` metered tier instead of the Codex/ChatGPT subscription. "
            "The scripted share above is measured separately and is unaffected."))
    if not breaches:
        print("healthy", file=sys.stderr)
        return 0
    if not args.alert:
        print("BREACH (would alert; --check mode, no Slack sent)", file=sys.stderr)
        return 0

    state = _state()
    posted = 0
    for name, msg in breaches:
        key = f"{name}:{args.window_hours:g}"
        if not _should_page(state, key, now):
            print(f"suppressed (already paged within {REPEAT_MINUTES}min): {key}", file=sys.stderr)
            continue
        if slack_post_critical(msg):
            _mark_page(state, key, now)
            posted += 1
        else:
            _save_state(state)
            return 2
    _save_state(state)
    print(f"ALERT posted ({posted} of {len(breaches)})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
