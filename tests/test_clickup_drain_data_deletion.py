"""Safety tests for scripts/clickup_drain/data_deletion.py.

This module MOVES customer support tickets (`customer-outcome:complete` closes
one) on the strength of the GDPR register's own records, and the failure it must
never have is closing a ticket for a removal the customer was never told about.
So the tests are written around the two facts that are NOT a completion --
`hidden_at` (the page is down) and `status='closed'` without a confirmation (a
human closed a register row) -- plus the two hard vetoes (counsel's classes,
and the overdue clock).

Stdlib unittest + a fake ClickUp client, no network, matching
tests/test_clickup_todo_dedupe.py.
"""
import ast
import contextlib
import copy
import importlib.util
import io
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import time
import types
import unittest
from datetime import datetime, timezone
from unittest import mock

_SCRIPT = (pathlib.Path(__file__).resolve().parent.parent
           / "scripts" / "clickup_drain" / "data_deletion.py")
_spec = importlib.util.spec_from_file_location("clickup_drain_data_deletion", _SCRIPT)
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)

NOW = datetime(2026, 11, 3, 12, 0, 0, tzinfo=timezone.utc)
PAST = "2026-10-01T00:00:00Z"
FUTURE = "2026-12-01T00:00:00Z"

# The subset of the register's schema this drainer reads. The columns and their
# shapes are gdpr_pipeline/store.py's `erasure_requests` / `erasure_keys` (PR
# #1629); TestRealRegisterSchema proves the real schema still fits this reader.
REGISTER_SCHEMA = """
CREATE TABLE erasure_requests (
  id INTEGER PRIMARY KEY,
  register_no INTEGER UNIQUE,
  status TEXT DEFAULT 'open',
  class TEXT NOT NULL,
  confirmed_at TEXT DEFAULT '',
  due_at TEXT NOT NULL,
  hide_due_at TEXT DEFAULT '',
  hidden_at TEXT DEFAULT '',
  clickup_ids TEXT DEFAULT '[]',
  conversation_id TEXT DEFAULT '',
  note TEXT DEFAULT ''
);
CREATE TABLE erasure_keys (key TEXT PRIMARY KEY, request_id INTEGER NOT NULL);
"""


def row(rid, *, register_no=None, status="open", cls="privacy_erasure",
        confirmed="", due=FUTURE, hidden="", clickup=(), conv="", note=""):
    return {"id": rid, "register_no": register_no or rid, "status": status, "class": cls,
            "confirmed_at": confirmed, "due_at": due, "hide_due_at": "", "hidden_at": hidden,
            "clickup_ids": json.dumps(list(clickup)), "conversation_id": conv, "note": note}


_counter = [0]


def make_register(tmpdir, rows, keys=()):
    _counter[0] += 1
    path = os.path.join(tmpdir, f"erasure-{_counter[0]}.sqlite")
    db = sqlite3.connect(path)
    db.executescript(REGISTER_SCHEMA)
    for r in rows:
        db.execute(
            "INSERT INTO erasure_requests(id, register_no, status, class, confirmed_at, due_at,"
            " hide_due_at, hidden_at, clickup_ids, conversation_id, note)"
            " VALUES (:id, :register_no, :status, :class, :confirmed_at, :due_at, :hide_due_at,"
            " :hidden_at, :clickup_ids, :conversation_id, :note)", r)
    for k, rid in keys:
        db.execute("INSERT INTO erasure_keys(key, request_id) VALUES (?,?)", (k, rid))
    db.commit()
    db.close()
    return path


def task(tid, status="to do", tags=("action:data-deletion",), conv=None):
    t = {"id": tid, "name": f"ticket {tid}", "status": {"status": status},
         "tags": [{"name": n} for n in tags]}
    if conv:
        t["description"] = (f"https://app.intercom.com/a/inbox/dwjzhcge/inbox/"
                            f"conversation/{conv}")
    return t


class FakeClickUp:
    """The two methods this module uses, with the shared client's signatures."""

    def __init__(self, tasks):
        self.tasks = {str(t["id"]): copy.deepcopy(t) for t in tasks}
        self.calls = []
        self.comments = []

    def list_tasks(self, list_id, params, max_pages):
        self.calls.append(("list", list_id))
        return [copy.deepcopy(t) for t in self.tasks.values()]

    def request(self, method, path, body=None, timeout=60):
        self.calls.append((method, path))
        parts = [p for p in path.split("/") if p]
        tid = parts[1]
        t = self.tasks.get(tid)
        if t is None:
            return 404, {"err": "not found"}
        if method == "GET":
            return 200, copy.deepcopy(t)
        if method == "PUT":
            new = str((body or {}).get("status", ""))
            t.setdefault("status", {})["status"] = new
            # ClickUp stamps `date_closed` when a task enters a closed status; the
            # revert orders it against the ledger's close record to tell our close
            # apart from a human re-resolving the ticket later.
            if new == "resolved":
                t["date_closed"] = str(int(time.time() * 1000))
            return 200, copy.deepcopy(t)
        if len(parts) >= 3 and parts[2] == "comment":
            self.comments.append({"task_id": tid, "body": copy.deepcopy(body)})
            return 200, {"id": f"c{len(self.comments)}"}
        tag = parts[3].replace("%3A", ":")
        names = [x.get("name") for x in t.setdefault("tags", [])]
        if method == "POST":
            if tag not in names:
                t["tags"].append({"name": tag})
            return 200, copy.deepcopy(t)
        if method == "DELETE":
            t["tags"] = [x for x in t["tags"] if x.get("name") != tag]
            return 200, copy.deepcopy(t)
        return 400, {"err": "unsupported"}

    def tagset(self, tid):
        return {x.get("name") for x in self.tasks[tid].get("tags") or []}


class DeafComment(FakeClickUp):
    """Refuses the audit-comment POST, everything else answers normally."""

    def __init__(self, tasks, fail=True):
        super().__init__(tasks)
        self.fail = fail

    def request(self, method, path, body=None, timeout=60):
        if method == "POST" and path.endswith("/comment") and self.fail:
            self.calls.append(("POST", path))
            return 500, {"err": "boom"}
        return super().request(method, path, body, timeout)


class FlakyReadback(DeafComment):
    """The status PUT lands, then the FIRST read-back GET answers 503.

    This is the close that ClickUp accepted and the drainer never saw: the exact
    window where `resolve_task()` returns before the audit comment.
    """

    def __init__(self, tasks, fail_gets=1):
        super().__init__(tasks, fail=False)
        self.fail_gets = fail_gets
        self.after_put = 0

    def request(self, method, path, body=None, timeout=60):
        if method == "PUT":
            self.after_put = self.fail_gets     # only the read-back of a close fails
        if method == "GET" and self.after_put > 0:
            self.after_put -= 1
            self.calls.append(("GET", path))
            return 503, {"err": "unavailable"}
        return super().request(method, path, body, timeout)


class StaleBoard(FakeClickUp):
    """The scan snapshot says one thing; the ticket says another (a mid-run retag)."""

    def __init__(self, tasks, stale_tags):
        super().__init__(tasks)
        self.stale_tags = stale_tags

    def list_tasks(self, list_id, params, max_pages):
        self.calls.append(("list", list_id))
        out = []
        for t in self.tasks.values():
            copy_t = copy.deepcopy(t)
            copy_t["tags"] = [{"name": n} for n in self.stale_tags]
            out.append(copy_t)
        return out


class RetaggedDuringRecovery(FakeClickUp):
    """The complete tag POST lands, its read-back GET fails, and by the time the
    verification GET runs a human has retagged the ticket to `action:other`."""

    def __init__(self, tasks):
        super().__init__(tasks)
        self.fail_next_get = False
        self.retagged = False

    def request(self, method, path, body=None, timeout=60):
        if method == "POST" and "/tag/" in path and "complete" in path:
            code, out = super().request(method, path, body, timeout)
            self.fail_next_get = True          # this write's own read-back will fail
            return code, out
        if method == "GET" and self.fail_next_get:
            self.fail_next_get = False
            self.retagged = True               # a human retags it before the re-check
            self.calls.append(("GET", path))
            return 503, {"err": "unavailable"}
        if method == "GET" and self.retagged:
            self.tasks["869aaa"]["tags"] = [{"name": "action:other"},
                                            {"name": "customer-outcome:complete"}]
        return super().request(method, path, body, timeout)


class MutatesThenRaises(FakeClickUp):
    """ClickUp APPLIES the mutation, then the response is lost (a read timeout).

    The ambiguous network outcome QA round 20 reproduced: the write is on the
    ticket and the client never hears about it. A lost response is not evidence
    of absence, so the drainer has to read the ticket and let the read decide.
    """

    def __init__(self, tasks, method="PUT", match=""):
        super().__init__(tasks)
        self.method = method
        self.match = match
        self.fired = False

    def request(self, method, path, body=None, timeout=60):
        if method == self.method and self.match in path and not self.fired:
            self.fired = True
            super().request(method, path, body, timeout)   # the mutation lands
            self.calls.append((method, path))
            raise TimeoutError("read timed out")
        return super().request(method, path, body, timeout)


class RefusesTheReplacement(FakeClickUp):
    """The old outcome is deleted, then the POST of the new one 500s: a hole."""

    def __init__(self, tasks, refuse="customer-outcome:blocked"):
        super().__init__(tasks)
        self.refuse = refuse

    def request(self, method, path, body=None, timeout=60):
        if method == "POST" and self.refuse.replace(":", "%3A") in path:
            self.calls.append(("POST", path))
            return 500, {"err": "boom"}
        return super().request(method, path, body, timeout)


def conv_of(t):
    """Test conv reader (the real one is lib.intercom_link.conv_id_of)."""
    desc = t.get("description") or ""
    return desc.rsplit("/", 1)[-1] if "/conversation/" in desc else ""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.ledger = os.path.join(self.tmp, "data-deletion.jsonl")
        # main() prints its report; keep stdout so a test can assert on it
        self.stdout = []
        self._buf = io.StringIO()
        self._ctx = contextlib.redirect_stdout(self._buf)
        self._ctx.__enter__()
        self.addCleanup(self._close_stdout)

    def _close_stdout(self):
        self._ctx.__exit__(None, None, None)
        self.stdout.append(self._buf.getvalue())

    def run_select(self, rows, board_tasks, keys=()):
        reg = m.load_register(make_register(self.tmp, rows, keys))
        board = {str(t["id"]): t for t in board_tasks}
        return reg, m.select(reg, board, NOW, conv_reader=conv_of)


