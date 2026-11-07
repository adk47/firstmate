"""The coded answerers and the one reply contract.

Every class except ``other`` is answered HERE, from code, with the evidence it
actually read. No model judges a credit on this surface, no agent turn decides a
hide, and no reply says anything the code did not measure - the three failures
the Jan-asks census documented:

* "Queued for FirstMate" on >= 24 proof asks, with no queue behind it;
* "Firstmate's independent read-only verdict: INSUFFICIENT" written by the Ops
  agent's own model turn 4 minutes after the ask;
* "Profile-only hide, credits remain intact" on every hide, where the mechanism
  was ``DELETE /admin/profile`` and the read-back showed 431 -> 0 credits.

The reply contract (spec j2 item 5) is one line:

    <class> · <ask_id> · <verdict or state> · <evidence ids> · <next coded step> · <ledger row id>

and :func:`render` REFUSES to produce it when the text would claim something the
row does not support: "queued"/"pending" without a due time, any credit
judgement whose ``verdict_source`` is not a coded source, and any "Firstmate"
attribution without a ruling file. A refusal to render is caught by the router,
which answers with :func:`render_minimal` and pages - never with the ambitious
sentence.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field, replace
from typing import Any, Callable, Protocol

from . import fraud, guard, ids as ids_mod, policy as policy_mod

SEP = " · "

# Verdict sources that may stand behind a credit-shaped statement. ``none`` is
# not one of them: an unanswered ask says so, it does not estimate.
CODED_SOURCES = ("coded", "dv_outcomes", "register", "fraud-lens", "queue")

PENDING_WORDS = ("queued", "pending", "in progress", "will be", "working on it")
ATTRIBUTION = re.compile(r"\bfirstmate\b", re.IGNORECASE)

# Statements no reply on this surface may make, whatever a backend returned.
FORBIDDEN_CLAIMS = (
    "credits remain intact",
    "profile-only hide",
    "i approved",
    "we approved",
    "credit approved",
    "merged the profiles",
    "refunded",
)


class ContractViolation(RuntimeError):
    """The reply would claim something the row cannot support."""


@dataclass(frozen=True)
class WriteRequest:
    """One W1 write the answerer wants, with the inverse it recorded."""

    action: str
    target: str | None
    params: dict[str, Any]
    inverse_action: str
    inverse_params: dict[str, Any]


@dataclass
class Answer:
    """A coded answer: the state word, the evidence, the next step, and at most
    one W1 write request."""

    state: str                       # answered | ask | refused | held | quarantined | failed
    verdict: str                     # the one measured sentence-fragment
    verdict_source: str = "coded"
    evidence: str = ""
    next_step: str = ""
    write: WriteRequest | None = None
    page: str | None = None          # page message, when the answer needs a human
    lens: fraud.LensResult | None = None
    due_at: str | None = None
    notes: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.page is not None and not isinstance(self.page, str):
            raise TypeError(
                f"Answer.page must be a message string, not {type(self.page).__name__}")


def page_for_lens(lens: fraud.LensResult | None, ask_id: str | None) -> str | None:
    """The page MESSAGE for a lens result that demands a human, or None.

    ``LensResult.page`` is a FLAG; ``Answer.page`` is the text a human reads. This
    is the one place the flag becomes a message, so a bool can never reach the
    pager (where it would be undeliverable and would crash the failure path).
    """
    if lens is None or not lens.page:
        return None
    reasons = ",".join(lens.reasons) or lens.decision
    return f"ops-intake: fraud lens paged ask {ask_id or '-'} ({lens.decision}: {reasons})"


@dataclass
class Reply:
    cls: str
    ask_id: str
    state: str
    verdict: str
    evidence: str
    next_step: str
    ledger_row: str = "-"

    def render(self) -> str:
        return SEP.join([self.cls, self.ask_id, f"{self.state}: {self.verdict}",
                         self.evidence or "ids=none", self.next_step or "next=none",
                         self.ledger_row])


MRKDWN_FORMATTING = ("*", "_", "`", "~")


def escape_mrkdwn(text: str) -> str:
    """Make user-derived text inert in Slack: no live mentions, links or markup.

    The ONE boundary every reply and every page passes through. A profile display
    name, an Intercom message or a ClickUp title is user text, and ``<!channel>``
    or ``<https://evil|label>`` in it must render as characters, never as a ping
    or a link; ``*``/``_``/`````/``~`` are broken up so they cannot format the
    line either. The contract fields (class, ask id, state, ledger row) are
    code-owned and are not escaped.
    """
    escaped = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    for char in MRKDWN_FORMATTING:
        escaped = escaped.replace(char, char + "\u200b")
    return escaped


def render(*, cls: str, ask_id: str, answer: Answer, due_at: str | None,
           ledger_row: int | None, fmt: dict[str, Any] | None = None) -> str:
    """Build the contract line, refusing every unmeasured claim."""
    verdict = (answer.verdict or "").strip()
    next_step = (answer.next_step or "").strip()
    evidence = (answer.evidence or "").strip()

    lowered = f"{verdict} {next_step}".lower()
    for claim in FORBIDDEN_CLAIMS:
        if claim in lowered:
            raise ContractViolation(f"forbidden claim in reply: {claim!r}")

    # "Queued"/"pending" is allowed ONLY with a named due time. The row that the
    # watcher escalates is the ask row itself, which the router wrote before any
    # answerer ran and whose id is already in this line - so a pending reply that
    # names its due time IS pointing at a row that will be chased.
    if answer.state in ("open", "ask") or any(w in lowered for w in PENDING_WORDS):
        if not due_at:
            raise ContractViolation("queued/pending without a due time")
        if not ask_id:
            raise ContractViolation("queued/pending without an ask row")
        # The due time is part of the line, not decoration: "soon" is not a queue.
        next_step = f"{next_step} [due {due_at}]"

    if ATTRIBUTION.search(f"{verdict} {next_step} {evidence}"):
        if not str(answer.verdict_source).startswith("firstmate-ruling"):
            raise ContractViolation("Firstmate attributed without a ruling file")
        if answer.verdict_source in CODED_SOURCES:
            raise ContractViolation("Firstmate attributed with a coded source")

    if not evidence:
        raise ContractViolation("reply carries no evidence field")

    reply = Reply(cls=cls, ask_id=ask_id, state=answer.state,
                  verdict=escape_mrkdwn(verdict),
                  evidence=escape_mrkdwn(evidence),
                  next_step=escape_mrkdwn(next_step),
                  ledger_row=f"ledger={ledger_row}" if ledger_row is not None else "ledger=-")
    line = reply.render()
    # A contract line is ONE Slack line. Anything longer is a report, not a reply.
    if len(line) > 900:
        raise ContractViolation("reply exceeds one Slack message")
    return line


def render_minimal(*, cls: str, ask_id: str, state: str, due_at: str | None,
                   ledger_row: int | None = None) -> str:
    """The fallback when a backend produced text that broke the contract."""
    due = f"due={due_at}" if due_at else "due=none"
    return SEP.join([cls, ask_id, f"{state}: contract-fallback",
                     "ids=none", escape_mrkdwn(f"next=human-review ({due})"),
                     f"ledger={ledger_row}" if ledger_row is not None else "ledger=-"])


# ---------------------------------------------------------------------------
# Backends: every production read is injected, so the tests run the real logic
# with fake data and NOTHING here can reach Trino, Intercom or ClickUp by accident.
# ---------------------------------------------------------------------------


class Poster(Protocol):
    def __call__(self, *, channel: str, thread_ts: str | None, text: str) -> str | None: ...


class Pager(Protocol):
    def __call__(self, text: str) -> None: ...


@dataclass
class Backends:
    # proof-review: the coded verdicts (dv_outcomes / proof store), keyed by
    # whatever ids the ask named. Returns {"verdict","source","request_ids"} or None.
    dv_outcomes: Callable[[ids_mod.ExtractedIds], dict[str, Any] | None] | None = None
    # summarize-resolve: the Intercom conversation parts, read-only.
    intercom_conversation: Callable[[str], dict[str, Any] | None] | None = None
    # summarize-resolve: the non-conversation fact seams. None = the real readers.
    readers: Any = None
    # profile-edit: the CURRENT display name, read before a rename so the inverse
    # can restore it. Absent = no rename, because no inverse, no write.
    profile_name: Callable[[str], str | None] | None = None
    # status-report / clickup: coded counts.
    status_counts: Callable[[ids_mod.ExtractedIds], dict[str, Any] | None] | None = None
    clickup_counts: Callable[[], dict[str, Any] | None] | None = None
    # register: the erasure register row for a profile id (hide path + verdict).
    register_row: Callable[[str], dict[str, Any] | None] | None = None
    # fraud lens (ProductionLens in production, a fake in tests).
    lens: fraud.ProductionLens | None = None
    # W1 adapters, by action name. ABSENT = no writer wired for that action, so a
    # plan is recorded with its inverse and marked as not executed.
    writers: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = field(default_factory=dict)
    poster: Poster | None = None
    pager: Pager | None = None

    def writer(self, action: str) -> Callable[[dict[str, Any]], dict[str, Any]] | None:
        return self.writers.get(action)


# ---------------------------------------------------------------------------
# Per-class answerers.
# ---------------------------------------------------------------------------


def _ids_evidence(ids: ids_mod.ExtractedIds) -> str:
    return ids.evidence()


def answer_proof_review(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                        backends: Backends, due_at: str) -> Answer:
    """Verdict from coded outcomes ONLY. No outcome = pending, named, never guessed."""
    if not ids.intercom and not ids.request:
        return Answer(state="ask", verdict="no intercom conversation or request id in the ask",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="ask the requester for the intercom id", due_at=due_at,
                      notes=("reask:missing-id",))
    outcome = None
    if backends.dv_outcomes is not None:
        try:
            outcome = backends.dv_outcomes(ids)
        except Exception as exc:  # noqa: BLE001 - a failed read is not a verdict
            return Answer(state="failed",
                          verdict=f"verdict store unreadable ({type(exc).__name__}) - no verdict produced",
                          verdict_source="coded", evidence=_ids_evidence(ids),
                          next_step="page: coded verdict store unreadable", due_at=due_at,
                          page="ops-intake: coded verdict store unreadable")
    if not outcome:
        return Answer(
            state="open",
            verdict="no coded verdict yet - proof-review runs in credit-review/doc-verify, not here",
            verdict_source="coded", evidence=_ids_evidence(ids),
            next_step="credit-review.py decide reads this conversation; watcher escalates at due",
            due_at=due_at, notes=("pending:dv-outcomes",))
    verdict = str(outcome.get("verdict") or "").strip()
    if not verdict:
        return Answer(state="failed", verdict="coded verdict row has no verdict field",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="page: malformed verdict row", due_at=due_at,
                      page="ops-intake: malformed dv outcome")
    return Answer(
        state="answered",
        verdict=f"proof {verdict}" + (f" ({outcome['request_ids']} request(s))"
                                       if outcome.get("request_ids") else ""),
        verdict_source="dv_outcomes", evidence=_ids_evidence(ids),
        next_step="approval is a captain/coded path: scripts/credit-review.py decide",
        due_at=due_at)


def _intercom_document(got: Any) -> Any:
    """The raw Intercom document `facts.collect` reads, from the router's flattened adapter.

    The adapter returns ordered `{role, text, created_at}` parts plus the contact; the card reads
    the raw document (`source`, `conversation_parts`, `contacts`). Converting here keeps ONE
    conversation read and stops the two sides drifting into different shapes.
    """
    if not isinstance(got, dict):
        return got
    if any(k in got for k in ("source", "conversation_parts", "contacts")):
        return got

    def part(p: dict[str, Any]) -> dict[str, Any]:
        return {"author": {"type": "user" if p.get("role") == "customer" else "admin"},
                "body": p.get("text"), "created_at": p.get("created_at")}

    parts = [p for p in (got.get("parts") or []) if isinstance(p, dict)]
    doc: dict[str, Any] = {"id": got.get("conversation_id"),
                           "conversation_parts": {"conversation_parts": [part(p) for p in parts[1:]]}}
    if parts:
        doc["source"] = part(parts[0])
    contact = got.get("contact")
    if isinstance(contact, dict) and contact:
        doc["contacts"] = {"contacts": [contact]}
    return doc


def _card_readers(backends: Backends, base: Any = None) -> Any:
    """The card's readers, with the router's own Intercom adapter when it has one.

    Sharing the adapter is the point: the card and the router must not disagree about what the
    conversation says, and a second Intercom client here would be a second thing to keep in step.
    `base` supplies the other seams (production keeps the real defaults; a test injects stubs).
    """
    from . import facts as facts_mod  # noqa: PLC0415

    base = base if base is not None else facts_mod.Readers()
    if backends.intercom_conversation is None:
        return base
    return replace(
        base, conversation=lambda cid: _intercom_document(backends.intercom_conversation(cid)))


@dataclass(frozen=True)
class _Proposal:
    """What the mapped action becomes on this surface: a W1 write request, or a named reason."""

    write: WriteRequest | None = None
    reason: str = ""
    page: str = ""

    @property
    def executable(self) -> bool:
        return self.write is not None


def _reply_request(card: Any, conversation_id: str, line_id: str) -> _Proposal:
    """One answer-bank line, guard-checked, as a W1 `intercom_customer_reply` request.

    The line is resolved VERBATIM from the plugin's own answer bank and then run through the real
    Caroline output guard (`output_guard`, which shells out to `caroline-output-guard.ts`). A guard
    that cannot run, or that blocks, means NOTHING is proposed - the Ops bot's replies bypassed
    this guard for 34 messages in the census, and "the guard was down so we sent it anyway" is the
    same bug with a better excuse.
    """
    from . import output_guard  # noqa: PLC0415

    open_request = bool(card.facts.value("requests") or [])
    try:
        text = output_guard.line(line_id, open_request=open_request)
        outcome = output_guard.check(text, customer_text=card.quoted.text or "",
                                     open_request=open_request)
    except output_guard.LineRefused as exc:
        return _Proposal(reason=f"answer-bank line {line_id!r} refused: {exc}")
    except output_guard.GuardUnavailable as exc:
        return _Proposal(reason=f"output guard unavailable, so nothing may be sent: {exc}",
                         page="ops-intake: output guard unavailable on a summarize/resolve reply")
    if outcome.blocked:
        flags = ",".join(f"{f.get('family')}/{f.get('rule')}" for f in outcome.flags) or "no rule"
        return _Proposal(reason=f"output guard blocked the reply ({flags})",
                         page=f"ops-intake: output guard blocked a reply ({flags})")
    return _Proposal(write=WriteRequest(
        action="intercom_customer_reply",
        target=conversation_id,
        params={"conversation_id": conversation_id, "body": outcome.body or text,
                "line_id": line_id, "guard_version": outcome.guard_version,
                "bank_version": outcome.bank_version},
        inverse_action="annotate_intercom_reply",
        inverse_params={}))


# A rename's target name is a REQUESTER-supplied field, never something read out of the customer's
# message. Only an explicit, labelled form counts; anything else leaves the name unset, and an
# unset name means no write (the answerer says so rather than guessing).
# `\Z`, not `$`: with re.MULTILINE, `$` matches the end of ANY line, so
# `rename to "Jane"\nand "John"` matched on line 1 and produced a W1 plan for one of two
# requested names. The quoted name must be the whole remainder of the MESSAGE; `\s*` still
# tolerates trailing whitespace and newlines, but any further content refuses.
_NEW_NAME = re.compile(
    r"(?:new\s+name|rename\s+(?:it\s+)?to|change\s+(?:the\s+)?name\s+to)\s*[:=]?\s*"
    r"(?:\"(?P<dq>[^\"\n]{1,120})\"|`(?P<bq>[^`\n]{1,120})`|'(?P<sq>[^\n]{1,120})')"
    r"\s*\Z",
    re.IGNORECASE)


