"""Behavioral tests for scripts/close-resolved-conversations.py.

This script runs UNATTENDED daily (`--apply` via close-resolved-conversations
.timer) and SILENTLY closes customer conversations. The whole reason it is safe
to run with no human in the loop is the `is_eligible` predicate — so a
regression there silently buries live customer conversations with no alarm.
These tests lock the invariants that make the close safe:

  - we must have spoken last (never close a chat where the customer is waiting,
    `customer_last`, or that never got an answer, `never_replied`);
  - the close must be tied to a *customer-complete ticket for THIS conversation* — by
    default only via the precise #417 "Intercom Link", so an unrelated/new
    conversation for a customer who merely had older complete tickets is left
    alone; the loose email match is reachable only behind `--backfill`;
  - an open ticket linked to the conversation blocks the close even under
    backfill, and email matching with any open ticket is skipped.

Stdlib unittest + stubs only — no pytest dependency, no network — so it runs
under the same bare `python3 -m unittest` the py-tests CI job already uses.
"""
import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
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


def cs(*resolved, tickets=None, intercom_url=None):
    """A conv_states value. is_eligible reads only ["complete"]; tickets and
    intercom_url exist for the summary builder."""
    return {"complete": set(resolved), "tickets": tickets or {}, "intercom_url": intercom_url}


