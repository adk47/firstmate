"""Per-draft pipeline and batch orchestrator for the outreach sender.

Imports of adapter modules are deferred/injected so tests can pass a
mock Adapters bag without the gog CLI being installed.
"""
from __future__ import annotations

import sys as _sys
import time as _time
from dataclasses import dataclass
from typing import Optional, Protocol

from . import gates
from .config import (
    CONTACT_REPLY_LOOKBACK_DAYS_NEW,
    MAX_FOLLOWUPS_PER_CONTACT,
    MUSO_ACCOUNTS,
    OUTREACH_ALLOWED_SENDERS,
    OUTREACH_LABEL,
)
from .metadata import parse_from_draft
import re

from .types import ContactRow, Kind, Metadata, NocoContact


def _safe_slack(fn, *args, fallback_tag: str = "") -> None:
    """Post to Slack; if Slack fails, degrade to stderr. Never raises.

    Used ONLY in the post-send phase where a raise would corrupt the
    retry envelope's 'pre-send failures only' invariant. Also used
    pre-send so a Slack outage doesn't blow a retry budget.
    """
    try:
        fn(*args)
    except Exception as e:  # noqa: BLE001
        print(
            f"[muso-outreach-sender] Slack alert degraded ({fallback_tag}): "
            f"{e!r}. Args: {args!r}",
            file=_sys.stderr,
            flush=True,
        )


def NOW_EPOCH() -> int:
    """Overridable for tests."""
    return int(_time.time())


SEND_RETRY_BACKOFF_SEC = 5


@dataclass(frozen=True)
class ProcessResult:
    draft_id: str
    sent: bool
    reason_code: Optional[str]
    reason_human: Optional[str]
    sent_message_id: Optional[str] = None


class Adapters(Protocol):
    gmail: object
    sheets: object
    nocodb: object
    slack: object
    ghl: object


@dataclass(frozen=True)
class BatchReport:
    sent_count: int
    blocked_count: int
    send_failed_count: int
    batch_halted: bool


def _fetch_thread(meta: Metadata, adapters) -> Optional[object]:
    if meta.kind is not Kind.FOLLOWUP or not meta.original_thread_id:
        return None
    return adapters.gmail.fetch_thread(meta.original_thread_id, meta.sender)


def _fetch_noco(meta: Metadata, adapters) -> Optional[NocoContact]:
    """NocoDB record for a NocoDB-keyed draft. A record whose Row ID differs
    from the draft's is a different contact: treat it as not found."""
    if meta.nocodb_id is None:
        return None
    rec = adapters.nocodb.get_contact(meta.nocodb_id)
    if rec is None or rec.row_id != meta.row_id:
        return None
    return rec


def _fetch_contact_row(meta: Metadata, adapters, noco=None) -> Optional[ContactRow]:
    if meta.kind is not Kind.NEW:
        return None
    if meta.nocodb_id is not None:
        if noco is None:
            return None
        return ContactRow(noco.row_id, noco.valid_professional_email)
    return adapters.sheets.get_contact_by_row_id(meta.sheet_row_id)


_FOLLOW_UP_STATUS_RE = re.compile(r"Follow Up (\d+)")


def prior_followups(meta: Metadata, adapters, noco=None) -> int:
    """Follow-ups already sent to this contact. NocoDB keys take the larger
    of the logbook count and the NocoDB Status ("Follow Up N"): the status
    can only make the cap stricter."""
    if meta.nocodb_id is None:
        return adapters.sheets.count_prior_followups(meta.sheet_row_id)
    logged = adapters.sheets.count_prior_followups_by_token(f"nocodb:{meta.nocodb_id}")
    m = _FOLLOW_UP_STATUS_RE.fullmatch(noco.status) if noco else None
    return max(logged, int(m.group(1)) if m else 0)


def _fetch_inbound(meta: Metadata, draft, adapters) -> tuple:
    if meta.kind is not Kind.NEW or not draft.to_addrs:
        return ()
    return adapters.gmail.search_inbound_from(
        draft.to_addrs[0],
        days=CONTACT_REPLY_LOOKBACK_DAYS_NEW,
        accounts=MUSO_ACCOUNTS,
    )