def _requested_new_name(text: str | None) -> str:
    """The name the REQUESTER quoted, or "" when they did not quote one explicitly."""
    if not text:
        return ""
    got = _NEW_NAME.search(text)
    if got is None:
        return ""
    for key in ("dq", "bq", "sq"):
        value = (got.group(key) or "").strip()
        if not value:
            continue
        if key == "sq" and any(ch == "'" and i and value[i - 1].isspace()
                               for i, ch in enumerate(value)):
            return ""
        return value
    return ""


def _page_for(action: Any, conversation_id: str) -> str:
    """The staff page a hand-off needs, naming the conversation so a human can pick it up.

    Every action that does not execute here pages. Nothing on this surface can reassign an
    Intercom conversation, so the page is the only thing that actually reaches a human - a
    hand-off that posts a line and pages nobody leaves the case with the bot.
    """
    if action.refuse:
        return (f"ops-intake: {action.key} on conversation {conversation_id} - refused, "
                "no customer reply and no write")
    where = action.handoff or "a named human"
    return (f"ops-intake: {action.key} on conversation {conversation_id} handed off to {where} - "
            "a human must pick it up; the conversation is not reassigned from this surface")


def _single_profile(card: Any) -> str:
    """The profile a rename acts on: the account's OWN open request, when there is exactly one.

    Several candidates means no target is chosen automatically - picking one would be exactly the
    improvised decision this surface exists to remove.
    """
    ids = {str(r.get("profile_id") or "").strip() for r in (card.facts.requests or [])}
    ids.discard("")
    return ids.pop() if len(ids) == 1 else ""


