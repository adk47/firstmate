"""Tests for the per-draft pipeline in worker.process_draft.

We mock all adapter functions so no network call happens. The pipeline
must:
  - Parse metadata
  - Run all gates A–G
  - On any gate failure, NOT send, and return a Block result
  - On all gates pass, send → apply label → append logbook row → advance GHL
  - Treat logbook failure after successful send as red-alert (warn devops)
  - Treat GHL failure after successful send+log as warn (sales-alerts)
"""
from __future__ import annotations

from dataclasses import replace
from unittest.mock import MagicMock

import pytest

from scripts.lib.muso_outreach import worker
from scripts.lib.muso_outreach.types import Kind
from tests.conftest import (
    make_contact_row, make_draft, make_message, make_metadata, make_noco_contact,
    make_thread,
)


class Adapters:
    """Dependency bag so tests can inject mocks."""
    def __init__(self):
        self.gmail = MagicMock()
        self.sheets = MagicMock()
        self.nocodb = MagicMock()
        self.slack = MagicMock()
        self.ghl = MagicMock()


def _labels_for(meta, approved=True):
    kind_label = f"muso-meta/kind-{meta.kind.value}"
    sender_label = f"muso-meta/sender-{meta.sender.replace('@', '_at_')}"
    key_labels = (
        [f"muso-meta/nocodb_id-{meta.nocodb_id}", f"muso-meta/row_id-{meta.row_id}"]
        if meta.nocodb_id is not None else [f"muso-meta/row-{meta.sheet_row_id}"])
    labels = [
        "B2B - Ads", kind_label, *key_labels,
        f"muso-meta/template-{meta.template}",
        sender_label,
    ]
    if meta.opp_id:
        labels.append(f"muso-meta/opp-{meta.opp_id}")
    if meta.kind is Kind.FOLLOWUP:
        labels.append(f"muso-meta/thread-{meta.original_thread_id}")
    if approved and meta.kind is Kind.NEW:
        labels.append("B2B - Ads/initial-approved")  # human-applied in Gmail
    return tuple(labels)


def _happy_followup(adapters):
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    draft = make_draft(
        labels=_labels_for(meta),
        body_html='<!-- muso-outreach:v1 '
                  '{"kind":"followup","sheet_row_id":1234,"opp_id":"abc",'
                  '"template":"FU-01","sender":"a@muso.ai",'
                  '"original_thread_id":"t1"} -->',
    )
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    adapters.gmail.fetch_draft.return_value = draft
    adapters.gmail.fetch_thread.return_value = thread
    adapters.gmail.send_draft.return_value = "sent-msg-id"
    adapters.sheets.count_prior_followups.return_value = 0
    return draft, meta


def test_happy_path_sends_relabels_logs_ghl(monkeypatch):
    a = Adapters()
    draft, meta = _happy_followup(a)
    monkeypatch.setattr(worker, "NOW_EPOCH",
                        lambda: 1776096000)  # Monday
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert result.sent
    a.gmail.send_draft.assert_called_once_with("r1", "a@muso.ai")
    a.gmail.apply_label.assert_called_once_with(
        "sent-msg-id", "B2B - Ads", "a@muso.ai")
    a.sheets.append_logbook_row.assert_called_once()
    # GHL sync is deferred — advance_opportunity_stage must NOT be called.
    a.ghl.advance_opportunity_stage.assert_not_called()


def test_hallucinated_recipient_is_blocked_not_sent(monkeypatch):
    a = Adapters()
    draft, meta = _happy_followup(a)
    # Break the draft: wrong To:
    a.gmail.fetch_draft.return_value = replace(
        draft, to_addrs=("ow@lfrequencies.com",))
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert not result.sent
    assert result.reason_code == "RECIPIENT_MISMATCH"
    a.gmail.send_draft.assert_not_called()
    a.sheets.append_logbook_row.assert_not_called()
    # Block must be reported.
    a.slack.post_sales_alert.assert_called_once()


def test_logbook_failure_after_send_raises_devops_red_alert(monkeypatch):
    a = Adapters()
    _happy_followup(a)
    a.sheets.append_logbook_row.side_effect = RuntimeError("Sheets down")
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    # Send happened but log didn't.
    assert result.sent
    assert result.reason_code == "LOGBOOK_APPEND_FAILED"
    a.slack.post_devops_alert.assert_called_once()


def test_ghl_sync_is_deferred_not_called(monkeypatch):
    """Until we wire in the GHL stage-id lookup, the worker deliberately
    does not call advance_opportunity_stage. A follow-up runbook note
    is posted to #sales-alerts so humans advance the opp manually."""
    a = Adapters()
    _happy_followup(a)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert result.sent
    assert result.reason_code is None
    a.ghl.advance_opportunity_stage.assert_not_called()
    # The "manual GHL" info message is expected.
    a.slack.post_sales_alert.assert_called_once()