class TestIsEligible(unittest.TestCase):
    """The safety predicate. Each case encodes a conversation we must / must not close."""

    # ---- we-spoke-last guard (independent of how the ticket tie is made) ----

    def test_customer_last_is_skipped(self):
        # Customer replied after us -> they are waiting on a human. Never close,
        # even though the linked ticket is resolved.
        conv = make_conv(cid="c1", lar=100, lcr=200)
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": cs(True)}, backfill=False))

    def test_never_replied_is_skipped(self):
        # No admin reply ever (lar==0) -> possibly a dropped customer. Never close.
        conv = make_conv(cid="c1", lar=0, lcr=50)
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": cs(True)}, backfill=False))

    def test_equal_timestamps_are_skipped(self):
        # lcr == lar -> ordering is ambiguous (Intercom timestamps are
        # second-granular). An unattended silent close requires PROVEN
        # admin-last, so equality must NOT close.
        conv = make_conv(cid="c1", lar=150, lcr=150)
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": cs(True)}, backfill=False))

    def test_strict_admin_last_is_eligible(self):
        # lar strictly greater than lcr -> proven we spoke last.
        conv = make_conv(cid="c1", lar=151, lcr=150)
        self.assertTrue(cr.is_eligible(conv, {}, {"c1": cs(True)}, backfill=False))

    # ---- precise (#417 link) path: the default unattended behavior ----

    def test_all_resolved_linked_conversation_is_eligible(self):
        # Tied via #417 link to tickets that are ALL resolved, and we spoke last.
        conv = make_conv(cid="c1")
        self.assertTrue(cr.is_eligible(conv, {}, {"c1": cs(True)}, backfill=False))

    def test_linked_open_ticket_blocks_close(self):
        # Any open ticket linked to THIS conversation blocks the close...
        conv = make_conv(cid="c1")
        self.assertFalse(cr.is_eligible(conv, {}, {"c1": cs(True, False)}, backfill=False))

    def test_linked_open_ticket_blocks_close_even_under_backfill(self):
        # ...and the precise signal stays authoritative even in backfill mode,
        # regardless of the customer's email-level ticket state.
        conv = make_conv(cid="c1", email="alice@example.com")
        email_states = {"alice@example.com": {True}}  # email says "all resolved"
        self.assertFalse(cr.is_eligible(conv, email_states, {"c1": cs(False)}, backfill=True))

    def test_held_resolve_notify_ticket_blocks_close(self):
        conv = make_conv(cid="c1")
        states = {"c1": cs(True, tickets={"T1": {"name": "held", "url": "u"}})}
        self.assertFalse(cr.is_eligible(
            conv, {}, states, backfill=False, held_ticket_ids={"T1"}))

    # ---- notify→close race guard: never close out from under a pending note ----
    # main() derives defer_convs = {conv : resolve-notify owes an unsent note},
    # so is_eligible only takes the finished set. These cases pin the gate.

    def test_deferred_conversation_never_closes_precise_path(self):
        # THE RACE (why this exists): a resolved hydra-action-request ticket that
        # resolve-notify has NOT processed yet resolved after the notifier's scan;
        # main put its conversation in defer_convs. Every linked ticket is
        # resolved and none is held, so without the guard this would close — and
        # the notifier's next run would suppress the customer's note because the
        # conversation is already closed. Must defer.
        conv = make_conv(cid="c1")
        states = {"c1": cs(True, tickets={"T1": {"name": "n", "url": "u"}})}
        self.assertFalse(cr.is_eligible(
            conv, {}, states, backfill=False, held_ticket_ids=set(), defer_convs={"c1"}))

    def test_not_deferred_conversation_closes(self):
        # Once resolve-notify has processed the ticket, main drops the
        # conversation from defer_convs and the close proceeds.
        conv = make_conv(cid="c1")
        states = {"c1": cs(True, tickets={"T1": {"name": "n", "url": "u"}})}
        self.assertTrue(cr.is_eligible(
            conv, {}, states, backfill=False, held_ticket_ids=set(), defer_convs=set()))

    def test_defer_also_blocks_backfill_email_path(self):
        # The guard is BEFORE the match split, so it also blocks a --backfill
        # email close of a conversation resolve-notify still owes a note for
        # (the ticket may be linked only via the notifier's description deeplink,
        # invisible to the closer's #417 index — so email backfill could close it
        # out from under the note without this).
        conv = make_conv(cid="c-legacy", email="alice@example.com")
        email_states = {"alice@example.com": {True}}
        self.assertFalse(cr.is_eligible(
            conv, email_states, {}, backfill=True, held_ticket_ids=set(),
            defer_convs={"c-legacy"}))

    def test_any_held_ticket_pauses_loose_email_backfill(self):
        conv = make_conv(cid="c-legacy", email="alice@example.com")
        self.assertFalse(cr.is_eligible(
            conv, {"alice@example.com": {True}}, {}, backfill=True,
            held_ticket_ids={"T-held"}))

    # ---- unrelated same-email conversations: the core of finding #1 ----

    def test_unrelated_same_email_not_eligible_by_default(self):
        # The customer has only complete tickets (email_states all True) but THIS
        # conversation has no #417 link. In the unattended default it must NOT be
        # closed just because the same person had older complete tickets.
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
    """ClickUp scan -> (email_states, conv_states, notify_owed). Parsing +
    resolved-detection + the notifier-owed defer index."""

    def _run(self, tasks):
        page = {"tasks": tasks, "last_page": True}
        with mock.patch.object(cr, "clickup_get", return_value=page):
            return cr.build_ticket_index("key", "list")

    @staticmethod
    def _task(status_type="open", status_name="open", email=None, link_val=None,
              tid=None, name=None, tags=None, description=None, outcome="complete"):
        cf = []
        if email is not None:
            cf.append({"id": cr.USER_EMAIL_FIELD, "value": email})
        if link_val is not None:
            cf.append({"id": cr.INTERCOM_LINK_FIELD, "value": link_val})
        t = {"status": {"type": status_type, "status": status_name}, "custom_fields": cf}
        if tid is not None:
            t["id"] = tid
        if name is not None:
            t["name"] = name
        tag_names = list(tags or [])
        if outcome is not None:
            tag_names.append(f"customer-outcome:{outcome}")
        if tag_names:
            t["tags"] = [{"name": n} for n in tag_names]
        if description is not None:
            t["description"] = description
        return t

    def test_resolved_detection_by_type_and_status(self):
        tasks = [
            self._task("closed", "complete", email="a@x.com", link_val=link("1")),
            self._task("open", "resolved", email="b@x.com", link_val=link("2")),  # status name
            self._task("open", "in progress", email="c@x.com", link_val=link("3")),
        ]
        email_states, conv_states, _ = self._run(tasks)
        resolved = {k: v["complete"] for k, v in conv_states.items()}
        self.assertEqual(resolved, {"1": {True}, "2": {True}, "3": {False}})
        self.assertEqual(email_states, {"a@x.com": {True}, "b@x.com": {True}, "c@x.com": {False}})

    def test_resolved_without_customer_complete_outcome_fails_closed(self):
        task = self._task(
            "closed", "resolved", email="a@x.com", link_val=link("1"), outcome=None)
        email_states, conv_states, _ = self._run([task])
        self.assertEqual(conv_states["1"]["complete"], {False})
        self.assertEqual(email_states["a@x.com"], {False})

    def test_ticket_id_name_and_intercom_url_captured(self):
        # The summary links come from here: each conv keeps its linked ClickUp
        # ticket(s) (id -> name + clickup url) and the raw Intercom deeplink.
        _, conv_states, _ = self._run(
            [self._task("closed", "done", email="a@x.com", link_val=link("42"),
                        tid="cu999", name="Refund for Alice")]
        )
        meta = conv_states["42"]
        self.assertEqual(meta["intercom_url"], link("42"))
        self.assertEqual(meta["tickets"], {
            "cu999": {"name": "Refund for Alice", "url": "https://app.clickup.com/t/cu999"}})

    def test_email_is_lowercased_and_link_conv_id_extracted(self):
        email_states, conv_states, _ = self._run(
            [self._task("closed", "done", email="ALICE@Example.COM", link_val=link("999"))]
        )
        self.assertIn("alice@example.com", email_states)
        self.assertIn("999", conv_states)

    def test_same_email_accumulates_open_and_resolved(self):
        # An email with both an open and a complete ticket -> {False, True},
        # which all() then rejects: this is what stops a backfill close.
        tasks = [
            self._task("closed", "done", email="a@x.com"),
            self._task("open", "open", email="a@x.com"),
        ]
        email_states, _, _ = self._run(tasks)
        self.assertEqual(email_states["a@x.com"], {True, False})

    def test_malformed_link_is_ignored(self):
        _, conv_states, _ = self._run(
            [self._task("closed", "done", email="a@x.com", link_val="https://example.com/no-conv-here")]
        )
        self.assertEqual(conv_states, {})

    def test_notify_owed_for_open_or_resolved_action_request_tickets(self):
        # notify_owed[conv] = every hydra-action-request ticket resolve-notify may
        # still owe a note for — OPEN or resolved (an open one is never "seen", so
        # it holds the conversation until it resolves AND the note goes out). Only
        # NON-action-request tickets are excluded.
        tasks = [
            self._task("closed", "done", link_val=link("1"), tid="A",
                       tags=["hydra-action-request", "billing"]),     # resolved + owned -> owed
            self._task("open", "in progress", link_val=link("2"), tid="B",
                       tags=["hydra-action-request"]),                # OPEN + owned -> owed too
            self._task("closed", "done", link_val=link("3"), tid="C",
                       tags=["random-tag"]),                          # resolved but NOT owned -> no
        ]
        _, _, notify_owed = self._run(tasks)
        self.assertEqual(notify_owed, {"1": {"A"}, "2": {"B"}})

    def test_notify_owed_uses_description_deeplink_when_no_417_field(self):
        # THE ORACLE FIX: resolve-notify links a ticket to its conversation via
        # the description deeplink when the #417 field is absent. The closer's
        # own conv_states index is #417-only, so notify_owed must recover the
        # description-linked conversation too — otherwise a sibling #417 ticket
        # could close conv D out from under this pending note.
        tasks = [
            self._task("closed", "done", tid="A", tags=["hydra-action-request"],
                       description="ticket body\n**Conversation:** "
                                   "https://app.intercom.com/a/inbox/w/inbox/conversation/D\nmore"),
        ]
        _, conv_states, notify_owed = self._run(tasks)
        self.assertEqual(notify_owed, {"D": {"A"}})   # recovered from the description
        self.assertEqual(conv_states, {})             # NOT in the #417-only close index

    def test_notify_owed_prefers_417_field_over_description(self):
        # conv_id_of parity: the structured #417 field wins over the description.
        tasks = [
            self._task("closed", "done", link_val=link("F1"), tid="A",
                       tags=["hydra-action-request"],
                       description="**Conversation:** "
                                   "https://app.intercom.com/a/inbox/w/inbox/conversation/D1"),
        ]
        _, _, notify_owed = self._run(tasks)
        self.assertEqual(notify_owed, {"F1": {"A"}})

    def test_open_desc_linked_owned_ticket_defers_conv_with_resolved_417_sibling(self):
        # The oracle's longer-window loss: conversation S is closeable via a
        # resolved #417 sibling (X), but also has an OPEN hydra-action-request
        # ticket (Y) linked ONLY via the description deeplink. notify_owed must
        # still list Y against S, so main's defer_convs (owed - seen) holds S
        # open — else closing S now loses Y's note when Y later resolves.
        s_link = link("S")
        tasks = [
            self._task("closed", "done", link_val=s_link, tid="X",
                       tags=["random"]),                              # resolved #417 -> S closeable
            self._task("open", "in progress", tid="Y", tags=["hydra-action-request"],
                       description=f"**Conversation:** {s_link}"),    # OPEN, desc-only -> owed
        ]
        _, conv_states, notify_owed = self._run(tasks)
        self.assertIn("S", conv_states)                 # closeable via the #417 sibling
        self.assertEqual(notify_owed.get("S"), {"Y"})   # but Y is owed -> defer
        # main: owed({"Y"}) - seen(empty) is non-empty -> S is deferred.
        defer = {cid for cid, owed in notify_owed.items() if owed - set()}
        self.assertIn("S", defer)

    def test_notify_owed_deeplink_stops_at_quote_matches_notifier(self):
        # Parity with resolve-notify.py's _CONV_ID_RE: the conv id must stop at a
        # trailing quote, so a quoted deeplink yields the SAME id the notifier
        # targets. Otherwise the defer set keys on `Dq"` while the open
        # conversation is `Dq`, and the guard would silently miss.
        tasks = [
            self._task("closed", "done", tid="A", tags=["hydra-action-request"],
                       description='see "https://app.intercom.com/a/inbox/w/inbox/conversation/Dq"'),
        ]
        _, _, notify_owed = self._run(tasks)
        self.assertEqual(notify_owed, {"Dq": {"A"}})