def _propose_write(card: Any, *, conversation_id: str, new_name: str | None,
                   profile_id: str, backends: Backends) -> _Proposal:
    """Turn the mapped action into a W1 write request, or say why it is not one.

    Nothing here executes. The router's step 9 owns tier -> fraud lens -> caps -> ledger plan ->
    writer, and its writers are gated off by captain decision (`OPS_INTAKE_WRITES`). A second
    executor in this module would be a second place to get that ordering wrong.
    """
    action = card.suggestion.action
    line_id = card.suggestion.line_id or action.line

    # A hand-off that names an approved line still SENDS that line. "We handed it off" with
    # nothing in the thread is the failure the census found: the customer is left in the dark.
    # The page that makes the hand-off real is attached by the caller from `action.page`.
    if action.key == "unknown" and line_id:
        return _reply_request(card, conversation_id, line_id)

    if not action.executes_here or action.tier != "W1":
        return _Proposal(reason=(f"{card.suggestion.rule_key or 'unmapped'} maps to {action.key} "
                                 f"(tier {action.tier}): "
                                 f"{action.handoff or 'a named human takes it from here'}"))

    if action.key == "status-line":
        if not line_id:
            return _Proposal(reason="the mapped status line has no answer-bank entry")
        return _reply_request(card, conversation_id, line_id)

    if action.key == "rename":
        target = (profile_id or "").strip() or _single_profile(card)
        if not target:
            return _Proposal(reason="rename: no single profile could be measured for this account")
        name = (new_name or "").strip()
        if not name:
            return _Proposal(reason=("rename: the requester must quote the new name in double "
                                     "quotes, single quotes, or backticks"))
        if backends.profile_name is None:
            return _Proposal(reason="rename: no profile-name reader is wired, so there is no inverse")
        try:
            previous = backends.profile_name(target)
        except Exception as exc:  # noqa: BLE001 - no before-image, no write
            return _Proposal(reason=f"rename: the previous name could not be read "
                                    f"({type(exc).__name__}: {exc})")
        if not previous:
            return _Proposal(reason="rename: no previous name measured, so there is no inverse")
        return _Proposal(write=WriteRequest(
            action="profile_rename", target=target,
            params={"profile_id": target, "display_name": name},
            inverse_action="profile_rename_back",
            inverse_params={"profile_id": target, "previous_display_name": previous}))

    return _Proposal(reason=f"{action.key} is W1 but this surface has no writer for it")


