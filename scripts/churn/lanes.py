"""Where a fix ticket goes: the intake its OWNER already reads. Never a queue of our own.

Routing is not a new queue (dispatch spec 1, ruling R4). Each lane already has an owner, and
the campaign's job is to arrive where that owner looks:

    lane            owner (real reader)                             how this lane routes
    ------------------------------------------------------------------------------------------
    credit-review   the decider cron, scripts/credit_review/       the churn priority list:
                    decide.py -> order_rows() (paid_tier)          <state>/intake/churn-priority.json
    proof           the same decider (proof-on-file holds) +       the same priority list
                    the doc-verify re-read
    refund          a person, on the support board                 ClickUp task (901000600160)
    claim           a person, on the support board                 ClickUp task
    merge           a person, on the support board                 ClickUp task
    analytics       a person, on the support board                 ClickUp task
    caroline-drain  a person, on the support board                 ClickUp task

Two consequences worth stating plainly, because the first version of this file got them wrong:

* **The credit and proof lanes write NO ticket and NO new file for a drain to discover.** Those
  users' open requests are already in the decider's queue; a paid-first ordering is what they
  lack (a churned user is by definition not "paying" any more, so ``paid_tier`` demotes them to
  the free segment at the exact moment we owe them most). So the campaign writes ONE document -
  the churn priority list - and ``credit_review.decide.order_rows`` reads it. That reader is in
  this same change: a priority file nobody reads would be a lie with a schema.

* **The ClickUp board is the intake for everything a person does**, and it is genuinely drained:
  ``scripts/resolve-notify.py``, ``scripts/clickup-todo-dedupe.py`` and the support agents read
  list 901000600160 through the ``hydra-action-request`` contract
  (workspaces/support/skills/action-request/SKILL.md). A task carries the ``churned:<date>`` tag,
  paid priority with an expiry, the measured evidence, and the read-back rule that says when it
  may be marked ``customer-outcome:complete``.

A real (``apply``) run with no ClickUp credentials REFUSES those lanes (``LaneUnavailable``)
instead of inventing a reference: a placeholder ``lane_ref`` would look routed in the ledger and
could never be read back, so the user would never be fixed and never be messaged.

Nothing here approves anything, decides anything, or messages anyone.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from . import cli, model

STATE_DIR_DEFAULT = "/var/lib/hydra/churn"

#: Lanes whose owner is the decider cron: they route through the priority list, not a ticket.
PRIORITY_LANES = (model.CREDIT_REVIEW, model.PROOF)
#: Lanes whose owner is a person on the support board.
BOARD_LANES = (model.CLAIM, model.MERGE, model.ANALYTICS, model.REFUND, model.CAROLINE)
#: The one file this module writes, relative to <state>/intake/. READ BY
#: ``credit_review.decide.order_rows`` (``load_churn_priority``); it is the R4 sort key.
PRIORITY_FILE = "churn-priority.json"
PRIORITY_SCHEMA = "churn-priority/v1"


class LaneUnavailable(RuntimeError):
    """The lane's real intake cannot be reached from here, so nothing was routed."""

#: G8 refund classes (refund-judge-build-r1). The evidence decides, the lane judges; an
#: unclassifiable charge is still routed, labelled so, because silence is the failure mode
#: this whole campaign exists to end.
G8_ACCIDENTAL_ANNUAL = "g8-accidental-annual"
G8_CHARGED_AFTER_CANCEL = "g8-charged-after-cancel"
G8_REFUND_ASKED_UNANSWERED = "g8-refund-asked-unanswered"
G8_UNCLASSIFIED = "g8-unclassified"


def marker(ticket_id: str) -> str:
    """The machine marker a ClickUp description carries, so dedupe never reads a name."""
    return f"churn-fix-ticket:{ticket_id}"


def _money(cents: int) -> str:
    return f"${cents / 100:,.2f}"


@dataclass(frozen=True)
class Payload:
    """One intake ticket, already ordered and labelled. Rendering is lane-specific."""

    lane: str
    ticket_id: str
    payload: dict[str, Any]

    def as_line(self) -> dict[str, Any]:
        return {"lane": self.lane, "ticket_id": self.ticket_id, **self.payload}