class TestResolveNotifyBacklog(unittest.TestCase):
    def test_valid_state_returns_held_ticket_ids_and_tampering_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "notified.json"
            state = {
                cr.RESOLVE_STATE_VERSION_KEY: cr.RESOLVE_STATE_VERSION,
                cr.RESOLVE_BULK_BACKLOG_KEY: {
                    "first_seen_at": 1, "ticket_ids": ["T1", "T2"], "alerted": True},
            }
            state[cr.RESOLVE_STATE_CHECKSUM_KEY] = cr._resolve_state_checksum(state)
            path.write_text(json.dumps(state))
            self.assertEqual(cr.load_held_ticket_ids(path), {"T1", "T2"})
            state[cr.RESOLVE_BULK_BACKLOG_KEY]["ticket_ids"].append("T3")
            path.write_text(json.dumps(state))
            self.assertIsNone(cr.load_held_ticket_ids(path))

    def test_load_seen_ticket_ids_returns_processed_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "notified.json"
            # resolve-notify records each processed ticket as a bare `<id>` key
            # and each notified conversation as `conv:<id>`; metadata is `__…__`.
            state = {
                cr.RESOLVE_STATE_VERSION_KEY: cr.RESOLVE_STATE_VERSION,
                "__seeded_at__": 111,
                "T1": 111, "T2": 222,          # processed tickets -> seen
                "conv:c1": 111,                # a notified conversation -> NOT a ticket
            }
            state[cr.RESOLVE_STATE_CHECKSUM_KEY] = cr._resolve_state_checksum(state)
            path.write_text(json.dumps(state))
            self.assertEqual(cr.load_seen_ticket_ids(path), {"T1", "T2"})
            # Tampering (checksum mismatch) fails closed -> None -> caller refuses.
            state["T3"] = 333
            path.write_text(json.dumps(state))
            self.assertIsNone(cr.load_seen_ticket_ids(path))

    def test_absent_state_file_is_clean_first_run(self):
        # No notifier state yet: held + seen are both empty (not None), so the
        # closer runs but defers every notifier-owned ticket until the notifier
        # has run at least once (empty seen-set) — the safe direction.
        missing = pathlib.Path("/nonexistent/resolve-notify/notified.json")
        self.assertEqual(cr.load_held_ticket_ids(missing), set())
        self.assertEqual(cr.load_seen_ticket_ids(missing), set())