def answer_summarize_resolve(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                             backends: Backends, due_at: str,
                             policy: policy_mod.Policy,
                             guardobj: "guard.Guard | None" = None,
                             requester_email: str | None = None,
                             requester_ids: tuple[str, ...] = (),
                             intent_override: str | None = None,
                             new_name: str | None = None,
                             profile_id: str = "",
                             text: str | None = None,
                             card_policy: Any = None,
                             readers: Any = None,
                             judge: Callable[..., Any] | None = None,
                             scan: Callable[[str], list[dict[str, str]]] | None = None,
                             record: Callable[..., Any] | None = None) -> Answer:
    """The facts card, then the ONE action `policies/ops-resolutions.json` maps it to.

    Spec §1: the card is built from code reads only - contact -> account (resolver r5), open
    requests by status, claims, merges, the erasure register row, the verify ledger, the Stripe
    subscription, ClickUp tickets, and the age of the last customer and staff messages. The
    customer's own text is quoted at most once, delimited, and only after the injection watch; a
    HIGH hit quarantines it and the card says so.

    Spec §2: the suggestion is a LOOKUP, not a judgement. The card prints the RULE KEY that
    produced it, so a wrong mapping is a one-line PR against the policy file rather than an
    argument about a model's reasoning. An unmapped ask is `unknown`, which is a hand-off.

    Spec §3: this answerer EXECUTES NOTHING. When the mapped action is a W1 write it returns a
    `WriteRequest` and the router's step 9 runs tier -> fraud lens -> caps -> ledger plan ->
    writer. That is the only write path on this surface, and its writers are gated off by captain
    decision (`OPS_INTAKE_WRITES`), so a plan is recorded with its inverse and marked as not
    executed rather than performed behind a gate nobody opened.

    `policy` is the router's tier table (the W1/W2 gate); the resolution LOOKUP is `card_policy`.
    Passing `policy` does not select the lookup.
    """
    from . import intent as intent_mod  # noqa: PLC0415
    from . import resolutions as res_mod  # noqa: PLC0415
    from . import summarize as summarize_mod  # noqa: PLC0415

    conversation_id = ids.intercom[0] if ids.intercom else ""
    if not conversation_id:
        return Answer(state="ask", verdict="no intercom conversation id in the ask",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="ask the requester for the intercom conversation id",
                      due_at=due_at, notes=("reask:missing-id",))

    if card_policy is None:
        try:
            card_policy = summarize_mod.load_policy()
        except res_mod.PolicyError as exc:
            return Answer(state="failed",
                          verdict=f"resolution policy unusable ({exc}) - nothing done",
                          verdict_source="coded", evidence=_ids_evidence(ids),
                          next_step="page: policies/ops-resolutions.json is not loadable",
                          due_at=due_at,
                          page="ops-intake: resolution policy unusable")

    card_readers = (readers if readers is not None
                    else _card_readers(backends, base=backends.readers))
    try:
        card = summarize_mod.build_card(
            conversation_id, ask_id=str(ask.get("ask_id") or ""), policy=card_policy,
            readers=card_readers,
            # The label goes through the router's `guard.Guard`: `Guard.call` is what wraps the
            # customer text in a nonce and raises `CanaryLeak` when the model echoes the frame
            # back. `judge` stays for a caller that has no guard (the CLI, the tests).
            judge=judge, guard=guardobj, scan=scan, record=record,
            requester_email=requester_email,
            requester_ids=requester_ids, intent_override=intent_override)
    except res_mod.PolicyError as exc:
        return Answer(state="failed",
                      verdict=f"resolution policy unusable ({exc}) - nothing done",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="page: policies/ops-resolutions.json is not loadable",
                      due_at=due_at, page="ops-intake: resolution policy unusable")
    except guard.CanaryLeak:
        # The tool-less call echoed the prompt frame: it obeyed the text instead of the frame, so
        # nothing it produced can be trusted and nothing is done.
        return Answer(state="failed",
                      verdict=("canary leak: the tool-less call echoed the prompt frame, so the "
                               "intent label is untrusted and nothing was done"),
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="human review of the ask; the model output is discarded",
                      due_at=due_at,
                      page="ops-intake: canary leak on a summarize/resolve ask")
    except Exception as exc:  # noqa: BLE001 - a card that cannot be built is not an answer
        return Answer(state="failed",
                      verdict=f"facts card failed ({type(exc).__name__}) - nothing done",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="page: the facts card raised", due_at=due_at,
                      page=f"ops-intake: facts card failed ({type(exc).__name__})")

    if card.quoted.quarantined:
        rules = ",".join(sorted({str(h.get("rule")) for h in card.quoted.hits})) or "unknown"
        return Answer(state="quarantined",
                      verdict=(f"input quarantine: HIGH injection hit ({rules}) in the fetched "
                               "conversation; nothing was summarised and nothing was resolved"),
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="human review of the quarantined ask", due_at=due_at,
                      page=f"ops-intake: quarantined fetched input (intercom, rules={rules})")

    if card.intent.label == "rename_profile":
        named_ids = [p.strip() for p in ids.profile if p.strip()]
        if len(named_ids) > 1:
            return Answer(
                state="refused",
                verdict=(f"rename: the requester named {len(named_ids)} profiles "
                         f"({', '.join(named_ids)}) - a rename target must be exactly one"),
                verdict_source="coded", evidence=_ids_evidence(ids),
                next_step=("page: a rename ask named more than one profile; "
                           "no rename is planned"),
                due_at=due_at,
                page="ops-intake: rename names more than one profile")
        named = (profile_id or "").strip() or (named_ids[0] if named_ids else "")
        owned = {str(r.get("profile_id") or "").strip().lower()
                 for r in (card.facts.requests or [])}
        owned.discard("")
        if named and named.lower() not in owned:
            return Answer(
                state="refused",
                verdict=(f"rename: profile {named} is not one of this account's profiles "
                         f"({len(owned)} measured) - nothing done"),
                verdict_source="coded", evidence=_ids_evidence(ids),
                next_step=("page: a requester named a profile the resolved account does not own; "
                           "no rename is planned"),
                due_at=due_at,
                page="ops-intake: rename target is not the account's profile")
        target = named or _single_profile(card)
        pop, measured = None, False
        if target:
            try:
                pop = card_readers.profile_popular(target, card_readers.query)
                measured = True
            except Exception:  # noqa: BLE001 - an unmeasured target is not a "not popular"
                measured = False
        if not measured or pop != card.facts.value("target_popular"):
            card.facts.put("target_popular", pop if measured else None,
                           "credit_requests popularity / count (target profile)",
                           measured=measured)
            card = replace(card, suggestion=res_mod.suggest_for(
                card.facts, card.intent.label, card_policy,
                requester_email=requester_email, requester_ids=requester_ids,
                quarantined=card.quoted.quarantined))

    action = card.suggestion.action
    verdict = (f"facts: {card.facts.counts_line()} · "
               f"intent: {intent_mod.bounded_label(card.intent.label) or 'unknown'} · "
               f"suggested: {card.suggestion.render()}")
    if action.key == "erasure-store-missing":
        detail = next((e for e in card.facts.errors if e.startswith("erasure:")), "")
        if detail:
            verdict = f"{verdict} · {detail}"

    if new_name is None:
        new_name = _requested_new_name(text)
    if not profile_id and len(ids.profile) == 1:
        profile_id = ids.profile[0]

    try:
        proposal = _propose_write(card, conversation_id=conversation_id, new_name=new_name,
                                  profile_id=profile_id, backends=backends)
    except Exception as exc:  # noqa: BLE001 - a proposal that cannot be built is not a write
        proposal = _Proposal(reason=f"the mapped action could not be prepared "
                                    f"({type(exc).__name__}: {exc})")

    evidence = f"{_ids_evidence(ids)} acct={card.facts.account_hash()}"
    notes = (f"rule={card.suggestion.rule_key or 'unmapped'}",
             f"policy={card.policy_version}")

    # A hand-off only reaches a human if it PAGES. Nothing on this surface can reassign an
    # Intercom conversation (the router's writers are empty by captain decision), so a hand-off
    # that posts the line and pages nobody leaves the case with the bot while the customer has
    # been told someone will follow up. The page names the conversation so a human can pick it up.
    page = proposal.page or None
    if page is None and action.page:
        page = _page_for(action, conversation_id)

    if proposal.executable:
        return Answer(
            state="answered", verdict=verdict, verdict_source="coded", evidence=evidence,
            next_step=(f"router step 9 executes {proposal.write.action} under the W1 gate "
                       f"(tier -> fraud lens -> caps -> ledger plan -> writer)"),
            write=proposal.write, due_at=due_at, page=page, notes=notes)

    # Not executable here. A mapped W1 action that could not be prepared is a REFUSAL (something
    # was supposed to happen and did not), and so is an action that declares `refuse` - a
    # requester-linked account must never get a customer reply. A plain hand-off tier is an
    # ANSWER (the card plus the human path is the whole answer).
    state = ("refused" if (action.refuse or (action.executes_here and action.tier == "W1"))
             else "answered")
    return Answer(state=state, verdict=verdict, verdict_source="coded", evidence=evidence,
                  next_step=proposal.reason or action.handoff or "a named human takes it from here",
                  due_at=due_at, page=page, notes=notes)