def _run_all_gates(draft, meta, thread, contact_row, adapters, noco=None) -> gates.GateResult:
    """Run gates A–G in order; first failure wins."""
    if meta.nocodb_id is not None and noco is None:
        # Follow-ups take the recipient from the thread, but the Status cap
        # lives on the NocoDB record: no usable record means no send.
        return gates.GateResult(
            passed=False,
            reason_code=gates.RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"{gates._contact_ref(meta)} was not found in NocoDB "
                "(or its Row ID differs from the draft's)."
            ),
        )
    a = gates.gate_a_recipient_match(draft, meta, thread, contact_row)
    if not a.passed:
        return a
    b = gates.gate_b_no_contact_reply(
        meta, thread,
        inbound_messages=_fetch_inbound(meta, draft, adapters),
        bot_senders=tuple(OUTREACH_ALLOWED_SENDERS),
    )
    if not b.passed:
        return b
    c = gates.gate_c_no_human_reply(meta, thread,
                                    bot_senders=tuple(OUTREACH_ALLOWED_SENDERS))
    if not c.passed:
        return c
    d = gates.gate_d_not_weekend(NOW_EPOCH())
    if not d.passed:
        return d
    prior = 0
    if meta.kind is Kind.FOLLOWUP:
        prior = prior_followups(meta, adapters, noco)
    e = gates.gate_e_followup_cap(prior, cap=MAX_FOLLOWUPS_PER_CONTACT)
    if not e.passed:
        return e
    f = gates.gate_f_sender_allowed(draft, meta,
                                    allow_list=OUTREACH_ALLOWED_SENDERS)
    if not f.passed:
        return f
    return gates.gate_g_cc_bcc_match_allowlist(draft, meta)


def _build_logbook_row(draft, meta, sent_message_id: str) -> list:
    from datetime import datetime, timezone
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    domain = (draft.to_addrs[0].split("@")[-1] if draft.to_addrs else "")
    action = "Follow-Up Sent" if meta.kind is Kind.FOLLOWUP else "Sent"
    if meta.nocodb_id is not None:
        notes = f"nocodb:{meta.nocodb_id} row_id:{meta.row_id} template:{meta.template}"
    else:
        notes = f"row:{meta.sheet_row_id} template:{meta.template}"
    if meta.override_reason:
        notes += f" override:{meta.override_reason[:120]}"
    return [
        "",        # # column (sheet autoincrements)
        date_str,
        meta.sender,
        domain,
        "",        # contact name — filled by agent's drafting step
        "",        # company — same
        "",        # title — same
        draft.to_addrs[0] if draft.to_addrs else "",
        action,
        "Sent",
        "",        # subject — optional
        meta.template,
        notes,
    ]