def refund_class(evidence: list[str], *, refunds: int, annual: bool) -> str:
    """Best-supported G8 class from the measured evidence; never a guess dressed as one."""
    text = " ".join(evidence).lower()
    if "refund" in text and "unanswered" in text:
        return G8_REFUND_ASKED_UNANSWERED
    if "charged after cancel" in text or ("after cancel" in text and "charge" in text):
        return G8_CHARGED_AFTER_CANCEL
    if refunds:
        return G8_REFUND_ASKED_UNANSWERED
    if annual:
        return G8_ACCIDENTAL_ANNUAL
    return G8_UNCLASSIFIED


def build(row: Mapping[str, Any], *, policy: Mapping[str, Any], lane: str) -> Payload:
    """The common ticket, plus the lane's own fields. Pure: same row in, same payload out."""
    cand = row.get("candidate") if isinstance(row.get("candidate"), Mapping) else row
    evidence = [str(e) for e in (row.get("evidence") or cand.get("evidence") or [])]
    ticket_id = str(row["ticket_id"])
    base: dict[str, Any] = {
        "tag": row["churned_tag"],
        "tags": [row["churned_tag"], "paid-priority", f"cause:{row['primary_class']}"],
        "priority": "paid",
        "priority_until": float(row["paid_priority_until"]),
        "user_id": row["user_id"],
        "tier": row["tier"],
        "cause_class": row["primary_class"],
        "classes": list(cand.get("classes") or []),
        "list_mrr": round(int(row["mrr_cents"]) / 100.0, 2),
        "wait_days": round(float(row["wait_days"]), 1),
        "cancel_at": float(row["cancel_at"]),
        "routed_at": float(row["routed_at"]),
        "marker": marker(ticket_id),
        "evidence": evidence,
        "ask": "close the thing this user was waiting on, then write the outcome where it can be read back",
        "no_customer_contact": True,
    }
    lane_fields: dict[str, Any] = {}
    if lane == model.CREDIT_REVIEW:
        credit_open = cand.get("credit_open") or {}
        lane_fields = {
            "queue": "held-row head",
            "open_credits": int(credit_open.get("open") or 0),
            "oldest_credit_at": credit_open.get("oldest"),
            "times_told": int(credit_open.get("asked") or 0),
            "judge_now": True,
            "apply_when": "hydra#1555 decider writer is live (judge the ruling now, apply on wake)",
            "readback": "a decision_outcomes row for this user AND a verify_messages status row",
        }
    elif lane == model.PROOF:
        lane_fields = {
            "queue": "proof_intake re-read",
            "recheck": True,
            "status_family": "status-doc-received",
            "readback": "approved credits on the re-read AND a verify_messages status row",
        }
    elif lane == model.CLAIM:
        lane_fields = {
            "queue": "claim-proof-check-c2 list head",
            "claims": cand.get("claims") or {},
            "readback": "a processed claim (claim-status outcome), then the credit line",
        }
    elif lane == model.MERGE:
        lane_fields = {
            "action": "merge",
            "queue": "merge-queue-clear-q1 ClickUp intake",
            "intercom_convs": list(cand.get("intercom_convs") or []),
            "readback": "the merge task reaches customer-outcome:complete",
        }
    elif lane == model.ANALYTICS:
        lane_fields = {
            "action": "analytics-followup",
            "queue": "analytics-followup ClickUp intake",
            "profile_id": cand.get("profile_id"),
            "profile_id_source": "resolved by the lane from user_id (profile_status); never assumed here",
            "stale_metric_evidence": evidence,
            "intercom_convs": list(cand.get("intercom_convs") or []),
            "readback": "the analytics task reaches customer-outcome:complete with a fresh as_of",
        }
    elif lane == model.REFUND:
        charge = int(cand.get("charge_cents") or (int(row["mrr_cents"]) * 12
                                                  if "annual" in str(cand.get("plan") or "").lower()
                                                  else int(row["mrr_cents"])))
        escalate = charge > model.SYSTEMIC_REFUND_CENTS
        lane_fields = {
            "queue": "cs-systemic-c3" if escalate else "refund-judge G8",
            "escalate_to": "cs-systemic-c3" if escalate else None,
            "charge_cents": charge,
            "charge": _money(charge),
            "g8_class": refund_class(evidence, refunds=int(cand.get("refunds") or 0),
                                     annual="annual" in str(cand.get("plan") or "").lower()),
            "refunds_on_file": int(cand.get("refunds") or 0),
            "disputes": int(cand.get("disputes") or 0),
            "customer_id": cand.get("customer_id"),
            "readback": (
                "close the task, keep the customer-outcome:complete tag, and write BOTH "
                "`stripe_refund_id: re_...` and `stripe_refund_amount: <dollars>` in the task body "
                "(a closed task with the id but no amount cannot be read back, so the customer is never told)"),
        }
    elif lane == model.CAROLINE:
        lane_fields = {
            "queue": "paid-threads-answer-a1 backlog drain",
            "human_quality": True,
            "sweep_copy": False,
            "never_automated_reply": True,
            "intercom_convs": list(cand.get("intercom_convs") or []),
            "promise_not_kept": "promise_not_kept" in " ".join(evidence).lower()
            or str(row.get("primary_class")) == "other",
            "readback": "the thread closed by an ADMIN reply of >= 40 words that is not a sweep line",
        }
    base.update(lane_fields)
    return Payload(lane=lane, ticket_id=ticket_id, payload=base)