def answer_gdpr_hide(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                     backends: Backends, due_at: str,
                     lens: fraud.LensResult | None) -> Answer:
    """The only hide path is a reversible PR, and only on a register-verified page."""
    profiles = ids.profile
    if not profiles:
        if ids.untagged:
            return Answer(
                state="ask",
                verdict=("the uuid in the ask is not typed as a profile id - no hide "
                         "planned"),
                verdict_source="register", evidence=_ids_evidence(ids),
                next_step="ask the requester to name it as a profile (full uuid)",
                due_at=due_at)
        return Answer(state="ask", verdict="no profile id in the ask",
                      verdict_source="register", evidence=_ids_evidence(ids),
                      next_step="ask the requester for the profile id(s)", due_at=due_at)
    if lens is None:
        return Answer(state="failed", verdict="fraud lens not run - no hide attempted",
                      verdict_source="register", evidence=_ids_evidence(ids),
                      next_step="page: lens missing", due_at=due_at,
                      page="ops-intake: lens missing on gdpr-hide")
    if lens.decision == "ask":
        return Answer(state="ask",
                      verdict="register identity UNKNOWN for the named page(s) - no hide",
                      verdict_source="register", evidence=_ids_evidence(ids),
                      next_step="gdpr-pipeline.py prepare re-reads identity; a human decides",
                      due_at=due_at, lens=lens,
                      page="ops-intake: gdpr hide ask (identity UNKNOWN)")
    if not lens.permits_write:
        return Answer(state="refused",
                      verdict=f"hide refused by fraud lens ({','.join(lens.reasons)})",
                      verdict_source="fraud-lens", evidence=_ids_evidence(ids),
                      next_step="a named human runs scripts/gdpr-pipeline.py prepare",
                      due_at=due_at, lens=lens,
                      page=page_for_lens(lens, ask["ask_id"]))
    write = WriteRequest(
        action="hide_pr_open",
        target=profiles[0],
        params={"profile_ids": list(profiles), "ask_id": ask["ask_id"]},
        inverse_action="hide_pr_close",
        inverse_params={"profile_ids": list(profiles)})
    return Answer(state="answered",
                  verdict=f"hide PR requested for {len(profiles)} page(s); reversible, a human merges",
                  verdict_source="register", evidence=_ids_evidence(ids),
                  next_step="HIDDEN_ENTITY_IDS + PDP sitemap PR (never DELETE /admin/profile)",
                  due_at=due_at, write=write, lens=lens)


