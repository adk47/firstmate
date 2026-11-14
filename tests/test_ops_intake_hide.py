"""scripts/ops_intake/hide.py — the operations intake for "hide this profile".

Locks (firstmate gdpr-tombstone-repair-21; incident 2026-11-04: 21 `DELETE /admin/profile/<id>` in 14 days):
  - the ask text is DATA: it names the pages and the reason, it never decides identity or a hide
  - a non-staff requester is tier R: nothing filed, nothing hidden
  - the requester id is VERIFIED against the author of the message the ask names, never asserted by the caller;
    an unreadable message refuses (exit 6) instead of passing
  - the two caps hold (10 ids per ask, 30 per requester per day) and are HELD, not truncated
  - the class comes from the requester's words: a verb alone is refused, a DSP removal is a catalog takedown and
    NEVER a profile hide, a threat is LEGAL_HIDE_FIRST (the captain's call)
  - one ask files one row per id, and an id that already has an open row ATTACHES to it instead of duplicating
  - the hide half only ever asks the pipeline's own planner, and never opens a legal-threat (captain-owned) page
  - the thread card carries the ask, the ids, the register rows, the two PR urls, hidden_at and the letter state

Hermetic: no network, no Trino, no Intercom, no git. The register is a temp sqlite file.
"""
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

SCRIPTS = os.path.join(os.path.dirname(__file__), "..", "scripts")
sys.path.insert(0, SCRIPTS)

from gdpr_pipeline import identity  # noqa: E402
from gdpr_pipeline.store import Store  # noqa: E402

HIDE_PATH = os.path.join(SCRIPTS, "ops_intake", "hide.py")
JAN = "U038BM16T7W"
AARON = "U7RP6HKUZ"
NICK = "U0AL36NADEY"
PROFILE = "0d898512-1111-2222-3333-444455556666"
OTHER = "11111111-2222-3333-4444-555555555555"


def decided(verdict, pid=PROFILE):
    """The detail `Run.decide_row` commits for a page. A pass carries the identity rules it was decided under - a pass
    without that stamp is one the hide batch may not use (`identity.stale_pass`) - and the account and page it rests
    on, which is what the hide guard re-reads the proof from."""
    d = {"id": pid, "verdict": verdict, "why": "test"}
    if verdict in identity.IDENTITY_PASS:
        d.update({"rules": identity.RULES_V, "account": 80419, "owner_page": pid})
    return json.dumps([d])