def process_draft(draft_id: str, account: str, adapters) -> ProcessResult:
    """Run the full per-draft pipeline. Returns a ProcessResult.

    Gate failure → post #sales-alerts, return sent=False.
    Send success + logbook failure → post devops red-alert.
    Send+log success + GHL failure → post #sales-alerts warning.
    """
    draft = adapters.gmail.fetch_draft(draft_id, account)

    try:
        meta, warnings = parse_from_draft(draft)
    except ValueError as e:
        reason = (
            "Metadata labels missing. This usually means the draft was "
            "created outside the agent workflow or the body was edited "
            "in Gmail. Re-create the draft from the agent."
            if e.args[0] == "METADATA_MISSING"
            else "Metadata label/body mismatch - refusing to send. Re-create the draft."
        )
        _safe_slack(
            adapters.slack.post_sales_alert,
            f":no_entry: Draft `{draft_id}` blocked: {reason}",
            fallback_tag="metadata-missing",
        )
        return ProcessResult(draft_id, False, e.args[0], reason)

    for w in warnings:
        _safe_slack(
            adapters.slack.post_sales_alert,
            f":warning: Draft `{draft_id}`: {w}",
            fallback_tag="metadata-warning",
        )

    thread = _fetch_thread(meta, adapters)
    noco = _fetch_noco(meta, adapters)
    contact_row = _fetch_contact_row(meta, adapters, noco)

    gate_result = _run_all_gates(draft, meta, thread, contact_row, adapters, noco)
    if not gate_result.passed:
        _safe_slack(
            adapters.slack.post_sales_alert,
            f":no_entry: Draft `{draft_id}` ({meta.kind.value}) blocked: "
            f"{gate_result.reason_code} - {gate_result.reason_human}",
            fallback_tag="gate-blocked",
        )
        return ProcessResult(draft_id, False,
                             gate_result.reason_code,
                             gate_result.reason_human)

    # Idempotency note: Gmail removes the draft object at send time, so
    # a replay of this worker against the same draft_id will already
    # have failed at fetch_draft() above with a 404. list_drafts_with_label
    # also stops returning sent drafts. No explicit guard needed here.

    # Send. From this point the email is out the door; any subsequent
    # failure is a LOGGING failure, not a send failure. We must NEVER
    # raise out of this function after send_draft succeeds, or the
    # retry envelope will re-send.
    sent_id = adapters.gmail.send_draft(draft_id, account)

    # Label re-apply is best-effort — the label on the sent message is
    # cosmetic, the logbook is the authoritative record. Failures here
    # get noted but do not fail the draft.
    try:
        adapters.gmail.apply_label(sent_id, OUTREACH_LABEL, account)
    except Exception as e:  # noqa: BLE001
        _safe_slack(
            adapters.slack.post_sales_alert,
            f":warning: Draft `{draft_id}` sent (message `{sent_id}`) "
            f"but label re-apply failed: {e!r}. Logbook append continues.",
            fallback_tag="apply-label-failure",
        )

    # Logbook append — critical. Failure here is a red alert.
    try:
        adapters.sheets.append_logbook_row(_build_logbook_row(draft, meta, sent_id))
    except Exception as e:  # noqa: BLE001
        _safe_slack(
            adapters.slack.post_devops_alert,
            f":rotating_light: RED ALERT: draft `{draft_id}` sent "
            f"(message `{sent_id}`) but logbook append failed: {e!r}. "
            "Manual reconciliation required.",
            fallback_tag="logbook-red-alert",
        )
        return ProcessResult(draft_id, True, "LOGBOOK_APPEND_FAILED",
                             f"Logbook failed: {e!r}", sent_id)

    # GHL sync is deferred — needs pipeline-stage ID lookup by (pipeline,
    # kind, prior_count). See docs/superpowers/specs/2026-04-14-cmo-outreach-sender-worker-design.md
    # §2 step 7 and workspaces/cmo/skills/muso-outreach-engine/references/pipeline-stages.md.
    # For now: skip the sync entirely rather than 400 GHL on every send.
    # Fede's runbook step "Advance the opp manually" remains the interim process.
    # TODO(outreach-sender): wire in stage-id lookup and re-enable.
    opp_hint = (f"advance opp `{meta.opp_id}` manually" if meta.opp_id
                else "no GHL opp yet — create it manually")
    _safe_slack(
        adapters.slack.post_sales_alert,
        f":information_source: Draft `{draft_id}` sent + logged. "
        f"GHL sync deferred - {opp_hint} "
        "(see runbook).",
        fallback_tag="ghl-deferred-info",
    )

    return ProcessResult(draft_id, True, None, None, sent_id)