def answer_clickup(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                   backends: Backends, due_at: str) -> Answer:
    counts = None
    if backends.clickup_counts is not None:
        try:
            counts = backends.clickup_counts()
        except Exception as exc:  # noqa: BLE001
            return Answer(state="failed", verdict=f"clickup unreadable ({type(exc).__name__})",
                          verdict_source="coded", evidence=_ids_evidence(ids),
                          next_step="page: clickup read failed", due_at=due_at,
                          page="ops-intake: clickup read failed")
    if not counts:
        return Answer(state="open", verdict="no coded clickup counts available",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="clickup-todo-dedupe.py produces the count; watcher escalates",
                      due_at=due_at, notes=("pending:clickup",))
    return Answer(state="answered",
                  verdict="clickup: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())),
                  verdict_source="coded", evidence=_ids_evidence(ids),
                  next_step="status moves are W1; the coded dedupe owns waiting/closed",
                  due_at=due_at)


def answer_status_report(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                         backends: Backends, due_at: str) -> Answer:
    counts = None
    if backends.status_counts is not None:
        try:
            counts = backends.status_counts(ids)
        except Exception as exc:  # noqa: BLE001
            return Answer(state="failed", verdict=f"counts unreadable ({type(exc).__name__})",
                          verdict_source="coded", evidence=_ids_evidence(ids),
                          next_step="page: report read failed", due_at=due_at,
                          page="ops-intake: report read failed")
    if not counts:
        return Answer(state="open", verdict="no coded count available for this report",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="a coded query must supply the number; watcher escalates",
                      due_at=due_at, notes=("pending:counts",))
    return Answer(state="answered",
                  verdict="counts: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())),
                  verdict_source="coded", evidence=_ids_evidence(ids),
                  next_step="none - a report of measured counts", due_at=due_at)


def answer_fraud_scan(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                      lens: fraud.LensResult | None, due_at: str) -> Answer:
    if lens is None:
        if ids.truncated and not (ids.profile or ids.request):
            return Answer(
                state="ask",
                verdict=("truncated profile id - the full uuid is needed to run the "
                         "fraud lens"),
                verdict_source="coded", evidence=_ids_evidence(ids),
                next_step="ask the requester for the full profile uuid", due_at=due_at)
        if not (ids.profile or ids.request):
            return Answer(
                state="ask",
                verdict="no profile or request id in the ask - nothing to look up",
                verdict_source="coded", evidence=_ids_evidence(ids),
                next_step="ask the requester for the profile uuid or request id",
                due_at=due_at)
        return Answer(state="failed", verdict="fraud lens not run",
                      verdict_source="fraud-lens", evidence=_ids_evidence(ids),
                      next_step="page: lens missing", due_at=due_at,
                      page="ops-intake: lens missing on fraud-scan")
    band = lens.evidence.get("band")
    return Answer(state="answered" if lens.decision == "allow" else "held",
                  verdict=f"fraud lens: {lens.decision}"
                          + (f" (band {band})" if band else "")
                          + (f" [{','.join(lens.reasons)}]" if lens.reasons else ""),
                  verdict_source="fraud-lens", evidence=_ids_evidence(ids),
                  next_step="credit removal is W2: scripts/credit-retro.py, named human session",
                  due_at=due_at, lens=lens, page=page_for_lens(lens, ask["ask_id"]))