class TestFormatSlackSummary(unittest.TestCase):
    """The #cs_chats message: clickable links, count, cap, graceful degrade."""

    def _states(self):
        return {
            "300545": cs(True, tickets={"cu1": {"name": "Refund", "url": "https://app.clickup.com/t/cu1"}},
                         intercom_url=link("300545")),
        }

    def test_links_are_slack_mrkdwn_for_clickup_and_intercom(self):
        out = cr.format_slack_summary([make_conv(cid="300545", email="a@x.com")], self._states(), "now")
        # Slack blue-text hyperlink form <url|text>, NOT markdown [text](url).
        self.assertIn(f"<{link('300545')}|conversation 300545>", out)
        self.assertIn("<https://app.clickup.com/t/cu1|Refund>", out)
        self.assertNotIn("](", out)  # no markdown links
        self.assertIn("Closed 1 resolved-ticket conversation*", out)  # singular, no trailing 's'
        self.assertIn("a@x.com", out)

    def test_plural_and_count(self):
        states = {"1": cs(True, intercom_url=link("1")), "2": cs(True, intercom_url=link("2"))}
        out = cr.format_slack_summary(
            [make_conv(cid="1"), make_conv(cid="2")], states, "now")
        self.assertIn("Closed 2 resolved-ticket conversations*", out)

    def test_cap_and_more(self):
        states = {str(i): cs(True, intercom_url=link(str(i))) for i in range(30)}
        closed = [make_conv(cid=str(i)) for i in range(30)]
        out = cr.format_slack_summary(closed, states, "now", max_lines=25)
        self.assertIn("…and 5 more", out)
        self.assertEqual(out.count("• "), 25)  # only max_lines bullets

    def test_no_link_close_degrades_gracefully(self):
        # An email-backfill close has no #417 link / not in conv_states -> plain
        # conv-id text, never a broken <|> link.
        out = cr.format_slack_summary([make_conv(cid="zzz", email="b@x.com")], {}, "now")
        self.assertIn("conversation zzz", out)
        self.assertNotIn("<", out.split("\n", 1)[1])  # no hyperlink on the bullet line
        self.assertIn("_no linked ticket_", out)

    def test_ticket_name_and_email_are_slack_escaped(self):
        # ClickUp titles are arbitrary text; raw <, >, & would break the
        # <url|text> link. They must be escaped per Slack's mrkdwn rules.
        states = {"1": cs(True, intercom_url=link("1"),
                          tickets={"cu1": {"name": "Refund <urgent> & A|B",
                                           "url": "https://app.clickup.com/t/cu1"}})}
        out = cr.format_slack_summary([make_conv(cid="1", email="a&b@x.com")], states, "now")
        self.assertIn("Refund &lt;urgent&gt; &amp; A|B", out)  # label escaped (| is safe in labels)
        self.assertNotIn("<urgent>", out)  # raw angle brackets gone
        self.assertIn("a&amp;b@x.com", out)  # email escaped too
        # the real link delimiters are still intact
        self.assertIn("<https://app.clickup.com/t/cu1|", out)

    def test_shadow_path_footer(self):
        out = cr.format_slack_summary([make_conv(cid="1")], {"1": cs(True, intercom_url=link("1"))},
                                      "now", shadow_path="/var/log/x.jsonl")
        self.assertIn("/var/log/x.jsonl", out)