def test_apply_label_failure_does_not_retry_send(monkeypatch):
    """If apply_label raises, the send already happened. We must NOT
    retry the send (would double-send). The worker should log, red-alert
    on the label gap, and return sent=True."""
    a = Adapters()
    draft, _ = _happy_followup(a)
    a.gmail.apply_label.side_effect = RuntimeError("label API transient")
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert result.sent is True
    # send_draft called exactly once — no retry.
    a.gmail.send_draft.assert_called_once_with("r1", "a@muso.ai")
    # Logbook still appended (critical path continues).
    a.sheets.append_logbook_row.assert_called_once()


def test_process_one_with_retry_does_not_retry_once_sent(monkeypatch):
    """If the first process_draft raises AFTER send, the retry wrapper
    must NOT call process_draft again — that would re-send. The wrapper
    should only retry if the exception was raised BEFORE send_draft."""
    a = Adapters()
    # Happy fetch, then send succeeds, but apply_label blows up after
    # the try/except was supposed to neutralise it. If the fix from
    # test_apply_label_failure_does_not_retry_send is in place, this is
    # defensive: even if a future change re-introduces a raise post-send,
    # the retry wrapper must guard against double-send.
    draft, _ = _happy_followup(a)

    call_count = {"send": 0}
    def count_send(did, acct):
        call_count["send"] += 1
        return "m1"
    a.gmail.send_draft.side_effect = count_send

    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result, failed = worker._process_one_with_retry(
        "r1", "a@muso.ai", a)
    assert call_count["send"] == 1
    assert failed is False


def test_batch_reports_summary(monkeypatch):
    """Batch of 3: one passes, one blocks, one send-fails once then succeeds."""
    a = Adapters()
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    # Draft IDs in order
    drafts = ["r1", "r2", "r3"]
    # Build happy responses for r1 and r3, blocker for r2 (bad To:)
    def fake_fetch(draft_id, account):
        base, meta = _happy_followup(a)
        if draft_id == "r2":
            return replace(base, draft_id="r2", to_addrs=("ow@wrong.com",))
        return replace(base, draft_id=draft_id)
    a.gmail.fetch_draft.side_effect = fake_fetch
    a.gmail.fetch_thread.return_value = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    a.sheets.count_prior_followups.return_value = 0

    # send_draft: r1 ok, r3 ok, r2 never called
    a.gmail.send_draft.side_effect = ["m1", "m3"]

    report = worker.process_batch(drafts, account="a@muso.ai", adapters=a)
    assert report.sent_count == 2
    assert report.blocked_count == 1
    assert report.batch_halted is False
    a.slack.post_sales_alert.assert_any_call(
        ":white_check_mark: Batch done - sent: 2, blocked: 1, halted: no"
    )


def test_slack_failure_after_send_does_not_double_send(monkeypatch):
    """If post_sales_alert raises AFTER send_draft succeeds, the retry
    envelope must NOT call send_draft a second time."""
    a = Adapters()
    _happy_followup(a)
    a.slack.post_sales_alert.side_effect = RuntimeError("Slack 503")
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result, failed = worker._process_one_with_retry("r1", "a@muso.ai", a)
    # Exactly one send, even though the final info-note raised.
    assert a.gmail.send_draft.call_count == 1
    assert result.sent is True
    assert failed is False


def test_slack_failure_during_logbook_red_alert_does_not_double_send(monkeypatch):
    """Worst case: logbook append fails AND the devops red-alert post
    also fails. send_draft must still be called exactly once."""
    a = Adapters()
    _happy_followup(a)
    a.sheets.append_logbook_row.side_effect = RuntimeError("Sheets down")
    a.slack.post_devops_alert.side_effect = RuntimeError("Slack down too")
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result, failed = worker._process_one_with_retry("r1", "a@muso.ai", a)
    assert a.gmail.send_draft.call_count == 1
    # Logbook failed -- sent=True, reason captures both failures' existence.
    assert result.sent is True
    assert result.reason_code == "LOGBOOK_APPEND_FAILED"


def test_batch_halts_after_two_consecutive_send_failures(monkeypatch):
    """If two drafts in a row both fail retry, halt the batch."""
    a = Adapters()
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    monkeypatch.setattr(worker._time, "sleep", lambda s: None)
    drafts = ["r1", "r2", "r3"]
    def fake_fetch(draft_id, account):
        base, _ = _happy_followup(a)
        return replace(base, draft_id=draft_id)
    a.gmail.fetch_draft.side_effect = fake_fetch
    a.gmail.fetch_thread.return_value = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    a.sheets.count_prior_followups.return_value = 0

    # Every send_draft call fails (twice per draft; after 2 consecutive
    # failing drafts the worker halts, so only r1 and r2 are attempted).
    a.gmail.send_draft.side_effect = RuntimeError("Gmail 503")

    report = worker.process_batch(drafts, account="a@muso.ai", adapters=a)
    assert report.batch_halted is True
    assert report.sent_count == 0
    # r3 never attempted.
    fetched = {call.args[0] for call in a.gmail.fetch_draft.call_args_list}
    assert "r3" not in fetched


