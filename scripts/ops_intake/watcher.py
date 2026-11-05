"""The escalation watcher and the daily digest for the ops-intake register.

Two jobs, both about the one thing the census proved was missing: a row that
someone actually acts on.

* ``overdue`` - every ask still ``open``/``ask`` past its ``due_at`` (Slack ts +
  30 minutes). The escalation is an append-only register event plus one page per
  run (the paging helper de-duplicates by content), and the ask moves to
  ``escalated`` so a second run does not re-page the same row forever. The
  watcher never invents an answer: the ONE row it may close as ``answered`` is a
  class-``other`` hand-off whose thread shows the agent turn actually replied
  (``verdict_source='agent'``); an unanswered or unreadable hand-off escalates.
* ``digest`` - the daily line: asks by class, answered-by-code, escalated,
  held/quarantined. Posted to #clio_devops at 07:00 UTC.

**Scheduling note (j-w1).** The *scheduling* of ``overdue`` belongs to firstmate
lane ``jan-asks-watch-w1``; this module ships the query and the escalation so
that lane does not have to re-derive what "overdue" means, and so the code that
decides it is the same code that wrote the row. The digest timer IS installed
here (ops-intake-digest.timer) because it must cover this register regardless of
which lane ends up owning the tick, and it reports the overdue COUNT, so an
unowned tick cannot hide.

The store and Slack client are injected, so a test can run both commands with a
temp sqlite file and no network.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

if __package__ in (None, ""):  # pragma: no cover - CLI path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from ops_intake import answer as answer_mod
    from ops_intake import ledger as ledger_mod
    from ops_intake import store as store_mod
else:
    from . import answer as answer_mod
    from . import ledger as ledger_mod
    from . import store as store_mod

PAGE_PREFIX = "ops-intake"


def escalate(store: store_mod.AskStore, *, now: datetime | None = None,
             page: Callable[[str], None] | None = None,
             agent_replied: Callable[[dict[str, Any]], bool] | None = None,
             ledger: "ledger_mod.ActionLedger | None" = None
             ) -> dict[str, Any]:
    """Escalate what is genuinely unanswered.

    A class-``other`` row is a HAND-OFF, not an answer: the agent turn owns it. So
    before escalating one, ask ``agent_replied`` whether the bot actually posted in
    the thread. Yes -> close it as answered-by-agent; no or unreadable -> escalate
    and page (a failed agent turn must never be silent).

    A run with no ``page`` is an INSPECTION: it reports the backlog and changes
    nothing, so reading the queue can never consume it. A hand-off is never
    escalated without the thread check, because "unchecked" is not "unanswered".
    """
    now = now or datetime.now(timezone.utc)
    rows = store.overdue(now=now)
    closed: list[str] = []
    if agent_replied is not None:
        pending = []
        for row in rows:
            if row["class"] != "other":
                pending.append(row)
                continue
            try:
                replied = agent_replied(row)
            except Exception as exc:  # noqa: BLE001 - unreadable is not "answered"
                store.event(row["ask_id"], "agent-reply-unknown", type(exc).__name__)
                pending.append(row)
                continue
            if not replied:
                pending.append(row)
                continue
            store.transition(row["ask_id"], "answered",
                             verdict="agent turn replied in the thread",
                             verdict_source="agent")
            store.event(row["ask_id"], "agent-replied", "thread reply found")
            closed.append(row["ask_id"])
        rows = pending
    handoffs = ([row["ask_id"] for row in rows if row["class"] == "other"]
                if agent_replied is None else [])
    orphaned = ([row["id"] for row in ledger.orphaned_plans(now=now)]
                if ledger is not None else [])
    escalatable = [row for row in rows if row["ask_id"] not in set(handoffs)]
    delivered = False
    if (escalatable or orphaned) and page is not None:
        lines = ([f"{PAGE_PREFIX}: {len(escalatable)} ask(s) past due_at, still unanswered"]
                 if escalatable else [f"{PAGE_PREFIX}: no ask is past due_at"])
        for row in escalatable[:10]:
            lines.append(f"- {row['ask_id']} {row['class']} by {row['requester_id']} "
                         f"due {row['due_at']}")
        if len(escalatable) > 10:
            lines.append(f"- ... +{len(escalatable) - 10} more")
        if handoffs:
            lines.append(f"- {len(handoffs)} hand-off(s) awaiting the agent turn "
                         f"(not escalated without the thread check)")
        if orphaned:
            lines.append(f"- {len(orphaned)} ledger plan(s) older than an hour with no "
                         f"applied/failed result: {', '.join(str(i) for i in orphaned[:10])}")
        lines.append("No coded answer landed; the row, not a sentence, is the queue.")
        delivered = page(answer_mod.escape_mrkdwn("\n".join(lines))) is not False
    escalated: list[str] = []
    if delivered:
        for row in escalatable:
            store.transition(row["ask_id"], "escalated",
                             note=f"watcher: past due_at {row['due_at']}")
            store.event(row["ask_id"], "escalated", f"due_at={row['due_at']}")
            escalated.append(row["ask_id"])
    return {"overdue": len(rows), "escalated": escalated,
            "handoffs_awaiting_agent": handoffs,
            "orphaned_plans": orphaned,
            "agent_answered": closed, "paged": delivered,
            "checked_at": store_mod.utcnow()}


def digest(store: store_mod.AskStore, *, day: datetime | None = None,
           page: Callable[[str], None] | None = None,
           ledger: "ledger_mod.ActionLedger | None" = None) -> dict[str, Any]:
    data = store.digest(day=day)
    answered = data["answered_by_code"]
    escalated = data["by_state"].get("escalated", 0)
    held = data["by_state"].get("held", 0)
    quarantined = data["by_state"].get("quarantined", 0)
    refused = data["by_state"].get("refused", 0)
    open_now = len(store.overdue(now=day or datetime.now(timezone.utc)))
    orphaned = len(ledger.orphaned_plans(now=day)) if ledger is not None else 0
    classes = ", ".join(f"{k}={v}" for k, v in data["by_class"].items()) or "none"
    line = (f"{PAGE_PREFIX} digest {data['day']}: asks={data['asks']} classes[{classes}] "
            f"answered-by-code={answered} agent-handled={data['agent_handled']} "
            f"escalated={escalated} held={held} "
            f"quarantined={quarantined} refused={refused} open-past-due={open_now} "
            f"orphaned-plans={orphaned}")
    if page is not None:
        page(line)
    data.update({"answered": data["by_state"].get("answered", 0), "held": held,
                 "quarantined": quarantined, "refused": refused,
                 "open_past_due": open_now, "orphaned_plans": orphaned, "line": line})
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ops-intake escalation + digest")
    parser.add_argument("command", choices=("overdue", "digest"))
    parser.add_argument("--post", action="store_true", help="page #clio_devops")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    store = store_mod.AskStore()
    ledger = ledger_mod.ActionLedger()
    page_fn = None
    replied_fn = None
    if args.post:
        try:
            from .slack import page as _page  # noqa: PLC0415
            from .slack import thread_has_bot_reply as _replied  # noqa: PLC0415
        except ImportError:  # `python3 scripts/ops_intake/watcher.py`
            from ops_intake.slack import page as _page  # noqa: PLC0415
            from ops_intake.slack import thread_has_bot_reply as _replied  # noqa: PLC0415

        page_fn = _page

        def replied_fn(row: dict[str, Any]) -> bool:
            return _replied(channel=row["slack_channel"],
                            thread_ts=row["slack_thread"] or row["slack_ts"],
                            after_ts=row["slack_ts"], ask_id=row["ask_id"])

    result = escalate(store, page=page_fn, agent_replied=replied_fn, ledger=ledger) \
        if args.command == "overdue" else digest(store, page=page_fn, ledger=ledger)
    if args.json or not args.post:
        print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