def answer_billing(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                   due_at: str) -> Answer:
    return Answer(state="answered",
                  verdict="billing reads are tracked; a refund is W2 and is not done here",
                  verdict_source="coded", evidence=_ids_evidence(ids),
                  next_step="refund: billing owner in a named human session",
                  due_at=due_at)


# The phrasings classes.RULES routes to this answerer: "change profile name",
# "create profile", "rename", "profile name to".
RENAME_PHRASE = re.compile(
    r"\b(?:profile\s+name|rename|change|set|update|put)\b", re.IGNORECASE)
RENAME_TO = re.compile(r"\bto\b", re.IGNORECASE)
RENAME_AS = re.compile(r"\bas\b", re.IGNORECASE)
# A name may be quoted; only a quote that STARTS the name position counts.
QUOTE_PAIRS = {"'": "'", '"': '"', "`": "`", "\u2018": "\u2019", "\u201c": "\u201d"}
QUOTE_CHARS = "".join(QUOTE_PAIRS) + "".join(QUOTE_PAIRS.values())
# Where the name ends: a structural field of the ask, never a bare word.
RENAME_TAIL = re.compile(
    r"(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"|\bprofile\b|\breason\b|\bbecause\b|:)",
    re.IGNORECASE)
# Lowercase connectors are prose, not part of a name ("John Smith for GDPR");
# a title-cased "To"/"For" is part of one ("Born To Die", "Waiting For The Sun").
PROSE_MARKERS = (" for ", " to ", " because", " reason", " profile")
# A trailing INSTRUCTION joined by a lowercase connector is prose too. These are
# refused only for an UNQUOTED name, so "Simon and Garfunkel" still works quoted.
INSTRUCTION_MARKERS = (" and ", " then ", " also ", " plus ", " so ", " but ")
INSTRUCTION_COMMA = re.compile(r",\s+\w")
UUID_ANY = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                      re.IGNORECASE)
URL_ANY = re.compile(r"https?://\S+", re.IGNORECASE)
MAX_DISPLAY_NAME = 120
MAX_NAME_WORDS = 6
POLITENESS = ("thank you", "thanks", "please", "pls", "asap")
# A name never starts with a determiner: "the name on her Spotify" is prose.
DETERMINERS = frozenset({"the", "a", "an", "this", "that", "her", "his",
                         "their", "its", "my", "your", "our"})


def _keyword_after(phrase_end: int, body: str) -> int | None:
    """End of the first "to" (else "as") within the phrase's line or the next."""
    newline = body.find("\n", phrase_end)
    window_end = len(body)
    if newline != -1:
        second = body.find("\n", newline + 1)
        window_end = len(body) if second == -1 else second
    window = body[phrase_end:window_end]
    for pattern in (RENAME_TO, RENAME_AS):
        match = pattern.search(window)
        if match is not None:
            return phrase_end + match.end()
    return None


def _quoted_at(rest: str) -> str | None:
    """The quoted span that STARTS at ``rest[0]``, or None when it is ambiguous.

    A closing quote followed by a word character is an apostrophe INSIDE the name
    ("'D'Angelo'"), not the terminator, so the span is refused rather than cut in
    half; a quote left over after the span is refused too.
    """
    opener = rest[0]
    closer = QUOTE_PAIRS[opener]
    end = rest.find(closer, 1)
    if end == -1:
        return None
    after = rest[end + 1: end + 2]
    if after and (after.isalnum() or after == "_"):
        return None
    remainder = rest[end + 1:]
    if any(char in remainder for char in QUOTE_CHARS):
        return None
    return rest[1:end]


def requested_display_name(text: str | None) -> str | None:
    """The display name the ask names verbatim, or None.

    The register stores only a hash of the body, so the value a rename writes must
    be captured HERE or it exists nowhere: a plan without it is not a record of
    the write. The parser is explicit: the rename phrase, the first "to" (else
    "as") on that line or the next, then either a quote that STARTS the name or
    the rest of that line cut at a structural field. Anything ambiguous - an
    embedded quote, a lowercase " for "/" to " connector, a trailing instruction
    joined by a lowercase connector (" and ", " then ", ...) or a comma, a colon,
    a newline, more than six words - is None, so the caller ASKS instead of
    recording a name the ask never named.
    """
    body = URL_ANY.sub(" ", (text or "").strip())
    if not body.strip():
        return None
    phrase = RENAME_PHRASE.search(body)
    if phrase is None:
        return None
    keyword_end = _keyword_after(phrase.end(), body)
    if keyword_end is None:
        return None
    rest = body[keyword_end:].lstrip(" \t")
    quoted = rest[:1] in QUOTE_PAIRS
    if quoted:
        name = _quoted_at(rest)
        if name is None:
            return None
    else:
        line_end = rest.find("\n")
        line = rest if line_end == -1 else rest[:line_end]
        name = RENAME_TAIL.split(line, maxsplit=1)[0]
    name = re.sub(r"\s+", " ", name).strip()
    name = name.rstrip(".,;:!?").strip()
    lowered = name.lower()
    for token in POLITENESS + ("for", "to", "because", "reason", "profile", "as"):
        if lowered.endswith(" " + token):
            name = name[: -len(token)].rstrip(" .,;:!?").strip()
            lowered = name.lower()
            break
    if not name or len(name) > MAX_DISPLAY_NAME:
        return None
    if "\n" in name or ":" in name:
        return None
    if any(char in name for char in QUOTE_CHARS):
        return None
    words = name.split()
    if len(words) > MAX_NAME_WORDS:
        return None
    if words[0].lower() in DETERMINERS:
        return None
    if any(marker in name for marker in PROSE_MARKERS):
        return None
    if not quoted and (any(marker in name for marker in INSTRUCTION_MARKERS)
                       or INSTRUCTION_COMMA.search(name)):
        return None
    if lowered in POLITENESS or lowered in {"for", "because", "reason", "profile",
                                            "intercom", "request", "to", "as"}:
        return None
    return name