def _process_one_with_retry(draft_id: str, account: str, adapters) -> tuple[ProcessResult, bool]:
    """Return (result, send_failed_after_retry).

    SAFETY: process_draft is designed to never raise after send_draft
    has succeeded — post-send failures are caught internally and
    surfaced via reason_code. That means any raise we see here is a
    pre-send problem and retrying is safe (no double-send risk).
    """
    try:
        return process_draft(draft_id, account, adapters), False
    except Exception:
        # Single retry for transient pre-send failures only.
        _time.sleep(SEND_RETRY_BACKOFF_SEC)
        try:
            return process_draft(draft_id, account, adapters), False
        except Exception as e:  # noqa: BLE001
            return (
                ProcessResult(
                    draft_id=draft_id, sent=False,
                    reason_code="SEND_FAILED_RETRIED",
                    reason_human=f"Both attempts raised: {e!r}",
                ),
                True,
            )


def process_batch(draft_ids: list[str], account: str, adapters) -> BatchReport:
    """Process a list of draft IDs sequentially.

    Halts the batch if two consecutive drafts fail to send after retry.
    Posts a summary to #sales-alerts when done.
    """
    sent = 0
    blocked = 0
    send_failed = 0
    halted = False
    consecutive_send_failures = 0

    for draft_id in draft_ids:
        result, failed_to_send = _process_one_with_retry(draft_id, account, adapters)
        if failed_to_send:
            send_failed += 1
            consecutive_send_failures += 1
            _safe_slack(
                adapters.slack.post_sales_alert,
                f":warning: Draft `{draft_id}` send failed after retry - skipping.",
                fallback_tag="send-failed-retry",
            )
            if consecutive_send_failures >= 2:
                halted = True
                _safe_slack(
                    adapters.slack.post_devops_alert,
                    f":rotating_light: Batch halted - 2 consecutive send failures. "
                    "Gmail likely in outage state.",
                    fallback_tag="batch-halted",
                )
                break
            continue
        consecutive_send_failures = 0
        if result.sent:
            sent += 1
        else:
            blocked += 1

    _safe_slack(
        adapters.slack.post_sales_alert,
        f":white_check_mark: Batch done - sent: {sent}, blocked: {blocked}, "
        f"halted: {'yes' if halted else 'no'}",
        fallback_tag="batch-summary",
    )
    return BatchReport(sent_count=sent, blocked_count=blocked,
                       send_failed_count=send_failed, batch_halted=halted)


def dry_run(labels: tuple[str, ...], adapters) -> tuple[list[str], int]:
    """Parse draft labels and look the contact up, with no side effects.

    Returns (output lines, exit code): 0 when the contact is found (and its
    Row ID matches), 1 when the labels do not parse or it is not. Only read calls
    are made (NocoDB / sheet lookups). The contact's email is never printed.
    """
    from .types import Draft
    stub = Draft("dry-run", "", (), (), (), "", tuple(labels), None)
    try:
        meta, _ = parse_from_draft(stub)
    except ValueError as e:
        return [f"metadata_error={e.args[0]}"], 1
    lines = [
        f"kind={meta.kind.value}",
        f"nocodb_id={meta.nocodb_id}",
        f"row_id={meta.row_id}",
        f"sheet_row_id={meta.sheet_row_id}",
        f"opp_id={meta.opp_id}",
        f"template={meta.template}",
        f"sender={meta.sender}",
        f"thread={meta.original_thread_id}",
    ]
    if meta.nocodb_id is not None:
        rec = adapters.nocodb.get_contact(meta.nocodb_id)
        found = rec is not None
        match = found and rec.row_id == meta.row_id
        noco = rec if match else None
        email = bool(noco and noco.valid_professional_email)
    elif meta.kind is Kind.NEW:
        row = adapters.sheets.get_contact_by_row_id(meta.sheet_row_id)
        found, match, noco = row is not None, "n/a", None
        email = bool(row and row.valid_professional_email)
    else:
        found, match, noco, email = True, "n/a", None, "n/a"
    lines += [
        f"contact_found={str(found).lower()}",
        f"row_id_match={str(match).lower() if isinstance(match, bool) else match}",
        f"email_present={str(email).lower() if isinstance(email, bool) else email}",
    ]
    if meta.kind is Kind.FOLLOWUP:
        lines.append(f"prior={prior_followups(meta, adapters, noco)}")
    return lines, 0 if found and match is not False else 1