# ── the churn priority list (read by the credit decider) ────────────────────
def priority_path(state_dir: str | Path) -> Path:
    return Path(state_dir) / "intake" / PRIORITY_FILE


def write_priority_lane(payload: Payload, *, state_dir: str | Path, apply: bool) -> str:
    """Add this user to the decider's churn priority list. Returns the lane_ref.

    The document is the sort key, not a queue of work: ``{"schema", "generated_at", "entries"}``
    where each entry is ``{user_id, until, tier, cause_class, ticket_id}``. ``until`` is an epoch,
    so the flag lapses on its own without another run and nothing has to remember to remove it.

    ``apply=False`` returns the same ref and writes nothing: a dry run must be able to say what it
    would have done without doing it.
    """
    path = priority_path(state_dir)
    ref = f"intake/{path.name}#{payload.ticket_id}"
    if not apply:
        return ref
    line = payload.as_line()
    doc: dict[str, Any] = {"schema": PRIORITY_SCHEMA, "generated_at": line["routed_at"], "entries": []}
    if path.exists():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and isinstance(loaded.get("entries"), list):
                doc = loaded
        except (OSError, ValueError):
            keep = path.with_suffix(path.suffix + ".unreadable")
            os.replace(path, keep)  # never silently drop a list we could not parse
    entry = {
        "user_id": line["user_id"],
        "until": line["priority_until"],
        "tier": line["tier"],
        "cause_class": line["cause_class"],
        "ticket_id": payload.ticket_id,
    }
    doc["entries"] = [e for e in doc.get("entries") or []
                      if isinstance(e, dict) and str(e.get("user_id")) != str(entry["user_id"])]
    doc["entries"].insert(0, entry)
    doc["generated_at"] = max(float(doc.get("generated_at") or 0.0), float(line["routed_at"]))
    cli.write_private_json(path, doc)
    return ref


# ── ClickUp lanes ────────────────────────────────────────────────────────────
CLICKUP_TOKEN_ENV = ("CLICKUP_API_KEY", "MUSOAI_CLICKUP_API_KEY")


def clickup_token(environ: Mapping[str, str] | None = None) -> str | None:
    env = environ if environ is not None else os.environ
    for name in CLICKUP_TOKEN_ENV:
        tok = (env.get(name) or "").strip()
        if tok:
            return tok
    return None


def task_body(payload: Payload, *, policy: Mapping[str, Any]) -> dict[str, Any]:
    """The ClickUp task: the support board's own contract, plus the churn tag and marker."""
    cfg = (policy.get("clickup") or {})
    action = (cfg.get("actions") or {}).get(payload.lane, {})
    line = payload.payload
    tags = list(cfg.get("base_tags") or []) + [cfg.get("tier_tag") or "tier-2"]
    if action.get("action_tag"):
        tags.append(action["action_tag"])
    tags.append(line["tag"])
    description = "\n".join(
        [
            f"<!-- {line['marker']} -->",
            f"**Churned paying user with an unhandled support state** ({line['tag']}, paid priority until "
            f"{_epoch_day(line['priority_until'])}).",
            "",
            f"- user id: `{line['user_id']}`",
            f"- tier: {line['tier']} · cause: {line['cause_class']}",
            f"- list MRR at cancel: {_money(int(round(line['list_mrr'] * 100)))} · waited {line['wait_days']} d",
        ]
        + ([f"- profile id: `{line['profile_id']}`"] if line.get("profile_id") else [])
        + ["", "**Evidence (measured)**", *[f"- {e}" for e in line.get("evidence") or []]]
        + ["", f"**Read-back rule:** {line.get('readback', '')}", "",
           "Nothing is owed to the customer from this task's existence alone: mark it "
           "`customer-outcome:complete` only when the customer-visible result is really done."]
    )
    return {
        "name": action.get("title") or f"Churned user fix ({line['cause_class']})",
        "description": description,
        "tags": tags,
        "priority": 2,
    }


