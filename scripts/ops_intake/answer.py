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
from dataclasses import dataclass, field
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


SUMMARY_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["summary"],
    "properties": {"summary": {"type": "string",
                               "description": "one paragraph, from the conversation text only"}},
}


def answer_summarize_resolve(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds,
                             backends: Backends, due_at: str,
                             policy: policy_mod.Policy,
                             guardobj: "guard.Guard | None" = None) -> Answer:
    """Summarize from the conversation itself; a resolution write is proposed, never assumed."""
    conv = None
    if ids.intercom and backends.intercom_conversation is not None:
        try:
            conv = backends.intercom_conversation(ids.intercom[0])
        except Exception as exc:  # noqa: BLE001
            return Answer(state="failed",
                          verdict=f"conversation unreadable ({type(exc).__name__})",
                          verdict_source="coded", evidence=_ids_evidence(ids),
                          next_step="page: intercom read failed", due_at=due_at,
                          page="ops-intake: intercom read failed")
    if conv is None:
        return Answer(state="open",
                      verdict="no coded conversation summary available for this ask",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="attach the intercom conversation id; watcher escalates at due",
                      due_at=due_at, notes=("pending:conversation",))
    parts = conv.get("parts") or []
    customer = [p for p in parts if p.get("role") == "customer"]
    text = "\n".join(str(p.get("text") or "") for p in parts)

    # Fetched text is data on every path, model or not: a HIGH hit quarantines
    # before it can be echoed into the thread the agent reads. ``text`` already
    # holds every part, so it is screened once.
    fetched = guard.screen(text)
    if fetched.quarantine:
        rules = ",".join(sorted({str(h.get("rule")) for h in fetched.hits})) or "unknown"
        return Answer(state="quarantined",
                      verdict=(f"input quarantine: HIGH injection hit ({rules}) in the "
                               "fetched conversation; nothing was summarised"),
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="human review of the quarantined ask", due_at=due_at,
                      page=f"ops-intake: quarantined fetched input (intercom, rules={rules})")

    # A model is OPTIONAL here and, when wired, is the tool-less ladder behind
    # scripts/ops_intake/guard.py: screened first, delimited as data,
    # canary-checked on the way out.
    if guardobj is not None and getattr(guardobj, "judge", None) is not None:
        try:
            guarded = guardobj.call(
                question=("Summarize the customer's issue in one paragraph, using only the "
                          "data block. Do not decide, approve or promise anything."),
                blocks=[("intercom_conversation", text)],
                schema=SUMMARY_SCHEMA)
        except Exception as exc:  # imported lazily to avoid a cycle at module load
            from . import guard as guard_mod  # noqa: PLC0415

            if isinstance(exc, guard_mod.Quarantined):
                return Answer(state="quarantined",
                              verdict=("input quarantine: HIGH injection hit in the fetched "
                                       "conversation; no model saw it"),
                              verdict_source="coded", evidence=_ids_evidence(ids),
                              next_step="human review of the quarantined ask", due_at=due_at,
                              page="ops-intake: quarantined fetched input (intercom)")
            if isinstance(exc, guard_mod.CanaryLeak):
                return Answer(state="failed",
                              verdict="canary leak: the model echoed the prompt frame - ask failed closed",
                              verdict_source="coded", evidence=_ids_evidence(ids),
                              next_step="page: canary leak on a tool-less call", due_at=due_at,
                              page="ops-intake: canary leak (fail closed)")
            raise
        summary = (guarded.text or "").strip() if guarded.data is None else \
            str(guarded.data.get("summary") or guarded.text or "").strip()
        return Answer(state="answered", verdict=f"summary: {summary[:400]}",
                      verdict_source="coded", evidence=_ids_evidence(ids),
                      next_step="resolve via the coded path named in the reply, not a free-form write",
                      due_at=due_at)

    summary = (f"{len(parts)} parts / {len(customer)} customer messages"
               + (f", last: {str(customer[-1].get('text', ''))[:120]!r}" if customer else ""))
    return Answer(
        state="answered", verdict=f"summary: {summary}", verdict_source="coded",
        evidence=_ids_evidence(ids),
        next_step="resolve via the coded path named in the reply, not a free-form write",
        due_at=due_at)


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