class NeverCloseOnThePageBeingDown(Base):
    def test_hidden_without_confirmation_never_closes(self):
        # THE rule: hiding is step 3 of 5. The page is down, the letter has not
        # gone out, so the ticket must not say complete.
        _reg, sel = self.run_select(
            [row(1, hidden="2026-10-02T00:00:00Z", clickup=["869aaa"])],
            [task("869aaa")])
        self.assertEqual(sel["complete"], [])
        self.assertEqual(sel["blocked"], [])
        self.assertFalse([w for w in sel["complete"] if w["task_id"] == "869aaa"])
        c = m.counts(sel, _reg, {"869aaa": task("869aaa")}, None)
        self.assertEqual(c["register_hidden_not_confirmed"], 1)
        self.assertEqual(c["writes_written"], 0)

    def test_closed_row_without_confirmation_never_closes(self):
        # A human closed the register row (markdown register COMPLETED). That is
        # not evidence any letter went out: report it, never tag it.
        _reg, sel = self.run_select(
            [row(2, status="closed", clickup=["869bbb"])], [task("869bbb")])
        self.assertEqual(sel["complete"], [])
        self.assertEqual(sel["attention"][0]["register_no"], 2)
        self.assertIn("NO written confirmation", sel["attention"][0]["why"])

    def test_confirmed_row_closes_even_while_the_register_keeps_it_open(self):
        # The register deliberately leaves a confirmed row `open` in `status`
        # (run.confirmations iterates store.all("open")), so the completion test
        # is `confirmed_at`, not `status`. Requiring both would never fire.
        _reg, sel = self.run_select(
            [row(3, status="open", confirmed="2026-10-23T00:00:00Z", clickup=["869ccc"])],
            [task("869ccc")])
        self.assertEqual([w["task_id"] for w in sel["complete"]], ["869ccc"])
        self.assertEqual(sel["complete"][0]["tag"], m.TAG_COMPLETE)

    def test_duplicate_row_is_not_a_completion(self):
        _reg, sel = self.run_select(
            [row(4, status="duplicate", confirmed="2026-10-23T00:00:00Z", clickup=["869ddd"])],
            [task("869ddd")])
        self.assertEqual(sel["complete"], [])

    def test_ticket_id_from_the_keys_table_also_closes(self):
        # erasure_keys is the idempotence record; a link recorded only there must
        # not be the reason a real completion never closes its ticket.
        _reg, sel = self.run_select(
            [row(5, confirmed="2026-10-24T00:00:00Z")], [task("869eee")],
            keys=[("clickup:869eee", 5)])
        self.assertEqual([w["task_id"] for w in sel["complete"]], ["869eee"])


class TheTwoVetoes(Base):
    def test_legal_threat_and_dmca_never_complete(self):
        for cls in ("legal_threat", "dmca_takedown"):
            with self.subTest(cls=cls):
                _reg, sel = self.run_select(
                    [row(10, cls=cls, confirmed="2026-10-23T00:00:00Z", clickup=[f"869{cls[:3]}"])],
                    [task(f"869{cls[:3]}")])
                self.assertEqual(sel["complete"], [])
                self.assertEqual(len(sel["legal_confirmed"]), 1)

    def test_unconfirmed_legal_row_blocks_its_ticket(self):
        _reg, sel = self.run_select(
            [row(11, cls="legal_threat", clickup=["869lll"])], [task("869lll")])
        self.assertEqual([(w["task_id"], w["tag"]) for w in sel["blocked"]],
                         [("869lll", m.TAG_BLOCKED)])
        self.assertIn("register row 11", sel["blocked"][0]["why"])

    def test_overdue_is_reported_and_never_tagged(self):
        _reg, sel = self.run_select(
            [row(12, due=PAST, clickup=["869ooo"])], [task("869ooo")])
        self.assertEqual([o["register_no"] for o in sel["overdue"]], [12])
        self.assertEqual(sel["complete"], [])
        written_tags = {w["tag"] for w in sel["complete"] + sel["blocked"]}
        self.assertNotIn("customer-outcome:not-applicable", written_tags)
        self.assertNotIn(m.TAG_COMPLETE, written_tags)

    def test_one_ticket_two_register_decisions_is_refused_not_both(self):
        # QA round 9: a ticket linked to a CONFIRMED erasure row and to an open
        # counsel row gets queued for `complete` and `blocked`. Written in
        # sequence it ends `resolved` with two outcome tags — the exact ambiguity
        # the shared reader answers None for.
        rows = [row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"]),
                row(2, cls="legal_threat", clickup=["869aaa"])]
        _reg, selected = self.run_select(rows, [task("869aaa")])
        self.assertEqual(len(selected["conflicting"]), 1)
        conflict = selected["conflicting"][0]
        self.assertEqual(conflict["task_id"], "869aaa")
        self.assertEqual(conflict["kinds"], ["blocked", "complete"])
        self.assertEqual(selected["complete"], [])
        self.assertEqual(selected["blocked"], [])
        self.assertIn("two outcome tags", conflict["why"])

        # and the run writes nothing for it, pages, and exits nonzero
        reg = make_register(self.tmp, rows)
        fake = FakeClickUp([task("869aaa")])
        pages = []
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack",
                                  lambda text, ch, *a, **k: pages.append((text, ch))):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion"})
        alerts = [p for p in pages if "CONFLICTING decisions" in p[0]]
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0][1], m.DEFAULT_ALERT_CHANNEL)

    def test_a_closed_row_past_its_date_is_named_not_folded_into_overdue(self):
        # QA round 8: the register's own watchdog reads store.all("open"), so a row
        # a human closed WITHOUT a letter vanishes from the legal clock. OVERDUE
        # stays the register's number; the excluded rows are named with the reason.
        rows = [row(1, status="closed", due=PAST, clickup=["869aaa"])]
        _reg, selected = self.run_select(rows, [])
        self.assertEqual(selected["overdue"], [])            # the register's count
        self.assertEqual(len(selected["attention"]), 1)
        self.assertTrue(selected["attention"][0]["past_due"])
        line = m.overdue_line(selected)
        self.assertIn("ALSO PAST ITS DATE", line)
        self.assertIn("CLOSED WITH NO WRITTEN LETTER", line)
        self.assertIn("#1", line)
        self.assertIn("only open rows", line)

    def test_overdue_counts_counsel_classes_too(self):
        # The register's watchdog counts every class, so this report must too —
        # otherwise the drainer publishes a smaller number than the register and
        # the two systems are back where they started. The row is still never
        # closed on a tag: it is counsel's letter.
        _reg, sel = self.run_select(
            [row(15, cls="legal_threat", due=PAST, clickup=["869lgl"])], [task("869lgl")])
        self.assertEqual([(o["register_no"], o["counsel"]) for o in sel["overdue"]],
                         [(15, True)])
        self.assertEqual(sel["complete"], [])

    def test_closed_row_with_no_ticket_is_not_reported_as_noise(self):
        reg, sel = self.run_select([row(16, status="closed")], [])
        self.assertEqual(sel["attention"], [])
        c = m.counts(sel, reg, {}, None)
        self.assertEqual(c["register_closed_no_confirmation"], 1)

    def test_blocked_line_names_the_register_row_behind_each_ticket(self):
        # "blocked" alone says nothing about WHY; the reason is a register row
        # this drainer must not write, so the digest has to carry the link.
        _reg, sel = self.run_select(
            [row(17, cls="dmca_takedown", clickup=["869dmc"])], [task("869dmc")])
        line = m.blocked_line(sel)
        self.assertIn("counsel 1 ticket(s)", line)
        self.assertIn("869dmc=row 17", line)
        self.assertIn("never closed here", line)

    def test_overdue_line_names_the_tickets_behind_the_clock(self):
        _reg, sel = self.run_select(
            [row(13, due=PAST, clickup=["869ooo"]), row(14, due=PAST)], [task("869ooo")])
        line = m.overdue_line(sel)
        self.assertIn("overdue 2 requests", line)
        self.assertIn("869ooo", line)
        self.assertIn("1 of those rows have no ticket", line)
        self.assertIn("none of these are tagged complete", line)


class TheBoardSide(Base):
    def test_ticket_without_a_register_row_gets_a_work_item_and_no_tag(self):
        reg, sel = self.run_select([], [task("869gap")])
        self.assertEqual([g["task_id"] for g in sel["no_register_row"]], ["869gap"])
        m.record_intake_gaps(self.tmp, sel["no_register_row"], now=NOW)
        spool = os.path.join(self.tmp, "intake-gaps.jsonl")
        item = json.loads(pathlib.Path(spool).read_text().splitlines()[0])
        self.assertEqual(item["clickup_id"], "869gap")
        self.assertEqual(item["owns_retry"], "gdpr-pipeline.py tick")
        self.assertEqual(item["kind"], "register-intake-gap")
        # nothing was written to the board and no register row was invented
        self.assertEqual(sel["complete"] + sel["blocked"], [])
        self.assertEqual(len(reg["rows"]), 0)

    def test_gap_ages_and_clears_itself(self):
        reg, sel = self.run_select([], [task("869gap")])
        for _ in range(3):
            m.record_intake_gaps(self.tmp, sel["no_register_row"], now=NOW)
        state = json.loads(pathlib.Path(os.path.join(self.tmp, "intake-gaps.json")).read_text())
        self.assertEqual(state["869gap"]["runs"], 3)
        m.record_intake_gaps(self.tmp, [], now=NOW)
        state = json.loads(pathlib.Path(os.path.join(self.tmp, "intake-gaps.json")).read_text())
        self.assertEqual(state, {})

    def test_ticket_linked_only_by_conversation_is_link_pending(self):
        # The register knows the request (its conversation is the key); the
        # ticket is not in clickup_ids yet, so the next tick links it and the run
        # after that closes it. Never a gap, never a write today.
        _reg, sel = self.run_select(
            [row(20, confirmed="2026-10-24T00:00:00Z", conv="2154")],
            [task("869tw", conv="2154")])
        self.assertEqual([p["task_id"] for p in sel["link_pending"]], ["869tw"])
        self.assertTrue(sel["link_pending"][0]["confirmed_at"])
        self.assertEqual(sel["no_register_row"], [])
        self.assertEqual(sel["complete"], [])

    def test_terminal_ticket_is_not_a_board_gap(self):
        _reg, sel = self.run_select([], [task("869res", status="resolved")])
        self.assertEqual(sel["no_register_row"], [])
        self.assertEqual([t["task_id"] for t in sel["already_terminal"]], ["869res"])