def _epoch_day(ts: Any) -> str:
    try:
        import time as _t
        return _t.strftime("%Y-%m-%d", _t.gmtime(float(ts)))
    except (TypeError, ValueError):
        return "unknown"


def find_clickup_task(client: Any, list_id: str, ticket_id: str, *, max_pages: int = 20) -> str | None:
    """Existing task carrying this ticket's marker, or None. Raises on a partial scan."""
    want = marker(ticket_id)
    for task in client.list_tasks(list_id, [("include_closed", "true"), ("subtasks", "false")], max_pages):
        text = f"{task.get('name') or ''}\n{task.get('description') or ''}\n{task.get('text_content') or ''}"
        if want in text:
            return str(task.get("id"))
    return None


def write_clickup_lane(payload: Payload, *, policy: Mapping[str, Any], client: Any,
                       apply: bool, task_cache: dict[str, str] | None = None) -> str:
    """Create the ClickUp task (or reuse the one already carrying this marker)."""
    cfg = policy.get("clickup") or {}
    list_id = str(cfg.get("list_id") or "")
    if not list_id:
        raise ValueError("policies/winback-fix.json clickup.list_id is required for the ClickUp lanes")
    if client is None:
        if apply:
            # A placeholder ref would be persisted as "already routed", and no reader could ever
            # verify a task id that is not a task id: the user would never be fixed, never messaged.
            raise LaneUnavailable(
                "no CLICKUP_API_KEY / MUSOAI_CLICKUP_API_KEY: this lane's intake is the support board, "
                "so nothing was routed (install the token and re-run: the ticket stays unrouted)")
        return f"clickup:{list_id}#{payload.ticket_id}"  # dry run without a client: the ref it would use
    if not apply:
        return f"clickup:{list_id}#{payload.ticket_id}"
    existing = find_clickup_task(client, list_id, payload.ticket_id)
    if existing:
        return existing
    status, body = client.request("POST", f"/list/{list_id}/task", body=task_body(payload, policy=policy))
    if status not in (200, 201) or not isinstance(body, dict) or not body.get("id"):
        raise RuntimeError(f"clickup create -> {status}: {body.get('err') if isinstance(body, dict) else body}")
    task_id = str(body["id"])
    if task_cache is not None:
        task_cache[payload.ticket_id] = task_id
    return task_id


def write(payload: Payload, *, state_dir: str | Path, policy: Mapping[str, Any], apply: bool,
          client: Any = None) -> str:
    """Put one ticket where its lane's OWNER reads it. Returns the lane_ref recorded on the ticket."""
    if payload.lane in PRIORITY_LANES:
        return write_priority_lane(payload, state_dir=state_dir, apply=apply)
    if payload.lane in BOARD_LANES:
        return write_clickup_lane(payload, policy=policy, client=client, apply=apply)
    raise LaneUnavailable(f"lane {payload.lane!r} has no intake: model.LANES and this dispatch disagree")


def render_preview(payload: Payload, *, policy: Mapping[str, Any]) -> str:
    """What the lane will actually receive - printed by --dry-run so it is reviewable."""
    if payload.lane in BOARD_LANES:
        return json.dumps(task_body(payload, policy=policy), indent=1, sort_keys=True)
    return json.dumps(payload.as_line(), indent=1, sort_keys=True)


def sweep_copy_like(text: str) -> bool:
    """Is this a sweep/automated close rather than a human answer?

    The "other" FIX_LINE quotes a human reply, so the read-back has to tell a person's answer
    from the sweepers' (cs-stale-drain / close-resolved / cs-ops-drain close silently and
    sometimes post a one-liner). Anything matching the sweeps' own vocabulary is refused.
    """
    if not text:
        return True
    low = text.lower()
    return bool(
        re.search(
            r"closing this (?:chat|conversation|ticket)|no response|"
            r"auto(?:matic(?:ally)?)?[- ]closed|this (?:chat|ticket) (?:has|was) been closed|"
            r"sorted for you|resolved for you",
            low,
        )
    )