# --- NocoDB-keyed drafts ---------------------------------------------------

def _noco_meta(kind=Kind.NEW, **kw):
    return make_metadata(kind=kind, sheet_row_id=None, nocodb_id=2,
                         row_id="dangjf643", opp_id=None if kind is Kind.NEW else "abc",
                         template="PrivateInvite" if kind is Kind.NEW else "FU-01",
                         original_thread_id=None if kind is Kind.NEW else "t1", **kw)


def _noco_new(a, record=None, to=("ow@larsenstrings.com",), approved=True):
    meta = _noco_meta()
    a.gmail.fetch_draft.return_value = make_draft(
        labels=_labels_for(meta, approved=approved), to=to)
    a.gmail.search_inbound_from.return_value = ()
    a.gmail.send_draft.return_value = "sent-msg-id"
    a.nocodb.get_contact.return_value = record or make_noco_contact()
    return meta


def test_nocodb_new_draft_looks_up_nocodb_not_sheets(monkeypatch):
    a = Adapters()
    _noco_new(a)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert result.sent, result
    a.nocodb.get_contact.assert_called_once_with(2)
    a.sheets.get_contact_by_row_id.assert_not_called()
    row = a.sheets.append_logbook_row.call_args.args[0]
    assert row[-1] == "nocodb:2 row_id:dangjf643 template:PrivateInvite"


def test_no_opp_slack_line_says_create_manually(monkeypatch):
    a = Adapters()
    _noco_new(a)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    worker.process_draft("r1", "a@muso.ai", a)
    msgs = [c.args[0] for c in a.slack.post_sales_alert.call_args_list]
    assert any("no GHL opp yet" in m and "create it manually" in m for m in msgs)
    assert not any("None" in m for m in msgs)


def test_row_id_mismatch_blocks_at_gate_a(monkeypatch):
    a = Adapters()
    _noco_new(a, record=make_noco_contact(row_id="someoneelse"))
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert not result.sent
    assert result.reason_code == "RECIPIENT_SOURCE_MISSING"
    assert "NocoDB contact Id 2" in result.reason_human
    a.gmail.send_draft.assert_not_called()


def test_contact_not_found_blocks_at_gate_a(monkeypatch):
    a = Adapters()
    _noco_new(a)
    a.nocodb.get_contact.return_value = None
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert result.reason_code == "RECIPIENT_SOURCE_MISSING"
    a.gmail.send_draft.assert_not_called()


def test_nocodb_error_raises_before_any_send(monkeypatch):
    a = Adapters()
    _noco_new(a)
    a.nocodb.get_contact.side_effect = RuntimeError("nocodb down")
    with pytest.raises(RuntimeError):
        worker.process_draft("r1", "a@muso.ai", a)
    a.gmail.send_draft.assert_not_called()


def _noco_followup(a, status, logged):
    meta = _noco_meta(Kind.FOLLOWUP)
    a.gmail.fetch_draft.return_value = make_draft(labels=_labels_for(meta))
    a.gmail.fetch_thread.return_value = make_thread(messages=(
        make_message(from_addr="a@muso.ai", to_addrs=("ow@larsenstrings.com",),
                     date_epoch=100),))
    a.gmail.send_draft.return_value = "sent-msg-id"
    a.nocodb.get_contact.return_value = make_noco_contact(status=status)
    a.sheets.count_prior_followups_by_token.return_value = logged


def test_followup_cap_takes_max_of_logbook_and_status(monkeypatch):
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    a = Adapters()
    _noco_followup(a, status="Follow Up 3", logged=1)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert not result.sent
    assert result.reason_code == "FOLLOWUP_CAP_REACHED"
    a.sheets.count_prior_followups_by_token.assert_called_once_with("nocodb:2")
    # logbook alone also hits the cap; a lower status never loosens it
    b = Adapters()
    _noco_followup(b, status="Follow Up 1", logged=3)
    assert worker.process_draft("r1", "a@muso.ai", b).reason_code == "FOLLOWUP_CAP_REACHED"
    # under the cap on both -> sends
    c = Adapters()
    _noco_followup(c, status="Emailed", logged=1)
    assert worker.process_draft("r1", "a@muso.ai", c).sent


def test_legacy_draft_still_uses_sheets_path(monkeypatch):
    a = Adapters()
    _happy_followup(a)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    assert worker.process_draft("r1", "a@muso.ai", a).sent
    a.sheets.count_prior_followups.assert_called_once_with(1234)
    a.nocodb.get_contact.assert_not_called()
    assert a.sheets.append_logbook_row.call_args.args[0][-1] == "row:1234 template:FU-01"


