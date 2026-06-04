"""Behavioral tests for scripts/close-resolved-conversations.py.

This script runs UNATTENDED daily (`--apply` via close-resolved-conversations
.timer) and SILENTLY closes customer conversations. The whole reason it is safe
to run with no human in the loop is the `is_eligible` predicate — so a
regression there silently buries live customer conversations with no alarm.
These tests lock the invariants that make the close safe:

  - we must have spoken last (never close a chat where the customer is waiting,
    `customer_last`, or that never got an answer, `never_replied`);
  - the close must be tied to a *resolved ticket for THIS conversation* — by
    default only via the precise #417 "Intercom Link", so an unrelated/new
    conversation for a customer who merely had older resolved tickets is left
    alone; the loose email match is reachable only behind `--backfill`;
  - an open ticket linked to the conversation blocks the close even under
    backfill, and email matching with any open ticket is skipped.

Stdlib unittest + stubs only — no pytest dependency, no network — so it runs
under the same bare `python3 -m unittest` the py-tests CI job already uses.
"""
import importlib.util
import pathlib
import unittest
from unittest import mock

# Hyphenated filename can't be imported by name; load it from its path as `cr`.
_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "close-resolved-conversations.py"
)
_spec = importlib.util.spec_from_file_location("close_resolved_conversations", _SCRIPT)
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)


def make_conv(cid="c1", lar=200, lcr=100, email="alice@example.com"):
    """Conversation shaped like fetch_open_convs output. Defaults = admin-last."""
    return {"id": cid, "email": email, "lar": lar, "lcr": lcr}


def link(conv_id, ws="abc123"):
    """An #417 "Intercom Link" field value pointing at conv_id."""
    return f"https://app.intercom.com/a/inbox/{ws}/inbox/conversation/{conv_id}"


class TestIsEligible(unittest.TestCase):
    """The safety predicate. Each case encodes a conversation we must / must not close."""

    # ---- we-spoke-last guard (independent of how the ticket tie is made) ----

    def test_customer_last_is_skipped(self):
        # Customer replied after us -> they are waiting on a human. Never close,
        # even though the linked ticket is resolved.
        conv = make_conv(cid="c1", lar=100, lcr=200)
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": {True}}, backfill=False))

    def test_never_replied_is_skipped(self):
        # No admin reply ever (lar==0) -> possibly a dropped customer. Never close.
        conv = make_conv(cid="c1", lar=0, lcr=50)
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": {True}}, backfill=False))

    def test_equal_timestamps_are_skipped(self):
        # lcr == lar -> ordering is ambiguous (Intercom timestamps are
        # second-granular). An unattended silent close requires PROVEN
        # admin-last, so equality must NOT close.
        conv = make_conv(cid="c1", lar=150, lcr=150)
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": {True}}, backfill=False))

    def test_strict_admin_last_is_eligible(self):
        # lar strictly greater than lcr -> proven we spoke last.
        conv = make_conv(cid="c1", lar=151, lcr=150)
        self.assertTrue(cr.is_eligible(conv, {}, {"c1": {True}}, backfill=False))

    # ---- precise (#417 link) path: the default unattended behavior ----

    def test_all_resolved_linked_conversation_is_eligible(self):
        # Tied via #417 link to tickets that are ALL resolved, and we spoke last.
        conv = make_conv(cid="c1")
        self.assertTrue(cr.is_eligible(conv, {}, {"c1": {True}}, backfill=False))

    def test_linked_open_ticket_blocks_close(self):
        # Any open ticket linked to THIS conversation blocks the close...
        conv = make_conv(cid="c1")
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": {True, False}}, backfill=False))

    def test_linked_open_ticket_blocks_close_even_under_backfill(self):
        # ...and the precise signal stays authoritative even in backfill mode,
        # regardless of the customer's email-level ticket state.
        conv = make_conv(cid="c1", email="alice@example.com")
        email_states = {"alice@example.com": {True}}  # email says "all resolved"
        self.assertFalse(cr.is_eligible(conv, email_states, {"c1": {False}}, backfill=True))

    # ---- unrelated same-email conversations: the core of finding #1 ----

    def test_unrelated_same_email_not_eligible_by_default(self):
        # The customer has only resolved tickets (email_states all True) but THIS
        # conversation has no #417 link. In the unattended default it must NOT be
        # closed just because the same person had older resolved tickets.
        conv = make_conv(cid="c-new", email="alice@example.com")
        email_states = {"alice@example.com": {True}}
        self.assertFalse(cr.is_eligible(conv, email_states, {}, backfill=False))

    def test_unrelated_same_email_eligible_only_under_backfill(self):
        # The same conversation is reachable only via the explicit one-time
        # --backfill path (human-run pre-#417 drain).
        conv = make_conv(cid="c-new", email="alice@example.com")
        email_states = {"alice@example.com": {True}}
        self.assertTrue(cr.is_eligible(conv, email_states, {}, backfill=True))

    # ---- email fallback (backfill) guards ----

    def test_mixed_open_resolved_email_skipped_under_backfill(self):
        # Same email with at least one OPEN ticket -> skip even in backfill.
        conv = make_conv(cid="c-new", email="alice@example.com")
        email_states = {"alice@example.com": {True, False}}
        self.assertFalse(cr.is_eligible(conv, email_states, {}, backfill=True))

    def test_email_with_no_tickets_skipped_under_backfill(self):
        # No ticket for this email and no link -> nothing ties it to a resolution.
        conv = make_conv(cid="c-new", email="nobody@example.com")
        self.assertFalse(cr.is_eligible(conv, {"alice@example.com": {True}}, {}, backfill=True))

    def test_no_link_no_email_not_eligible(self):
        conv = make_conv(cid="c-new", email="")
        self.assertFalse(cr.is_eligible(conv, {}, {}, backfill=True))


