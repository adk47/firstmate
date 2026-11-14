"""The ops-intake router: one inbound Slack message in, one coded answer out.

Called by the ``ops-intake`` openclaw plugin (plugins/ops-intake) on the
``operations`` account's ``inbound_claim`` hook - it is NOT an agent turn, and
the agent's own model never sees a message this module answers. The plugin
passes the Slack envelope on stdin as JSON; this module owns every decision.

Order (each step fails closed, and the state column records which one it got to):

  1. identity - ``event.user`` from the envelope, resolved in
     policies/ops-requesters.json. Text is never identity.
  2. classify - scripts/ops_intake/classes.py (first match wins; all matches kept).
  3. ids - scripts/ops_intake/ids.py; truncated prefixes are never a write handle.
  4. W2 - an irreversible action named anywhere in the message refuses the WHOLE
     ask and names the human path (policies/ops-intake-actions.json W2 triggers).
     The refusal happens before any read-only answer, because "refund it and add
     a note" must not get the note.
  4b. impersonation - a STAFF name in a pasted quote header, sent by a non-staff
     id, refuses the ask and pages: a forwarded instruction is not the person's.
  5. quarantine - the message text is screened with the same injection watch as
     fetched inputs. A HIGH hit on a message the agent WOULD otherwise see
     quarantines it and pages (the agent never sees it).
  6. row - the ask is written to the register BEFORE any work (idempotent on
     channel+ts, so a Slack retry is not a second ask).
  7. conflict of interest - the requester-linked half of the fraud lens, for
     every class that names a profile or request (request ids resolve to their
     owner too). A match is a W2 refusal + page, and an UNMEASURED link refuses
     as well - on reads, not only on writes.
  8. answer - the coded answerer for the class (scripts/ops_intake/answer.py).
  9. write - if the answer proposes a W1 write: tier check, full fraud lens
     (band + reused document + identity verdict), burst caps, then ledger plan
     -> execute (only when a writer is wired) -> record the inverse handle the
     write returned -> mark applied. No inverse, no write: an inverse that could
     not run is refused at plan time.
 10. reply - the row's state is recorded FIRST, then the contract line is posted
     in the asker's thread (retried once); if the post never lands the answer is
     still durable and the row says so.

"claimed" in the result tells the plugin whether the router answered the message
(agent turn suppressed) or handed it to the agent. Only ``other`` is handed over,
and only when it is not quarantined.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

if __package__ in (None, ""):  # `python3 scripts/ops_intake/router.py`
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from ops_intake import answer as answer_mod  # noqa: E402
    from ops_intake import classes, fraud, guard, ids as ids_mod, ledger as ledger_mod  # noqa: E402
    from ops_intake import policy as policy_mod, store as store_mod  # noqa: E402
else:
    from . import answer as answer_mod
    from . import classes, fraud, guard, ids as ids_mod, ledger as ledger_mod
    from . import policy as policy_mod, store as store_mod

WRITES_ENABLED_ENV = "OPS_INTAKE_WRITES"
RETRY_PAUSE_S = 0.5
NO_TS_PAGE_STAMP = "no-ts-paged"
# How long one intake run owns its ask row. A Slack retry inside the lease resumes
# (does nothing: the first child is still working); past it the child is presumed
# dead and the retry re-runs the pipeline. The lease MUST expire inside Slack's
# redelivery window (seconds to ~5 minutes), or a retry can never acquire it; the
# child renews it at every step boundary so a live run keeps it.
INTAKE_LEASE = timedelta(minutes=2)


@dataclass(frozen=True)
class Envelope:
    """The Slack message as the plugin saw it. Every field comes from the
    envelope; ``text`` is the only prose, and it is never identity."""

    account_id: str
    channel: str
    user_id: str
    text: str
    ts: str
    thread_ts: str | None = None
    is_dm: bool = False
    display_name: str | None = None
    bot_id: str | None = None
    subtype: str | None = None

    def as_row(self) -> dict[str, Any]:
        return {"account_id": self.account_id, "channel": self.channel,
                "user_id": self.user_id, "ts": self.ts, "thread_ts": self.thread_ts,
                "is_dm": self.is_dm, "bot_id": self.bot_id, "subtype": self.subtype}


@dataclass
class Routed:
    ask_id: str | None
    claimed: bool
    state: str
    reply: str | None
    posted: bool = False
    ledger_id: int | None = None
    page: str | None = None
    duplicate: bool = False
    skip_reason: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {"ask_id": self.ask_id, "claimed": self.claimed, "state": self.state,
                "reply": self.reply, "posted": self.posted, "ledger_id": self.ledger_id,
                "page": self.page, "duplicate": self.duplicate,
                "skip_reason": self.skip_reason}


def _now(now: datetime | None = None) -> datetime:
    return now or datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def channel_allowed(policy: policy_mod.Policy, envelope: Envelope) -> bool:
    channels = policy.channels()
    if envelope.is_dm or envelope.channel.startswith("D"):
        return bool(channels.get("DMs"))
    return envelope.channel in channels


def should_ignore(envelope: Envelope) -> str | None:
    """Bot/echo/subtype guard. Our own reply must never become an ask."""
    if envelope.bot_id:
        return "from-bot"
    if envelope.subtype:
        return f"subtype:{envelope.subtype}"
    if not (envelope.text or "").strip():
        return "empty"
    if not (envelope.ts or "").strip():
        return "no-ts"
    return None


def route(*, envelope: Envelope, policy: policy_mod.Policy | None = None,
          store: store_mod.AskStore | None = None,
          ledger: ledger_mod.ActionLedger | None = None,
          backends: answer_mod.Backends | None = None,
          guardobj: guard.Guard | None = None,
          now: datetime | None = None,
          dry_run: bool = False) -> Routed:
    now = _now(now)
    policy = policy or policy_mod.load()
    store = store or store_mod.AskStore()
    ledger = ledger or ledger_mod.ActionLedger()
    backends = backends or answer_mod.Backends()

    skip = should_ignore(envelope)
    if skip:
        return Routed(ask_id=None, claimed=False, state="ignored", reply=None,
                      skip_reason=skip)
    if not channel_allowed(policy, envelope):
        return Routed(ask_id=None, claimed=False, state="ignored", reply=None,
                      skip_reason="channel-not-allowlisted")

    # 1. identity
    requester = policy.resolve(envelope.user_id, display_name=envelope.display_name)

    # 2. classify
    text_sha = hashlib.sha256((envelope.text or "").encode("utf-8")).hexdigest()
    cls = classes.classify(envelope.text or "", text_sha256=text_sha)

    # 3. ids
    extracted = ids_mod.extract(envelope.text or "")

    due_dt = store_mod.slack_ts_to_dt(envelope.ts) + store_mod.DUE_AFTER
    due_at = _iso(due_dt)

    # 6 (early, idempotent): an existing row answers the same way twice.
    existing = store.by_slack(envelope.channel, envelope.ts)
    if existing and existing.get("reply_ts"):
        return Routed(ask_id=existing["ask_id"], claimed=existing["class"] != "other",
                      state=existing["state"], reply=existing["reply_text"],
                      posted=True, ledger_id=existing.get("ledger_id"),
                      duplicate=True)
    if existing and existing.get("reply_text"):
        # The reply never landed (no reply_ts): a retry re-attempts the post, and
        # "posted" only ever reports a reply that actually reached Slack.
        posted, post_error = _post_reply(backends, envelope, existing["reply_text"], dry_run)
        if posted:
            store.transition(existing["ask_id"], existing["state"], reply_ts=str(posted),
                             note=_without_post_failure(existing.get("note")))
            store.event(existing["ask_id"], "reply-reposted", str(posted))
        elif post_error is not None:
            store.event(existing["ask_id"], "reply-post-failed", post_error)
            _page(backends, f"ops-intake: reply still did not land on ask "
                            f"{existing['ask_id']} ({post_error})")
        return Routed(ask_id=existing["ask_id"], claimed=existing["class"] != "other",
                      state=existing["state"], reply=existing["reply_text"],
                      posted=bool(posted), ledger_id=existing.get("ledger_id"),
                      duplicate=True)

    ask_id, created = store.add_ask(store_mod.NewAsk(
        slack_ts=envelope.ts, slack_channel=envelope.channel,
        slack_thread=envelope.thread_ts, account_id=envelope.account_id,
        requester_id=requester.user_id, requester_name=requester.name,
        tier=requester.tier, cls=cls.cls, candidates=cls.candidates,
        text_sha256=text_sha, extracted_ids=extracted.as_dict(), due_at=due_at), now=_iso(now))
    lease_owner = uuid.uuid4().hex
    if not store.acquire_intake_lease(ask_id, owner=lease_owner, within=INTAKE_LEASE, now=now):
        # Another child owns this ask: resume it, never run a second pipeline.
        row = store.get(ask_id) or {}
        return Routed(ask_id=ask_id, claimed=row.get("class") != "other",
                      state=row.get("state") or "open", reply=None, posted=False,
                      ledger_id=row.get("ledger_id"), duplicate=True)
    store.event(ask_id, "intake-started", f"class={cls.cls}", at=_iso(now))

    def superseded() -> Routed | None:
        """Renew the lease; a lost lease means another child owns this ask now."""
        if store.renew_intake_lease(ask_id, owner=lease_owner):
            store.event(ask_id, "intake-heartbeat", f"class={cls.cls}")
            return None
        store.event(ask_id, "intake-superseded", f"class={cls.cls}")
        row = store.get(ask_id) or {}
        return Routed(ask_id=ask_id, claimed=row.get("class") != "other",
                      state=row.get("state") or "open", reply=None, posted=False,
                      ledger_id=row.get("ledger_id"), duplicate=True)

    def finish(ans: answer_mod.Answer, *, ledger_id: int | None = None,
               claimed: bool = True, page: str | None = None) -> Routed:
        state = ans.state
        if ans.page:
            page = page or ans.page
        if page and not _page(backends, page):
            store.event(ask_id, "page-failed", page[:500])
        reply = _safe_render(cls.cls, ask_id, ans, due_at, ledger_id)
        notes = ";".join(ans.notes)
        # The answer is recorded BEFORE the reply is posted: a Slack failure must
        # never lose the verdict the code already computed.
        store.transition(
            ask_id, state, verdict=ans.verdict, verdict_source=ans.verdict_source,
            action=ans.write.action if ans.write else None, ledger_id=ledger_id,
            lens_json=json.dumps(ans.lens.as_row()) if ans.lens else None,
            reply_text=reply if claimed else None, note=notes or None)
        if state == "quarantined":
            _escalate_quarantine(store, ask_id, ans.verdict)
        posted: str | None = None
        if claimed:
            posted, post_error = _post_reply(backends, envelope, reply, dry_run)
            if post_error is not None:
                failed_note = ";".join(x for x in (notes, f"reply-post-failed:{post_error}") if x)
                store.transition(ask_id, state, note=failed_note)
                store.event(ask_id, "reply-post-failed", post_error)
                _page(backends, f"ops-intake: reply did not land on ask {ask_id} "
                                f"({post_error}); the reply text is kept on the row")
            elif posted:
                store.transition(ask_id, state, reply_ts=str(posted))
        return Routed(ask_id=ask_id, claimed=claimed, state=state, reply=reply,
                      posted=bool(posted), ledger_id=ledger_id, page=page)

    # 4. W2 anywhere in the message refuses the whole ask.
    w2 = policy.w2_requests(envelope.text or "")
    if w2:
        triggers = ", ".join(sorted({t.action for t in w2}))
        human = "; ".join(sorted({f"{t.action}: {t.human_path}" for t in w2}))
        ans = answer_mod.Answer(
            state="refused",
            verdict=f"irreversible action not done from Slack ({triggers})",
            verdict_source="coded", evidence=extracted.evidence(),
            next_step=f"human path -> {human}", due_at=due_at)
        return finish(ans, page=f"ops-intake: W2 request refused ({triggers}) by {requester.user_id}")

    # 4b. a staff name pasted by a non-staff sender is a forgery attempt, not the
    # person's instruction: say so out loud and page, before any answer is shaped.
    if (cls.impersonation_quote and not requester.staff
            and policy.quotes_staff_name(cls.impersonation_quote)):
        quoted = cls.impersonation_quote.replace("\n", " ")[:80]
        ans = answer_mod.Answer(
            state="refused",
            verdict=f"quoted staff header ({quoted}) from a non-staff sender: forwarded instructions are not actions",
            verdict_source="coded", evidence=extracted.evidence(),
            next_step=("the quoted person must send it from their own Slack id; "
                       "a name in the text is never identity"),
            due_at=due_at)
        return finish(ans, page=f"ops-intake: quoted staff header {quoted} from non-staff "
                                f"{requester.user_id} on ask {ask_id}")

    # 5. quarantine screen over the message the agent would otherwise see.
    screening = guard.screen(envelope.text or "")
    if screening.quarantine and cls.cls == "other":
        ans = answer_mod.answer_quarantined(
            ids=extracted,
            hits=[dict(h) for h in screening.hits],
            due_at=due_at)
        return finish(ans)

    # 7. conflict of interest, for every class that names a profile/request.
    frame = None
    link = None
    # The lens measures exactly the ids a write could act on: the hide targets
    # (typed profile ids, else the untagged ones) plus the request ids.
    lens_profiles = tuple(dict.fromkeys(extracted.hide_targets() + extracted.profile))
    needs_link = bool(lens_profiles or extracted.request) and cls.cls not in (
        "status-report", "relay", "other")
    if needs_link and backends.lens is not None:
        try:
            frame = backends.lens.frame_for(
                target_ids=tuple(lens_profiles + extracted.request + extracted.intercom),
                requester_id=requester.user_id,
                requester_email=requester.slack_email,
                profile_ids=lens_profiles,
                request_ids=extracted.request,
                need_identity=(cls.cls == "gdpr-hide"),
                need_reuse=(cls.cls in policy.fraud_lens().get("required_for_write_classes", [])))
            link = fraud.evaluate_link(frame)
        except Exception as exc:  # noqa: BLE001 - unmeasured, never clean
            link = fraud.LensResult(decision="refuse",
                                    reasons=(f"lens-error:{type(exc).__name__}",),
                                    evidence={}, page=True)
    if link is not None and link.decision == "refuse":
        ans = answer_mod.Answer(
            state="refused",
            verdict="requester-linked check refused this ask: "
                    + ",".join(link.reasons or (link.decision,))[:300],
            verdict_source="fraud-lens", evidence=extracted.evidence(),
            next_step="W2: a named human, never the requester's own Slack ask",
            due_at=due_at, lens=link)
        return finish(ans, page="ops-intake: requester-link refused ask "
                                f"{ask_id} by {requester.user_id} "
                                f"({','.join(link.reasons) or 'unmeasured'})")

    # 8. the coded answerer for the class.
    lost = superseded()
    if lost is not None:
        return lost
    try:
        ans = _answer_for(cls=cls.cls, ask={"ask_id": ask_id}, extracted=extracted,
                          backends=backends, due_at=due_at, policy=policy,
                          requester=requester, frame=frame, guardobj=guardobj,
                          text=envelope.text, asked_at=_iso(now))
    except Exception as exc:  # noqa: BLE001 - fail closed, never invent an answer
        ans = answer_mod.Answer(state="failed",
                                verdict=f"answerer error ({type(exc).__name__}) - nothing done",
                                verdict_source="coded", evidence=extracted.evidence(),
                                next_step="page: coded answerer raised", due_at=due_at,
                                page=f"ops-intake: answerer error on {cls.cls}")

    if cls.cls == "other" and not ans.write and not ans.page:
        # Hand it to the agent, but the row exists so "queued" can never be a lie.
        return finish(ans, claimed=False)

    lost = superseded()
    if lost is not None:
        return lost

    # 9. a proposed write goes through tier -> lens -> caps -> ledger.
    ledger_id = None
    if ans.write is not None:
        write = ans.write
        # The answerer's verdict is the ANSWER (the facts card and the mapped suggestion); step 9's
        # text is the WRITE OUTCOME. Replacing one with the other would hide the card from the
        # requester, so every step-9 answer carries both.
        base = ans.verdict
        ok, why = policy.may_write(requester, write.action)
        if not ok:
            # `page=ans.page` again: a read-only or unknown requester asking for a resolution
            # still gets a hand-off page from the answerer, and dropping it here means the case
            # reaches nobody. The refusal is about the WRITE, not about the hand-off.
            ans = answer_mod.Answer(
                state="refused",
                verdict=f"{base} · write {write.action} refused for this requester ({why})",
                verdict_source="coded", evidence=extracted.evidence(),
                next_step="a W1 requester (Jan / Nick / Aaron) or a named human",
                due_at=due_at, lens=ans.lens, page=ans.page)
            return finish(ans)

        if frame is None and backends.lens is not None:
            try:
                frame = backends.lens.frame_for(
                    target_ids=tuple(lens_profiles + extracted.request + extracted.intercom),
                    requester_id=requester.user_id,
                    requester_email=requester.slack_email,
                    profile_ids=lens_profiles,
                    request_ids=extracted.request,
                    need_identity=(cls.cls == "gdpr-hide"), need_reuse=True)
            except Exception as exc:  # noqa: BLE001
                frame = fraud.Frame(unmeasured=(f"lens-error:{type(exc).__name__}",))
        lens = (fraud.evaluate(frame, require_identity_verdict=(
                policy.actions["classes"][cls.cls].get("requires_register_verdict") or ()))
                if frame is not None else
                fraud.LensResult(decision="refuse", reasons=("lens-not-wired",), evidence={}))
        if not lens.permits_write:
            state = {"hold": "held", "ask": "ask"}.get(lens.decision, "refused")
            ans = answer_mod.Answer(
                state=state,
                verdict=(f"{base} · write blocked by fraud lens "
                         f"({','.join(lens.reasons) or lens.decision})"),
                verdict_source="fraud-lens", evidence=extracted.evidence(),
                next_step="human review of the lens result; no write performed",
                due_at=due_at, lens=lens,
                page=answer_mod.page_for_lens(lens, ask_id))
            return finish(ans, page=ans.page)

        allowed, cap_reason = ledger.cap_check(
            requester_id=requester.user_id, target=write.target,
            limits=policy.caps(), now=now)
        if not allowed:
            ans = answer_mod.Answer(
                state="held",
                verdict=f"{base} · write held by burst cap ({cap_reason})",
                verdict_source="coded", evidence=extracted.evidence(),
                next_step="page: a human decides whether the burst is real work",
                due_at=due_at, lens=lens)
            return finish(ans, page=f"ops-intake: cap hold on ask {ask_id} ({cap_reason})")

        try:
            ledger_id = ledger.plan(
                ask_id=ask_id, requester_id=requester.user_id, tier=requester.tier,
                action=write.action, target=write.target, params=write.params,
                inverse_action=write.inverse_action, inverse_params=write.inverse_params,
                at=_iso(now), detail=f"class={cls.cls} ask={ask_id}")
        except ledger_mod.LedgerError as exc:
            ans = answer_mod.Answer(
                state="refused",
                verdict=(f"{base} · {write.action} not performed: its inverse is not "
                         f"executable ({exc})"),
                verdict_source="coded", evidence=extracted.evidence(),
                next_step="no inverse, no write: a human decides, or the answerer records one",
                due_at=due_at, lens=lens)
            return finish(ans, page=f"ops-intake: write refused for a missing inverse on ask {ask_id}")

        writer = backends.writer(write.action)
        if writer is None:
            reason = f"no writer wired for {write.action}"
            ledger.mark_failed(ledger_id, undo_state="n/a", detail=f"{reason}; nothing executed")
            # `page=ans.page` is load-bearing: `_production_writers()` is empty by captain
            # decision, so this is the branch EVERY production ask takes. Dropping the page here
            # discarded the answerer's hand-off page and left the case with the bot while the
            # customer had been told someone would follow up.
            ans = answer_mod.Answer(
                state="answered",
                verdict=f"{base} · {write.action} recorded with its inverse; {reason}, nothing executed",
                verdict_source="coded", evidence=extracted.evidence(),
                next_step=(f"captain decision: wire a writer for {write.action} and set "
                           f"{WRITES_ENABLED_ENV}=1; the ledger row is the plan"),
                due_at=due_at, lens=lens, page=ans.page)
        else:
            try:
                result = writer(write.params)
            except Exception as exc:  # noqa: BLE001 - the inverse stays available
                ledger.mark_failed(ledger_id, detail=f"write failed: {exc}")
                ans = answer_mod.Answer(
                    state="failed",
                    verdict=f"{base} · {write.action} failed ({type(exc).__name__}); inverse not needed",
                    verdict_source="coded", evidence=extracted.evidence(),
                    next_step="page: write failure with a ledger row", due_at=due_at,
                    lens=lens, page=f"ops-intake: write failed on ask {ask_id}")
                return finish(ans, ledger_id=ledger_id, page=ans.page)
            handle = ledger_mod.inverse_handle(write.inverse_action, result)
            if handle:
                ledger.set_inverse(ledger_id, handle)
            if handle is None:
                ledger.mark_applied(
                    ledger_id, undo_state="unavailable",
                    detail=(f"{write.action} applied but its inverse handle is missing from "
                            f"the writer result: {json.dumps(result, sort_keys=True)[:500]}"))
                ans = answer_mod.Answer(
                    state="failed",
                    verdict=(f"{base} · {write.action} applied but the inverse handle was not "
                             f"returned - undo is unavailable"),
                    verdict_source="coded", evidence=extracted.evidence(),
                    next_step="page: a human must undo this write by hand", due_at=due_at,
                    lens=lens)
                return finish(ans, ledger_id=ledger_id,
                              page=f"ops-intake: {write.action} applied with no inverse handle on ask {ask_id}")
            ledger.mark_applied(ledger_id,
                                detail=json.dumps(result, sort_keys=True)[:2000])

    return finish(ans, ledger_id=ledger_id)


def _proof_review_answer(*, ask: dict[str, Any], ids: ids_mod.ExtractedIds, due_at: str,
                         asked_at: str) -> answer_mod.Answer:
    """The coded proof-review verdict for a conversation the router reached. Dry run only: the
    customer send stays on the credit-review.py uvn-status path, never here."""
    from . import proof_review
    if len(ids.intercom) > 1:
        # A review is ONE conversation: build_ask matches a single conversation_id, so naming two and
        # reviewing the first would mark the ask answered with the second one's proof never read. A
        # person splits the ask instead of this lane deciding on a conversation it was not asked about.
        return answer_mod.Answer(
            state="ask",
            verdict=(f"proof-review not decided: the ask names {len(ids.intercom)} conversations and a review "
                     "is one conversation"),
            verdict_source="coded", evidence=ids.evidence(),
            next_step="a person must split the ask into one conversation per ask, then re-ask",
            due_at=due_at)
    conversation = ids.intercom[0] if ids.intercom else ""
    try:
        built = proof_review.build_ask(ask_id=str(ask.get("ask_id") or ""),
                                       conversation_id=conversation,
                                       asked_at=asked_at or proof_review.utcnow(),
                                       lens=proof_review.real_lens())
        rev = proof_review.run(built, mode="dry-run")
    except proof_review.ProofReviewError as exc:
        return answer_mod.Answer(
            state="failed",
            verdict=f"proof-review could not read the evidence ({exc}) - no verdict produced",
            verdict_source="coded", evidence=ids.evidence(),
            next_step="page: coded proof-review store unreadable", due_at=due_at,
            page=f"ops-intake: proof-review evidence unreadable on {conversation or 'no conversation'}")
    if not rev.verdicts:
        # Nothing was decided: no H3 filing at all (`unfiled`), filings whose candidate requests were
        # never recorded, or an ask this lane refuses to decide (it covers several accounts). That is
        # not an answer - the ask stays OPEN with the gate reason, so the missing step is chased
        # instead of the ask closing on zero requests. A refused ask carries no card, and an empty
        # evidence trips the reply contract, so the refusal states itself here.
        evidence = rev.card or (f"proof-review {rev.ask.ask_id} · acct {rev.ask.account} · refused: "
                               f"{rev.gate_reason or 'no verdict'} · sent: none")
        return answer_mod.Answer(
            state="ask",
            verdict=f"proof-review {rev.state}: no verdict produced for this ask",
            verdict_source="coded", evidence=evidence,
            next_step=(rev.gate_reason or "file the conversation's proof and its candidate requests "
                       "(credit-proof.py file --apply) before the review can decide"),
            due_at=due_at)
    if rev.state in ("unknown", "ask"):
        # UNKNOWN asks nothing and approves nothing: a judge has not finished reading (or a read
        # names no document on file), so the ask is not answered and not closed - it stays OPEN and
        # is chased by the overdue-ask tick until doc-verify's next read or the stage-2 write decides
        # it. The campaign travels with the review; the sender owns the copy and the send.
        counts = ", ".join(f"{n} {v}" for v, n in sorted(rev.counts.items()) if n)
        return answer_mod.Answer(
            state="ask",
            verdict=f"proof-review {rev.state}: nothing asked and nothing decided"
                    + (f": {counts}" if counts else ""),
            verdict_source="coded", evidence=rev.card,
            next_step="doc-verify's next read or the stage-2 write decides this ask; it stays open until then"
                      + (f" (campaign {rev.campaign})" if rev.campaign else ""),
            due_at=due_at)
    counts = ", ".join(f"{n} {v}" for v, n in sorted(rev.counts.items()) if n)
    if rev.state in ("hold", "declined"):
        # A hold (a forged document, a fraud hold) and a contradiction are decisions this lane may
        # NOT take: un-holding a forged document or refusing a claim is a named human's. So the ask
        # is not answered - it is HELD, the human queue is paged, and the state says which one it is
        # so nobody reads "answered" as resolved.
        held_for = ("a held or forged document and the claim" if rev.state == "hold"
                    else "a returned document that contradicts the claim")
        return answer_mod.Answer(
            state="held",
            verdict=f"proof-review {rev.state}: a person decides this ask"
                    + (f": {counts}" if counts else ""),
            verdict_source="coded", evidence=rev.card,
            next_step=f"a named human decides {held_for}; this lane records the verdict and sends nothing",
            due_at=due_at,
            page=(f"ops-intake: proof-review {rev.state} on ask {ask.get('ask_id') or '-'} "
                  f"- a person decides"))
    if rev.state == "waiting_route":
        # Every request is supported, but approving a credit is not this lane's step and the route
        # that would record the approval is OFF (`policies/proof-review-route.json`). The ask is not
        # answered: it stays OPEN in the ask state, so the overdue tick chases the captain decision
        # instead of the review closing on a decision nobody made.
        return answer_mod.Answer(
            state="ask",
            verdict=(f"proof-review {rev.state}: every request is supported, no approval route to record it"
                     + (f": {counts}" if counts else "")),
            verdict_source="coded", evidence=rev.card,
            next_step=("approval is a captain decision and the route that records it is off, so this ask "
                       "stays open until a person rules on it"),
            due_at=due_at)
    if rev.state == "asked" and rev.sent in ("", "none"):
        # The review chose a campaign but nothing has been sent: this answer runs `mode="dry-run"`, so no
        # customer message leaves from here. Closing the ask `answered` would retire it from the open queue
        # before anyone was asked, so it stays OPEN and the missing send is what a person is told to do.
        # A recorded send (`rev.sent` names the campaign the sender reported `sent_notes` for) closes it.
        return answer_mod.Answer(
            state="ask",
            verdict=(f"proof-review asked: {rev.campaign or 'a campaign'} chosen, no customer message sent yet"
                     + (f": {counts}" if counts else "")),
            verdict_source="coded", evidence=rev.card,
            next_step=("the approved sender has not been invoked for this ask: run the sender's "
                       f"--campaign {rev.campaign or 'gap-ask|uvn-status'} for this account, then re-ask"),
            due_at=due_at)
    return answer_mod.Answer(
        state="answered",
        verdict=f"proof-review {rev.state}" + (f": {counts}" if counts else ""),
        verdict_source="coded", evidence=rev.card,
        next_step="the ask is the only coded step; approval is a captain decision",
        due_at=due_at)


def _answer_for(*, cls: str, ask: dict[str, Any], extracted: ids_mod.ExtractedIds,
                backends: answer_mod.Backends, due_at: str,
                policy: policy_mod.Policy, requester: policy_mod.Requester,
                frame: fraud.Frame | None | None = None,
                guardobj: guard.Guard | None = None,
                text: str | None = None,
                asked_at: str = "") -> answer_mod.Answer:
    if cls == "proof-review":
        if extracted.intercom:
            return _proof_review_answer(ask=ask, ids=extracted, due_at=due_at, asked_at=asked_at)
        return answer_mod.answer_proof_review(ask=ask, ids=extracted, backends=backends,
                                              due_at=due_at)
    if cls == "summarize-resolve":
        # The card's account state depends on WHO asked (a requester-linked account is a refusal),
        # so the requester travels with the ask. `text` is the requester's own message: it is the
        # only place a rename's target name may come from.
        return answer_mod.answer_summarize_resolve(
            ask=ask, ids=extracted, backends=backends, due_at=due_at, policy=policy,
            guardobj=guardobj,
            requester_email=requester.slack_email,
            requester_ids=(requester.user_id,), text=text)
    if cls == "gdpr-hide":
        lens = fraud.evaluate(frame, require_identity_verdict=(
            policy.actions["classes"]["gdpr-hide"].get("requires_register_verdict") or ())
        ) if frame is not None else None
        return answer_mod.answer_gdpr_hide(ask=ask, ids=extracted, backends=backends,
                                           due_at=due_at, lens=lens)
    if cls == "clickup-categorize":
        return answer_mod.answer_clickup(ask=ask, ids=extracted, backends=backends,
                                         due_at=due_at)
    if cls == "status-report":
        return answer_mod.answer_status_report(ask=ask, ids=extracted, backends=backends,
                                               due_at=due_at)
    if cls == "fraud-scan":
        lens = fraud.evaluate(frame) if frame is not None else None
        return answer_mod.answer_fraud_scan(ask=ask, ids=extracted, lens=lens,
                                            due_at=due_at)
    if cls == "billing":
        return answer_mod.answer_billing(ask=ask, ids=extracted, due_at=due_at)
    if cls == "profile-edit":
        lens = fraud.evaluate(frame) if frame is not None else None
        return answer_mod.answer_profile_edit(ask=ask, ids=extracted, backends=backends,
                                              lens=lens, due_at=due_at, policy=policy,
                                              requester=requester, text=text)
    if cls == "relay":
        return answer_mod.answer_relay(ask=ask, ids=extracted, due_at=due_at)
    return answer_mod.answer_other(ask=ask, ids=extracted, due_at=due_at)


def _safe_render(cls: str, ask_id: str, ans: answer_mod.Answer, due_at: str,
                 ledger_id: int | None) -> str:
    try:
        return answer_mod.render(cls=cls, ask_id=ask_id, answer=ans, due_at=due_at,
                                 ledger_row=ledger_id)
    except answer_mod.ContractViolation:
        return answer_mod.render_minimal(cls=cls, ask_id=ask_id, state=ans.state,
                                         due_at=due_at, ledger_row=ledger_id)


POST_ATTEMPTS = 2


def _post_reply(backends: answer_mod.Backends, envelope: Envelope, text: str,
                dry_run: bool) -> tuple[str | None, str | None]:
    """Post the reply, retrying once. Returns (ts, error); a dry run says neither.

    A post failure must never abort intake (the verdict is already recorded): the
    caller keeps the row and pages.
    """
    if dry_run:
        return None, None
    if backends.poster is None:
        return None, None
    last = "poster failed"
    for attempt in range(POST_ATTEMPTS):
        try:
            ts = backends.poster(channel=envelope.channel,
                                 thread_ts=envelope.thread_ts or envelope.ts, text=text)
            return str(ts or ""), None
        except Exception as exc:  # noqa: BLE001 - recorded, never fatal
            last = f"{type(exc).__name__}: {exc}"[:300]
            if attempt + 1 < POST_ATTEMPTS:
                time.sleep(RETRY_PAUSE_S)
    return None, last


def _without_post_failure(note: str | None) -> str:
    """The row's note minus any reply-post-failure markers; everything else stays."""
    kept = [part for part in (note or "").split(";")
            if part and not part.startswith("reply-post-failed:")]
    return ";".join(kept)