class Writes(Base):
    def board(self):
        return {"869aaa": task("869aaa")}

    def test_a_completion_labels_and_then_closes(self):
        # `customer_complete()` requires BOTH a terminal status and the complete
        # tag, so labelling without closing would leave the ticket open forever —
        # which is the complaint that started this. Order is tag first, status
        # second: a crash between them leaves an honest, still-open ticket.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "request_id": 1, "register_no": 1, "why": "register row 1 confirmed"}
        res = m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        self.assertEqual(len(res["written"]), 1)
        self.assertEqual(len(res["resolved"]), 1)
        self.assertIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        posts = [c[0] for c in fake.calls]
        self.assertLess(posts.index("POST"), posts.index("PUT"))
        self.assertEqual([r["action"] for r in m.read_ledger(self.ledger)][2],
                         "resolve")

    def test_a_close_leaves_the_reason_on_the_ticket(self):
        # A ticket that closes with no trace cannot be told apart from a human's
        # close, and the reason lives in a register a support person may not have.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "request_id": 19, "register_no": 19,
                    "confirmed_at": "2026-10-24T09:00:00Z", "why": "row 19 confirmed"}
        res = m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        self.assertEqual(res["resolved"][0]["result"]["comment"], "written")
        self.assertEqual(len(fake.comments), 1)
        body = fake.comments[0]["body"]
        self.assertEqual(body["notify_all"], False)          # never emails anyone
        self.assertIn("register row 19", body["comment_text"])
        self.assertIn("confirmed 2026-10-24", body["comment_text"])
        self.assertIn("never on the page being hidden", body["comment_text"])
        self.assertIn("not modified by this job", body["comment_text"])
        ledgered = [r for r in m.read_ledger(self.ledger) if r["action"] == "comment"]
        self.assertEqual([r["result"] for r in ledgered], ["attempted", "written"])
        self.assertEqual(ledgered[-1]["register_no"], 19)

    def test_a_half_finished_completion_is_finished_by_the_next_run(self):
        # The tag read back but the process died before the close. "Already tagged"
        # must not turn that into a ticket that stays open forever.
        half = task("869aaa", tags=("action:data-deletion", m.TAG_COMPLETE))
        fake = FakeClickUp([half])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 5, "confirmed_at": "2026-10-24T00:00:00Z"}
        res = m.execute(fake, [selected], {"869aaa": half}, self.ledger, max_writes=200)
        self.assertEqual(len(res["already_tagged"]), 1)
        self.assertEqual(len(res["resolved"]), 1)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        # and a third run is a clean no-op: terminal now, so nothing is written
        fake2 = FakeClickUp([fake.tasks["869aaa"]])
        res2 = m.execute(fake2, [selected], {"869aaa": fake.tasks["869aaa"]}, self.ledger,
                         max_writes=200)
        self.assertEqual(res2["resolved"], [])
        self.assertEqual(res2["skipped_terminal"], [])

    def test_a_ticket_that_left_this_queue_is_never_written(self):
        # QA #2: the register's link can outlive the ticket's action tag. A
        # reclassified ticket is about something else; closing it would be a
        # false statement about an unrelated request.
        gone = task("869aaa", tags=("action:refund", "team:catalog"))
        fake = FakeClickUp([copy.deepcopy(gone)])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 7, "confirmed_at": "2026-10-24T00:00:00Z"}
        # board scan does not have it (it is filtered by the action tag), so the
        # fallback GET is the only place the tag can be checked
        res = m.execute(fake, [selected], {}, self.ledger, max_writes=200)
        self.assertEqual(len(res["skipped_untagged"]), 1)
        self.assertEqual(res["written"], [])
        self.assertEqual(res["resolved"], [])
        self.assertEqual(fake.calls, [("GET", "/task/869aaa")])
        self.assertIn("no longer carries `action:data-deletion`", res["skipped_untagged"][0]["why"])

    def test_a_comment_that_fails_never_undoes_the_close(self):
        # The close is a fact once it reads back. A missing note degrades the audit
        # trail; it does not make the ticket open again.
        class NoComments(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if path.endswith("/comment"):
                    self.calls.append((method, path))
                    return 500, {"err": "nope"}
                return super().request(method, path, body, timeout)

        fake = NoComments([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        res = m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        self.assertEqual(res["resolved"][0]["result"]["result"], "resolved")
        self.assertEqual(res["resolved"][0]["result"]["comment"], "failed")
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        failed = [r for r in m.read_ledger(self.ledger)
                  if r["action"] == "comment" and r["result"] == "failed"]
        self.assertEqual(len(failed), 1)

    def test_revert_leaves_a_ticket_a_human_has_moved(self):
        # QA #3: revert once, a human sets it `in progress`, revert again — their
        # change must survive. Only the `resolved` this drainer wrote is undone.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        fake.request("PUT", "/task/869aaa", {"status": "in progress"})   # a human
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["left_for_human"][0]["was"], "in progress")
        self.assertEqual(out["reopened"], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "in progress")

    def test_revert_is_idempotent_and_reports_a_partial_undo(self):
        # A second revert on an already-restored ticket PUTs nothing; a delete
        # that fails makes the revert exit nonzero instead of claiming success.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        m.revert(fake, self.ledger)
        puts = [c for c in fake.calls if c[0] == "PUT"]
        out = m.revert(fake, self.ledger)
        self.assertEqual([c for c in fake.calls if c[0] == "PUT"], puts)   # no second PUT
        self.assertEqual(out["reopened"], [])

        class NoDelete(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "DELETE":
                    self.calls.append((method, path))
                    return 500, {"err": "nope"}
                return super().request(method, path, body, timeout)

        led2 = os.path.join(self.tmp, "second.jsonl")     # a fresh ledger, no prior undo
        fake2 = NoDelete([task("869aaa")])
        m.execute(fake2, [selected], {"869aaa": task("869aaa")}, led2, max_writes=200)
        with mock.patch.object(m, "_client", lambda: fake2):
            code = m.main(["--register", make_register(self.tmp, [row(1)]),
                           "--state-dir", self.tmp, "--revert", led2,
                           "--kill-file", os.path.join(self.tmp, "off"), "--no-notify"])
        self.assertEqual(code, 6)

    def test_a_removal_that_did_not_read_back_is_retried_not_assumed(self):
        # QA round 2: DELETE 200 but the tag is still on the ticket (or the
        # read-back failed) = `still_present`. Treating that as undone makes the
        # next revert skip it and exit 0 while the tag is on the board.
        class DeafDelete(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "DELETE":
                    self.calls.append((method, path))
                    return 200, {}          # claims success, removes nothing
                return super().request(method, path, body, timeout)

        reg = make_register(self.tmp, [row(1)])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        deaf = DeafDelete([task("869aaa")])
        m.execute(deaf, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        out = m.revert(deaf, self.ledger)
        self.assertEqual(len(out["still_present"]), 1)
        self.assertIn(m.TAG_COMPLETE, deaf.tagset("869aaa"))
        with mock.patch.object(m, "_client", lambda: deaf):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                     "--revert", self.ledger, "--no-notify",
                                     "--kill-file", os.path.join(self.tmp, "off")]), 6)
        # a second revert with a working client retries and confirms
        working = FakeClickUp([deaf.tasks["869aaa"]])
        out2 = m.revert(working, self.ledger)
        self.assertEqual(len(out2["removed"]), 1)
        self.assertNotIn(m.TAG_COMPLETE, working.tagset("869aaa"))

    def test_an_unreadable_ledger_is_never_a_successful_revert(self):
        # QA round 2: a mistyped, missing or truncated ledger read as [] and the
        # revert exited 0 having undone nothing.
        reg = make_register(self.tmp, [row(1)])
        fake = FakeClickUp([task("869aaa")])
        missing = os.path.join(self.tmp, "nope.jsonl")
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--revert", missing,
                           "--no-notify", "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 2)
        truncated = os.path.join(self.tmp, "truncated.jsonl")
        with open(truncated, "w") as fh:
            fh.write('{"action": "add", "task_id": "869aaa", "result": "written", '
                     '"tag": "customer-outcome:complete"}\n{"action": "add", "task_id": "869a')
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--revert", truncated,
                           "--no-notify", "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 2)
        self.assertEqual([c for c in fake.calls if c[0] != "list"], [])   # no write on a broken ledger

    def test_a_read_back_that_could_not_be_read_is_not_a_removal(self):
        # QA round 3: DELETE 200 + GET 500 used to land in `removed` (tag_names({})
        # is [], and "not in []" reads as gone). Nobody observed that removal.
        class BlindReadback(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "DELETE":
                    super().request(method, path, body, timeout)      # removed for real
                    return 200, {}
                if method == "GET" and any(c[0] == "DELETE" for c in self.calls[-2:]):
                    self.calls.append((method, path))
                    return 500, {"err": "read-back down"}
                return super().request(method, path, body, timeout)

        reg = make_register(self.tmp, [row(1)])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        fake = BlindReadback([task("869aaa")])
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["removed"], [])
        self.assertEqual(len(out["still_present"]), 1)
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                     "--revert", self.ledger, "--no-notify",
                                     "--kill-file", os.path.join(self.tmp, "off")]), 6)

    def test_revert_does_not_reopen_a_ticket_whose_tag_it_could_not_remove(self):
        # QA round 3: reopening it while `complete` is still attached makes the
        # next apply run close it again — churn, and a status write for nothing.
        class NoDelete(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "DELETE":
                    self.calls.append((method, path))
                    return 500, {"err": "nope"}
                return super().request(method, path, body, timeout)

        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        fake = NoDelete([task("869aaa")])
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        puts_before = [c for c in fake.calls if c[0] == "PUT"]      # the close itself
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["status_kept"][0]["task_id"], "869aaa")
        self.assertEqual(out["reopened"], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        self.assertIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        self.assertEqual([c for c in fake.calls if c[0] == "PUT"], puts_before)

    def test_a_tag_written_again_after_a_revert_is_removed_by_the_next_revert(self):
        # QA round 4: "pairs ever removed" is not "pairs still on the board".
        # add -> revert (removed) -> apply adds again -> revert used to skip it and
        # report success with the tag attached.
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        fake = FakeClickUp([task("869aaa")])
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        m.revert(fake, self.ledger)
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        m.execute(fake, [selected], copy.deepcopy(fake.tasks["869aaa"]), self.ledger, max_writes=200)
        self.assertIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        out = m.revert(fake, self.ledger)
        self.assertEqual(len(out["removed"]), 1)
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))

    def test_a_probe_cleans_up_an_add_that_never_read_back(self):
        # QA round 4: POST accepted + confirmation GET failed. The tag may be ON
        # the ticket; a canary that walks away from it has damaged the board.
        class BlindAdd(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                res = super().request(method, path, body, timeout)
                if method == "POST":
                    self._blind = True
                elif method == "GET" and getattr(self, "_blind", False):
                    self._blind = False
                    return 500, {"err": "read-back down"}
                return res

        reg = make_register(self.tmp, [row(1)])
        fake = BlindAdd([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack"):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--probe", "869aaa",
                           "--ledger", os.path.join(self.tmp, "probe.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off"), "--no-notify"])
        self.assertEqual(code, 5)                       # unproven, not a success
        self.assertNotIn(m.TAG_BLOCKED, fake.tagset("869aaa"))   # and not left behind
        results = [(r["mode"], r["action"], r["result"])
                   for r in m.read_ledger(os.path.join(self.tmp, "probe.jsonl"))
                   if r.get("result") != "attempted"]
        self.assertIn(("probe", "add", "readback_missing"), results)
        self.assertIn(("probe-revert", "remove", "removed"), results)

    def test_a_crash_between_the_post_and_its_record_is_still_undone(self):
        # QA round 5: the ledger record is written BEFORE the POST, so a crash in
        # between leaves `result: attempted` and nothing else. The tag may be on
        # the ticket. Revert must look, then remove.
        def ledger_with(*records):
            path = os.path.join(self.tmp, "crash.jsonl")
            with open(path, "w") as fh:
                for r in records:
                    fh.write(json.dumps(r) + "\n")
            return path

        attempted = {"at": "2026-11-04T00:00:00Z", "mode": "apply", "action": "add",
                     "task_id": "869aaa", "tag": m.TAG_COMPLETE, "result": "attempted"}
        present = FakeClickUp([task("869aaa", tags=("action:data-deletion", m.TAG_COMPLETE))])
        out = m.revert(present, ledger_with(attempted))
        self.assertEqual(len(out["removed"]), 1)
        self.assertNotIn(m.TAG_COMPLETE, present.tagset("869aaa"))

        absent_fake = FakeClickUp([task("869aaa")])
        out = m.revert(absent_fake, ledger_with(attempted))
        self.assertEqual(len(out["absent"]), 1)
        self.assertEqual(out["removed"], [])
        self.assertEqual([c for c in absent_fake.calls if c[0] == "DELETE"], [])

        # and a crash between the status PUT and its record: the ticket IS
        # resolved, so the revert puts back the recorded `before_status`
        landed = FakeClickUp([task("869aaa", status="resolved",
                                   tags=("action:data-deletion", m.TAG_COMPLETE))])
        resolve = {"at": "2026-11-04T00:00:01Z", "mode": "apply", "action": "resolve",
                   "task_id": "869aaa", "before_status": "to do", "result": "attempted"}
        out = m.revert(landed, ledger_with(attempted, resolve))
        self.assertEqual(len(out["reopened"]), 1)
        self.assertEqual(landed.tasks["869aaa"]["status"]["status"], "to do")

    def test_revert_ignores_the_audit_comment(self):
        # A comment cannot be un-said, so revert must not treat it as a write to undo.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                    "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["removed"][0]["tag"], m.TAG_COMPLETE)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
        self.assertEqual(out["skipped"], [])

    def test_a_blocked_ticket_keeps_its_status(self):
        # Counsel's ticket is not finished by anything this drainer can do.
        fake = FakeClickUp([task("869lll")])
        selected = {"task_id": "869lll", "tag": m.TAG_BLOCKED, "kind": "blocked"}
        res = m.execute(fake, [selected], {"869lll": task("869lll")}, self.ledger, max_writes=200)
        self.assertEqual(len(res["written"]), 1)
        self.assertEqual(res["resolved"], [])
        self.assertEqual(fake.tasks["869lll"]["status"]["status"], "to do")

    def test_a_stale_outcome_tag_is_replaced_never_doubled(self):
        # Two outcome tags make customer_outcome_of() return None — consumers fail
        # closed — so a writer that only ADDS silently unsets the outcome.
        stale = task("869aaa", tags=("action:data-deletion", "customer-outcome:partial"))
        fake = FakeClickUp([copy.deepcopy(stale)])
        selected = {"task_id": "869aaa", "tag": m.TAG_BLOCKED, "kind": "blocked"}
        m.execute(fake, [selected], {"869aaa": copy.deepcopy(stale)}, self.ledger, max_writes=200)
        held = {t for t in fake.tagset("869aaa") if t.startswith("customer-outcome:")}
        self.assertEqual(held, {m.TAG_BLOCKED})
        self.assertEqual([c[0] for c in fake.calls if c[0] in ("POST", "DELETE")],
                         ["DELETE", "POST"])

    def test_already_tagged_is_not_rewritten(self):
        # No tag is ever posted or deleted twice. (A `complete` tag on an OPEN
        # ticket is the half-state a crash leaves; that one still gets the close,
        # pinned by test_a_half_finished_completion_is_finished_by_the_next_run.)
        tagged = task("869aaa", tags=("action:data-deletion", m.TAG_BLOCKED))
        fake = FakeClickUp([copy.deepcopy(tagged)])
        selected = {"task_id": "869aaa", "tag": m.TAG_BLOCKED, "kind": "blocked"}
        res = m.execute(fake, [selected], {"869aaa": copy.deepcopy(tagged)},
                        self.ledger, max_writes=200)
        self.assertEqual(len(res["already_tagged"]), 1)
        self.assertEqual(len(res["written"]), 0)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "DELETE")], [])

    def test_resolved_ticket_is_skipped_not_tagged(self):
        fake = FakeClickUp([task("869aaa", status="resolved")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        res = m.execute(fake, [selected], {"869aaa": task("869aaa", status="resolved")},
                        self.ledger, max_writes=200)
        self.assertEqual(len(res["skipped_terminal"]), 1)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "DELETE", "PUT")], [])

    def test_the_cap_bounds_one_run(self):
        # The budget is spent in MUTATIONS: labelling + closing one ticket is 3
        # (POST, PUT, comment), so a cap of 2 buys nothing at all.
        writes = [{"task_id": f"869{i}", "tag": m.TAG_COMPLETE, "kind": "complete"}
                  for i in range(5)]
        board = {w["task_id"]: task(w["task_id"]) for w in writes}
        fake = FakeClickUp([task(w["task_id"]) for w in writes])
        res = m.execute(fake, writes, board, self.ledger, max_writes=2)
        self.assertEqual(res["written"], [])
        self.assertEqual(res["capped_out"], 5)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])

        fake = FakeClickUp([task(w["task_id"]) for w in writes])
        res = m.execute(fake, writes, board, self.ledger, max_writes=6)
        self.assertEqual(len(res["written"]), 2)
        self.assertEqual(len(res["resolved"]), 2)
        self.assertEqual(res["capped_out"], 3)
        self.assertEqual(res["mutations"], 6)
        self.assertLessEqual(len([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")]), 6)

    def test_a_replacement_that_also_closes_is_budgeted_as_four_mutations(self):
        # QA round 5: a per-ticket cap let one completion over a conflicting
        # outcome tag issue DELETE + POST + PUT + comment while spending 1.
        stale = task("869aaa", tags=("action:data-deletion", m.TAG_BLOCKED))
        writes = [{"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                   "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}]
        board = {"869aaa": copy.deepcopy(stale)}
        tight = FakeClickUp([copy.deepcopy(stale)])
        res = m.execute(tight, writes, board, self.ledger, max_writes=3)
        self.assertEqual(res["written"], [])
        self.assertEqual(res["capped_out"], 1)
        self.assertEqual([c for c in tight.calls if c[0] in ("POST", "PUT", "DELETE")], [])

        roomy = FakeClickUp([copy.deepcopy(stale)])
        res = m.execute(roomy, writes, board, self.ledger, max_writes=4)
        self.assertEqual(len(res["written"]), 1)
        self.assertEqual(res["mutations"], 4)
        self.assertEqual(roomy.tasks["869aaa"]["status"]["status"], "resolved")
        self.assertEqual(roomy.tagset("869aaa"), {m.TAG_COMPLETE, "action:data-deletion"})

    def test_every_stale_outcome_tag_is_paid_for_from_the_budget(self):
        # QA round 6: `replace_outcome` deletes EVERY outcome tag that is not the
        # desired one, so a ticket with two stale tags costs 2 DELETEs + POST + PUT
        # + comment. Reserving one DELETE undercounted by one, per stale tag.
        stale = task("869aaa", tags=("action:data-deletion", m.TAG_BLOCKED,
                                     "customer-outcome:partial"))
        writes = [{"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete",
                   "register_no": 1, "confirmed_at": "2026-10-24T00:00:00Z"}]
        board = {"869aaa": copy.deepcopy(stale)}
        tight = FakeClickUp([copy.deepcopy(stale)])
        res = m.execute(tight, writes, board, self.ledger, max_writes=4)
        self.assertEqual(res["written"], [])
        self.assertEqual(res["capped_out"], 1)
        self.assertEqual([c for c in tight.calls if c[0] in ("POST", "PUT", "DELETE")], [])

        roomy = FakeClickUp([copy.deepcopy(stale)])
        res = m.execute(roomy, writes, board, self.ledger, max_writes=5)
        self.assertEqual(len(res["written"]), 1)
        self.assertEqual(res["mutations"], 5)          # 2 DELETE + POST + PUT + comment
        mutating = [c for c in roomy.calls if c[0] in ("POST", "PUT", "DELETE")]
        self.assertEqual(len(mutating), 5)
        self.assertLessEqual(len(mutating), res["mutations"])
        self.assertEqual(roomy.tagset("869aaa"), {m.TAG_COMPLETE, "action:data-deletion"})

    def test_a_linked_ticket_that_cannot_be_read_fails_the_run(self):
        # QA round 5: an unreadable linked ticket was recorded as
        # `skipped_terminal`, so a live open ticket with a confirmed register row
        # behind it left the unit green and un-paged.
        class NoGet(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "GET":
                    self.calls.append((method, path))
                    return 500, {"err": "down"}
                return super().request(method, path, body, timeout)

        # the ticket is NOT on the scanned board, so the fallback GET is the only
        # way to learn anything about it — and that GET is what fails
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                           clickup=["869zzz"])])
        fake = NoGet([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)

    def test_the_hard_cap_cannot_be_raised_by_a_flag(self):
        writes = [{"task_id": f"869{i}", "tag": m.TAG_COMPLETE, "kind": "complete"}
                  for i in range(3)]
        fake = FakeClickUp([task(w["task_id"]) for w in writes])
        board = {w["task_id"]: task(w["task_id"]) for w in writes}
        res = m.execute(fake, writes, board, self.ledger, max_writes=10_000)
        self.assertEqual(len(res["written"]), 3)          # 3 < 200, the real cap
        self.assertEqual(m.MAX_WRITES_HARD, 200)

    def test_a_write_that_did_not_read_back_is_caught_before_it_is_claimed(self):
        # The POST says 200 but the tag is not on the ticket: the write is
        # reported, ledgered as unconfirmed, and never counted as landed.
        class Lying(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST":
                    self.calls.append((method, path))
                    return 200, {}
                return super().request(method, path, body, timeout)

        fake = Lying([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        res = m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        self.assertEqual(res["written"], [])
        self.assertEqual(len(res["readback_missing"]), 1)
        self.assertEqual(res["resolved"], [])             # never closed unlabelled
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_verify_pending_refuses_an_ambiguous_outcome(self):
        # QA round 7: a stale tag whose DELETE "succeeded" but did not take effect
        # leaves complete + blocked. `customer_outcome_of()` returns None for that,
        # so promoting it to confirmed would CLOSE a ticket whose outcome no
        # consumer can read.
        both = task("869aaa", tags=("action:data-deletion", m.TAG_COMPLETE, m.TAG_BLOCKED))
        item = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        ok, missing = m.verify_pending(FakeClickUp([both]), [item], self.ledger)
        self.assertEqual(ok, [])
        self.assertEqual(len(missing), 1)
        self.assertIn("must be exactly one", missing[0]["why"])
        from lib import customer_outcome as co
        self.assertIsNone(co.customer_outcome_of(both))     # the reason it cannot close

        # ...and the ticket is NOT closed on it
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                           clickup=["869aaa"])])
        class DeafDelete(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "DELETE":
                    self.calls.append((method, path))
                    return 200, {}          # accepted, and the stale tag survives
                return super().request(method, path, body, timeout)

        fake = DeafDelete([copy.deepcopy(both)])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_verify_pending_confirms_what_actually_landed(self):
        fake = FakeClickUp([task("869aaa", tags=("action:data-deletion", m.TAG_COMPLETE))])
        w = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        ok, missing = m.verify_pending(fake, [w], self.ledger)
        self.assertEqual([x["task_id"] for x in ok], ["869aaa"])
        self.assertEqual(missing, [])
        fake2 = FakeClickUp([task("869bbb")])
        ok2, missing2 = m.verify_pending(fake2, [{**w, "task_id": "869bbb"}], self.ledger)
        self.assertEqual(ok2, [])
        self.assertEqual(len(missing2), 1)

    def test_revert_removes_only_what_the_ledger_recorded(self):
        fake = FakeClickUp([task("869aaa", tags=("action:data-deletion", "escalation:x")),
                            task("869bbb", tags=("action:data-deletion", "escalation:x"))])
        m.add_tag(fake, fake.tasks["869aaa"], m.TAG_COMPLETE, self.ledger)
        out = m.revert(fake, self.ledger)
        self.assertEqual(len(out["removed"]), 1)
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        # a tag the drainer did not add is never touched
        self.assertIn("escalation:x", fake.tagset("869bbb"))
        # and a second revert is a no-op
        self.assertEqual(len(m.revert(fake, self.ledger)["removed"]), 0)

    def test_revert_never_removes_a_tag_our_failed_write_did_not_add(self):
        # QA round 21: `add_tag` records `attempted` then `failed` when the POST is
        # rejected (or a read proves it did not land). The replay used to leave that
        # pair live, so a LATER writer's `customer-outcome:complete` looked like ours
        # and `--revert` DELETEd it — a rollback reaching past its own write.
        class RejectsThePost(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST" and "/tag/" in path:
                    self.calls.append((method, path))
                    return 400, {"err": "rejected"}
                return super().request(method, path, body, timeout)

        fake = RejectsThePost([task("869aaa")])
        res = m.add_tag(fake, fake.tasks["869aaa"], m.TAG_COMPLETE, self.ledger)
        self.assertEqual(res["result"], "failed")
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        # somebody else answers the same question afterwards
        fake.tasks["869aaa"]["tags"].append({"name": m.TAG_COMPLETE})
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["removed"], [])
        self.assertIn(m.TAG_COMPLETE, fake.tagset("869aaa"))

    def test_revert_still_tries_a_write_whose_readback_was_missing(self):
        # The other side of the same rule: `readback_missing` is NOT a definitive
        # failure — the POST may have landed — so the pair stays live and a revert
        # must still look at the ticket.
        class UnreadableAfterPost(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST" and "/tag/" in path:
                    super().request(method, path, body, timeout)
                    self.calls.append((method, path))
                    return 503, {"err": "unavailable"}
                if method == "GET" and self.calls and self.calls[-1][0] == "POST":
                    self.calls.append((method, path))
                    return 503, {"err": "unavailable"}
                return super().request(method, path, body, timeout)

        fake = UnreadableAfterPost([task("869aaa")])
        res = m.add_tag(fake, fake.tasks["869aaa"], m.TAG_COMPLETE, self.ledger)
        self.assertEqual(res["result"], "readback_missing")
        self.assertIn(m.TAG_COMPLETE, fake.tagset("869aaa"))
        out = m.revert(fake, self.ledger)
        self.assertEqual(len(out["removed"]), 1)
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))

    def test_revert_reopens_a_ticket_it_closed(self):
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        out = m.revert(fake, self.ledger)
        self.assertEqual(len(out["reopened"]), 1)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))

    def test_revert_does_not_reopen_a_ticket_a_human_closed_again(self):
        # QA round 23: `resolved` alone cannot tell our close apart from a human
        # re-resolving a ticket we already reopened, so a later revert reopened their
        # decision. The ticket's own close time settles it.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        fake.tasks["869aaa"]["date_closed"] = str(int(time.time() * 1000) + 3_600_000)
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["reopened"], [])
        self.assertEqual(len(out["left_for_human"]), 1)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")

    def test_a_restore_that_landed_before_the_crash_is_settled_by_the_next_revert(self):
        # QA round 24: the `attempted` restore row precedes the PUT, but replay
        # ignored it, so a PUT that landed and then lost its result record left the
        # close debt live. A human re-resolving the ticket inside the close slack
        # could then have that newer decision reopened by a later revert.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        # the restore PUT lands, then the process dies before the result record
        fake.tasks["869aaa"]["status"]["status"] = "to do"
        m.append_ledger(self.ledger, {"at": m._now_iso(), "mode": "revert",
                                      "action": "restore-status", "task_id": "869aaa",
                                      "tag": "", "status": "", "result": "attempted"})
        out = m.revert(fake, self.ledger)
        self.assertEqual([r["task_id"] for r in out["already_at_target"]], ["869aaa"])
        # the debt is paid, so a human re-resolving the ticket is not reopened
        fake.tasks["869aaa"]["status"]["status"] = "resolved"
        fake.tasks["869aaa"]["date_closed"] = str(int(time.time() * 1000) + 60_000)
        out2 = m.revert(fake, self.ledger)
        self.assertEqual(out2["reopened"], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")

    def test_an_interrupted_restore_never_reopens_a_human_close(self):
        # QA round 25: the `attempted` restore row only settles when a later GET sees
        # the TARGET status. If the PUT never landed and a human re-resolved the
        # ticket inside the five-minute close slack, the ticket looks exactly like our
        # own close, so the close-time guard cannot tell them apart and the next revert
        # reopened the human's decision. Refuse instead.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        # the restore PUT never landed, then the process died before its result record
        m.append_ledger(self.ledger, {"at": m._now_iso(), "mode": "revert",
                                      "action": "restore-status", "task_id": "869aaa",
                                      "tag": "", "status": "", "result": "attempted"})
        # a human re-resolves it, well inside the five-minute close slack
        fake.tasks["869aaa"]["status"]["status"] = "resolved"
        fake.tasks["869aaa"]["date_closed"] = str(int(time.time() * 1000) + 30_000)
        out = m.revert(fake, self.ledger)
        self.assertEqual(out["reopened"], [])
        self.assertEqual([r["task_id"] for r in out["left_for_human"]], ["869aaa"])
        self.assertIn("interrupted", out["left_for_human"][0]["why"])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")

    def test_the_status_restore_is_ledgered_before_the_put(self):
        # A restore that lands and then loses its result record must not leave the
        # close looking active, so the `attempted` line is written first.
        fake = FakeClickUp([task("869aaa")])
        selected = {"task_id": "869aaa", "tag": m.TAG_COMPLETE, "kind": "complete"}
        m.execute(fake, [selected], {"869aaa": task("869aaa")}, self.ledger, max_writes=200)
        m.revert(fake, self.ledger)
        restores = [r for r in m.read_ledger(self.ledger) if r.get("action") == "restore-status"]
        self.assertEqual([r["result"] for r in restores], ["attempted", "restored"])

    def test_probe_writes_the_weaker_claim_and_undoes_it(self):
        fake = FakeClickUp([task("869aaa")])
        out = m.probe(fake, "869aaa", self.ledger, board={"869aaa": task("869aaa")})
        self.assertEqual(out["probe"]["result"], "written")
        self.assertEqual(out["reverted"]["result"], "removed")
        self.assertEqual(out["probe"]["tag"], m.TAG_BLOCKED)
        self.assertNotIn(m.TAG_BLOCKED, fake.tagset("869aaa"))
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
        # both halves stay in the ledger, so a crash between them is revertible
        modes = [r["mode"] for r in m.read_ledger(self.ledger)]
        self.assertEqual(set(modes), {"probe", "probe-revert"})
        self.assertEqual(len(modes), 4)          # attempted + result for each half

    def test_a_probe_whose_cleanup_failed_is_not_a_success(self):
        # QA #5: the probe is a canary. A canary that leaves `blocked` on a live
        # ticket and reports success is worse than no canary.
        class NoDelete(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "DELETE":
                    self.calls.append((method, path))
                    return 500, {"err": "nope"}
                return super().request(method, path, body, timeout)

        reg = make_register(self.tmp, [row(1)])
        fake = NoDelete([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack"):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--probe", "869aaa",
                           "--ledger", os.path.join(self.tmp, "probe.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off"), "--no-notify"])
        self.assertEqual(code, 5)
        self.assertIn(m.TAG_BLOCKED, fake.tagset("869aaa"))   # it really is still there

    def test_probe_refuses_a_ticket_that_already_has_an_outcome(self):
        tagged = task("869aaa", tags=("action:data-deletion", "customer-outcome:partial"))
        fake = FakeClickUp([copy.deepcopy(tagged)])
        with self.assertRaises(m.RegisterUnavailable):
            m.probe(fake, "869aaa", self.ledger, board={"869aaa": copy.deepcopy(tagged)})


class TheModuleHoldsNoSendCapability(unittest.TestCase):
    def test_it_does_not_import_the_register_or_its_sender(self):
        tree = ast.parse(_SCRIPT.read_text())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(a.name for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add(node.module or "")
        self.assertFalse([i for i in imported if i.startswith("gdpr_pipeline")],
                         f"the drainer must not import the register/sender: {imported}")
        # ...and nothing in the loaded module graph of the drainer is the register
        held = [v.__name__ for v in vars(m).values()
                if isinstance(v, types.ModuleType) and v.__name__.startswith("gdpr")]
        self.assertEqual(held, [])

    def test_it_has_no_intercom_or_mail_code_path(self):
        # Check the CODE's string literals, not the prose: the docstring explains
        # where the message comes from, and a comment is not a code path.
        tree = ast.parse(_SCRIPT.read_text())
        docstrings = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef)):
                if node.body and isinstance(node.body[0], ast.Expr) \
                        and isinstance(node.body[0].value, ast.Constant):
                    docstrings.add(id(node.body[0].value))
        literals = [n.value.lower() for n in ast.walk(tree)
                    if isinstance(n, ast.Constant) and isinstance(n.value, str)
                    and id(n) not in docstrings]
        for forbidden in ("api.intercom.io", "intercom.io", "intercom-ops-write", "gog",
                          "gmail", "erasure_sends", "begin_send", "smtp"):
            self.assertFalse([lit for lit in literals if forbidden in lit],
                             f"a send path leaked into the drainer: {forbidden}")

    def test_it_writes_only_the_two_contract_tags(self):
        self.assertEqual({m.TAG_COMPLETE, m.TAG_BLOCKED}, {t for t in m.VALID_OUTCOME_TAGS
                                                          if t in (m.TAG_COMPLETE, m.TAG_BLOCKED)})
        self.assertEqual(m.TAG_COMPLETE, "customer-outcome:complete")
        self.assertEqual(m.TAG_BLOCKED, "customer-outcome:blocked")

    def test_tag_names_match_the_shared_contract_when_it_is_present(self):
        try:
            sys.path.insert(0, str(pathlib.Path(_SCRIPT).resolve().parents[1]))
            from lib.customer_outcome import VALID_OUTCOMES, outcome_tag  # noqa: F401
        except ImportError:
            self.skipTest("scripts/lib/customer_outcome.py is not merged yet "
                          "(hydra PR #1706); the literals above are pinned to it")
        self.assertEqual(m.VALID_OUTCOME_TAGS,
                         {outcome_tag(o) for o in VALID_OUTCOMES})


class TheRegisterIsReadOnly(Base):
    def test_the_connection_cannot_write(self):
        path = make_register(self.tmp, [row(1)])
        db = m.open_register(path)
        self.addCleanup(db.close)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("INSERT INTO erasure_requests(id, class, due_at) VALUES (99,'x','y')")
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("UPDATE erasure_requests SET status='closed'")

    def test_a_missing_register_fails_closed(self):
        code = m.main(["--register", os.path.join(self.tmp, "nope.sqlite"),
                       "--board-json", self._dump([]), "--state-dir", self.tmp,
                       "--no-notify", "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 2)

    def _dump(self, tasks):
        p = os.path.join(self.tmp, "board.json")
        pathlib.Path(p).write_text(json.dumps({"tasks": tasks}))
        return p


class TheRunEndToEnd(Base):
    def dump(self, tasks):
        p = os.path.join(self.tmp, "board.json")
        pathlib.Path(p).write_text(json.dumps({"tasks": tasks}))
        return p

    def test_dry_run_is_the_default_and_writes_nothing(self):
        reg = make_register(self.tmp, [
            row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"]),
            row(2, cls="legal_threat", clickup=["869lll"]),
            row(3, hidden="2026-10-02T00:00:00Z", clickup=["869hid"]),
            row(4, due=PAST, clickup=["869over"]),
        ])
        fake = FakeClickUp([task("869aaa"), task("869lll"), task("869hid"), task("869over")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "DELETE")], [])
        self.assertFalse(os.path.exists(self.ledger))

    def test_apply_tags_complete_and_blocked_and_nothing_else(self):
        reg = make_register(self.tmp, [
            row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"]),
            row(2, cls="legal_threat", clickup=["869lll"]),
            row(3, hidden="2026-10-02T00:00:00Z", clickup=["869hid"]),
            row(4, due=PAST, clickup=["869over"]),
            row(5, status="closed", clickup=["869closed"]),
        ])
        fake = FakeClickUp([task(t) for t in ("869aaa", "869lll", "869hid", "869over", "869closed")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", m.TAG_COMPLETE})
        self.assertEqual(fake.tagset("869lll"), {"action:data-deletion", m.TAG_BLOCKED})
        for untouched in ("869hid", "869over", "869closed"):
            self.assertEqual(fake.tagset(untouched), {"action:data-deletion"},
                             f"{untouched} must not be tagged")

    def test_revert_puts_the_replaced_outcome_back(self):
        # QA round 17: apply removes the prior outcome tag and adds `complete`;
        # `--revert` removed `complete`, reopened the ticket, and reported a clean undo
        # while leaving it with NO outcome at all.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        prior = "customer-outcome:needs-customer"
        fake = FakeClickUp([task("869aaa", tags=("action:data-deletion", prior))])
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--no-notify", "--ledger", ledger,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 0)
            self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", m.TAG_COMPLETE})
            self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--revert",
                                     ledger, "--kill-file", os.path.join(self.tmp, "off")]), 0)
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", prior})
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_revert_restores_the_outcome_a_blocked_write_replaced(self):
        # QA round 18: restoration iterated the CLOSE records, so a `blocked`
        # replacement (which never closes anything) lost the prior outcome on revert.
        reg = make_register(self.tmp, [row(1, cls="legal_threat", clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        prior = "customer-outcome:needs-customer"
        fake = FakeClickUp([task("869aaa", tags=("action:data-deletion", prior))])
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--no-notify", "--ledger", ledger,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 0)
            self.assertEqual(fake.tagset("869aaa"),
                             {"action:data-deletion", m.TAG_BLOCKED})
            self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--revert",
                                     ledger, "--kill-file", os.path.join(self.tmp, "off")]), 0)
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", prior})

    def test_a_replacement_that_deleted_the_old_tag_then_failed_still_reverts(self):
        # QA round 19: DELETE of `needs-customer` confirmed, POST of `blocked` 500s.
        # The ticket is left with NO outcome, and the revert had nothing of ours to
        # remove, so it reported success and left the hole.
        reg = make_register(self.tmp, [row(1, cls="legal_threat", clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        prior = "customer-outcome:needs-customer"
        fake = RefusesTheReplacement([task("869aaa", tags=("action:data-deletion", prior))])
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--no-notify", "--ledger", ledger,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 5)
            self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion"})   # the hole
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--revert",
                                     ledger, "--kill-file", os.path.join(self.tmp, "off")]), 0)
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", prior})

    def test_revert_is_idempotent_over_a_restored_outcome(self):
        # QA round 18: the re-add was ledgered as an ordinary write, so running
        # `--revert` a second time removed the outcome the first revert had restored.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        prior = "customer-outcome:needs-customer"
        fake = FakeClickUp([task("869aaa", tags=("action:data-deletion", prior))])
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--no-notify", "--ledger", ledger,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 0)
            for _ in range(2):
                self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                         "--revert", ledger,
                                         "--kill-file", os.path.join(self.tmp, "off")]), 0)
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", prior})
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_revert_will_not_overwrite_a_newer_outcome(self):
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        prior = "customer-outcome:needs-customer"
        newer = "customer-outcome:refunded"
        fake = FakeClickUp([task("869aaa", tags=("action:data-deletion", prior))])
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--no-notify", "--ledger", ledger,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 0)
            # a human answers the same question differently before the revert
            fake.tasks["869aaa"]["tags"] = [{"name": "action:data-deletion"},
                                            {"name": newer}]
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--revert",
                                     ledger, "--kill-file", os.path.join(self.tmp, "off")]), 0)
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion", newer})

    def test_a_write_that_never_lands_pages_and_fails_the_run(self):
        class Lying(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST":
                    self.calls.append((method, path))
                    return 200, {}
                return super().request(method, path, body, timeout)

        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"])])
        fake = Lying([task("869aaa")])
        pages = []
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda text, ch, *a, **k: pages.append((text, ch))):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        alerts = [p for p in pages if "NOT LAND" in p[0]]
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0][1], m.DEFAULT_ALERT_CHANNEL)
        # ...and the ticket was never closed on an unconfirmed label
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_the_comment_retry_shares_the_one_per_run_budget(self):
        # QA round 11: a fresh MutationBudget for the retries doubled the documented
        # per-run mutation cap on an armed hourly job.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        fake = DeafComment([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--no-notify", "--ledger", ledger,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 5)
        fake.fail = False
        fake.calls.clear()
        # a NEW confirmed request needs 3 mutations (label + close + comment); the
        # cap is 3, so the retry for the other ticket has nothing left to spend
        reg2 = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                           clickup=["869aaa"]),
                                        row(2, confirmed="2026-10-24T00:00:00Z",
                                            clickup=["869bbb"])])
        fake.tasks["869bbb"] = task("869bbb")
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg2, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", ledger, "--max-writes", "3",
                           "--kill-file", os.path.join(self.tmp, "off")])
        mutations = [c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")]
        self.assertLessEqual(len(mutations), 3)         # the documented bound, once
        # the debt ticket got nothing at all: no budget left for its retry
        self.assertEqual([c for c in mutations if "869aaa" in c[1]], [])
        self.assertEqual(code, 5)                       # the debt is still unsettled

    def test_a_comment_retry_that_could_not_run_is_not_green(self):
        # QA round 11: `skipped` debt (absent ticket, failed re-read) was invisible
        # to main(), which only counted `failed` — so a closed ticket could still be
        # missing its register-row note on a run that exited 0.
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        pathlib.Path(ledger).write_text("\n".join(json.dumps(r) for r in [
            {"at": "2026-11-01T00:00:00Z", "action": "resolve", "task_id": "869aaa",
             "result": "resolved", "comment": "failed"},
            {"at": "2026-11-01T00:00:01Z", "mode": "apply", "action": "comment",
             "task_id": "869aaa", "register_no": 1,
             "confirmed_at": "2026-10-24T00:00:00Z", "result": "failed", "status": 500},
        ]) + "\n")
        # no writes are selected, so the ONLY reason this run can be non-green is
        # the debt: the ticket is gone from the board, the retry skips, and saying
        # nothing would mean a closed ticket with no note on a green run
        reg = make_register(self.tmp, [row(1)])
        with mock.patch.object(m, "_client", lambda: FakeClickUp([])):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        debt = m.comment_debt(ledger)
        self.assertEqual(sorted(debt), ["869aaa"])
        self.assertEqual(debt["869aaa"]["register_no"], 1)

    def test_an_attempted_close_with_no_result_still_owes_its_comment(self):
        # QA round 13: the process died between the status PUT being accepted and
        # the ledger result being appended, leaving only `resolve/attempted`. That is
        # an uncertain close, and it owes the note exactly as a 503 read-back does.
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        pathlib.Path(ledger).write_text(json.dumps(
            {"at": "2026-11-01T00:00:00Z", "mode": "apply", "action": "resolve",
             "task_id": "869aaa", "tag": "", "before_status": "to do",
             "before_outcome": "", "register_no": 1,
             "confirmed_at": "2026-10-24T00:00:00Z", "result": "attempted"}) + "\n")
        debt = m.comment_debt(ledger)
        self.assertEqual(sorted(debt), ["869aaa"])
        self.assertIn("died before recording", debt["869aaa"]["why"])

        # the next run posts the note, because the close did land
        fake = FakeClickUp([{**task("869aaa", tags=("action:data-deletion",
                                                   "customer-outcome:complete"),
                                     status="resolved")}])
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.comments), 1)
        self.assertEqual(m.comment_debt(ledger), {})

    def test_the_readback_recovery_cannot_close_a_retagged_ticket(self):
        # QA round 14: the tag POST landed, its read-back GET failed, and the
        # recovery then re-read the ticket — but closed it on the STALE board
        # snapshot, bypassing the queue/status revalidation `execute()` performs.
        # Reproduced: a ticket switched to `action:other` before the recovery GET
        # was still PUT to `resolved` on unrelated erasure evidence.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        fake = RetaggedDuringRecovery([task("869aaa")])
        pages = []
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack",
                                  lambda text, ch, *a, **k: pages.append(text)):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--ledger", ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual([c for c in fake.calls if c[0] == "PUT"], [])   # never closed
        # QA round 15: the page must not tell an operator the tag is absent when the
        # tag is sitting on the ticket — that is the thing they have to look at.
        alert = [t for t in pages if "need a human" in t]
        self.assertEqual(len(alert), 1)
        self.assertIn("DID get the outcome tag", alert[0])
        self.assertIn("The tag is ON", alert[0])
        self.assertNotIn("NOT labelled", alert[0])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
        self.assertEqual(code, 5)          # a label landed on a ticket we no longer own
        self.assertIn("customer-outcome:complete", fake.tagset("869aaa"))

    def test_an_unreadable_readback_is_not_reported_as_absent(self):
        # QA round 16: the POST is accepted and BOTH confirmation GETs 503. The write
        # is correctly left unconfirmed — but the page said "did NOT LAND / NOT
        # labelled", when the tag may well be sitting on the ticket.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        fake = FlakyReadback([task("869aaa")], fail_gets=99)   # every post-PUT GET fails
        real = fake.request

        def request(method, path, body=None, timeout=60):
            if method == "POST" and "/tag/" in path:
                fake.after_put = 0
                code, out = real(method, path, body, timeout)
                fake.after_put = 99                            # tag reads fail too
                fake.tasks["869aaa"]["tags"].append({"name": m.TAG_COMPLETE})
                return code, out
            return real(method, path, body, timeout)

        fake.request = request
        pages = []
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack",
                                  lambda text, ch, *a, **k: pages.append(text)):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--ledger", os.path.join(self.tmp, "ledger.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")   # never closed
        alert = [t for t in pages if "need a human" in t]
        self.assertEqual(len(alert), 1)
        self.assertIn("could NOT BE CONFIRMED", alert[0])
        self.assertIn("MAY be on those tickets", alert[0])
        self.assertNotIn("NOT labelled", alert[0])

    def test_a_superseded_row_cannot_label_a_live_ticket(self):
        # QA round 17: a `duplicate` counsel row keeps its ClickUp id, so the counsel
        # branch tagged the SURVIVING request's ticket `customer-outcome:blocked` on the
        # say-so of a row the register itself had retired.
        reg = make_register(self.tmp, [
            row(1, cls="legal_threat", status="duplicate", clickup=["869aaa"]),
            row(2, cls="privacy_erasure", clickup=["869aaa"]),
        ])
        fake = FakeClickUp([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", os.path.join(self.tmp, "ledger.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion"})
        self.assertIn("duplicate", self._buf.getvalue())

    def test_the_close_helper_itself_refuses_a_non_open_ticket(self):
        # QA rounds 14-16 each found the ONE close path that had forgotten to re-check
        # the status, so the gate now lives inside `resolve_task()`: handing it a ticket
        # that is not open (here `archived`) must write nothing at all, whatever the
        # caller believed.
        fake = FakeClickUp([task("869aaa", status="archived")])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        out = m.resolve_task(fake, "869aaa", ledger, task=fake.tasks["869aaa"],
                             before_status="archived", register_no=1)
        self.assertEqual(out["result"], "not_open")
        self.assertEqual([c for c in fake.calls if c[0] in ("PUT", "POST")], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "archived")
        self.assertFalse(os.path.exists(ledger))         # not even an `attempted` row

    def test_an_already_tagged_ticket_in_an_unknown_status_is_not_closed(self):
        # QA round 16: the half-state completion ran BEFORE the open-status gate, so an
        # archived ticket that already carried `complete` was still PUT to `resolved`.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        fake = FakeClickUp([task("869aaa", status="archived",
                                 tags=("action:data-deletion", m.TAG_COMPLETE))])
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", os.path.join(self.tmp, "ledger.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "archived")
        self.assertEqual(fake.comments, [])
        self.assertEqual(code, 0)
        self.assertIn("already carries", self._buf.getvalue())

    def test_a_ticket_in_an_unknown_status_is_not_written_to(self):
        # QA round 15: the gate was "not one of the three terminal statuses", so a
        # ticket in ANY other non-open status (`archived` here) was treated as open
        # and got labelled `complete` and PUT `resolved`.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        fake = FakeClickUp([task("869aaa", status="archived")])
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", os.path.join(self.tmp, "ledger.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])
        self.assertEqual(fake.tagset("869aaa"), {"action:data-deletion"})
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "archived")
        self.assertEqual(code, 0)          # reported, not paged: nothing was lost
        out = self._buf.getvalue()
        self.assertIn("not one the drainer", out)
        self.assertIn("archived", out)

    def test_a_ticket_retagged_after_the_scan_is_not_touched(self):
        # QA round 13: `execute()` trusted the scan snapshot for tickets already in
        # it, so a human retagging the ticket between scan and write let the drainer
        # label and CLOSE a ticket that is no longer action:data-deletion.
        fake = StaleBoard([task("869aaa")], stale_tags=["action:data-deletion"])
        fake.tasks["869aaa"]["tags"] = [{"name": "action:other"}]   # the live truth
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", os.path.join(self.tmp, "ledger.jsonl"),
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])
        self.assertEqual(fake.tagset("869aaa"), {"action:other"})
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")
        # and the reason is visible in the human report, naming what it carries now
        with mock.patch.object(m, "_client", lambda: fake):
            m.main(["--register", reg, "--state-dir", self.tmp, "--examples", "5"])
        out = self._buf.getvalue()
        self.assertIn("action:other", out)
        self.assertIn("no longer carries", out)

    def test_a_close_that_never_read_back_still_owes_its_comment(self):
        # QA round 12: PUT accepted, read-back 503 -> `resolve_task()` returns BEFORE
        # the comment, leaving a `resolved` ticket with no note and no debt: the next
        # scan skips a terminal ticket and `comment_debt()` only knew about failed
        # comment rows. The note was gone for good.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        # TWO 503s: the close's own read-back AND the same run's retry re-read, so
        # the note really does have to wait for the next hourly run
        fake = FlakyReadback([task("869aaa")], fail_gets=2)
        with mock.patch.object(m, "_client", lambda: fake):
            first = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                            "--no-notify", "--ledger", ledger,
                            "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(first, 5)                       # unconfirmed close is not green
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        self.assertEqual(fake.comments, [])
        debt = m.comment_debt(ledger)
        self.assertEqual(sorted(debt), ["869aaa"])
        self.assertIn("never confirmed", debt["869aaa"]["why"])

        # the next hourly run: the ticket is terminal (so no write is selected into
        # action) but the debt is settled, and it says which row closed it
        with mock.patch.object(m, "_client", lambda: fake):
            second = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                             "--no-notify", "--ledger", ledger,
                             "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(second, 0)
        self.assertEqual(len(fake.comments), 1)
        self.assertIn("1", fake.comments[0]["body"]["comment_text"])
        self.assertEqual(fake.comments[0]["body"]["notify_all"], False)
        self.assertEqual(m.comment_debt(ledger), {})

    def test_a_lost_put_response_still_owes_its_comment(self):
        # QA round 20: ClickUp applies the close and the connection times out. The
        # drainer used to record `failed`, which `comment_debt()` reads as "no close,
        # the next run's write path owns it" — but the ticket WAS resolved, and an
        # hourly scan skips a terminal ticket, so the audit note was never posted and
        # nothing was left to retry.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        fake = MutatesThenRaises([task("869aaa")], method="PUT")
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")
        self.assertEqual(len(fake.comments), 1)          # the note is not lost
        self.assertEqual(m.comment_debt(ledger), {})
        self.assertEqual(code, 0)

    def test_a_lost_post_response_does_not_leave_the_probe_tag_behind(self):
        # QA round 20: the probe's POST lands and the response is lost. `add_tag`
        # used to answer `failed`, the probe concluded "nothing was written" and
        # skipped cleanup — leaving `customer-outcome:blocked` on a live ticket it
        # had just damaged.
        fake = MutatesThenRaises([task("869aaa")], method="POST", match="/tag/")
        out = m.probe(fake, "869aaa", self.ledger, board={"869aaa": task("869aaa")})
        self.assertEqual(out["probe"]["result"], "written")
        self.assertEqual(out["reverted"]["result"], "removed")
        self.assertNotIn(m.TAG_BLOCKED, fake.tagset("869aaa"))

    def test_a_lost_post_that_did_not_land_is_reported_as_absent(self):
        # The other half of the same ambiguity: when the read shows the tag is NOT
        # there, `failed` is a measured fact and the probe may say so.
        class NeverLands(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST" and "/tag/" in path:
                    self.calls.append((method, path))
                    raise TimeoutError("read timed out")
                return super().request(method, path, body, timeout)

        fake = NeverLands([task("869aaa")])
        out = m.probe(fake, "869aaa", self.ledger, board={"869aaa": task("869aaa")})
        self.assertEqual(out["probe"]["result"], "failed")
        self.assertIn("nothing was written", out["note"])
        self.assertNotIn(m.TAG_BLOCKED, fake.tagset("869aaa"))

    def test_a_dropped_report_is_not_a_green_run(self):
        # QA round 10: every Slack result was discarded, so the legal-clock line
        # could stop being delivered while the hourly unit exited 0 forever.
        reg = make_register(self.tmp, [row(1, due=PAST), row(2)])
        with mock.patch.object(m, "_client", lambda: FakeClickUp([])), \
                mock.patch.object(m, "post_slack", lambda *a, **k: False):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 7)          # the writes are fine; the report is not

        # and a delivered report is still green
        with mock.patch.object(m, "_client", lambda: FakeClickUp([])), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                                     "--kill-file", os.path.join(self.tmp, "off")]), 0)

    def test_a_failed_audit_comment_is_a_debt_the_next_run_settles(self):
        # QA round 10: a close whose comment POST 500s exited 0, leaving a
        # `resolved` ticket with no ticket-local evidence of the confirmation.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        fake = DeafComment([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)                      # not green: the note is missing
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "resolved")   # close stands
        self.assertEqual(fake.comments, [])
        debt = m.comment_debt(ledger)
        self.assertEqual(sorted(debt), ["869aaa"])
        self.assertEqual(debt["869aaa"]["register_no"], 1)
        self.assertEqual(debt["869aaa"]["confirmed_at"], "2026-10-24T00:00:00Z")

        # the next run settles it, and says the same thing the first one meant to
        fake.fail = False
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.comments), 1)
        self.assertIn("1", fake.comments[0]["body"]["comment_text"])
        self.assertEqual(fake.comments[0]["body"]["notify_all"], False)
        self.assertEqual(m.comment_debt(ledger), {})   # the debt is settled, not re-posted

        # a third run posts nothing: the note is on the ticket exactly once
        with mock.patch.object(m, "_client", lambda: fake):
            m.main(["--register", reg, "--state-dir", self.tmp, "--apply", "--no-notify",
                    "--ledger", ledger, "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(len(fake.comments), 1)

    def test_an_interrupted_restore_does_not_retire_the_audit_comment_debt(self):
        # QA round 26: ANY restore-status record retired the debt, including the
        # `attempted` one written BEFORE the PUT. A revert that died between the two
        # left the ticket `resolved` with no note, and the next hourly run saw no
        # debt and never posted the register-row explanation.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                          clickup=["869aaa"])])
        ledger = os.path.join(self.tmp, "ledger.jsonl")
        fake = DeafComment([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake):
            m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                    "--no-notify", "--ledger", ledger,
                    "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(sorted(m.comment_debt(ledger)), ["869aaa"])
        # the revert logs `attempted` and dies before its PUT
        m.append_ledger(ledger, {"at": m._now_iso(), "mode": "revert",
                                 "action": "restore-status", "task_id": "869aaa",
                                 "tag": "", "status": "", "result": "attempted"})
        self.assertEqual(sorted(m.comment_debt(ledger)), ["869aaa"])
        # a restore that DID land retires it
        m.append_ledger(ledger, {"at": m._now_iso(), "mode": "revert",
                                 "action": "restore-status", "task_id": "869aaa",
                                 "tag": "", "status": "to do", "result": "restored"})
        self.assertEqual(m.comment_debt(ledger), {})

    def test_a_preview_neither_ages_the_gap_state_nor_pages(self):
        # QA round 8: `record_intake_gaps()` ran before the --apply and kill-file
        # gates, so two previews pushed `runs` to 2 and the next REAL hourly run
        # paged "gap survived 3 runs" after one hour of actual evidence.
        reg = make_register(self.tmp, [row(1)])
        fake = FakeClickUp([task("869zzz")])          # open, on the board, no row
        gaps = os.path.join(self.tmp, "intake-gaps.json")
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            for _ in range(2):
                self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                         "--kill-file", os.path.join(self.tmp, "off")]), 0)
            self.assertFalse(os.path.exists(gaps))
            # a killed run is not a preview either: it promised to write nothing
            kill = os.path.join(self.tmp, "off")
            open(kill, "w").close()
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                     "--apply", "--kill-file", kill]), 4)
            self.assertFalse(os.path.exists(gaps))
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                     "--apply", "--kill-file", os.path.join(self.tmp, "nope")]), 0)
        with open(gaps) as f:
            state = json.load(f)
        self.assertEqual(state["869zzz"]["runs"], 1)   # ONE real run, not three

    def test_a_dry_run_does_not_post_unless_asked(self):
        # The hourly unit always runs --apply, so a dry run is a human preview; the
        # runbook promises it sends nothing.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                           clickup=["869aaa"])])
        pages = []
        with mock.patch.object(m, "_client", lambda: FakeClickUp([task("869aaa")])), \
                mock.patch.object(m, "post_slack",
                                  lambda text, ch, *a, **k: pages.append((text, ch))):
            self.assertEqual(m.main(["--register", reg, "--state-dir", self.tmp,
                                     "--kill-file", os.path.join(self.tmp, "off")]), 0)
            self.assertEqual(pages, [])
            m.main(["--register", reg, "--state-dir", self.tmp, "--notify-dry-run",
                    "--kill-file", os.path.join(self.tmp, "off")])
        self.assertTrue(pages)                       # asked for, so posted

    def test_no_notify_suppresses_even_the_failure_page(self):
        class Lying(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST":
                    return 200, {}
                return super().request(method, path, body, timeout)

        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"])])
        fake = Lying([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack") as page:
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply", "--no-notify",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        page.assert_not_called()

    def test_an_unreadable_ledger_refuses_the_run_before_any_write(self):
        # QA round 23: `execute()` appended to the ledger and only then did the run
        # discover a crash-truncated line. `--revert` refuses the whole file, so the
        # new closes were recorded in a ledger nothing could undo. Refuse first.
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                           clickup=["869aaa"])])
        pathlib.Path(self.ledger).write_text('{"at": "2026-11-03T00:00:00Z", "act')
        fake = FakeClickUp([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--no-notify", "--ledger", self.ledger,
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 2)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")], [])
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_the_kill_file_is_honoured_before_the_reads(self):
        # QA round 23: with the switch on, a ClickUp read outage exited 2 and paged
        # through OnFailure — a kill switch that pages about the thing it was
        # switched off for, every hour.
        class DeadBoard(FakeClickUp):
            def list_tasks(self, list_id, params, max_pages):
                raise RuntimeError("clickup is down")

        reg = make_register(self.tmp, [row(1)])
        kill = os.path.join(self.tmp, "disabled")
        pathlib.Path(kill).write_text("")
        with mock.patch.object(m, "_client", lambda: DeadBoard([])), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", kill])
        self.assertEqual(code, 4)

    def test_a_write_that_errors_fails_the_unit(self):
        # QA #4: a 403 on the tag POST leaves the confirmed ticket open. The
        # best-effort Slack page may fail too, so the EXIT CODE has to be the
        # signal that a run did not do its job (the unit is OnFailure-wired).
        class NoPost(FakeClickUp):
            def request(self, method, path, body=None, timeout=60):
                if method == "POST":
                    self.calls.append((method, path))
                    return 403, {"err": "forbidden"}
                return super().request(method, path, body, timeout)

        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z",
                                           clickup=["869aaa"])])
        fake = NoPost([task("869aaa")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack"):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 5)
        self.assertEqual(fake.tasks["869aaa"]["status"]["status"], "to do")

    def test_the_kill_file_refuses_every_write(self):
        reg = make_register(self.tmp, [row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"])])
        fake = FakeClickUp([task("869aaa")])
        kill = os.path.join(self.tmp, "disabled")
        pathlib.Path(kill).write_text("")
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--apply",
                           "--kill-file", kill])
        self.assertEqual(code, 4)
        self.assertEqual([c for c in fake.calls if c[0] in ("POST", "DELETE")], [])

    def test_the_kill_file_does_not_disable_the_undo(self):
        # The kill switch stops the scheduled writer, not the rollback. A switch that
        # also disabled `--revert` would leave a bad run on the board with no way back.
        fake = FakeClickUp([task("869aaa")])
        m.add_tag(fake, fake.tasks["869aaa"], m.TAG_COMPLETE, self.ledger)
        kill = os.path.join(self.tmp, "disabled")
        pathlib.Path(kill).write_text("")
        with mock.patch.object(m, "_client", lambda: fake):
            code = m.main(["--revert", self.ledger, "--kill-file", kill, "--json"])
        self.assertEqual(code, 0)
        self.assertNotIn(m.TAG_COMPLETE, fake.tagset("869aaa"))

    def test_the_digest_carries_the_board_and_the_legal_clock_on_one_line(self):
        reg = make_register(self.tmp, [
            row(1, confirmed="2026-10-24T00:00:00Z", clickup=["869aaa"]),
            row(2, due=PAST, clickup=["869over"]),
        ])
        fake = FakeClickUp([task("869aaa"), task("869over"), task("869gap")])
        with mock.patch.object(m, "_client", lambda: fake), \
                mock.patch.object(m, "post_slack", lambda *a, **k: True):
            code = m.main(["--register", reg, "--state-dir", self.tmp, "--json",
                           "--kill-file", os.path.join(self.tmp, "off")])
        self.assertEqual(code, 0)
        report = json.loads(self._buf.getvalue())
        digest = report["digest"]
        self.assertEqual(len(digest.splitlines()), 1)
        self.assertIn("board 3 tickets / 3 open", digest)
        self.assertIn("OVERDUE 1", digest)
        self.assertIn(f"→{m.TAG_COMPLETE} 1", digest)
        self.assertIn("no-register-row 1", digest)
        # the legal clock is in the same report, never a separate system
        self.assertIn("overdue 1 requests", report["overdue_line"])


class TestRealRegisterSchema(unittest.TestCase):
    """The reader must fit the register's OWN schema, not a fixture of it."""

    def test_reader_works_against_gdpr_pipeline_store(self):
        try:
            sys.path.insert(0, str(pathlib.Path(_SCRIPT).resolve().parents[1]))
            from gdpr_pipeline.store import Store
        except ImportError:
            self.skipTest("the erasure register is not merged yet (hydra PR #1629)")
        tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        path = os.path.join(tmp, "erasure.sqlite")
        store = Store(path)
        store.upsert({"keys": ["clickup:869real"], "channel": "support",
                      "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                      "clickup_ids": ["869real"],
                      "pages": [{"entity": "profile",
                                 "id": "ef2a4bbe-df17-4b14-9fa5-bb7287ca75a8"}]})
        reg = m.load_register(path)
        self.assertEqual(list(reg["by_clickup"]), ["869real"])
        sel = m.select(reg, {"869real": task("869real")}, NOW, conv_reader=conv_of)
        self.assertEqual(sel["complete"], [])            # unconfirmed: nothing closes
        self.assertEqual(len(sel["overdue"]), 1)         # 2026-10-01 + 30 d < NOW


if __name__ == "__main__":
    unittest.main()