class TestPostSlackSummaryBestEffort(unittest.TestCase):
    """post_slack_summary must NEVER raise — the closes already happened, so a
    Slack/network failure must stay non-fatal (return False, not propagate)."""

    def test_network_and_read_failures_are_non_fatal(self):
        import io
        from contextlib import redirect_stderr
        # Exactly the exceptions the narrow (URLError, ValueError) catch missed:
        # read timeout, connection reset (OSError), plus a generic Exception.
        for exc in (TimeoutError("read timed out"), OSError("connection reset"),
                    ValueError("bad json"), RuntimeError("anything else")):
            with mock.patch.object(cr, "_read_slack_token", return_value="xoxb-test"), \
                 mock.patch.object(cr.urllib.request, "urlopen", side_effect=exc), \
                 redirect_stderr(io.StringIO()):
                self.assertFalse(  # returns False, does not raise
                    cr.post_slack_summary("msg", "C0ANM0PN9L5", "/cfg", "operations"))

    def test_missing_token_is_non_fatal(self):
        import io
        from contextlib import redirect_stderr
        with mock.patch.object(cr, "_read_slack_token", return_value=None), \
             redirect_stderr(io.StringIO()):
            self.assertFalse(cr.post_slack_summary("msg", "C0ANM0PN9L5", "/cfg", "operations"))