def load_hide():
    spec = importlib.util.spec_from_file_location("ops_intake_hide", HIDE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Base(unittest.TestCase):
    def setUp(self):
        self.hide = load_hide()
        self.tmp = tempfile.TemporaryDirectory()
        self.store_path = os.path.join(self.tmp.name, "erasure.sqlite")

    def tearDown(self):
        self.tmp.cleanup()

    def run_ask(self, ask, argv=None, decide=None, author=JAN, body=None, requester=JAN, hidden_now=None):
        """main() against the temp store. `ask` is the BODY of the Slack message the run names: there is no
        ask-text argument, so the body is the only text the parser can see. `decide` replaces Run.decide_rows,
        `cli_module` (the pipeline's hidden_now) is stubbed and `message_author` is the Slack read: those are the
        only steps that leave the process."""
        args = ["--requester-id", requester, "--store", self.store_path,
                "--message-ts", "1793704998.000001", "--channel", "C0OPS"] + list(argv or [])
        buf = io.StringIO()
        stub = types.SimpleNamespace(hidden_now=hidden_now or (lambda _run: (set(), {})))
        with mock.patch.object(self.hide.Run, "decide_rows", side_effect=decide or (lambda *_a, **_k: None)), \
                mock.patch.object(self.hide, "message_author",
                                  return_value=(author, ask if body is None else body)), \
                mock.patch.object(self.hide, "cli_module", return_value=stub):
            with redirect_stdout(buf):
                rc = self.hide.main(args)
        return rc, buf.getvalue()

    def store(self):
        return Store(self.store_path)


class Requests(Base):
    def test_a_non_staff_requester_is_refused_and_nothing_is_filed(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = self.hide.main(["--requester-id", "U_NOT_STAFF", "--store", self.store_path,
                                 "--message-ts", "1793704998.000001", "--channel", "C0OPS"])
        self.assertEqual(rc, 3)
        self.assertIn("tier R", buf.getvalue())
        self.assertEqual(self.store().all(), [], "a non-staff ask files nothing")
        # ...and the same words from staff DO file, so the refusal is about the requester, not the text
        rc2, out2 = self.run_ask(f"customer asked under GDPR to erase {PROFILE}", ["--apply"])
        self.assertEqual(rc2, 0, out2)
        self.assertEqual(len(self.store().all()), 1)

    def test_the_ask_files_one_slack_ops_row_per_id_with_the_ask_key(self):
        rc, out = self.run_ask(f"customer wrote asking under GDPR to erase {PROFILE}", ["--apply"])
        self.assertEqual(rc, 0, out)
        rows = self.store().all()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["channel"], "slack-ops")
        self.assertEqual(rows[0]["class"], "privacy_erasure")
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [PROFILE])
        self.assertIn(f"slack-ops:{JAN}:C0OPS:1793704998000001", rows[0]["row_key"])
        self.assertIn("ops intake", rows[0]["note"])

    def test_a_second_ask_for_the_same_page_by_another_requester_gets_its_own_row(self):
        # Captain, 2026-11-14 (option (c)): one row per REQUESTER. Customer A's request keeps its receipt and its
        # statutory clock; the staff ask that names the same profile must not be folded into A's row, or one customer
        # ends up holding another's deadline. Dedupe happens in hide_batch.plan, which keys on page id, so the page
        # still yields exactly one hide PR.
        st = self.store()
        st.upsert({"keys": [f"intercom:2154712345"], "channel": "intercom", "class": "privacy_erasure",
                   "received_at": "2026-11-01T09:14:00Z", "conversation_id": "2154712345",
                   "pages": [{"entity": "profile", "id": PROFILE}]})
        rc, out = self.run_ask(f"customer's GDPR erasure {PROFILE}", ["--apply"])
        self.assertEqual(rc, 0, out)
        rows = self.store().all()
        self.assertEqual(len(rows), 2, "a different requester files its own request; the rows are never merged")
        theirs = [r for r in rows if r["row_key"].startswith("intercom:")][0]
        mine = [r for r in rows if r["row_key"].startswith(f"slack-ops:{JAN}")][0]
        self.assertEqual(theirs["received_at"], "2026-11-01T09:14:00Z", "the other request's date is never moved")
        self.assertFalse(any(k.startswith(f"slack-ops:{JAN}") for k in theirs["keys"]),
                         "no merged row: this ask's key is never copied onto someone else's request")
        self.assertNotEqual(mine["received_at"], theirs["received_at"], "each row carries its own receipt date")
        self.assertEqual([p["id"] for p in mine["pages"]], [PROFILE])

    def test_one_staff_member_handling_two_customers_files_two_rows(self):
        # QA 5903932382 (Critical). The staff id in row_key is the OPERATOR, not the customer. Jan files customer A's
        # request, then customer B's independent request for the same page: treating the matching operator id as proof
        # of one customer folded B into A's row, so B got no receipt, no statutory deadline and no reply target. Only
        # customer evidence -- the linked conversation or the same Intercom contact -- may do that.
        def file_it(conversation, contact, ts):
            buf = io.StringIO()
            with mock.patch.object(self.hide.sources, "conversation", return_value=contact), \
                    mock.patch.object(self.hide.Run, "decide_rows"), \
                    mock.patch.object(self.hide, "message_author",
                                      return_value=(JAN, f"GDPR erasure {PROFILE}")), \
                    mock.patch.object(self.hide, "cli_module",
                                      return_value=types.SimpleNamespace(hidden_now=lambda _r: (set(), {}))):
                with redirect_stdout(buf):
                    rc = self.hide.main(["--requester-id", JAN, "--store", self.store_path,
                                         "--conversation", conversation, "--apply", "--channel", "C0OPS",
                                         "--message-ts", ts])
            self.assertIn(rc, (0, 2), buf.getvalue())
            return buf

        file_it("2154712345", {"author_email": "a@example.com", "contact_id": "c1"}, "1793704998.000001")
        self.assertEqual(len(self.store().all()), 1)
        file_it("9999888777", {"author_email": "b@example.com", "contact_id": "c2"}, "1793704998.000002")
        rows = self.store().all()
        self.assertEqual(len(rows), 2, "a different customer is a different request, even from the same staffer")
        self.assertFalse(any(e["kind"] == "ask_noted" for r in rows for e in self.store().events(r["id"])),
                         "no note either: a note is for the SAME customer's request, never for a different one")
        self.assertEqual(sorted(r.get("contact_id") or "" for r in rows), ["c1", "c2"],
                         "each row keeps its own customer's contact")

    def test_the_same_contact_days_later_is_a_new_request_not_a_note(self):
        # QA 5904134453 (Important). Matching contact_id alone is not a same-EVENT test: one customer can open a second
        # independent request for the same page weeks later from another conversation, and that request needs its own
        # receipt, deadline and reply target. The contact match is bounded by the register's own same-event window, the
        # one Store._match uses, because two deliveries of one notice differ by seconds and never by days.
        def file_it(conversation, ts):
            buf = io.StringIO()
            with mock.patch.object(self.hide.sources, "conversation",
                                   return_value={"author_email": "a@example.com", "contact_id": "c1"}), \
                    mock.patch.object(self.hide.Run, "decide_rows"), \
                    mock.patch.object(self.hide, "message_author",
                                      return_value=(JAN, f"GDPR erasure {PROFILE}")), \
                    mock.patch.object(self.hide, "cli_module",
                                      return_value=types.SimpleNamespace(hidden_now=lambda _r: (set(), {}))):
                with redirect_stdout(buf):
                    rc = self.hide.main(["--requester-id", JAN, "--store", self.store_path,
                                         "--conversation", conversation, "--apply", "--channel", "C0OPS",
                                         "--message-ts", ts])
            self.assertIn(rc, (0, 2), buf.getvalue())

        # 2026-11-01 09:14:00Z, then the same contact again 19 days later in a different conversation.
        file_it("2154712345", "1793524440.000001")
        file_it("9999888777", "1795166040.000002")
        rows = self.store().all()
        self.assertEqual(len(rows), 2, "same contact, days apart, another conversation: a NEW request with its own row")
        self.assertFalse(any(e["kind"] == "ask_noted" for r in rows for e in self.store().events(r["id"])),
                         "an old row must never absorb a later request")

    def test_a_same_customer_conversation_is_the_only_thing_that_makes_a_note(self):
        # The mirror of the case above: when the conversation IS the one the row was filed from, the ask joins as a
        # note instead of filing a duplicate. Nothing else about the ask can earn that -- not the staff id.
        st = self.store()
        rid = st.upsert({"keys": ["intercom:2154712345"], "channel": "intercom", "class": "privacy_erasure",
                        "received_at": "2026-11-01T09:14:00Z", "conversation_id": "2154712345",
                        "contact_id": "c1", "pages": [{"entity": "profile", "id": PROFILE}]})[0]
        buf = io.StringIO()
        with mock.patch.object(self.hide.sources, "conversation",
                               return_value={"author_email": "dan@example.com", "contact_id": "c1"}), \
                mock.patch.object(self.hide.Run, "decide_rows"), \
                mock.patch.object(self.hide, "message_author",
                                  return_value=(JAN, f"GDPR erasure {PROFILE}")), \
                mock.patch.object(self.hide, "cli_module",
                                  return_value=types.SimpleNamespace(hidden_now=lambda _r: (set(), {}))):
            with redirect_stdout(buf):
                rc = self.hide.main(["--requester-id", JAN, "--store", self.store_path,
                                     "--conversation", "2154712345", "--apply", "--channel", "C0OPS",
                                     "--message-ts", "1793704998.000003"])
        self.assertIn(rc, (0, 2), buf.getvalue())
        self.assertEqual(len(self.store().all()), 1, "same customer, same page: one request, noted")
        self.assertTrue(any(e["kind"] == "ask_noted" for e in self.store().events(rid)))

    def test_two_competing_asks_cannot_both_spend_the_daily_cap(self):
        # QA 5903932382 (Important). Read-then-write is not atomic across processes: with 20 ids already filed, two
        # asks of 10 each could both read 20, both see room for 10, and both commit -- 40 against a 30/day hold. The
        # per-ask cap is 10, so the race is built from two LEGAL asks (a 20-id bulk list is HELD for a different
        # reason). Both children are released from one barrier and each one stalls AFTER it reads the count, which is
        # the window the lock has to close: without it both read 20 and both file.
        import multiprocessing
        import time
        seed = [f"c{i:07d}-1111-2222-3333-444455556666" for i in range(10)]
        seed2 = [f"d{i:07d}-1111-2222-3333-444455556666" for i in range(10)]
        self.assertEqual(self.run_ask(f"GDPR erasure {' '.join(seed)}", ["--apply", "--ask-id", "seed1"])[0], 0)
        self.assertEqual(self.run_ask(f"GDPR erasure {' '.join(seed2)}", ["--apply", "--ask-id", "seed2"])[0], 0)
        self.assertEqual(len(self.store().all()), 20, "20 of the 30/day are already spent")
        ctx = multiprocessing.get_context("fork")
        go = ctx.Event()
        a_ids = " ".join(f"a{i:07d}-1111-2222-3333-444455556666" for i in range(10))
        b_ids = " ".join(f"b{i:07d}-1111-2222-3333-444455556666" for i in range(10))
        procs = [ctx.Process(target=self._file_in_child, args=(text, ts, go, time.sleep))
                 for text, ts in ((a_ids, "1793704998.100001"), (b_ids, "1793704998.100002"))]
        for p in procs:
            p.start()
        go.set()
        for p in procs:
            p.join(120)
        self.assertEqual(len(self.store().all()), 30,
                         "one ask takes the last 10, the other is HELD: 40 filed would mean the lock is not held")

    def _file_in_child(self, ids, ts, go, sleep):
        """A real second process: the cap race is between processes, so it cannot be reproduced in one. `ids_today`
        stalls after it reads, holding both children in the read window until one of them has committed."""
        real = self.hide.ids_today

        def slow_ids_today(store, requester, day):
            n = real(store, requester, day)
            sleep(1.5)
            return n

        go.wait(60)
        with mock.patch.object(self.hide, "ids_today", slow_ids_today), \
                mock.patch.object(self.hide.Run, "decide_rows"), \
                mock.patch.object(self.hide, "message_author",
                                  return_value=(JAN, f"GDPR erasure {ids}")), \
                mock.patch.object(self.hide, "cli_module",
                                  return_value=types.SimpleNamespace(hidden_now=lambda _r: (set(), {}))), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.hide.main(["--requester-id", JAN, "--store", self.store_path, "--apply",
                            "--channel", "C0OPS", "--message-ts", ts])

    def test_an_ask_naming_the_full_uuid_finds_the_row_holding_the_8_char_prefix(self):
        # The mail ledger keeps 8-char prefixes and Intercom keeps full uuids, so the same page arrives spelled two
        # ways. Compared verbatim, the same CUSTOMER's repeat ask files a second row for one page. The match is on
        # page_prefix, and the customer evidence is the linked conversation -- never the staff id, which is the same
        # person for every customer that staffer handles (QA 5903932382, Critical).
        st = self.store()
        st.upsert({"keys": ["intercom:2154712345"], "channel": "intercom", "class": "privacy_erasure",
                   "received_at": "2026-11-01T09:14:00Z", "conversation_id": "2154712345",
                   "pages": [{"entity": "profile", "id": "fc31a861"}]})
        buf = io.StringIO()
        with mock.patch.object(self.hide.sources, "conversation",
                               return_value={"author_email": "dan@example.com", "contact_id": "c1"}), \
                mock.patch.object(self.hide.Run, "decide_rows"), \
                mock.patch.object(self.hide, "message_author",
                                  return_value=(JAN, "GDPR erasure fc31a861-0297-4b1e-9d3c-5a6b7c8d9e0f")), \
                mock.patch.object(self.hide, "cli_module",
                                  return_value=types.SimpleNamespace(hidden_now=lambda _r: (set(), {}))):
            with redirect_stdout(buf):
                rc = self.hide.main(["--requester-id", JAN, "--store", self.store_path,
                                     "--conversation", "2154712345", "--apply", "--channel", "C0OPS",
                                     "--message-ts", "1793704998.000001"])
        self.assertEqual(rc, 0, buf.getvalue())
        rows = self.store().all()
        self.assertEqual(len(rows), 1, "prefix and full uuid are the same page: note, never a second row")
        self.assertTrue(any(e["kind"] == "ask_noted" for e in self.store().events(rows[0]["id"])))

    def test_two_pages_that_share_no_prefix_do_not_attach(self):
        st = self.store()
        st.upsert({"keys": ["notices:fc31a861"], "channel": "notices", "class": "privacy_erasure",
                   "received_at": "2026-11-01T09:14:00Z", "pages": [{"entity": "profile", "id": "fc31a861"}]})
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.store().all()), 2, "a different page is a different request")

    def test_the_daily_cap_is_held_not_truncated(self):
        st = self.store()
        for i in range(30):
            st.upsert({"keys": [f"slack-ops:{JAN}:C0OPS:1793704998000001:{1000 + i}"], "channel": "slack-ops",
                       "class": "privacy_erasure", "received_at": "2026-11-04T00:00:00Z",
                       "pages": [{"entity": "profile", "id": f"0000000{i}-1111-2222-3333-444455556666"}]})
        # created_at is "now" (today), which is what the cap counts
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"])
        self.assertEqual(rc, 4, out)
        self.assertIn("held", out)
        self.assertEqual(len(self.store().all()), 30, "a held ask files nothing")

    def test_a_caller_supplied_ask_id_cannot_widen_the_daily_cap(self):
        # A cap a caller can step around by naming its own key is not a cap: the count is by REQUESTER, so three
        # asks with three different --ask-id labels still add up, and the fourth is held.
        for n, label in enumerate(("ticket-7", "ticket-8", "ticket-9")):
            ids = " ".join(f"{n}{i:07d}-1111-2222-3333-444455556666" for i in range(10))
            rc, out = self.run_ask(f"GDPR erasure {ids}", ["--apply", "--ask-id", label])
            self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.store().all()), 30)
        rc, out = self.run_ask(f"GDPR erasure {OTHER}", ["--apply", "--ask-id", "ticket-10"])
        self.assertEqual(rc, 4, out)
        self.assertIn("held", out)
        self.assertIn(JAN, out)
        self.assertIn(str(self.hide.MAX_IDS_PER_REQUESTER_PER_DAY), out)
        self.assertEqual(len(self.store().all()), 30, "a held ask files nothing")

    def test_replaying_the_same_ask_is_not_charged_against_the_cap_twice(self):
        # A retry after a failed PR-open is the SAME ask, not a new one. Charging it again would push the requester
        # past the cap and lock them out of finishing the job they already started -- the worst case, which is the
        # one that matters, is at the cap boundary: 3 asks of 10 must leave the THIRD replayable.
        for n in range(3):
            ids = " ".join(f"{n}{i:07d}-1111-2222-3333-444455556666" for i in range(10))
            rc, out = self.run_ask(f"GDPR erasure {ids}", ["--apply"])
            self.assertEqual(rc, 0, out)
        day = self.store().all()[0]["created_at"][:10]
        self.assertEqual(self.hide.ids_today(self.store(), JAN, day), 30, "three asks of 10 is the cap")
        # Replay the third ask exactly as a retry after a failed open_prs would. It is not new work, so it is not new
        # charge: the register keys are per page (`<ask>:<pid>`), and a check against the BARE ask never matches one.
        third = " ".join(f"2{i:07d}-1111-2222-3333-444455556666" for i in range(10))
        rc, out = self.run_ask(f"GDPR erasure {third}", ["--apply"])
        self.assertEqual(rc, 0, "a replay at the cap must not be held, or the PRs can never be opened: " + out)
        self.assertEqual(len(self.store().all()), 30, "the replay attaches to its own rows, it does not re-file")
        self.assertEqual(self.hide.ids_today(self.store(), JAN, day), 30, "a replay is charged nothing")

    def test_an_ask_id_naming_another_staff_member_cannot_spend_their_cap(self):
        # The label is appended AFTER the requester segment, so a membership test anywhere in the key would charge
        # Nick for Jan's asks. The cap is positional: only the segment right after the channel prefix counts.
        for n in range(3):
            ids = " ".join(f"{n}{i:07d}-1111-2222-3333-444455556666" for i in range(10))
            rc, out = self.run_ask(f"GDPR erasure {ids}", ["--apply", "--ask-id", NICK])
            self.assertEqual(rc, 0, out)
        day = self.store().all()[0]["created_at"][:10]
        self.assertEqual(self.hide.ids_today(self.store(), JAN, day), 30)
        self.assertEqual(self.hide.ids_today(self.store(), NICK, day), 0,
                         "a label naming Nick must not charge Nick")
        rc, out = self.run_ask(f"GDPR erasure {OTHER}", ["--apply"], author=NICK, requester=NICK)
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.store().all()), 31, "Nick's own ask is not held by Jan's labels")

    def test_a_second_requesters_ask_is_not_merged_and_is_charged_on_its_own(self):
        # Captain, 2026-11-14 (option (c)) supersedes the old "an attach adds a key, never a page" rule: a key copied
        # onto A's row made A's request carry B's ask and left B charged nothing for work that produced a hide PR.
        # Now B files its own row and is charged for it; A keeps exactly the ten pages A asked for.
        ids = " ".join(f"{i:08d}-1111-2222-3333-444455556666" for i in range(10))
        rc, out = self.run_ask(f"GDPR erasure {ids}", ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.store().all()), 10)
        rc, out = self.run_ask(f"GDPR erasure {ids.split()[0]}", ["--apply"], author=NICK, requester=NICK)
        self.assertEqual(rc, 0, out)
        rows = self.store().all()
        self.assertEqual(len(rows), 11, "B's ask is its own request, not a key smuggled onto A's row")
        theirs = [r for r in rows if r["row_key"].startswith(f"slack-ops:{NICK}")]
        self.assertEqual(len(theirs), 1)
        self.assertFalse(any(k.startswith(f"slack-ops:{NICK}") for r in rows if r not in theirs for k in r["keys"]),
                         "no row of A's carries B's key")
        day = rows[0]["created_at"][:10]
        self.assertEqual(self.hide.ids_today(self.store(), JAN, day), 10, "A is charged for A's ten pages")
        self.assertEqual(self.hide.ids_today(self.store(), NICK, day), 1, "B is charged for the page B asked about")

    def test_a_caller_supplied_ask_id_is_still_idempotent(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply", "--ask-id", "ticket-7"])
        self.assertEqual(rc, 0, out)
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply", "--ask-id", "ticket-7"])
        self.assertEqual(rc, 0, out)
        rows = self.store().all()
        self.assertEqual(len(rows), 1, "the same ask re-run must not file a second row")
        self.assertTrue(any(":ticket-7:" in k for k in rows[0]["keys"]))

    def test_more_than_ten_ids_is_held(self):
        ids = " ".join(f"{i:08d}-1111-2222-3333-444455556666" for i in range(11))
        rc, out = self.run_ask(f"GDPR erasure {ids}", ["--apply"])
        self.assertEqual(rc, 4)
        self.assertIn("cap", out)
        self.assertEqual(self.store().all(), [])

    def test_an_ask_that_names_no_id_is_refused(self):
        rc, out = self.run_ask("hide that profile please, GDPR")
        self.assertEqual(rc, 1)
        self.assertIn("names no profile/track id", out)

    def test_an_unreadable_linked_conversation_fails_closed(self):
        # Without the conversation the register cannot identify the customer, so the ask must not file a row that
        # nothing can identify -- and the run must not look green.
        buf = io.StringIO()
        with mock.patch.object(self.hide.sources, "conversation",
                               side_effect=self.hide.sources.Unknown("500 part cap")), \
                mock.patch.object(self.hide, "message_author", return_value=(JAN, f"GDPR erasure {PROFILE}")):
            with redirect_stdout(buf):
                rc = self.hide.main(["--requester-id", JAN,
                                     "--store", self.store_path, "--conversation", "2154712345", "--apply",
                                     "--channel", "C0OPS", "--message-ts", "1793704998.000001"])
        self.assertEqual(rc, 2)
        self.assertEqual(self.store().all(), [])

    def test_the_linked_conversation_supplies_the_customer_identity_for_the_note(self):
        # Same linked conversation = provably the same customer's request, so the ask joins as a NOTE (captain's rule:
        # a staff ask joins as a note on the customer's row, never as a merged row) and no key is copied onto it.
        st = self.store()
        st.upsert({"keys": ["intercom:2154712345"], "channel": "intercom", "class": "privacy_erasure",
                   "received_at": "2026-11-01T09:14:00Z", "conversation_id": "2154712345",
                   "requester_email": "dan@example.com", "pages": [{"entity": "profile", "id": PROFILE}]})
        buf = io.StringIO()
        with mock.patch.object(self.hide.sources, "conversation",
                               return_value={"author_email": "dan@example.com", "author_name": "Dan",
                                             "contact_id": "c1"}), \
                mock.patch.object(self.hide.Run, "decide_rows"), \
                mock.patch.object(self.hide, "message_author", return_value=(JAN, f"GDPR erasure {PROFILE}")), \
                mock.patch.object(self.hide, "cli_module",
                                  return_value=types.SimpleNamespace(hidden_now=lambda _r: (set(), {}))):
            with redirect_stdout(buf):
                rc = self.hide.main(["--requester-id", JAN,
                                     "--store", self.store_path, "--conversation", "2154712345", "--apply",
                                     "--channel", "C0OPS", "--message-ts", "1793704998.000001"])
        self.assertEqual(rc, 0, buf.getvalue())
        rows = self.store().all()
        self.assertEqual(len(rows), 1, "same customer + same page = one request, so the ask is noted on it")
        self.assertFalse(any(k.startswith(f"slack-ops:{JAN}") for k in rows[0]["keys"]),
                         "a note never merges: the ask's key is not copied onto the customer's row")
        self.assertEqual(rows[0]["received_at"], "2026-11-01T09:14:00Z",
                         "the customer's own receipt date is never moved")
        self.assertTrue(any(e["kind"] == "ask_noted" for e in self.store().events(rows[0]["id"])))

    def test_a_dry_run_writes_nothing(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.store().all(), [])
        self.assertIn("gdpr-hide ·", out)

    def test_an_apply_without_open_prs_says_no_pr_was_opened(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertIn("no PR was opened by this run", out)
        self.assertIn("hide-batch --open-prs", out)

    def test_a_failed_pr_open_still_reports_the_filed_rows(self):
        with mock.patch.object(self.hide, "hide_for_rows",
                               side_effect=RuntimeError("gh pr create: rate limit")):
            rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply", "--open-prs"])
        self.assertEqual(rc, 2, "no PR exists, so the run did NOT do the job: exit non-zero (QA 5903932382)" + out)
        self.assertIn("hide-batch --open-prs", out)
        self.assertEqual(len(self.store().all()), 1, "the register row is filed even when the PRs fail")

    def test_a_hide_list_read_failure_after_the_rows_are_committed_still_reports_them(self):
        # hidden_now() calls run.fail() and then raises SystemExit(2), and it runs AFTER store.upsert committed every
        # row. Unguarded, the process exits 2 having printed nothing: the operator cannot tell a refusal-with-nothing-
        # filed from an ask that IS on the register.
        def boom(run):
            run.fail("hide lists", self.hide.sources.Unknown("gh: no token"))
            raise SystemExit(2)

        err = io.StringIO()
        with redirect_stderr(err):
            rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"], hidden_now=boom)
        self.assertEqual(rc, 2, out)
        self.assertIn("identity NOT decided", err.getvalue())
        self.assertIn("gh: no token", err.getvalue())
        self.assertIn("ARE filed and stand", err.getvalue())
        self.assertIn("gdpr-hide ·", out, "the card is still rendered")
        self.assertNotIn("waiting on identity", out,
                         "a deferred read is not an ask in flight: nothing was asked of the customer")
        rows = self.store().all()
        self.assertEqual(len(rows), 1, "the register row is committed and stands")
        self.assertIn(str(rows[0]["register_no"]), out)

    def test_a_deferred_identity_keeps_an_already_decided_verdict_and_the_captain_bucket(self):
        st = self.store()
        rid, _ = st.upsert({"keys": [f"slack-ops:{JAN}:C0OPS:1793704998000001:{PROFILE}"], "channel": "slack-ops",
                            "class": "privacy_erasure", "received_at": "2026-11-04T00:00:00Z",
                            "pages": [{"entity": "profile", "id": PROFILE}]})
        st.update(rid, "decide", identity_verdict="LEGAL_HIDE_FIRST",
                  verdict_detail=json.dumps([{"id": PROFILE, "verdict": "LEGAL_HIDE_FIRST", "why": "test"}]))

        def boom(run):
            run.fail("hide lists", self.hide.sources.Unknown("gh: no token"))
            raise SystemExit(2)

        err = io.StringIO()
        with redirect_stderr(err):
            rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"], hidden_now=boom)
        self.assertEqual(rc, 2, out)
        self.assertIn("identity NOT decided", err.getvalue())
        self.assertIn("captain owns this: LEGAL_HIDE_FIRST", out)
        self.assertNotIn("waiting on identity", out)
        self.assertEqual(self.store().all()[0]["identity_verdict"], "LEGAL_HIDE_FIRST",
                         "a deferred read must not overwrite a verdict that was already decided")

    def test_a_pr_open_that_times_out_or_returns_garbage_still_reports_the_filed_rows(self):
        # gh pr create can hang past hide_batch's subprocess timeout, and `gh` output can fail to parse; that raises
        # subprocess.TimeoutExpired / json.JSONDecodeError, neither of which is a RuntimeError. The operator must
        # still be told the register rows are committed.
        import subprocess
        for exc in (subprocess.TimeoutExpired(cmd=["gh", "pr", "create"], timeout=600),
                    json.JSONDecodeError("truncated", "", 0),
                    OSError("the H-DevOps checkout is missing")):
            with self.subTest(exc=type(exc).__name__):
                with tempfile.TemporaryDirectory() as tmp:
                    self.store_path = os.path.join(tmp, "erasure.sqlite")
                    with mock.patch.object(self.hide, "hide_for_rows", side_effect=exc):
                        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply", "--open-prs"])
                    self.assertEqual(rc, 2, "a caller keying on status must not record a hide that never happened:"
                                     + out)
                    self.assertIn("the hide PRs could not be opened", out)
                    self.assertIn("hide-batch --open-prs", out)
                    self.assertEqual(len(self.store().all()), 1,
                                     "the register row survives a non-RuntimeError PR failure")

    def test_a_dry_run_leaves_no_database_no_directory_and_no_lock_file(self):
        # QA 5904316216 (Important). The cap lock is a WRITE, so taking it on a preview created `<store>.cap-lock` (and
        # its parent) for a store that may not exist yet, and a preview against a read-only store dir failed before
        # printing anything. A preview spends nothing, so it serializes nothing.
        with tempfile.TemporaryDirectory() as tmp:
            fresh = os.path.join(tmp, "not", "yet", "erasure.sqlite")
            rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--store", fresh, "--message-ts", "1793704998.000001"])
            self.assertEqual(rc, 0, out)
            self.assertIn("create a register row", out)
            self.assertFalse(os.path.exists(fresh), "a preview must not create the store")
            self.assertFalse(os.path.exists(fresh + ".cap-lock"), "a preview must not create the cap lock")
            self.assertFalse(os.path.isdir(os.path.dirname(fresh)),
                             "a preview must not create the store's parent directory")

    def test_a_dry_run_predicts_what_the_apply_path_will_do(self):
        st = self.store()
        st.upsert({"keys": ["intercom:2154712345"], "channel": "intercom", "class": "privacy_erasure",
                   "received_at": "2026-11-01T09:14:00Z", "conversation_id": "2154712345",
                   "pages": [{"entity": "profile", "id": PROFILE}]})
        rc, out = self.run_ask(f"customer's GDPR erasure {PROFILE}")
        self.assertEqual(rc, 0, out)
        # A different requester: the preview must say the ask gets its OWN row, never that it attaches.
        self.assertIn("create its own register row", out)
        self.assertNotIn("note the ask on the existing row", out)
        self.assertEqual(len(self.store().all()), 1, "the preview wrote nothing")


class Identity(Base):
    """The requester id is a VERIFIED FACT, not an attestation: the message the ask names is read back from Slack
    and its author must be the requester. The ask TEXT is derived from that same message, never accepted from the
    caller. An unreadable message is UNKNOWN, and UNKNOWN is a refusal."""

    def test_a_message_authored_by_the_requester_files_the_ask(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"], author=JAN)
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.store().all()), 1)

    def test_the_ids_and_the_class_come_from_the_message_body(self):
        rc, out = self.run_ask(f"please erase {PROFILE} under GDPR", ["--apply"], author=JAN)
        self.assertEqual(rc, 0, out)
        row = self.store().all()[0]
        self.assertEqual(row["class"], "privacy_erasure")
        self.assertEqual([p["id"] for p in row["pages"]], [PROFILE])

    def test_a_different_body_cannot_be_smuggled_in_alongside_a_genuine_message(self):
        # The message Jan really wrote names OTHER; the caller would like PROFILE hidden and says so in the only
        # text it still controls (--ask-id). The two values differ by construction, so a run that read the label
        # as the ask would file PROFILE and fail here.
        rc, out = self.run_ask(f"GDPR erasure {OTHER}", ["--apply", "--ask-id", PROFILE], author=JAN)
        self.assertEqual(rc, 0, out)
        row = self.store().all()[0]
        self.assertEqual([p["id"] for p in row["pages"]], [OTHER])
        self.assertNotIn(PROFILE, [p["id"] for p in row["pages"]])
        self.assertIn(PROFILE, row["keys"][0], "the label is carried on the key, never as the ask")

    def test_there_is_no_argument_that_supplies_the_ask_text(self):
        for flag in ("--ask-text", "--ask-file"):
            with self.assertRaises(SystemExit) as caught:
                self.hide.main([flag, f"GDPR erasure {PROFILE}", "--requester-id", JAN,
                                "--store", self.store_path, "--channel", "C0OPS",
                                "--message-ts", "1793704998.000001"])
            self.assertEqual(caught.exception.code, 2, f"{flag} must be rejected, not ignored")
        self.assertEqual(self.store().all(), [])

    def test_a_message_with_no_text_refuses_and_files_nothing(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"], author=JAN, body="   ")
        self.assertEqual(rc, 6, out)
        self.assertIn("no text", out)
        self.assertEqual(self.store().all(), [])

    def test_the_same_ask_with_the_requester_id_supplied_by_someone_else_refuses(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", ["--apply"], author=OTHER)
        self.assertEqual(rc, 6, out)
        self.assertIn("identity unverified", out)
        self.assertIn(OTHER, out)
        self.assertEqual(self.store().all(), [], "an ask whose author is not the requester files nothing")

    def test_the_identity_check_runs_in_dry_run_too(self):
        rc, out = self.run_ask(f"GDPR erasure {PROFILE}", author=OTHER)
        self.assertEqual(rc, 6, out)
        self.assertEqual(self.store().all(), [])

    def test_an_unreadable_message_refuses_rather_than_passing(self):
        buf = io.StringIO()
        args = ["--requester-id", JAN, "--store", self.store_path,
                "--message-ts", "1793704998.000001", "--channel", "C0OPS", "--apply"]
        with mock.patch.object(self.hide, "message_author", side_effect=RuntimeError("conversations.history failed: "
                                                                                    "ratelimited")):
            with redirect_stdout(buf):
                rc = self.hide.main(args)
        self.assertEqual(rc, 6, buf.getvalue())
        self.assertIn("could not be read", buf.getvalue())
        self.assertEqual(self.store().all(), [])

    def test_an_ask_with_no_message_ts_refuses(self):
        buf = io.StringIO()
        args = ["--requester-id", JAN, "--store", self.store_path,
                "--channel", "C0OPS", "--apply"]
        with mock.patch.object(self.hide, "message_author", return_value=(JAN, "GDPR")) as lookup:
            with redirect_stdout(buf):
                rc = self.hide.main(args)
        self.assertEqual(rc, 6, buf.getvalue())
        self.assertFalse(lookup.called, "no ts means no message to read, so no lookup is attempted")
        self.assertEqual(self.store().all(), [])

    def test_an_ask_with_no_channel_refuses(self):
        buf = io.StringIO()
        args = ["--requester-id", JAN, "--store", self.store_path,
                "--message-ts", "1793704998.000001", "--apply"]
        with mock.patch.object(self.hide, "message_author", return_value=(JAN, "GDPR")) as lookup:
            with redirect_stdout(buf):
                rc = self.hide.main(args)
        self.assertEqual(rc, 6, buf.getvalue())
        self.assertFalse(lookup.called)
        self.assertEqual(self.store().all(), [])


class Classes(Base):
    def test_a_verb_alone_is_not_a_reason(self):
        rc, out = self.run_ask(f"hide {PROFILE}")
        self.assertEqual(rc, 5)
        self.assertIn("only a verb", out)
        self.assertEqual(self.store().all(), [])

    def test_removed_from_spotify_is_a_catalog_takedown_not_a_gdpr_erasure(self):
        rc, out = self.run_ask(f"the track was removed from Spotify https://muso.ai/track/{PROFILE}", ["--apply"])
        self.assertEqual(rc, 0, out)
        row = self.store().all()[0]
        self.assertEqual(row["class"], "dmca_takedown")
        self.assertEqual(row["pages"][0]["entity"], "track")

    def test_a_legal_threat_is_its_own_class(self):
        rc, out = self.run_ask(f"his lawyer sent a cease and desist about https://muso.ai/profile/{PROFILE}",
                               ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.store().all()[0]["class"], "legal_threat")

    def test_a_plain_dmca_notice_is_a_routine_takedown_not_a_legal_threat(self):
        # "DMCA notice" is the ordinary opening of a copyright complaint, not a threat of action. Classifying it as
        # legal_threat would hold a routine takedown for the captain and skip the documented claim-first DMCA path.
        self.assertEqual(self.hide.classify("DMCA notice for track")[0], "dmca_takedown")
        self.assertEqual(self.hide.classify("DMCA notice for track, please remove it from Spotify")[0],
                         "dmca_takedown")
        # an actual threat of action still wins, in the same message shape
        self.assertEqual(self.hide.classify("DMCA notice for track; our attorney will sue")[0], "legal_threat")

    def test_a_threat_inside_a_copyright_complaint_is_a_legal_threat(self):
        # most restrictive wins: the captain owns a threat even when the same message also reads like a takedown
        self.assertEqual(self.hide.classify("DMCA takedown, and our attorney will sue")[0], "legal_threat")

    def test_a_bare_uuid_is_filed_as_a_profile_never_a_track(self):
        self.assertEqual(self.hide.parse_ids(PROFILE), [("profile", PROFILE)])
        self.assertEqual(self.hide.parse_ids(f"https://muso.ai/track/{PROFILE}"), [("track", PROFILE)])


class HideHalf(Base):
    def _row(self, verdict, pid=PROFILE, cls="privacy_erasure"):
        st = self.store()
        rid, _ = st.upsert({"keys": [f"slack-ops:{JAN}:C0OPS:1793704998000001:{pid}"], "channel": "slack-ops",
                            "class": cls, "received_at": "2026-11-04T00:00:00Z",
                            "pages": [{"entity": "profile", "id": pid}]})
        st.update(rid, "decide", identity_verdict=verdict,
                  verdict_detail=decided(verdict, pid))
        return st.get(rid)

    def test_a_page_shared_with_an_older_row_opens_the_pair_while_nothing_is_in_flight(self):
        # plan() dedups by PAGE and keeps the earliest row, so this ask's own row is filtered out and its batch is
        # empty. That is NOT "the other row's hide is in flight": with no open PR and the page on neither list,
        # returning there claimed a hide that did not exist and exited 0 with no URL, so the page reached no PR at all
        # (QA 5904134453, Important). The whole planned set goes to open_prs, exactly as the nightly path does.
        st = self.store()

        def row(key):
            rid, _ = st.upsert({"keys": [key], "channel": "slack-ops", "class": "privacy_erasure",
                                "received_at": "2026-11-04T00:00:00Z",
                                "pages": [{"entity": "profile", "id": PROFILE}]})
            st.update(rid, "decide", identity_verdict="PASS_A",
                      verdict_detail=decided("PASS_A"))
            return st.get(rid)

        older = row("notices:fc31a861")
        newer = row("intercom:2154712345")
        self.assertLess(older["register_no"], newer["register_no"])
        run = self.hide.Run(self.store(), log=lambda *_a: None)
        opened = {}
        with mock.patch.object(self.hide.sources, "hidden_lists", return_value=(set(), set())), \
                mock.patch.object(self.hide.hide_batch, "in_flight_ids",
                                  return_value={"hdevops": set(), "pdp": set()}), \
                mock.patch.object(self.hide.hide_batch, "open_prs",
                                  side_effect=lambda batch, **kw: opened.update({"batch": batch, **kw}) or
                                  {"hdevops": "https://github.com/x/pull/1", "pdp": "https://github.com/x/pull/2"}):
            res = self.hide.hide_for_rows([newer], run, ask="ask-1", apply=True)
        self.assertEqual(res["batch"], [], "the card still names only this ask's rows")
        self.assertEqual(res["ids"], [PROFILE], "but the page is reported, because a PR is now open for it")
        self.assertTrue(opened.get("batch"), "nothing in flight means the planned set is opened")
        self.assertIn(PROFILE, [b["id"] for b in opened["batch"]], "the page rides the older row's entry")
        self.assertEqual(res["prs"]["hdevops"], "https://github.com/x/pull/1")

    def test_a_page_whose_hide_pr_is_still_open_names_that_pr_and_not_a_missing_page(self):
        row = self._row("PASS_A")
        run = self.hide.Run(self.store(), log=lambda *_a: None)
        with mock.patch.object(self.hide.sources, "hidden_lists", return_value=(set(), set())), \
                mock.patch.object(self.hide.hide_batch, "in_flight_ids",
                                  return_value={"hdevops": {PROFILE}, "pdp": {PROFILE}}):
            res = self.hide.hide_for_rows([row], run, ask="ask-1", apply=True)
        self.assertEqual(res["batch"], [], "one page, one PR: the open PR is the one in flight")
        self.assertIn("already open", res["why"])
        self.assertIn(PROFILE, res["why"])
        self.assertNotIn("missing a hide-list entry", res["why"])

    def test_a_page_already_on_both_hide_lists_says_so(self):
        row = self._row("PASS_A")
        run = self.hide.Run(self.store(), log=lambda *_a: None)
        with mock.patch.object(self.hide.sources, "hidden_lists", return_value=({PROFILE}, {PROFILE})), \
                mock.patch.object(self.hide.hide_batch, "in_flight_ids",
                                  return_value={"hdevops": set(), "pdp": set()}):
            res = self.hide.hide_for_rows([row], run, ask="ask-1", apply=True)
        self.assertEqual(res["batch"], [])
        self.assertIn("already on both hide lists", res["why"])

    def test_a_legal_hide_first_page_is_never_opened_by_this_path(self):
        row = self._row("LEGAL_HIDE_FIRST", cls="legal_threat")
        run = self.hide.Run(self.store(), log=lambda *_a: None)
        opened = {}
        with mock.patch.object(self.hide.sources, "hidden_lists", return_value=(set(), set())), \
                mock.patch.object(self.hide.hide_batch, "in_flight_ids", return_value={"hdevops": set(), "pdp": set()}), \
                mock.patch.object(self.hide.hide_batch, "open_prs",
                                  side_effect=lambda batch, **kw: opened.update({"batch": batch, **kw}) or {}):
            res = self.hide.hide_for_rows([row], run, ask="ask-1", apply=True)
        self.assertEqual(res["batch"], [])
        self.assertEqual(opened, {}, "the captain owns a legal threat: no PR, no include-legal")
        self.assertIn("identity-PASS", res["why"])

    def test_an_identity_pass_page_opens_the_pair_with_the_ask_in_the_body(self):
        row = self._row("PASS_A")
        run = self.hide.Run(self.store(), log=lambda *_a: None)
        seen = {}

        def fake_open(batch, dry_run=True, runner=None, ask=""):
            seen.update({"batch": batch, "dry_run": dry_run, "ask": ask})
            return {"ids": [b["id"] for b in batch], "hdevops": "https://example.test/hd", "pdp": ""}

        with mock.patch.object(self.hide.sources, "hidden_lists", return_value=(set(), set())), \
                mock.patch.object(self.hide.hide_batch, "in_flight_ids", return_value={"hdevops": set(), "pdp": set()}), \
                mock.patch.object(self.hide.hide_batch, "open_prs", side_effect=fake_open):
            res = self.hide.hide_for_rows([row], run, ask="ask-1", apply=True)
        self.assertEqual([b["id"] for b in seen["batch"]], [PROFILE])
        self.assertEqual(seen["ask"], "ask-1")
        self.assertFalse(seen["dry_run"], "--apply means the PRs open now, not at the next tick")
        self.assertEqual(res["prs"]["hdevops"], "https://example.test/hd")

    def test_the_pair_carries_the_whole_pending_set_while_the_card_names_only_this_ask(self):
        # open_prs is written for one pipeline PR per repository carrying EVERY pending id: given a narrower set it
        # closes the open pair as superseded and reopens one holding just that set. An ops ask that narrowed to its
        # own rows would therefore drop another row's page out of the open PR. Two rows, two pages, one ask.
        st = self.store()
        for key, pid in (("slack-ops:" + JAN + ":C0OPS:1793704998000001:" + OTHER, OTHER),
                         ("slack-ops:" + JAN + ":C0OPS:1793704998000002:" + PROFILE, PROFILE)):
            rid, _ = st.upsert({"keys": [key], "channel": "slack-ops", "class": "privacy_erasure",
                                "received_at": "2026-11-04T00:00:00Z",
                                "pages": [{"entity": "profile", "id": pid}]})
            st.update(rid, "decide", identity_verdict="PASS_A",
                      verdict_detail=decided("PASS_A", pid))
        mine = [r for r in st.all("open") if r["pages"][0]["id"] == PROFILE]
        run = self.hide.Run(st, log=lambda *_a: None)
        seen = {}

        def fake_open(batch, dry_run=True, runner=None, ask=""):
            seen.update({"ids": sorted(b["id"] for b in batch)})
            return {"ids": [b["id"] for b in batch], "hdevops": "https://example.test/hd", "pdp": ""}

        with mock.patch.object(self.hide.sources, "hidden_lists", return_value=(set(), set())), \
                mock.patch.object(self.hide.hide_batch, "in_flight_ids", return_value={}), \
                mock.patch.object(self.hide.hide_batch, "open_prs", side_effect=fake_open):
            res = self.hide.hide_for_rows(mine, run, ask="ask-1", apply=True)
        self.assertEqual(seen["ids"], sorted([PROFILE, OTHER]),
                         "open_prs gets the whole pending set, or it supersedes the open pair and drops the other page")
        self.assertEqual([b["id"] for b in res["batch"]], [PROFILE], "the card is this ask's page only")
        self.assertEqual(res["ids"], [PROFILE])

    def test_the_pr_body_quotes_the_ask_and_only_adds(self):
        body = self.hide.hide_batch.pr_body("hdevops", [{"register_no": 12, "id": PROFILE, "basis": "PASS_A",
                                                         "due_at": "2026-11-20T00:00:00Z"}], ask="ask-1")
        self.assertIn("ask-1", body)
        self.assertIn("reversible hide only", body)
        mentions = [ln for ln in body.splitlines() if "DELETE /api/v3/admin/profile" in ln]
        self.assertEqual(len(mentions), 1, "the body names the soft-delete exactly once, as a prohibition")
        self.assertIn("there is no", mentions[0])


class Ownership(Base):
    """Who owns a page after the pipeline's verdict: pass -> the reversible PR, ask -> nothing hidden, big name or
    legal threat -> the captain (red-team j2 case 3 is the ASK one: a hide request for a page the linked Intercom
    contact does not own must never open a PR)."""

    def test_an_ask_verdict_opens_no_pr_and_says_what_the_customer_is_being_asked(self):
        hide = self.hide
        filed = [{"id": 1, "register_no": 12, "row_key": "k", "status": "open", "class": "privacy_erasure",
                  "pages": [{"entity": "profile", "id": PROFILE}],
                  "verdict_detail": [{"id": PROFILE, "verdict": "ASK_IDENTITY", "why": "not verified"}]}]
        run = hide.Run(self.store(), log=lambda *_a: None)
        with mock.patch.object(hide.sources, "hidden_lists", return_value=(set(), set())):
            res = hide.hide_for_rows(filed, run, ask="ask-1", apply=True)
        self.assertEqual(res["batch"], [], "an ASK page is never hidden")
        self.assertIn("identity-PASS", res["why"])

    def test_a_big_name_page_is_the_captains_call_not_this_path(self):
        hide = self.hide
        filed = [{"id": 1, "register_no": 12, "row_key": "k", "status": "open", "class": "privacy_erasure",
                  "pages": [{"entity": "profile", "id": PROFILE}],
                  "verdict_detail": [{"id": PROFILE, "verdict": "JAN_BIGNAME", "why": "popularity 61"}]}]
        run = hide.Run(self.store(), log=lambda *_a: None)
        with mock.patch.object(hide.sources, "hidden_lists", return_value=(set(), set())):
            res = hide.hide_for_rows(filed, run, ask="ask-1", apply=True)
        self.assertEqual(res["batch"], [])


class DecideSeam(Base):
    def test_the_pipeline_hide_lists_reach_decide_rows_unpacked(self):
        seen = {}

        def spy(_rows, hidden, *args, **kwargs):
            seen["hidden"] = hidden
            seen["half"] = kwargs.get("half")

        caller = mock.Mock()
        caller.hidden_now.return_value = ({"both"}, {"halfid": "hdevops"})
        with mock.patch.object(self.hide, "cli_module", return_value=caller), \
                mock.patch.object(self.hide, "message_author",
                                  return_value=(JAN, f"customer asked under GDPR to erase {PROFILE}")), \
                mock.patch.object(self.hide.Run, "decide_rows", side_effect=spy):
            self.hide.main(["--requester-id", JAN,
                            "--store", self.store_path, "--apply",
                            "--channel", "C0OPS", "--message-ts", "1793704998.000001"])
        self.assertEqual(seen.get("hidden"), {"both"})
        self.assertEqual(seen.get("half"), {"halfid": "hdevops"})


class Card(Base):
    def test_the_thread_card_carries_every_field_the_lane_defines(self):
        line = self.hide.card("slack-ops:U038:123", ["a", "b"], [{"register_no": 12}],
                              {"hdevops": "https://example.test/hd", "pdp": "https://example.test/pdp"},
                              "pending", "due")
        self.assertTrue(line.startswith("gdpr-hide · slack-ops:U038:123 · 2 ids · register #12 · PRs "))
        self.assertIn("https://example.test/hd", line)
        self.assertIn("https://example.test/pdp", line)
        self.assertTrue(line.endswith("hidden_at pending · letter due"))
        self.assertRegex(line, r"^gdpr-hide · .* · \d+ ids · register #\d+ · PRs .* · hidden_at .* · letter .*$")

    def test_a_deferred_batch_says_which_pr_it_waits_for(self):
        line = self.hide.card("ask", ["a"], [{"register_no": 12}],
                              {"deferred": {"hdevops": "https://example.test/hd-open"}}, "pending", "due")
        self.assertIn("deferred", line)
        self.assertIn("https://example.test/hd-open", line)


class Staff(Base):
    def test_the_staff_allowlist_is_read_from_the_pipeline_not_copied(self):
        allow = self.hide.staff_approvers()
        self.assertEqual(allow, (AARON, JAN, "U0AL36NADEY"))
        # ...and it follows the pipeline's own tuple, not a copy: point the CLI at a different one and watch
        other = os.path.join(self.tmp.name, "gdpr-pipeline.py")
        with open(other, "w") as f:
            f.write('APPROVERS = ("U_NEW_ONE",)\n')
        with mock.patch.object(self.hide, "CLI_PATH", type(self.hide.CLI_PATH)(other)):
            self.assertEqual(self.hide.staff_approvers(), ("U_NEW_ONE",))
        # ...and an unreadable/moved allowlist refuses rather than degrading to a wildcard or an empty list
        with mock.patch.object(self.hide, "CLI_PATH",
                               type(self.hide.CLI_PATH)(os.path.join(self.tmp.name, "nope.py"))):
            with self.assertRaises(SystemExit):
                self.hide.staff_approvers()


if __name__ == "__main__":
    unittest.main()
