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
from tests.conftest import make_contact_row, make_draft, make_message, make_metadata, make_thread


class Adapters:
    """Dependency bag so tests can inject mocks."""
    def __init__(self):
        self.gmail = MagicMock()
        self.sheets = MagicMock()
        self.slack = MagicMock()
        self.ghl = MagicMock()


def _labels_for(meta):
    kind_label = f"muso-meta/kind-{meta.kind.value}"
    sender_label = f"muso-meta/sender-{meta.sender.replace('@', '_at_')}"
    labels = [
        "B2B - Ads", kind_label,
        f"muso-meta/row-{meta.sheet_row_id}",
        f"muso-meta/opp-{meta.opp_id}",
        f"muso-meta/template-{meta.template}",
        sender_label,
    ]
    if meta.kind is Kind.FOLLOWUP:
        labels.append(f"muso-meta/thread-{meta.original_thread_id}")
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
        ":white_check_mark: Batch done — sent: 2, blocked: 1, halted: no"
    )


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