def reply_safe_name(name: str) -> str | None:
    """The name, or None when printing it would trip the reply contract's guards.

    A display name is user text: one containing "pending" or "firstmate" would
    downgrade the whole contract line to ``render_minimal``. The ledger still
    records it verbatim; only the reply omits it.
    """
    lowered = name.lower()
    if ATTRIBUTION.search(name) or any(word in lowered for word in PENDING_WORDS):
        return None
    if any(claim in lowered for claim in FORBIDDEN_CLAIMS):
        return None
    return name


def answer_profile_edit(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                        backends: Backends, lens: fraud.LensResult | None, due_at: str,
                        policy: policy_mod.Policy, requester: policy_mod.Requester,
                        text: str | None = None) -> Answer:
    profiles = ids.profile
    if not profiles:
        return Answer(state="ask", verdict="no profile id in the ask",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="ask which profile (full uuid, not a truncated prefix)",
                      due_at=due_at)
    ok, why = policy.may_write(requester, "profile_rename")
    if not ok:
        return Answer(state="refused", verdict=f"profile rename refused ({why})",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="a person with admin access renames it; the ask is recorded",
                      due_at=due_at)
    if lens is not None and not lens.permits_write:
        return Answer(state="held",
                      verdict=f"lens withheld the rename ({','.join(lens.reasons) or lens.decision})",
                      verdict_source="fraud-lens", evidence=_ids_evidence(ids),
                      next_step="human review of the lens result", due_at=due_at,
                      lens=lens, page=page_for_lens(lens, ask["ask_id"]))
    new_name = requested_display_name(text)
    if new_name is None:
        return Answer(
            state="ask",
            verdict="no new display name in the ask - nothing planned",
            verdict_source="coded", evidence=_ids_evidence(ids),
            next_step=("ask the requester to quote the exact new name, e.g. "
                       "change profile name to 'Franki Love'"),
            due_at=due_at)
    previous: str | None = None
    if backends.profile_name is not None:
        try:
            previous = backends.profile_name(profiles[0])
        except Exception as exc:  # noqa: BLE001 - unreadable is not "no previous name"
            return Answer(state="failed",
                          verdict=f"rename not planned: the current display name is unreadable "
                                  f"({type(exc).__name__}), so the inverse would be a guess",
                          verdict_source="coded", evidence=_ids_evidence(ids),
                          next_step="page: profile read failed; nothing written", due_at=due_at,
                          page="ops-intake: rename blocked (profile read failed)")
    if not str(previous or "").strip():
        return Answer(
            state="failed",
            verdict="rename not planned: no way to capture the current display name, "
                    "so there is no inverse",
            verdict_source="coded", evidence=_ids_evidence(ids),
            next_step="wire the profile read, or a human renames it; no reverse, no write",
            due_at=due_at, page="ops-intake: rename blocked (no previous name)")
    write = WriteRequest(
        action="profile_rename", target=profiles[0],
        params={"profile_id": profiles[0], "ask_id": ask["ask_id"],
                "display_name": new_name},
        inverse_action="profile_rename_back",
        inverse_params={"profile_id": profiles[0],
                        "previous_display_name": str(previous).strip()})
    shown = reply_safe_name(new_name)
    target = f"displayName -> {shown!r}" if shown else "displayName recorded in the ledger"
    prior = reply_safe_name(str(previous).strip())
    inverse = f"previous {prior!r} as the inverse" if prior else "previous name recorded in the ledger"
    return Answer(state="answered",
                  verdict=f"rename planned: {target} ({inverse})",
                  verdict_source="coded", evidence=_ids_evidence(ids),
                  next_step="W1 write (reversible)", due_at=due_at, write=write, lens=lens)


def answer_relay(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds, due_at: str) -> Answer:
    """Relay is the queue: the row + its due time, and the watcher escalates."""
    return Answer(state="open",
                  verdict="recorded in the ask register (this IS the queue)",
                  verdict_source="queue", evidence=_ids_evidence(ids),
                  next_step="watcher escalates this row at due unless a coded answer lands",
                  due_at=due_at)


def answer_other(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds, due_at: str) -> Answer:
    return Answer(state="open",
                  verdict="not a coded class: handed to the operations agent turn",
                  verdict_source="agent-handoff", evidence=_ids_evidence(ids),
                  next_step="the agent turn answers in the thread; the watcher escalates if it does not",
                  due_at=due_at)


def answer_quarantined(*, ids: ids_mod.ExtractedIds, hits: list[dict[str, Any]],
                       due_at: str) -> Answer:
    rules = ",".join(sorted({str(h.get("rule")) for h in hits})) or "unknown"
    return Answer(state="quarantined",
                  verdict=f"input quarantine: HIGH injection hit ({rules}); no model saw it",
                  verdict_source="coded", evidence=_ids_evidence(ids),
                  next_step="human review of the quarantined ask", due_at=due_at,
                  page=f"ops-intake: quarantined ask (rules={rules})")