def _page(backends: answer_mod.Backends, text: str) -> bool:
    """Page, and report whether it landed. A failed page never undoes an answer.

    The ONE page boundary: user-derived fragments (a quoted staff header, a lens
    reason, an ask id) are made inert here, exactly as the reply boundary does.
    """
    if backends.pager is None:
        return False
    text = answer_mod.escape_mrkdwn(text)
    try:
        delivered = backends.pager(text)
    except Exception as exc:  # noqa: BLE001 - logged below, never raised
        print(f"ops-intake: page failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return False
    if delivered is False:
        print(f"ops-intake: page not delivered: {text[:200]}", file=sys.stderr)
        return False
    return True


def _escalate_quarantine(store: store_mod.AskStore, ask_id: str, verdict: str) -> None:
    store.event(ask_id, "quarantined", verdict)


# ---------------------------------------------------------------------------
# CLI: the plugin's only entry point. JSON envelope on stdin, JSON result on stdout.
# ---------------------------------------------------------------------------


def page_no_ts(envelope: Envelope, *, store: store_mod.AskStore | None = None) -> bool:
    """Page ONCE per UTC day about a message that carries no Slack ts.

    ``(channel, ts)`` is the register's idempotency key, so a message without a
    ts cannot be recorded: keying it on a constant would fold every such message
    into one row and answer the second asker with the first ask's reply. The
    plugin therefore CLAIMS it (no agent turn) and posts the fail-closed line;
    this page is the on-call half. It is the NETWORK half and therefore never
    runs in the claim fast path - the detached ``page`` child calls it.
    """
    store = store or store_mod.AskStore()
    print(f"ops-intake: no Slack ts on a message in {envelope.channel} from "
          f"{envelope.user_id}; it was not claimed", file=sys.stderr)
    stamp = Path(store.path).parent / NO_TS_PAGE_STAMP
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        if stamp.is_file() and stamp.read_text().strip() == today:
            return False
    except OSError:
        pass
    text = answer_mod.escape_mrkdwn(
        f"ops-intake: a message from {envelope.user_id} in {envelope.channel} carried no "
        "Slack ts; no ask row was written (a stable key is required) and no action "
        "was taken. The plugin claimed it, so no agent turn saw it - handle it by hand.")
    try:
        if not slack_page(text):
            return False
    except Exception as exc:  # noqa: BLE001 - the claim refusal is the guarantee
        print(f"ops-intake: no-ts page failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return False
    try:
        stamp.write_text(today + "\n")
    except OSError:
        pass
    return True


ROUTER_UNAVAILABLE_STAMP = "router-unavailable-paged"
ROUTER_UNAVAILABLE_WINDOW = timedelta(minutes=30)


def page_router_unavailable(envelope: Envelope, *, store: store_mod.AskStore | None = None,
                            window: timedelta = ROUTER_UNAVAILABLE_WINDOW) -> bool:
    """Page #clio_devops ONCE per outage window when the router cannot answer.

    The plugin's fail-closed reply only reaches the asker's thread; a systemic
    outage (python missing, sqlite wedged, policy unreadable) must reach the
    on-call too. The window keeps a redelivery storm from paging per message.
    """
    store = store or store_mod.AskStore()
    stamp = Path(store.path).parent / ROUTER_UNAVAILABLE_STAMP
    now = datetime.now(timezone.utc)
    try:
        last = datetime.strptime(stamp.read_text().strip(), "%Y-%m-%dT%H:%M:%SZ")
        if now - last.replace(tzinfo=timezone.utc) < window:
            return False
    except (OSError, ValueError):
        pass
    text = answer_mod.escape_mrkdwn(
        f"ops-intake: the router did not answer a claim from {envelope.user_id} in "
        f"{envelope.channel}; the message was claimed and the asker got the "
        "fail-closed reply. Check the router (python, sqlite, policy).")
    try:
        if not slack_page(text):
            return False
    except Exception as exc:  # noqa: BLE001 - the claim is the guarantee
        print(f"ops-intake: router-unavailable page failed: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return False
    try:
        stamp.write_text(now.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n")
    except OSError:
        pass
    return True


def slack_page(text: str) -> bool:
    from ops_intake.slack import page  # noqa: PLC0415
    return page(text)


def _envelope_from_payload(payload: dict[str, Any]) -> Envelope:
    return Envelope(
        account_id=str(payload.get("account_id") or "operations"),
        channel=str(payload.get("channel") or ""),
        user_id=str(payload.get("user_id") or ""),
        text=str(payload.get("text") or ""),
        ts=str(payload.get("ts") or ""),
        thread_ts=payload.get("thread_ts"),
        is_dm=bool(payload.get("is_dm")),
        display_name=payload.get("display_name"),
        bot_id=payload.get("bot_id"),
        subtype=payload.get("subtype"))


def claim(*, envelope: Envelope, policy: policy_mod.Policy | None = None,
          store: store_mod.AskStore | None = None,
          now: datetime | None = None) -> dict[str, Any]:
    """The FAST half: decide whether this message is ours, and write the row.

    The plugin must answer ``inbound_claim`` synchronously (an 8s ``spawnSync``
    budget), so the claim decision touches NO network: it is pure classification
    plus one sqlite insert - and the row it writes is the same row the full run
    then answers, which is why a crash between the two leaves a queue entry
    instead of silence. A message it refuses to key (``no-ts``) comes back with a
    ``page`` marker, which the plugin turns into a detached ``page`` child; the
    plugin also claims that message and posts the fail-closed line, so it never
    reaches an agent turn.

    Only ``other`` is handed to the agent, and only when its text is not a HIGH
    injection hit: an injected message must not reach an agent turn either.
    """
    now = now or datetime.now(timezone.utc)
    policy = policy or policy_mod.load()
    store = store or store_mod.AskStore()

    skip = should_ignore(envelope)
    if skip:
        if skip == "no-ts":
            # Network-free: the plugin spawns the detached `page` child for it.
            print(f"ops-intake: no Slack ts on a message in {envelope.channel} from "
                  f"{envelope.user_id}; not claiming it", file=sys.stderr)
        return {"claimed": False, "state": "ignored", "skip_reason": skip,
                "page": "no-ts" if skip == "no-ts" else None,
                "ask_id": None, "class": None}
    if not channel_allowed(policy, envelope):
        return {"claimed": False, "state": "ignored", "skip_reason": "channel-not-allowlisted",
                "ask_id": None, "class": None}

    requester = policy.resolve(envelope.user_id, display_name=envelope.display_name)
    text_sha = hashlib.sha256((envelope.text or "").encode("utf-8")).hexdigest()
    cls = classes.classify(envelope.text or "", text_sha256=text_sha)
    extracted = ids_mod.extract(envelope.text or "")
    due_at = _iso(store_mod.slack_ts_to_dt(envelope.ts) + store_mod.DUE_AFTER)
    ask_id, _created = store.add_ask(store_mod.NewAsk(
        slack_ts=envelope.ts, slack_channel=envelope.channel,
        slack_thread=envelope.thread_ts, account_id=envelope.account_id,
        requester_id=requester.user_id, requester_name=requester.name,
        tier=requester.tier, cls=cls.cls, candidates=cls.candidates,
        text_sha256=text_sha, extracted_ids=extracted.as_dict(), due_at=due_at),
        now=_iso(now))
    quarantine = guard.screen(envelope.text or "").quarantine and cls.cls == "other"
    store.event(ask_id, "claimed",
                f"class={cls.cls} tier={requester.tier} quarantine={quarantine}")
    handoff = cls.cls == "other" and not quarantine
    if handoff:
        # The row stays OPEN: the agent turn has not answered yet, and a hand-off
        # is not an answer. The watcher closes it when the thread shows the agent
        # replied, and escalates it when it does not.
        store.mark_handoff(
            ask_id, verdict="not a coded class: handed to the operations agent turn")
    return {"claimed": cls.cls != "other" or quarantine, "ask_id": ask_id,
            "state": "open", "class": cls.cls,
            "tier": requester.tier, "quarantined": quarantine}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command",
                        choices=("intake", "claim", "digest", "overdue", "page",
                                 "page-unavailable"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.command == "digest":
        print(json.dumps(store_mod.AskStore().digest(), sort_keys=True))
        return 0
    if args.command == "overdue":
        rows = store_mod.AskStore().overdue()
        print(json.dumps({"count": len(rows),
                          "asks": [{"ask_id": r["ask_id"], "class": r["class"],
                                    "requester_id": r["requester_id"],
                                    "due_at": r["due_at"]} for r in rows]}, sort_keys=True))
        return 0

    try:
        payload = json.load(sys.stdin)
    except ValueError as exc:
        print(json.dumps({"error": f"bad envelope json: {exc}"}))
        return 2
    if args.command == "claim":
        policy = policy_mod.load()
        print(json.dumps(claim(envelope=_envelope_from_payload(payload), policy=policy),
                         sort_keys=True))
        return 0
    if args.command == "page":
        # The ONE trigger for the no-ts page: the plugin spawns this detached child
        # when claim() returns its `page` marker. `intake` never pages, because a
        # no-ts message has no ask row and so never reaches it.
        paged = page_no_ts(_envelope_from_payload(payload))
        print(json.dumps({"paged": paged}, sort_keys=True))
        return 0
    if args.command == "page-unavailable":
        # The plugin spawns this detached child when the router cannot answer a
        # claim, so a systemic outage reaches #clio_devops and not only the thread.
        paged = page_router_unavailable(_envelope_from_payload(payload))
        print(json.dumps({"paged": paged}, sort_keys=True))
        return 0

    backends = production_backends()
    guardobj = production_guard() if os.environ.get("OPS_INTAKE_MODEL") == "1" else None
    try:
        policy = policy_mod.load()
    except policy_mod.PolicyError as exc:
        # No policy, no tier, no write, no claim: the agent gets the message and a
        # page tells a human the policy file is broken.
        print(json.dumps({"error": f"policy: {exc}", "claimed": False}))
        return 3
    routed = route(envelope=_envelope_from_payload(payload), policy=policy,
                   backends=backends, guardobj=guardobj, dry_run=args.dry_run)
    print(json.dumps(routed.as_dict(), sort_keys=True))
    return 0


def production_guard() -> guard.Guard:
    """The tool-less judge for the ONE optional model step (the intent label).

    ``credit_trust/llm.py`` is the repo's only sanctioned tool-less ladder; the
    Ops agent turn is not in this path. Every call is an ``llm_calls`` row.
    ``answer_summarize_resolve`` screens the fetched text first, delimits it as
    data, and calls through ``guard.Guard.call`` so the canary is checked on the
    way out.
    """

    def _judge(prompt: str, schema: dict[str, Any] | None):
        from credit_trust import llm  # noqa: PLC0415

        result = llm.Provider().judge(prompt, schema or {}, step="ops-intake")
        if not result.ok:
            raise RuntimeError(f"model chain exhausted: {result.error}")
        return {"text": result.text, "data": result.json}

    return guard.Guard(judge=_judge)


def production_backends() -> answer_mod.Backends:
    """Wire the real adapters. The reads, the reply and the page are ALWAYS wired
    (an ask that is claimed must be answered and escalated); only W1 execution is
    gated, and writers exist only when OPS_INTAKE_WRITES=1 (captain decision).

    The two coded reads (coded proof verdicts, the Intercom conversation) are
    wired; ClickUp counts and the status report are deliberately unwired until a
    coded producer is chosen (scripts/ops_intake/sources.py), so those classes
    answer "no coded count available" with a due time instead of a number nobody
    measured."""
    from ops_intake import sources  # noqa: PLC0415

    def _poster(*, channel: str, thread_ts: str | None, text: str) -> str | None:
        from ops_intake.slack import post_message  # noqa: PLC0415
        return post_message(channel=channel, thread_ts=thread_ts, text=text,
                            account="operations")

    def _pager(text: str) -> bool:
        from ops_intake.slack import page  # noqa: PLC0415
        return page(text)

    writers: dict[str, Any] = {}
    if os.environ.get(WRITES_ENABLED_ENV) == "1":
        writers = _production_writers()

    return answer_mod.Backends(
        dv_outcomes=sources.dv_outcome,
        intercom_conversation=sources.intercom_conversation,
        profile_name=sources.profile_display_name,
        lens=fraud.ProductionLens(),
        writers=writers,
        poster=_poster,
        pager=_pager,
    )


def _production_writers() -> dict[str, Any]:
    """The W1 actuators, by ledger action name. None is implemented yet - a plan
    is recorded with its inverse and marked as not executed, never applied."""
    return {}


if __name__ == "__main__":
    raise SystemExit(main())