class TestShouldNotify(unittest.TestCase):
    """Gate: post the summary ONLY on a real run that actually closed >=1."""

    def test_posts_only_when_apply_and_enabled_and_closed(self):
        self.assertTrue(cr.should_notify(apply=True, notify_enabled=True, ok=1))

    def test_no_post_on_dry_run(self):
        self.assertFalse(cr.should_notify(apply=False, notify_enabled=True, ok=5))

    def test_no_post_when_notify_disabled(self):
        self.assertFalse(cr.should_notify(apply=True, notify_enabled=False, ok=5))

    def test_no_post_when_nothing_closed(self):
        self.assertFalse(cr.should_notify(apply=True, notify_enabled=True, ok=0))




# --------------------------------------------------------------------------
# Phase 2a shadow wiring (docs/plans/jev-adoption.md #2a). The close-resolved
# Jev call fires strictly AFTER is_eligible() above, on a RANDOM sample of the
# FULL open-conversation scan (never just the eligible slice), and must never
# change `eligible`, closes, stdout, or the exit code -- regardless of whether
# jev.sh succeeds, fails, hangs, or is disabled.
# --------------------------------------------------------------------------
_FAKE_JEV = str(
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts" / "tests" / "fixtures" / "jev" / "fake-jev-sh.sh"
)
_REAL_JEV = str(
    pathlib.Path(__file__).resolve().parent.parent / "scripts" / "lib" / "jev.sh"
)


