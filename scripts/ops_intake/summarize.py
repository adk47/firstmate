#!/usr/bin/env python3
"""`summarize.py <conversation_id>` — the facts card for "give me a summary and suggest a resolution".

The card is built ONLY from code reads (`facts.collect`) plus at most one tool-less model call for a
≤ 40-word intent label (`intent.label`). It contains no prose the code did not measure, and it
prints, for every suggestion, the POLICY KEY that produced it — so a wrong mapping is a one-line PR
against `policies/ops-resolutions.json`, not an argument about a model's reasoning.

Format (dispatch spec §4):

    summarize · <ask_id> · account <hash> · facts: <k statuses / claims / merges / erasure / refund> ·
    intent: <label> · suggested: <rule key> -> <action> · executed: <action or none> ·
    sent: <line id or none> · ledger <row>

`family` (facts) is ONE line; the remaining fields are on the second line so the card survives a
narrow Slack pane without losing a field.

Exit codes: 0 card printed (whatever it says — a hand-off is a valid answer), 2 the card could not
be built at all (bad arguments). A failed FACT is not an exit code: the card says `unknown`.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from ops_intake import facts as facts_mod  # noqa: E402
from ops_intake import intent as intent_mod  # noqa: E402
from ops_intake import output_guard as guard_mod  # noqa: E402
from ops_intake import resolutions as res_mod  # noqa: E402

SLA_SECONDS = 5 * 60          # spec §5: a summary within 5 minutes, else the watcher escalates
QUOTE_OPEN, QUOTE_CLOSE = "«", "»"   # the ONE customer quote is delimited, never woven into prose


@dataclass
class Card:
    ask_id: str
    conversation_id: str
    facts: facts_mod.Facts
    quoted: facts_mod.QuotedText
    intent: intent_mod.Intent
    suggestion: res_mod.Suggestion
    policy_version: str
    elapsed_s: float = 0.0
    executed: str = "none"
    sent: str = "none"
    ledger_row: str = "none"

    # -- rendering -------------------------------------------------------------------------

    def render(self) -> str:
        head = f"summarize · {self.ask_id} · account {self.facts.account_hash()} · facts: {self.facts.counts_line()}"
        tail = (f"intent: {intent_mod.bounded_label(self.intent.label) or 'unknown'} · "
                f"suggested: {self.suggestion.render()} · "
                f"executed: {self.executed} · sent: {self.sent} · ledger {self.ledger_row}")
        lines = [head, tail]
        if self.quoted.quarantined:
            lines.append(f"customer text quarantined (injection watch {self.quoted.severity})")
        elif self.quoted.text:
            lines.append(f"customer {QUOTE_OPEN}{self.quoted.text}{QUOTE_CLOSE}")
        if self.facts.errors:
            lines.append("unmeasured: " + "; ".join(self.facts.errors))
        if self.intent.reason and not self.intent.ok:
            lines.append(f"intent unavailable: {self.intent.reason}")
        if self.elapsed_s > SLA_SECONDS:
            lines.append(f"SLA BREACH: summary took {int(self.elapsed_s)}s (budget {SLA_SECONDS}s)")
        return "\n".join(lines)

    def as_dict(self) -> dict[str, Any]:
        """The machine view. It redacts exactly what `render()` redacts.

        `render()` hashes the account and bounds/quarantines the customer text; a JSON view that
        printed the raw `account_id`, the contact's email/external id and the full conversation
        text would be the same leak through a different door - and `--json` output is what lands
        in a log, a ticket or a model prompt. So the identity facts are replaced by the same hash
        the card prints, and the customer text is emitted only when it is not quarantined and
        only in the bounded form `quote_customer_text` already produced.
        """
        redacted = {name: {"value": _redact(name, f.value, self.facts),
                           "source": f.source, "measured": f.measured}
                    for name, f in self.facts.facts.items()}
        return {
            "ask_id": self.ask_id,
            "conversation_id": self.conversation_id,
            "account_hash": self.facts.account_hash(),
            "facts": redacted,
            "fact_errors": self.facts.errors,
            "counts_line": self.facts.counts_line(redact=True),
            "quoted": {"text": None if self.quoted.quarantined else self.quoted.text,
                       "quarantined": self.quoted.quarantined,
                       "severity": self.quoted.severity},
            "intent": {"label": self.intent.label, "reason": self.intent.reason,
                       "model": self.intent.model, "llm_call_id": self.intent.llm_call_id},
            "suggested": {"rule": self.suggestion.rule_key, "action": self.suggestion.action.key,
                          "tier": self.suggestion.action.tier,
                          "executes_here": self.suggestion.action.executes_here,
                          "line": self.suggestion.line_id, "why": self.suggestion.why},
            "policy_version": self.policy_version,
            "executed": self.executed,
            "sent": self.sent,
            "ledger_row": self.ledger_row,
            "elapsed_s": round(self.elapsed_s, 1),
        }


# Facts whose VALUE is an identity or the raw conversation. `render()` never prints them; the
# JSON view must not either. `customer_text` is replaced by the bounded quote the card already
# carries, so a reader still sees what the customer said without a second, unbounded copy.
IDENTITY_FACTS = ("account_id", "contact_email", "contact_external_id", "contact_id")

# Facts whose value is a STRUCTURED row set. `render()` prints only an aggregate of these (a count,
# a status), so the JSON view must not print the rows: `read_requests` returns
# `{"id", "status", "profile_id"}` and `read_erasure` returns the register row
# (`id`, `register_no`, `class`, `status`, `due_at`, `hide_due_at`, `identity_verdict`,
# `hidden_at`). Those are raw request ids, profile ids and register numbers - exactly the
# identifiers `render()` withholds - and `--json` output is what lands in a log, a ticket or a
# model prompt. Each summarizer below keeps the shape a reader needs and drops the identifiers.

def _summarize_requests(value: Any) -> Any:
    if not isinstance(value, list):
        return value
    statuses: dict[str, int] = {}
    for row in value:
        if isinstance(row, dict):
            status = str(row.get("status") or "unknown")
            statuses[status] = statuses.get(status, 0) + 1
    return {"count": len(value), "statuses": statuses}


def _summarize_erasure(value: Any) -> Any:
    if not isinstance(value, dict):
        return value
    # `status` and `class` are categories; `hidden` is a boolean derived from `hidden_at`. The
    # register number, the row id and the due dates are identifiers and stay out.
    return {"status": value.get("status"), "class": value.get("class"),
            "hidden": bool(value.get("hidden_at"))}


STRUCTURED_FACTS: dict[str, Callable[[Any], Any]] = {
    "requests": _summarize_requests,
    "erasure": _summarize_erasure,
}


def _redact(name: str, value: Any, facts: facts_mod.Facts) -> Any:
    if name in IDENTITY_FACTS:
        return None if value is None else facts.account_hash()
    if name == "customer_text":
        return None if value is None else "<see quoted>"
    summarizer = STRUCTURED_FACTS.get(name)
    if summarizer is not None:
        return summarizer(value)
    return value


def build_card(conversation_id: str, *, ask_id: str = "", policy: res_mod.Policy | None = None,
               readers: facts_mod.Readers | None = None,
               judge: Callable[..., Any] | None = None,
               guard: Any = None,
               scan: Callable[[str], list[dict[str, str]]] | None = None,
               record: Callable[..., Any] | None = None,
               bank_ids: Iterable[str] | None = None,
               requester_email: str | None = None,
               requester_ids: Sequence[str] = (),
               intent_override: str | None = None,
               clock: Callable[[], float] = time.monotonic) -> Card:
    """Collect facts, quote the customer text once, label the intent, look the resolution up.

    `intent_override` exists for the tests and for a caller that already knows the label (e.g. a
    red-team replay); it is NOT a model path and cannot change what an action is allowed to do.
    """
    started = clock()
    if policy is None:
        policy = res_mod.Policy.load(bank_ids=bank_ids)
    collected = facts_mod.collect(conversation_id, readers=readers)
    quoted = facts_mod.quote_customer_text(
        collected.value("customer_text"), conversation_id=conversation_id,
        contact_id=collected.value("contact_id"), scan=scan, record=record)
    collected.put("customer_text_quarantined", quoted.quarantined,
                  "lib/injection_watch.scan (Caroline watch, HIGH => quarantined)")

    if intent_override is not None:
        got = intent_mod.Intent(label=intent_override if intent_override in policy.intent_labels else None,
                                reason="caller-supplied label")
    else:
        got = intent_mod.label(quoted.text if not quoted.quarantined else None,
                               policy.intent_labels, judge=judge, guard=guard,
                               quarantined=quoted.quarantined)

    suggestion = res_mod.suggest_for(collected, got.label, policy,
                                     requester_email=requester_email,
                                     requester_ids=requester_ids,
                                     quarantined=quoted.quarantined)
    return Card(ask_id=ask_id or f"conv-{conversation_id}", conversation_id=conversation_id,
                facts=collected, quoted=quoted, intent=got, suggestion=suggestion,
                policy_version=policy.version, elapsed_s=clock() - started)


def load_policy(bank_ids: Iterable[str] | None = None) -> res_mod.Policy:
    """The resolution policy, with the answer-bank ids so a typo'd `line` fails at LOAD.

    Public because the router's summarize-resolve answerer loads it too: one loader means the
    card and the reply cannot disagree about which lines exist.
    """
    return _policy_for_cli(bank_ids)


def _policy_for_cli(bank_ids: Iterable[str] | None) -> res_mod.Policy:
    """Load the policy with the answer-bank ids so a typo'd `line` fails at load, not at send-time.
    If the bank cannot be read (no node on this host), the policy still loads: the LINE check then
    happens in `answer.py`, where a reply is actually being built — never send on an unknown line."""
    ids = bank_ids
    if ids is None:
        try:
            ids = list(guard_mod.bank())
        except guard_mod.GuardUnavailable:
            ids = None
    return res_mod.Policy.load(bank_ids=ids)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Facts card + suggested resolution for one Intercom conversation.")
    p.add_argument("conversation_id")
    p.add_argument("--ask-id", default="", help="the j2 ops_asks row id, when this came from one")
    p.add_argument("--policy", default=None, help="override policies/ops-resolutions.json")
    p.add_argument("--requester-email", default="",
                   help="the requester's own email; a match to the contact is a refusal (j2 §4)")
    p.add_argument("--requester-id", action="append", default=[],
                   help="one of the requester's own presented ids (repeatable)")
    p.add_argument("--intent", default=None, help="skip the model call with a known label (tests/replays)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-model", action="store_true", help="never call a model; the label stays unknown")
    a = p.parse_args(argv)

    try:
        policy = res_mod.Policy.load(a.policy, bank_ids=None) if a.policy else _policy_for_cli(None)
    except res_mod.PolicyError as exc:
        print(f"POLICY ERROR: {exc}", file=sys.stderr)
        return 2

    judge = None
    if a.no_model and a.intent is None:
        judge = _refuse_model
    try:
        card = build_card(a.conversation_id, ask_id=a.ask_id, policy=policy, judge=judge,
                          requester_email=a.requester_email or None,
                          requester_ids=a.requester_id, intent_override=a.intent)
    except res_mod.PolicyError as exc:
        print(f"POLICY ERROR: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(card.as_dict(), indent=1, default=str) if a.json else card.render())
    return 0


def _refuse_model(*_a: Any, **_k: Any) -> Any:
    raise RuntimeError("--no-model: this run may not call a model")


if __name__ == "__main__":
    raise SystemExit(main())