class TestBuildTicketIndex(unittest.TestCase):
    """ClickUp scan -> (email_states, conv_states). Parsing + resolved-detection."""

    def _run(self, tasks):
        page = {"tasks": tasks, "last_page": True}
        with mock.patch.object(cr, "clickup_get", return_value=page):
            return cr.build_ticket_index("key", "list")

    @staticmethod
    def _task(status_type="open", status_name="open", email=None, link_val=None):
        cf = []
        if email is not None:
            cf.append({"id": cr.USER_EMAIL_FIELD, "value": email})
        if link_val is not None:
            cf.append({"id": cr.INTERCOM_LINK_FIELD, "value": link_val})
        return {"status": {"type": status_type, "status": status_name}, "custom_fields": cf}

    def test_resolved_detection_by_type_and_status(self):
        tasks = [
            self._task("closed", "complete", email="a@x.com", link_val=link("1")),
            self._task("open", "resolved", email="b@x.com", link_val=link("2")),  # status name
            self._task("open", "in progress", email="c@x.com", link_val=link("3")),
        ]
        email_states, conv_states = self._run(tasks)
        self.assertEqual(conv_states, {"1": {True}, "2": {True}, "3": {False}})
        self.assertEqual(email_states, {"a@x.com": {True}, "b@x.com": {True}, "c@x.com": {False}})

    def test_email_is_lowercased_and_link_conv_id_extracted(self):
        email_states, conv_states = self._run(
            [self._task("closed", "done", email="ALICE@Example.COM", link_val=link("999"))]
        )
        self.assertIn("alice@example.com", email_states)
        self.assertIn("999", conv_states)

    def test_same_email_accumulates_open_and_resolved(self):
        # An email with both an open and a resolved ticket -> {False, True},
        # which all() then rejects: this is what stops a backfill close.
        tasks = [
            self._task("closed", "done", email="a@x.com"),
            self._task("open", "open", email="a@x.com"),
        ]
        email_states, _ = self._run(tasks)
        self.assertEqual(email_states["a@x.com"], {True, False})

    def test_malformed_link_is_ignored(self):
        _, conv_states = self._run(
            [self._task("closed", "done", email="a@x.com", link_val="https://example.com/no-conv-here")]
        )
        self.assertEqual(conv_states, {})


if __name__ == "__main__":
    unittest.main()