class JevShadowWiring(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.shadow_log = os.path.join(self.d, "close-shadow.jsonl")
        self.jev_shadow_dir = os.path.join(self.d, "jev-shadow")
        os.makedirs(self.jev_shadow_dir, exist_ok=True)
        os.environ.update({
            "MUSOAI_INTERCOM_TOKEN": "fake",
            "CLICKUP_API_KEY": "fake",
            # Points at a file that does not exist -> a clean first run for
            # resolve-notify's state (load_held/seen_ticket_ids both return
            # set()), never the real /var/lib default.
            "RESOLVE_NOTIFY_STATE": os.path.join(self.d, "notified.json"),
            "CLOSE_SHADOW_LOG": self.shadow_log,
            "JEV_SHADOW_DIR": self.jev_shadow_dir,
        })
        self.calls = {"close": []}
        self._orig = {k: getattr(cr, k) for k in
                      ("build_ticket_index", "fetch_open_convs", "close_conversation",
                       "get_conversation_for_shadow", "post_slack_summary", "shadow_judge")}
        # One conversation the script's own logic makes ELIGIBLE (linked ticket
        # customer-complete, we-spoke-last) and one it does NOT.
        eligible_conv = make_conv(cid="E1", lar=200, lcr=100, email="a@b.com")
        not_eligible_conv = make_conv(cid="N1", lar=100, lcr=200, email="c@d.com")
        cr.build_ticket_index = lambda key, list_id: (
            {}, {"E1": cs("2026-06-01")}, {})
        cr.fetch_open_convs = lambda token: [eligible_conv, not_eligible_conv]
        cr.close_conversation = lambda tok, aid, cid: self.calls["close"].append(cid) or {"state": "closed"}
        cr.get_conversation_for_shadow = lambda conv_id, token: {
            "conversation_parts": {"conversation_parts": [
                {"author": {"type": "admin", "id": "1"}, "body": "<p>all set?</p>"},
                {"author": {"type": "user"}, "body": "<p>yes, thanks!</p>"},
            ]}}
        cr.post_slack_summary = lambda *a, **k: True

    def tearDown(self):
        for k, v in self._orig.items():
            setattr(cr, k, v)
        for k in ("MUSOAI_INTERCOM_TOKEN", "CLICKUP_API_KEY", "RESOLVE_NOTIFY_STATE",
                  "CLOSE_SHADOW_LOG", "JEV_SHADOW_DIR", "CLOSE_RESOLVED_JEV_SAMPLE_SIZE",
                  "JEV_SH", "JEV_SHADOW_FAKE_MODE", "JEV_DISABLED_FILE"):
            os.environ.pop(k, None)
        shutil.rmtree(self.d, ignore_errors=True)

    def _run_scenario(self, jev_sh, disabled_file=None, argv=("--apply",)):
        os.environ["JEV_SH"] = jev_sh
        if disabled_file:
            os.environ["JEV_DISABLED_FILE"] = disabled_file
        else:
            os.environ.pop("JEV_DISABLED_FILE", None)
        with mock.patch.object(sys, "argv", ["close-resolved-conversations.py", *argv]):
            rc = cr.main()
        return {"rc": rc, "close": list(self.calls["close"])}

    def test_shadow_call_never_changes_outcome_across_ok_rc2_hang_killswitch(self):
        os.environ["JEV_SHADOW_FAKE_MODE"] = "ok"
        baseline = self._run_scenario(_FAKE_JEV)
        self.assertEqual(baseline["close"], ["E1"])  # sanity: only the eligible conv closed

        for mode in ("rc2", "hang"):
            self.calls["close"].clear()
            os.environ["JEV_SHADOW_FAKE_MODE"] = mode
            result = self._run_scenario(_FAKE_JEV)
            self.assertEqual(result, baseline, f"mode={mode} changed observable behaviour")

        # Kill switch: real jev.sh, JEV_DISABLED_FILE present -> jev.sh exits 6.
        self.calls["close"].clear()
        ks_file = os.path.join(self.d, "jev.disabled")
        with open(ks_file, "w"):
            pass
        result = self._run_scenario(_REAL_JEV, disabled_file=ks_file)
        self.assertEqual(result, baseline, "kill switch changed observable behaviour")

    def test_shadow_actual_matches_the_real_eligible_not_eligible_split(self):
        captured = []
        cr.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
            captured.append((surface, item_id, actual)) or None)
        result = self._run_scenario(_FAKE_JEV, argv=("--apply",))
        self.assertEqual(result["rc"], 0)
        self.assertEqual(
            sorted(captured),
            sorted([(cr.JEV_SURFACE_CLOSE_RESOLVED, "E1", "eligible"),
                    (cr.JEV_SURFACE_CLOSE_RESOLVED, "N1", "not-eligible")]))

    def test_dry_run_also_reaches_the_sample_unharmed(self):
        # The sample is drawn from the full scan BEFORE the --apply/dry-run
        # branch, so a dry-run must sample (and never close) exactly like an
        # --apply run never changes the sample.
        captured = []
        cr.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
            captured.append(item_id) or None)
        result = self._run_scenario(_FAKE_JEV, argv=())
        self.assertEqual(result["rc"], 0)
        self.assertEqual(result["close"], [])
        self.assertEqual(sorted(captured), ["E1", "N1"])

    def test_sample_never_exceeds_the_configured_knob_even_over_a_large_pool(self):
        os.environ["CLOSE_RESOLVED_JEV_SAMPLE_SIZE"] = "3"
        convs = [make_conv(cid=f"C{i}", lar=100, lcr=50, email=f"u{i}@x.com") for i in range(40)]
        cr.fetch_open_convs = lambda token: convs
        captured = []
        cr.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
            captured.append(item_id) or None)
        result = self._run_scenario(_FAKE_JEV, argv=("--apply",))
        self.assertEqual(result["rc"], 0)
        self.assertEqual(len(captured), 3)
        self.assertEqual(len(set(captured)), 3)  # no duplicate items in one sample

    def test_build_state_is_a_lazy_callable_and_a_raising_fetch_never_blocks_the_close(self):
        # Regression for the same bug class as the other Phase-2a call sites:
        # a raising get_conversation_for_shadow (this script's OWN eligibility
        # decision never depends on conversation body text -- only the shadow
        # state fetch does) must never abort the real close loop.
        captured = []

        def boom(conv_id, token):
            raise RuntimeError("network boom")
        cr.get_conversation_for_shadow = boom

        def spy_shadow_judge(surface, item_id, state, questions, actual=None):
            captured.append((surface, item_id, actual))
            self.assertTrue(callable(state), state)  # NOT a pre-built dict
            return None
        cr.shadow_judge = spy_shadow_judge
        result = self._run_scenario(_FAKE_JEV, argv=("--apply",))
        self.assertEqual(result["rc"], 0)
        self.assertEqual(result["close"], ["E1"])  # the real close still happens
        self.assertEqual(len(captured), 2)

    def test_a_nonfixed_seed_is_logged_to_stderr_with_the_sample_size(self):
        import io
        from contextlib import redirect_stderr
        buf = io.StringIO()
        with redirect_stderr(buf):
            result = self._run_scenario(_FAKE_JEV, argv=("--apply",))
        self.assertEqual(result["rc"], 0)
        self.assertRegex(buf.getvalue(),
                          r"jev shadow sample: seed=\d+ size=2 \(pool=2\)")

    def test_samples_across_runs_vary_never_pinned_to_the_scan_head(self):
        # convs is scanned in fetch_open_convs' own (arbitrary, API-page) order
        # -- a caller that (bug) sliced convs[:k] instead of drawing a random
        # sample would deterministically pick the SAME item (index 0) on every
        # run. Over enough runs a genuinely random draw from a 10-item pool
        # with k=1 must land on more than one distinct id.
        os.environ["CLOSE_RESOLVED_JEV_SAMPLE_SIZE"] = "1"
        pool = [make_conv(cid=f"P{i}", lar=100, lcr=50, email=f"p{i}@x.com") for i in range(10)]
        cr.fetch_open_convs = lambda token: pool
        seen = set()
        for _ in range(30):
            captured = []
            cr.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
                captured.append(item_id) or None)
            self._run_scenario(_FAKE_JEV, argv=())
            seen.update(captured)
        self.assertGreater(len(seen), 1, seen)  # a head-slice would always yield {"P0"}


if __name__ == "__main__":
    unittest.main()