def _logbook(monkeypatch, notes):
    from scripts.lib.muso_outreach import sheets_client
    header = ["Action", "Hook / Notes"]
    rows = [header] + [["Follow-Up Sent", n] for n in notes]
    monkeypatch.setattr(sheets_client, "_run_gog",
                        lambda *a: __import__("json").dumps({"values": rows}))
    return sheets_client


def test_logbook_token_match_is_whole_token(monkeypatch):
    sc = _logbook(monkeypatch, ["nocodb:12 row_id:x template:T",
                                "nocodb:1 row_id:y template:T",
                                "foo nocodb:1", "xnocodb:1"])
    assert sc.count_prior_followups_by_token("nocodb:1") == 2
    assert sc.count_prior_followups_by_token("nocodb:12") == 1


def test_legacy_logbook_needle_is_whole_token(monkeypatch):
    sc = _logbook(monkeypatch, ["row:12 template:T", "row:1 template:T"])
    assert sc.count_prior_followups(1) == 1


def _noco_followup_record(a, record):
    meta = _noco_meta(kind=Kind.FOLLOWUP)
    a.gmail.fetch_draft.return_value = make_draft(labels=_labels_for(meta))
    a.gmail.fetch_thread.return_value = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    a.gmail.send_draft.return_value = "sent-msg-id"
    a.sheets.count_prior_followups_by_token.return_value = 0
    a.nocodb.get_contact.return_value = record
    return meta


@pytest.mark.parametrize("record", [
    None,
    make_noco_contact(row_id="other", status="Follow Up 3"),
], ids=["not-found", "row-id-mismatch"])
def test_nocodb_followup_with_unusable_record_is_blocked(monkeypatch, record):
    """The Status cap is read from NocoDB: a follow-up whose record is gone or
    belongs to another contact must not send with that cap silently dropped
    (dry-run reports contact_found=false for the same labels)."""
    a = Adapters()
    _noco_followup_record(a, record)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert not result.sent
    assert result.reason_code == "RECIPIENT_SOURCE_MISSING"
    a.gmail.send_draft.assert_not_called()


def test_nocodb_followup_with_matching_record_still_sends(monkeypatch):
    a = Adapters()
    _noco_followup_record(a, make_noco_contact(status="Follow Up 1"))
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    assert worker.process_draft("r1", "a@muso.ai", a).sent


# --- initial-approved gate (NEW drafts need a human-applied label) ---------

def _assert_nothing_read_or_sent(a):
    a.gmail.send_draft.assert_not_called()
    a.nocodb.get_contact.assert_not_called()
    a.sheets.get_contact_by_row_id.assert_not_called()
    a.gmail.fetch_thread.assert_not_called()
    a.sheets.append_logbook_row.assert_not_called()


def test_nocodb_new_without_initial_approved_is_blocked_before_any_read(monkeypatch):
    a = Adapters()
    _noco_new(a, approved=False)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert not result.sent
    assert result.reason_code == "INITIAL_NOT_APPROVED"
    _assert_nothing_read_or_sent(a)
    msg = a.slack.post_sales_alert.call_args.args[0]  # last alert = the block
    assert msg.startswith(":no_entry:") and "INITIAL_NOT_APPROVED" in msg


def test_legacy_sheet_new_without_initial_approved_is_blocked_before_any_read(monkeypatch):
    a = Adapters()
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None, template="PrivateInvite")
    a.gmail.fetch_draft.return_value = make_draft(
        labels=_labels_for(meta, approved=False))
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert not result.sent
    assert result.reason_code == "INITIAL_NOT_APPROVED"
    _assert_nothing_read_or_sent(a)


def test_override_approved_does_not_stand_in_for_initial_approved(monkeypatch):
    a = Adapters()
    meta = _noco_meta()
    a.gmail.fetch_draft.return_value = make_draft(
        labels=(*_labels_for(meta, approved=False), "B2B - Ads/override-approved"))
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert result.reason_code == "INITIAL_NOT_APPROVED"
    _assert_nothing_read_or_sent(a)


def test_nocodb_new_with_initial_approved_runs_gates_and_sends(monkeypatch):
    a = Adapters()
    _noco_new(a, approved=True)
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    assert worker.process_draft("r1", "a@muso.ai", a).sent
    a.nocodb.get_contact.assert_called_once_with(2)
    a.gmail.send_draft.assert_called_once()


def test_initial_approved_does_not_skip_the_other_gates(monkeypatch):
    a = Adapters()
    _noco_new(a, approved=True, to=("ow@lfrequencies.com",))
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft("r1", "a@muso.ai", a)
    assert result.reason_code == "RECIPIENT_MISMATCH"
    a.gmail.send_draft.assert_not_called()
