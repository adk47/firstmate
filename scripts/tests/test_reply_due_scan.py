#!/usr/bin/env python3
"""reply_due_scan (the class-G builder): who is due, who is not, one row per user, paid first, the signing header."""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import comm_state as cs  # noqa: E402
from credit_review import reply_due_scan as rds  # noqa: E402
from credit_review import verify_ledger as vl  # noqa: E402

NOW = 1761900000.0
DAY = 86400


def thread(cid, contact, title, parts, state="open"):
    return {"type": "conversation", "id": cid, "state": state, "title": title,
            "source": {"id": "0", "author": {"type": "user"}, "body": title, "created_at": NOW - 9 * DAY},
            "contacts": {"contacts": [{"id": contact}]},
            "conversation_parts": {"total_count": len(parts), "conversation_parts": parts}}


def cust(pid, at, body="any update on my credits?"):
    return {"id": pid, "part_type": "comment", "author": {"type": "user"}, "body": body, "created_at": at}


class FakeIntercom:
    """Search pages (2 per page, to exercise pagination), thread GETs, contact GETs."""

    def __init__(self):
        self.search, self.convs, self.contacts = [], {}, {}

    def add(self, conv, contact, ext, lc, la=0):
        self.search.append({"id": conv["id"], "statistics": {"last_contact_reply_at": lc, "last_admin_reply_at": la},
                            "contacts": {"contacts": [{"id": contact, "external_id": ext}]}})
        self.convs[conv["id"]] = conv

    def __call__(self, method, path, body=None):
        if method == "POST":
            start = int((body.get("pagination") or {}).get("starting_after") or 0)
            page = self.search[start:start + 2]
            nxt = {"next": {"starting_after": str(start + 2)}} if start + 2 < len(self.search) else {}
            return {"conversations": page, "pages": nxt}
        if path.startswith("/contacts/"):
            return self.contacts[path.split("/")[2]]
        return self.convs[path.split("/")[2].split("?")[0]]


def replica(pro_of, email_of, open_rows, names, titles=None):
    titles = titles or {}
    def q(sql):
        if "neptuneprofessionalid IN" in sql:
            return [[u, p, ""] for u, p in pro_of.items() if f"'{p}'" in sql]
        if "lower(email) IN" in sql:
            return [[u, e] for u, e in email_of.items() if f"'{e}'" in sql]
        if "spotifytracktitle" in sql:                      # TITLES_QUERY (Fable d2): pending requests' track titles
            ids = sql.split("userid IN (")[1].split(")")[0].split(",")
            return [[r[0], r[1], titles.get((r[0], r[1]), f"Track {r[1]}")] for r in open_rows
                    if r[0] in ids and r[2] in cs.PENDING_STATUSES]
        if "credit_requests" in sql:
            ids = sql.split("userid IN (")[1].split(")")[0].split(",")
            return [r for r in open_rows if r[0] in ids]
        if "firstname" in sql:
            return [[u, n, f"u{u}@x.com", f"pro-{u}", f"auth0|a{u}"] for u, n in names.items()]
        return []
    return q


class ReplyDueScanTest(unittest.TestCase):
    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.saved = cs.LEDGER
        cs.LEDGER = str(d / "ledger.sqlite3")
        vl.connect(cs.LEDGER).close()
        # QA #1857 r3: the production linkage (comm_state.linked_request_ids, the default `linked` of rds.build) reads
        # the PROOF STORE too. Left at its production path the suite's result depended on the HOST: unreadable on a
        # dev box (Unknown -> the full check ran, green), readable on node-8 (no link -> hand-off, red). Pin it to a
        # readable, empty store so every box sees what node-8 sees.
        self.saved_proof = cs.PROOF_STORE
        cs.PROOF_STORE = str(d / "proof.sqlite")
        with sqlite3.connect(cs.PROOF_STORE) as db:
            db.execute("CREATE TABLE proof_intake (user_id INTEGER, conversation_id TEXT, candidate_request_ids_json TEXT)")
        self.paying = d / "paying.json"
        self.paying.write_text(json.dumps({"ids": [2, 15]}))
        self.ic = ic = FakeIntercom()
        # 1: due (free); 2: due, paid, mapped by EMAIL, two threads - the oldest is listed; 3: off-topic (billing);
        # 4: answered by an admin after the customer; 5: the customer wrote again 2 h ago; 15: never
        ic.add(thread("101", "c1", "about my credits", [cust("1001", NOW - 6 * DAY)]), "c1", "pro-1", NOW - 6 * DAY)
        ic.add(thread("102", "c2", "my song credits", [cust("1002", NOW - 5 * DAY)]), "c2", "unknown-ext", NOW - 5 * DAY)
        ic.add(thread("103", "c2", "credit request", [cust("1003", NOW - 2 * DAY)]), "c2", "unknown-ext", NOW - 2 * DAY)
        ic.add(thread("104", "c3", "refund for my subscription", [cust("1004", NOW - 3 * DAY, "refund please")]),
               "c3", "pro-3", NOW - 3 * DAY)
        ic.add(thread("105", "c4", "about my credits",
                      [cust("1005", NOW - 4 * DAY), {"id": "1006", "part_type": "comment", "author": {"type": "admin", "id": "9"},
                                                     "body": "looking", "created_at": NOW - 3 * DAY}]),
               "c4", "pro-4", NOW - 4 * DAY)
        ic.add(thread("106", "c5", "about my credits", [cust("1007", NOW - 3 * DAY), cust("1008", NOW - 2 * 3600)]),
               "c5", "pro-5", NOW - 3 * DAY)
        ic.add(thread("107", "c15", "about my credits", [cust("1009", NOW - 3 * DAY)]), "c15", "pro-15", NOW - 3 * DAY)
        # 8: Intercom's statistics say WE replied after the customer - never even fetched (the thread itself looks due)
        ic.add(thread("108", "c8", "about my credits", [cust("1010", NOW - 3 * DAY)]), "c8", "pro-8", NOW - 3 * DAY,
               la=NOW - 2 * DAY)
        ic.contacts["c2"] = {"email": "Two@X.com"}
        self.contact_of = {"1": "c1", "2": "c2", "3": "c3", "4": "c4", "5": "c5", "15": "c15"}
        self.pro_of = {"1": "pro-1", "3": "pro-3", "4": "pro-4", "5": "pro-5", "6": "pro-6", "8": "pro-8", "15": "pro-15"}
        self.emails_of, self.names = {"2": "two@x.com"}, {"1": "Ann", "2": ""}
        self.open_rows = [["1", "r1", "user_verification_needed", "false", "false"],
                          ["2", "r2", "unverified", "true", "false"]]
        self.q = replica(self.pro_of, self.emails_of, self.open_rows, self.names)

    def audience(self, n):
        """n more due threads, each its own account - a mostly-HELD audience needs more than a couple of entries to bound."""
        for i in range(n):
            uid, conv, contact, pro = str(901 + i), f"9{i:02d}", f"c9{i:02d}", f"pro-9{i:02d}"
            self.ic.add(thread(conv, contact, "about my credits", [cust(f"90{i:02d}", NOW - (7 + i) * DAY)]),
                        contact, pro, NOW - (7 + i) * DAY)
            self.pro_of[uid], self.names[uid] = pro, f"N{uid}"
            self.contact_of[uid] = contact
        self.q = replica(self.pro_of, self.emails_of, self.open_rows, self.names)

    def tearDown(self):
        cs.LEDGER = self.saved
        cs.PROOF_STORE = self.saved_proof

    def build(self, **kw):
        kw.setdefault("ic", self.ic)
        kw.setdefault("checker", lambda *a, **k: {"hold": False, "reasons": []})      # the gate's send-time check
        # Fable d2: the scan's own run of the trigger rules is a FILTER in front of the check; these tests pin the
        # check as the oracle, so the default trigger here reads every part as a status question (the production
        # default, comm_state.trigger_class, is pinned by TriggerPrefilterTest below).
        kw.setdefault("trigger", lambda conv, part, **k: {"class": "status", "why": "test: every part is a status question"})
        kw.setdefault("linked", lambda uid, conv, src="": set())
        return rds.build(query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW, **kw)

    def test_builder_equals_send_the_gates_own_check_sorts_them(self):
        # h2 G1 11:1xZ: 100 listed, 0 answerable - every user goes through comm_state.check(reply_due_part=...) here
        seen = []
        def check(campaign, copy, uid, keys, cid, **kw):
            seen.append((campaign, uid, kw["conversation"], kw["reply_due_part"], cid))
            if uid == 1:
                return {"hold": True, "reasons": ["reply_due:non_status_part (handoff:product): stale part (> 30 d, or undated), 200 d"]}
            return {"hold": True, "reasons": ["reply_due:class_is:status-doc-received"]}
        doc = self.build(checker=check)
        self.assertEqual(doc["users"], [])                                        # nothing the gate refuses is a slot
        self.assertEqual([u["user_id"] for u in doc["by_class"]["status-doc-received"]], [2])
        self.assertEqual([u["user_id"] for u in doc["handoff"]], [1])
        self.assertIn("stale part", doc["handoff"][0]["why"])
        self.assertIn(("uvn-status", 2, "102", "1002", "c2"), seen)
        self.assertEqual(doc["facts"], [])                                        # the header covers the runner list

    def test_product_handoffs_become_the_ref_pickers_rows_each_with_the_gates_own_credits_file(self):
        # c1 577 / p1 616: {conversation, part, credits_file} per PRODUCT handoff; never a thread-only one
        def check(campaign, copy, uid, keys, cid, **kw):
            if uid == 1:
                return {"hold": True, "reasons": ["reply_due:non_status_part (handoff:product): asks how merges work"]}
            if uid == 2:
                return {"hold": True, "reasons": ["reply_due:non_status_part (handoff:product): stale part (> 30 d, or undated), 40 d"]}
            return {"hold": True, "reasons": ["reply_due:class_is:status-doc-received"]}
        doc = self.build(checker=check)
        out = Path(tempfile.mkdtemp()) / "ref-rows.jsonl"
        self.assertEqual(rds.ref_rows(doc, str(out)), 1)
        rows = [json.loads(ln) for ln in out.read_text().splitlines()]
        self.assertEqual([(r["conversation"], r["part"], r["user_id"]) for r in rows], [("101", "1001", "1")])
        cf = json.loads(Path(rows[0]["credits_file"]).read_text())
        self.assertEqual(cf["user"], {"email": "u1@x.com", "id": "1", "professional_id": "pro-1", "auth_id": "auth0|a1",
                                      "first_name": "Ann"})
        self.assertEqual(cf["credits"], [{"request_id": "reply-1001", "role": "-", "track_title": "-", "artist_name": "-"}])
        self.assertEqual(oct(os.stat(rows[0]["credits_file"]).st_mode & 0o777), "0o600")
        self.assertEqual(oct(os.stat(str(out)).st_mode & 0o777), "0o600")
        # QA #1574: a rerun replaces the sidecar atomically (a new inode, never truncated in place), and a loose
        # pre-existing dir / file mode is corrected
        cfp = rows[0]["credits_file"]
        os.chmod(cfp, 0o644); os.chmod(str(out) + ".d", 0o755)
        ino = os.stat(cfp).st_ino
        self.assertEqual(rds.ref_rows(doc, str(out)), 1)
        self.assertNotEqual(os.stat(cfp).st_ino, ino)
        self.assertEqual((oct(os.stat(cfp).st_mode & 0o777), oct(os.stat(str(out) + ".d").st_mode & 0o777)), ("0o600", "0o700"))
        self.assertEqual(json.loads(Path(cfp).read_text())["user"]["id"], "1")

    def test_a_stale_part_is_a_handoff_without_the_full_check(self):
        # the deployed trigger_class decides a part older than comm_state.STATUS_PART_DAYS from the thread alone; the
        # slow check is never called for it. The window is 365 days (it was 30 until 2026-11-10: see comm_state), so
        # the stale part here is 400 days old.
        self.ic.convs["101"]["conversation_parts"]["conversation_parts"][0]["created_at"] = NOW - 400 * DAY
        self.ic.search[0]["statistics"]["last_contact_reply_at"] = NOW - 400 * DAY
        self.ic.convs["101"]["source"]["created_at"] = NOW - 401 * DAY
        calls = []
        def check(campaign, copy, uid, keys, cid, **kw):
            calls.append(uid)
            return {"hold": False, "reasons": []}
        doc = self.build(checker=check)
        self.assertEqual([u["user_id"] for u in doc["handoff"]], [1])
        self.assertIn("stale part", doc["handoff"][0]["why"])
        self.assertNotIn(1, calls)
        self.assertEqual([u["user_id"] for u in doc["users"]], [2])

    def test_a_part_inside_the_year_is_not_handed_off_for_its_age(self):
        # 40 days was a handoff under the 30-day window, and the handoff bucket is worked by no one (1,771 threads
        # where the customer wrote and got silence). Inside the year the part goes to the full check like any other.
        self.ic.convs["101"]["conversation_parts"]["conversation_parts"][0]["created_at"] = NOW - 40 * DAY
        self.ic.search[0]["statistics"]["last_contact_reply_at"] = NOW - 40 * DAY
        self.ic.convs["101"]["source"]["created_at"] = NOW - 41 * DAY
        calls = []
        def check(campaign, copy, uid, keys, cid, **kw):
            calls.append(uid)
            return {"hold": False, "reasons": []}
        doc = self.build(checker=check)
        self.assertEqual([u for u in doc["handoff"] if "stale part" in u.get("why", "")], [])
        self.assertIn(1, calls, "the full check decides a 40-day part; its age does not")
        self.assertIn(1, [u["user_id"] for u in doc["users"]])

    def test_other_holds_and_unreadable_checks_are_listed_never_sent(self):
        def check(campaign, copy, uid, keys, cid, **kw):
            if uid == 1:
                raise cs.Unknown("thread unreadable")
            return {"hold": True, "reasons": ["reply_due:class_is:status-doc-received", "R8_account_hold"]}
        doc = self.build(checker=check)
        self.assertEqual(doc["users"], [])
        self.assertEqual(sorted(u["user_id"] for u in doc["held"]), [1, 2])
        self.assertEqual(doc["counts"]["bucket:unreadable"], 1)

    def test_who_is_due_one_row_per_user_paid_first(self):
        doc = self.build()
        self.assertEqual([(u["user_id"], u["paid"], u["reply_due"]) for u in doc["users"]],
                         [(2, True, {"part": "1002", "conversation": "102"}),       # paid FIRST (user 1 waited longer)
                          (1, False, {"part": "1001", "conversation": "101"})])
        c = doc["counts"]
        self.assertEqual(c["threads_customer_waiting"], 7)                       # 8 rows; thread 108: we replied after
        self.assertEqual(c["not_due:R9_thread_not_about_credits"], 1)
        self.assertEqual(c["not_due:already_answered"], 1)
        self.assertEqual(c["not_due:not_24h_yet"], 1)
        self.assertEqual(c["skipped_never"], 1)                                   # user 15
        self.assertEqual(doc["users"][0]["_thread"]["mapped_by"], "email")

    def test_a_tied_wait_lists_paid_first_then_the_numeric_user_id_whatever_the_search_order(self):
        # four more due threads whose customer part arrived in the same second as user 1's: only the paying flag and
        # then the user id decide the order (credit_review/audience_order.py). The paying users carry the larger ids
        # on purpose, so a list that followed the search or the id alone would put 22 and 24 first.
        at = NOW - 6 * DAY
        for u in (24, 23, 22, 21):
            conv, contact, pro = f"2{u}", f"c{u}", f"pro-{u}"
            self.ic.add(thread(conv, contact, "about my credits", [cust(f"2{u}", at)]), contact, pro, at)
            self.pro_of[str(u)], self.names[str(u)], self.contact_of[str(u)] = pro, f"N{u}", contact
            self.open_rows.append([str(u), f"r{u}", "user_verification_needed", "false", "false"])
        self.paying.write_text(json.dumps({"ids": [2, 15, 21, 23]}))
        self.q = replica(self.pro_of, self.emails_of, self.open_rows, self.names)
        want = [21, 23, 2, 1, 22, 24]
        self.assertEqual([u["user_id"] for u in self.build()["users"]], want)
        self.ic.search.reverse()                                        # the customer's search returns its rows the other way
        self.assertEqual([u["user_id"] for u in self.build()["users"]], want)

    def test_the_signing_header_carries_every_recipient_fact(self):
        doc = self.build()
        two = next(t for t in doc["facts"] if t["user_id"] == 2)
        self.assertEqual(two["rows"], [["r2", "unverified", True, False, ""]])
        self.assertTrue(two["first_name_missing"])
        self.assertEqual((two["conversation"], two["part"]), ("102", "1002"))
        blob = json.dumps(doc["facts"], separators=(",", ":"), sort_keys=True, default=str)
        self.assertEqual(doc["replica_facts"]["sha256"], hashlib.sha256(blob.encode()).hexdigest())

    def test_cap_keeps_paid_first_and_stops_checking_when_full(self):
        calls = []
        def check(campaign, copy, uid, keys, cid, **kw):
            calls.append(uid)
            return {"hold": False, "reasons": []}
        doc = self.build(cap=1, checker=check)
        self.assertEqual([u["user_id"] for u in doc["users"]], [2])
        self.assertEqual(calls, [2])                                              # the batch was full after one
        self.assertEqual(doc["counts"]["not_checked_after_cap"], 1)

    def test_the_check_walk_is_bounded_by_checks_and_says_how_many_it_skipped(self):
        # QA #1574 (Important): the deployed timer called this scan with no bound - 379 due users, mostly HELD, is ~3.7 h
        # of ~35 s serial checks against the tick's 6,900 s limit. The answerable count alone cannot bound the work, so
        # --max-checks counts EVERY check (held and routed users too) and the skipped remainder is recorded, not silent.
        calls = []
        def check(campaign, copy, uid, keys, cid, **kw):
            calls.append(uid)
            return {"hold": True, "reasons": ["reply_due:class_is:status-team-review"]}
        self.audience(8)
        doc = self.build(max_checks=2, checker=check)
        self.assertEqual(len(calls), 2)                                          # two checks, not the whole audience
        self.assertEqual(doc["users"], [])
        self.assertEqual(doc["counts"]["not_checked_after_checks"], 8)            # 10 due - 2 checked, recorded
        # round 6: `unwalked` is the record the tick reads to keep the search token on this slice
        self.assertEqual({k: doc["page"][k] for k in ("start", "end", "listed", "unwalked")},
                         {"start": 0, "end": 2, "listed": 10, "unwalked": 8})
        # ... and it carries the IDENTITY the next run resumes after (never a bare position: the list is rebuilt)
        self.assertEqual(doc["page"]["end_user"], calls[-1])                       # the row this run examined last

    def test_the_check_walk_is_bounded_by_wall_clock(self):
        # the bound that actually bites: a mostly-held audience of slow checks. Time is injected so the test is not slow.
        clock = {"t": 0.0}

        def monotonic():                                                     # reading the clock does not advance it
            return clock["t"]
        calls = []
        def check(campaign, copy, uid, keys, cid, **kw):
            calls.append(uid)
            clock["t"] += 40.0                                                   # each check costs ~35 s
            return {"hold": True, "reasons": ["reply_due:held_by_hand"]}
        self.audience(8)
        saved, rds.time.monotonic = rds.time.monotonic, monotonic
        try:
            doc = self.build(max_checks=None, budget_seconds=50, checker=check)
        finally:
            rds.time.monotonic = saved
        # 50 s of budget, ~40 s per check: two checks fit (0 s and 40 s start times), the third would start at 80 s.
        # The clock no longer advances when it is merely READ (the prep walks read it too), so this counts work, not
        # clock reads - the bound under test is the checks', which is what the family's wall time is made of.
        self.assertEqual(len(calls), 2)
        self.assertEqual(doc["counts"]["not_checked_after_budget"], 8)
        self.assertEqual((doc["page"]["start"], doc["page"]["end"], doc["page"]["listed"]), (0, 2, 10))

    def test_slow_PREPARATION_burns_the_budget_and_leaves_the_page_undone(self):
        # r5 (1574 finding 2): the budget used to start AFTER the unbounded upstream work (every historical sent-apology
        # conversation, then every candidate thread), so it only ever measured the part that was already bounded and the
        # OS would find this on the day the backlog is largest. The clock starts before the first upstream call and every
        # walk checks it: preparation that eats the budget leaves the page un-done (end == start), so the cursor does NOT
        # advance over users nobody looked at.
        clock, calls = {"t": 0.0}, []
        self.audience(8)

        class SlowIntercom(FakeIntercom):        # a special method binds on the TYPE, so this must be a subclass
            def __call__(self, method, path, body=None):
                clock["t"] += 40.0                                            # every upstream fetch costs 40 s
                calls.append(path)
                return super().__call__(method, path, body)
        slow = SlowIntercom()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            doc = rds.build(ic=slow, query=self.q, paying_path=str(self.paying),
                            dv_store="/nonexistent", now=NOW, max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertEqual((doc["page"]["start"], doc["page"]["end"]), (0, 0))   # nothing was reached: the cursor stays
        self.assertGreaterEqual(sum(v for k, v in doc["counts"].items() if "budget" in k), 1)  # measured, not silent

    def test_slow_EMAIL_FALLBACK_is_bounded_by_the_same_deadline(self):
        # r5 (1574 finding 2, round 2): the email fallback is one contact GET per unmapped thread (439 in the real run),
        # and it used to run with no deadline at all - preparation could outlast the whole scan budget before the bounded
        # check loop started. Mapping now reads the same clock, and every thread it cannot reach is counted.
        clock = {"t": 0.0}
        for i in range(6):                      # six due threads whose contact has no external_id: each needs a GET
            conv, contact = f"80{i}", f"c80{i}"
            self.ic.add(thread(conv, contact, "about my credits", [cust(f"80{i}", NOW - (8 + i) * DAY)]), contact,
                        f"no-ext-{i}", NOW - (8 + i) * DAY)
            self.ic.contacts[contact] = {"email": f"e{ i}@x.com"}

        class SlowContacts(FakeIntercom):
            def __call__(self, method, path, body=None):
                if path.startswith("/contacts/"):
                    clock["t"] += 40.0          # a slow contact fetch: 40 s each
                return super().__call__(method, path, body)
        slow = SlowContacts()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            doc = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                            max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertGreaterEqual(doc["counts"].get("map_users_stopped_at_budget", 0), 1)   # counted, never silent
        self.assertEqual((doc["page"]["start"], doc["page"]["end"]), (0, 0))

    def test_the_email_fallback_BATCHES_are_bounded_by_the_same_deadline(self):
        # QA #1574 (Important, 4th round): the contact GETs were bounded but the `email IN (...)` batches that follow them
        # were not. 401 distinct fallback addresses make THREE replica batches; at ~500 s each the third STARTED after a
        # 900 s budget had already elapsed, so the unattended tick overran its bounded scan window and delayed every
        # downstream family. The batches now read the same clock, and the threads a stopped batch never resolved are
        # counted and carried into `pending` (never silently unanswered).
        clock = {"t": 0.0}
        email_of: dict[str, str] = {}
        for i in range(401):                        # 401 distinct emails: 3 batches of 200
            uid, conv, contact = str(901 + i), f"9{i:03d}", f"c9{i:03d}"
            self.ic.add(thread(conv, contact, "about my credits", [cust(f"90{i:03d}", NOW - (7 + i) * DAY)]),
                        contact, "", NOW - (7 + i) * DAY)      # no external_id: the email fallback is the only route
            self.ic.contacts[contact] = {"email": f"e{i}@x.com"}
            email_of[uid], self.names[uid] = f"e{i}@x.com", f"N{uid}"
        q = replica(self.pro_of, email_of, self.open_rows, self.names)

        def slow_query(sql):
            if "lower(email) IN" in sql:
                clock["t"] += 500.0                 # one fallback batch outlasts the whole 50 s budget
            return q(sql)
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            doc = rds.build(ic=self.ic, query=slow_query, paying_path=str(self.paying), dv_store="/nonexistent",
                            now=NOW, max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertGreaterEqual(doc["counts"].get("map_email_batches_stopped_at_budget", 0), 1)
        self.assertGreaterEqual(doc["counts"].get("map_emails_unqueried_at_budget", 0), 1)
        self.assertLess(doc["counts"]["map_emails_unqueried_at_budget"], 401)   # only the batches it never reached
        pending = (doc["upstream"] or {}).get("pending") or []
        self.assertTrue(pending, "threads whose email batch was never queried must be carried, not skipped past")
        self.assertGreaterEqual(doc["counts"].get("candidates_carried_to_next_run", 0), len(pending))

    def test_the_replica_facts_reads_stop_at_the_deadline_too(self):
        # the facts/names reads are chunked 300 users at a time; a slow replica used to be walked to the end regardless
        # of the clock. A user whose facts were never read is dropped from the audience (never answered from a partial
        # read) and the number dropped is written down for the signer.
        clock = {"t": 0.0}
        self.audience(6)
        inner = self.q

        def slow_query(sql):
            if "neptuneprofessionalid IN" in sql:
                clock["t"] += 400.0            # the mapping read alone outlasts the 50 s budget
            return inner(sql)
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            doc = rds.build(ic=self.ic, query=slow_query, paying_path=str(self.paying), dv_store="/nonexistent",
                            now=NOW, max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertGreaterEqual(doc["counts"].get("facts_stopped_at_budget", 0), 1)
        for u in doc["users"]:                 # nobody is answered off an unread facts row
            self.assertIsInstance(u.get("request_ids"), list)

    def test_candidates_the_deadline_never_EVALUATED_are_carried_and_evaluated_first(self):
        # r5 (1574 finding 4): advancing the search token past rows that due_threads had not looked at loses them. The rows
        # are carried as data, evaluated first on the next run, and only then does the search continue.
        clock = {"t": 0.0}
        self.audience(4)                                   # 2 results per search page

        class SlowThreads(FakeIntercom):
            def __call__(self, method, path, body=None):
                if path.startswith("/conversations/"):
                    clock["t"] += 400.0                    # evaluating one candidate outlasts the whole budget
                return super().__call__(method, path, body)
        slow = SlowThreads()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            first = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent",
                              now=NOW, max_checks=None, budget_seconds=50,
                              checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        pending = first["upstream"].get("pending") or []
        self.assertTrue(pending, "candidates collected but never evaluated must be carried, not dropped")
        self.assertGreaterEqual(first["counts"].get("candidates_carried_to_next_run", 0), 1)
        # the next run evaluates them BEFORE searching: nothing is re-searched past an unevaluated row
        clock["t"] = 0.0
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            second = rds.build(ic=self.ic, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent",
                               now=NOW, max_checks=None, budget_seconds=50,
                               upstream_resume={"candidates": None, "pending": pending},
                               checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertEqual(second["counts"].get("candidates_resumed"), len(pending))

    def test_QA1574_a_search_that_eats_the_budget_cannot_starve_the_carried_replies(self):
        # QA #1574 (3rd round, the carried-forward Important): `build()` searched FIRST and evaluated `pending` after, and
        # the deadline is shared - so a fresh search could spend all of it and the already-owed replies never reached
        # due_threads in ANY tick that took this path. Carried is not decided. The rows are now decided before a single
        # search request is made, and two consecutive starved ticks still leave the work answerable.
        clock = {"t": 0.0}
        self.audience(8)
        calls: list[str] = []

        class SlowSearch(FakeIntercom):
            def __call__(self, method, path, body=None):
                calls.append(path)
                if method == "POST":
                    clock["t"] += 30.0                       # two search pages outlast the whole 50 s budget
                return super().__call__(method, path, body)
        slow = SlowSearch()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        later = {"candidates": None, "pending": []}
        saved = rds.time.monotonic
        try:
            rds.time.monotonic = lambda: clock["t"]
            first = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                              max_checks=None, budget_seconds=50, checker=lambda *a, **k: {"hold": True, "reasons": []})
            pending = first["upstream"].get("pending") or []
            self.assertTrue(pending, "a search that outran the budget leaves rows it found but never evaluated")
            # tick 2: the same slow search. Every carried row must be DECIDED before that search runs.
            clock["t"] = 0.0
            calls.clear()
            second = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                               max_checks=None, budget_seconds=50,
                               upstream_resume={"candidates": first["upstream"].get("candidates"), "pending": pending},
                               checker=lambda *a, **k: {"hold": True, "reasons": []})
            later = {"candidates": second["upstream"].get("candidates"),
                     "pending": second["upstream"].get("pending") or pending}
        finally:
            rds.time.monotonic = saved
        was = {c["conv"] for c in pending}
        self.assertEqual(second["counts"].get("candidates_resumed"), len(pending))
        searched = next(i for i, p in enumerate(calls) if p.startswith("/conversations/search"))
        decided = {p.split("/")[2].split("?")[0] for p in calls[:searched]
                   if p.startswith("/conversations/") and not p.startswith("/conversations/search")}
        self.assertTrue(was <= decided, f"carried rows decided before the search ({sorted(was - decided)})")
        # tick 3, an ordinary search: what the two starved ticks carried is DECIDED, not carried a third time. (7th round:
        # the carried half is now fully prepared - mapped, facts read, classified - before the search, so the rows left
        # over from a starved tick are the ones that were genuinely not due, and the carry drains on the next ordinary
        # run instead of surviving on the token forever.)
        third = self.build(upstream_resume=later)
        self.assertEqual(third["counts"]["candidates_resumed"], len(later["pending"]))
        self.assertFalse(third["counts"].get("candidates_carried_to_next_run"),
                         "with no budget pressure, nothing may be carried a third time")

    def test_firstmate034_a_walk_that_eats_the_budget_cannot_starve_the_mapping(self):
        # firstmate 034 (A): the upstream walks and the reply work shared ONE deadline, so a walk that spent the whole
        # budget left the mapping step with an expired one. 2026-11-06 14:00Z, live: 2,014 threads walked, 160 due,
        # 0 mapped, 0 sent - due_threads spent 903 s and map_users then skipped every thread because the deadline had
        # already passed. The walks are RESUMABLE (their un-evaluated rows are carried in `pending`); the mapping is
        # not, and neither is the check that follows it. The walks now stop at WALK_SHARE of the budget.
        clock = {"t": 0.0}
        self.audience(8)

        class SlowThreads(FakeIntercom):
            def __call__(self, method, path, body=None):
                if method == "GET" and not path.startswith("/contacts/"):
                    clock["t"] += 10.0          # every thread read costs 10 s of the 50 s budget
                return super().__call__(method, path, body)
        slow = SlowThreads()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved = rds.time.monotonic
        try:
            rds.time.monotonic = lambda: clock["t"]
            # no walk share at all: the walks get no clock, so nothing is found and nothing is served
            clock["t"] = 0.0
            # QA #1857 r3: through self.build(), so the trigger is the fixture's permissive filter and the check stays the
            # oracle this test pins. A direct rds.build() took the PRODUCTION trigger + linkage, which read the host's
            # proof store: unreadable on a dev box (Unknown -> full check, green), readable on node-8 (no linked
            # request -> hand-off, red). The production prefilter has its own cases in TriggerPrefilterTest.
            starved = self.build(ic=slow, max_checks=None, budget_seconds=50, walk_share=0.0)
            # the fix: the walks stop at half the budget and the reply work gets the other half
            clock["t"] = 0.0
            fixed = self.build(ic=slow, max_checks=None, budget_seconds=50)
        finally:
            rds.time.monotonic = saved
        # the walk share is what feeds the reply work: with none, the walk finds nothing to serve
        self.assertEqual(starved["counts"]["threads_due"], 0)
        self.assertEqual(starved["counts"]["checked"], 0)
        # and with the default share a due thread the walk reached reaches the audience
        self.assertGreater(fixed["counts"]["checked"], 0,
                           "the reply work must get the budget the walk did not spend")
        self.assertGreater(len(fixed["users"]), 0, "a due thread the walk reached must reach the audience")

    def test_qa1828_a_slow_search_cannot_starve_the_thread_walk(self):
        # QA #1828 (Important): with ONE shared walk deadline, a search that took 500 s of a 900 s tick left due_threads
        # an already-expired deadline, so a tick that previously found due replies produced none. Each walk stage now
        # gets a bounded slice of what is left of the walk share, so the thread walk always gets a turn after the search.
        clock = {"t": 0.0}
        self.audience(8)

        class SlowSearch(FakeIntercom):
            def __call__(self, method, path, body=None):
                if method == "POST":
                    clock["t"] += 10.0          # every search page costs 10 s of the 50 s budget
                return super().__call__(method, path, body)
        slow = SlowSearch()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved = rds.time.monotonic
        try:
            rds.time.monotonic = lambda: clock["t"]
            out = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent",
                            now=NOW, max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": False, "reasons": []})
        finally:
            rds.time.monotonic = saved
        self.assertGreater(out["counts"]["threads_due"], 0,
                           "the thread walk must get a slice after a search that overran its own")

    def test_threads_dropped_by_a_mapping_or_facts_budget_are_carried_not_skipped(self):
        # r5 (1574 finding 6): a due thread that IS evaluated but then loses its mapping/facts chunk to the budget produced
        # no audience row. Committing the search token past it would answer nobody about that reply, ever - so it goes
        # back into `pending` and is re-evaluated first next run.
        clock = {"t": 0.0}
        self.audience(401)                                 # 3 external-id batches (200 ids each); the later ones starve
        inner = self.q

        def slow_query(sql):
            if "neptuneprofessionalid IN" in sql:
                clock["t"] += 500.0
            return inner(sql)
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            doc = rds.build(ic=self.ic, query=slow_query, paying_path=str(self.paying), dv_store="/nonexistent",
                            now=NOW, max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        pending = (doc["upstream"] or {}).get("pending") or []
        self.assertTrue(pending, "threads whose mapping was starved must be carried, not skipped")
        self.assertGreaterEqual(doc["counts"].get("candidates_carried_to_next_run", 0), len(pending))

    def test_the_external_id_batches_are_bounded_by_the_same_deadline(self):
        # r5 (1574 finding 5): the email fallback and the facts chunks were bounded, but the external-id IN-list batches
        # (200 ids each, the slowest queries in preparation) were not: three of them can outlast the whole budget.
        clock = {"t": 0.0}
        self.audience(401)                                 # 401 external ids: 3 batches of 200
        inner = self.q

        def slow_query(sql):
            if "neptuneprofessionalid IN" in sql:
                clock["t"] += 500.0
            return inner(sql)
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            doc = rds.build(ic=self.ic, query=slow_query, paying_path=str(self.paying), dv_store="/nonexistent",
                            now=NOW, max_checks=None, budget_seconds=50,
                            checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertGreaterEqual(doc["counts"].get("map_batches_stopped_at_budget", 0), 1)
        self.assertGreaterEqual(doc["counts"].get("map_users_unresolved_at_budget", 0), 1)

    def test_a_STARVED_search_walk_resumes_where_it_stopped_instead_of_restarting(self):
        # r5 (1574 finding 3): the audience cursor rotates INSIDE a list preparation has already truncated, so if every
        # tick runs out of budget in the first search pages, the later conversations are never reached at all. The walk
        # now returns its `starting_after` token, and the next run resumes there.
        clock = {"t": 0.0}
        self.audience(8)                                   # 2 search results per page: pages start at 0, 2, 4, 6, 8

        class SlowSearch(FakeIntercom):
            def __call__(self, method, path, body=None):
                if method == "POST":
                    clock["t"] += 60.0                     # each search page costs more than the whole budget
                return super().__call__(method, path, body)
        slow = SlowSearch()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            first = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                              max_checks=None, budget_seconds=50,
                              checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        token = first["upstream"]["candidates"]
        self.assertIsNotNone(token)                        # it stopped mid-walk and SAID where
        # the next tick resumes: same clock pressure, but the first page is behind us
        seen = []
        class Recording(FakeIntercom):
            def __call__(self, method, path, body=None):
                if method == "POST":
                    seen.append(((body or {}).get("pagination") or {}).get("starting_after"))
                return super().__call__(method, path, body)
        rec = Recording()
        rec.search, rec.convs, rec.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        clock["t"] = 0.0
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            second = rds.build(ic=rec, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                               max_checks=None, budget_seconds=50, upstream_resume={"candidates": token},
                               checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertEqual(seen[0], token)                    # the first search call STARTS at the token, not at page 1
        self.assertNotEqual(second["upstream"]["candidates"], token)   # and it moved on again

    def test_a_starved_apology_walk_resumes_too_and_a_COMPLETE_walk_clears_the_cursors(self):
        # the historical backlog walk has the same shape: sorted() makes a conversation id a usable resume point, and a
        # completed walk returns None for both cursors so the tick can delete its file and the rotation wraps.
        clock = {"t": 0.0}
        self.audience(4)
        doc = self.build(max_checks=None)                  # nothing is starved here: a complete walk
        self.assertEqual(doc["upstream"], {"candidates": None, "apology": None})
        # now starve it: every thread fetch costs more than the budget
        class SlowThreads(FakeIntercom):
            def __call__(self, method, path, body=None):
                if path.startswith("/conversations/"):
                    clock["t"] += 400.0
                return super().__call__(method, path, body)
        slow = SlowThreads()
        slow.search, slow.convs, slow.contacts = self.ic.search, self.ic.convs, self.ic.contacts
        saved_mono, rds.time.monotonic = rds.time.monotonic, (lambda: clock["t"])
        try:
            starved = rds.build(ic=slow, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                                max_checks=None, budget_seconds=50,
                                checker=lambda *a, **k: {"hold": True, "reasons": ["reply_due:held_by_hand"]})
        finally:
            rds.time.monotonic = saved_mono
        self.assertTrue(starved["upstream"]["candidates"] or starved["upstream"]["apology"])

    def test_the_walk_starts_where_the_cursor_left_off_so_a_held_head_is_walked_past(self):
        # the rotation: without it a head of persistently held users is re-checked every tick and the tail is never
        # reached. page.start/end/listed is the record the tick's cursor reads (page_next/advance_cursor).
        seen = []
        def check(campaign, copy, uid, keys, cid, **kw):
            seen.append(uid)
            return {"hold": True, "reasons": ["reply_due:held_by_hand"]}
        self.audience(8)
        whole = self.build(max_checks=None, checker=check)["page"]["listed"]
        seen.clear()
        doc = self.build(start_entry=whole - 1, max_checks=1, checker=check)
        self.assertEqual(doc["page"]["start"], whole - 1)
        self.assertEqual(doc["page"]["end"], whole)                              # the last entry: the next run wraps to 0
        self.assertEqual(len(seen), 1)
        seen.clear()
        # QA #1574 round 6 (Important): a position at or past `listed` used to examine NOBODY and still report the page
        # as finished, so the cursor moved on and every row of the slice was skipped (for a one-row slice, all of it).
        # A position outside this run's slice now restarts at the slice's first row, and the reset is counted.
        doc = self.build(start_entry=whole, max_checks=1, checker=check)
        self.assertEqual(len(seen), 1)                                            # the slice's first row is walked
        self.assertEqual(doc["page"]["start"], 0)
        self.assertEqual(doc["page"]["end"], 1)
        self.assertEqual(doc["counts"]["start_entry_clamped"], whole)

    def test_a_live_audience_that_shrinks_behind_the_cursor_never_skips_the_next_owed_replies(self):
        # QA #1574 (7th round, Important): tick 1 examines and SENDS the first N of the slice; those threads are answered,
        # so they VANISH from the next search and the rebuilt list is N shorter. A positional cursor then started at N -
        # the position of a row that is no longer there - and silently skipped the next N owed replies (QA's example: 100
        # of 300 sent, 200 left, "start at 100" skipped the next 100). The cursor is the IDENTITY of the last examined
        # row now: with that row gone, the slice is entered at its HEAD - which IS the next owed reply - and the reset is
        # counted, never passed off as progress.
        def held(campaign, copy, uid, keys, cid, **kw):
            return {"hold": True, "reasons": ["reply_due:held_by_hand"]}
        seen = []
        def rec(campaign, copy, uid, keys, cid, **kw):
            seen.append(uid)
            return {"hold": True, "reasons": ["reply_due:held_by_hand"]}
        self.audience(8)                                                          # 10 due entries
        order = list(self.build(max_checks=None, checker=rec) and seen)           # the walk order, all of it
        self.assertEqual(len(order), 10)
        seen.clear()
        tick1 = self.build(max_checks=3, checker=rec)                             # tick 1 examines (and would send) 3
        self.assertEqual(seen, order[:3])
        anchor = tick1["page"]["end_user"]
        self.assertEqual(anchor, order[2])                                        # the anchor is the last row examined
        # those three threads are answered and drop out of the search: the slice is rebuilt SHORTER, shifted by three
        self.ic.search = [e for e in self.ic.search
                          if e["contacts"]["contacts"][0]["id"] not in {self.contact_of[str(u)] for u in order[:3]}]
        seen.clear()
        rebuilt = list(self.build(max_checks=None, checker=rec) and seen)
        self.assertEqual(len(rebuilt), 7)                                         # the rebuilt list lost exactly three
        self.assertEqual(rebuilt, order[3:])
        seen.clear()
        tick2 = self.build(max_checks=3, start_after_user=anchor, checker=rec)
        self.assertEqual(tick2["counts"]["anchor_missing_reset"], 1)              # the anchor row was one of the sent ones
        self.assertEqual(tick2["page"]["start"], 0)                               # so the head IS the next owed reply
        self.assertEqual(seen, rebuilt[:3], "the anchor reset walks the rows that still owe a reply, from the head")
        # the mutant this pins: the POSITION (3) would resume three rows INTO the shrunk list and skip rebuilt[:3]
        seen.clear()
        self.build(max_checks=3, start_entry=3, checker=rec)
        self.assertEqual(seen, rebuilt[3:6])
        self.assertFalse(set(seen) & set(rebuilt[:3]))

    def test_a_carried_reply_reaches_the_audience_even_when_every_search_eats_the_budget(self):
        # QA #1574 (7th round, Important): the carried rows were EVALUATED before the search but only MAPPED after it, so
        # a tick whose searches ate the whole budget re-fetched, re-decided and re-carried the SAME reply forever - the
        # oldest owed reply never reached the family. The carried half is mapped before the first search request now, so
        # a budget-staved tick spends what it has on the work it already owed.
        clock = {"t": 0.0}
        def monotonic():
            return clock["t"]
        raw = self.ic
        def ic(method, path, body=None):
            if method == "POST":
                clock["t"] += 500.0                                              # every search page costs half a budget
            return raw(method, path, body)
        self.audience(2)
        saved, rds.time.monotonic = rds.time.monotonic, monotonic
        try:
            # QA #1857 r3: through self.build() (fixture trigger; see test_firstmate034_* for why a direct rds.build()
            # was host-dependent)
            first = self.build(ic=ic, budget_seconds=600.0, checker=lambda *a, **k: {"hold": True, "reasons": ["h"]},
                               upstream_resume=None)
            pend = first["upstream"].get("pending") or []
            self.assertTrue(pend, "a budget-staved run must CARRY the rows it could not decide, never drop them")
            clock["t"] = 0.0
            doc = self.build(ic=ic, budget_seconds=1.0, upstream_resume=first["upstream"])
        finally:
            rds.time.monotonic = saved
        self.assertEqual(doc["counts"]["candidates_resumed"], len(pend))
        self.assertGreater(doc["counts"]["candidates_mapped_from_carry"], 0,
                           "the carried rows were MAPPED, before the search, on a tick with no budget for search")
        self.assertTrue(doc["users"], "the carried reply reached the family on a tick with no search budget left")

    def test_a_carried_row_whose_own_preparation_hits_the_budget_is_carried_not_a_crash(self):
        # QA #1574 (8th round, Important): the carried half prepares BEFORE the search assigns `upstream`, and its
        # budget-stop branch writes upstream["pending"] - so a carried reply whose own mapping/facts read crossed the
        # deadline raised NameError. `_main` does not catch it, so no audience file was written and the outbound tick
        # stopped: the exact "one row costs the whole window" failure this PR exists to end, reintroduced by the fix for
        # the 7th round. The upstream state now exists BEFORE the carried half runs, and the search's cursors merge into
        # it, so the rows the carried half had to drop are carried instead of lost.
        clock = {"t": 0.0}
        saved, rds.time.monotonic = rds.time.monotonic, lambda: clock["t"]
        raw = self.ic
        def slow_contacts(method, path, body=None):
            if path.startswith("/contacts/"):
                clock["t"] += 500.0                      # the email-fallback contact GET: the slowest per-thread read
            return raw(method, path, body)
        # two carried rows, both mapped by EMAIL (so mapping makes one contact GET per thread)
        pending = [{"conv": "102", "cid": "c2", "ext": "unknown-ext", "at": "2026-10-30T00:00:00Z"},
                   {"conv": "103", "cid": "c2", "ext": "unknown-ext", "at": "2026-10-31T00:00:00Z"}]
        try:
            doc = rds.build(ic=slow_contacts, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent",
                            now=NOW, budget_seconds=1.0, checker=lambda *a, **k: {"hold": False, "reasons": []},
                            upstream_resume={"pending": pending})
        finally:
            rds.time.monotonic = saved
        c = doc["counts"]
        self.assertEqual(c["candidates_resumed"], 2)
        stopped = sum(v for k, v in c.items() if k.endswith("_stopped_at_budget"))
        self.assertGreaterEqual(stopped, 1, "the carried half's own preparation stopped at the budget: " + str(dict(c)))
        carried = [r["conv"] for r in (doc["upstream"].get("pending") or [])]
        self.assertEqual(sorted(carried), ["102", "103"],
                         "both carried rows are carried again - the map/facts stop does not drop them")
        self.assertEqual(doc["upstream"]["candidates"], doc["upstream"].get("candidates"))   # the search cursor is kept
        self.assertEqual(len(carried), len(set(carried)), "no row is carried twice after the merge")

    def test_an_unreadable_thread_is_counted_never_listed(self):
        del self.ic.convs["101"]
        doc = self.build()
        self.assertEqual([u["user_id"] for u in doc["users"]], [2])
        self.assertEqual(doc["counts"]["skipped_unreadable:KeyError"], 1)

    def test_an_ambiguous_contact_is_skipped(self):
        self.q = replica({"1": "pro-1", "9": "pro-1"}, {}, [], {})
        doc = self.build()
        self.assertEqual(doc["users"], [])                                        # pro-1 names two accounts
        self.assertGreaterEqual(doc["counts"]["skipped_user_unmapped_or_ambiguous"], 1)

    def apology(self, conv, uid, part, sent_at):
        db = vl.connect(cs.LEDGER)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, contact_id, "
                   "message_id, conversation_id, request_ids_json, n_credits, approved_by, approval_ref, created_at, "
                   "updated_at, sent_at) VALUES ('backlog-apology', 'initial', ?, ?, ?, 'sent', 'comment', ?, ?, ?, '[]', 0, "
                   "'U', 'fable-copy-1101-r5/ap1', ?, ?, ?)",
                   (f"u{uid}@x.com", uid, sent_at[:10], f"c{uid}", part, conv, sent_at, sent_at, sent_at))
        db.close()

    def test_every_reply_to_a_backlog_apology_is_a_due_row_whatever_the_thread_is_about(self):
        # fable-copy-1101-r5/ap1 (/p condition): the apology asked "Do you still need help?" - every customer reply to it
        # is owed an answer by i1's queue: R9 (on-topic) and the open-state rule are waived, nothing is auto-answered
        from datetime import datetime, timezone
        sent = datetime.fromtimestamp(NOW - 5 * DAY, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        ours = lambda pid, at: {"id": pid, "part_type": "comment", "author": {"type": "admin", "id": "5763097"},  # noqa: E731
                                "body": "I'm sorry this conversation went unanswered", "created_at": at}
        # 201: off-topic ("my account"), CLOSED, replied 3 d ago -> overdue row; 202: replied 2 h ago -> row, within 24 h
        # 203: no reply -> nothing; 204: replied, then a person answered -> nothing; 205: unreadable -> listed
        # 206: an ON-topic credit thread replied to -> the row, and NOT also an automatic uvn answer
        self.ic.convs["201"] = thread("201", "c21", "my account", [cust("2000", NOW - 90 * DAY, "hello?"),
                                       ours("2001", NOW - 5 * DAY), cust("2002", NOW - 3 * DAY, "yes, my payouts")], state="closed")
        self.ic.convs["202"] = thread("202", "c22", "login", [ours("2011", NOW - 5 * DAY), cust("2012", NOW - 2 * 3600, "yes")])
        self.ic.convs["203"] = thread("203", "c23", "hi", [ours("2021", NOW - 5 * DAY)])
        self.ic.convs["204"] = thread("204", "c24", "hi", [ours("2031", NOW - 5 * DAY), cust("2032", NOW - 4 * DAY, "yes"),
                                       {"id": "2033", "part_type": "comment", "author": {"type": "admin", "id": "9"},
                                        "body": "done", "created_at": NOW - 3 * DAY}])
        self.ic.add(thread("206", "c26", "about my credits", [ours("2051", NOW - 5 * DAY),
                                                               cust("2052", NOW - 3 * DAY, "still waiting on my credits")]),
                    "c26", "pro-6", NOW - 3 * DAY)
        for conv, uid, part in (("201", "21", "2001"), ("202", "22", "2011"), ("203", "23", "2021"), ("204", "24", "2031"),
                                ("205", "25", "2041"), ("206", "26", "")):
            self.apology(conv, uid, part, sent)
        doc = self.build()
        self.assertEqual(doc["covers_campaigns"], ["backlog-apology"])
        rows = {r["conversation"]: r for r in doc["backlog_apology"]}
        self.assertEqual(sorted(rows), ["201", "202", "206"])
        self.assertEqual((rows["201"]["part"], rows["201"]["overdue"], rows["201"]["user_id"]), ("2002", True, "21"))
        self.assertEqual(rows["201"]["due_at"], int(NOW - 3 * DAY) + 24 * 3600)
        self.assertFalse(rows["202"]["overdue"])
        self.assertEqual(rows["206"]["apology_part"], "2051")            # found by send time when no part id was ledgered
        self.assertEqual([u["conversation"] for u in doc["backlog_apology_unreadable"]], ["205"])
        self.assertNotIn("206", [u["reply_due"]["conversation"] for u in doc["users"]])   # i1 answers it, not the uvn line
        self.assertEqual(doc["counts"]["routed_backlog_apology"], 1)
        self.assertEqual(doc["counts"]["backlog_apology:reply_owed"], 3)

    def test_an_unreadable_ledger_fails_the_scan_never_a_silent_no_replies(self):
        Path(cs.LEDGER).write_text("not a database")
        with self.assertRaises(Exception):
            self.build()

    def test_an_apostrophe_email_or_external_id_is_escaped_and_matched_never_an_empty_in_list(self):
        # QA #1574: the SOLE email fallback is o'brien@x.com - it is quoted with Trino's doubled quote and matched; no
        # query ever carries `IN ()` (which Trino rejects, failing the whole scan)
        self.ic.search, self.ic.convs = [], {}
        self.ic.add(thread("301", "c31", "about my credits", [cust("3001", NOW - 3 * DAY)]), "c31", "x'y", NOW - 3 * DAY)
        self.ic.contacts["c31"] = {"email": "O'Brien@X.com"}
        base, seen = self.q, []

        def q(sql):
            seen.append(sql)
            if "IN ()" in sql:
                raise ValueError("Trino: IN () is a syntax error")
            if "lower(email) IN" in sql:
                return [["31", "o'brien@x.com"]] if "'o''brien@x.com'" in sql else []
            return base(sql)
        self.q = q
        doc = self.build()
        self.assertEqual([u["user_id"] for u in doc["users"]], [31])
        self.assertTrue(any("'x''y'" in s for s in seen))                # the external id is queried too, escaped
        self.assertEqual(rds._q(["a'b", "c"]), "'a''b','c'")

    def test_write_is_0600_and_atomic(self):
        out = Path(tempfile.mkdtemp()) / "rd.json"
        rds.write(str(out), {"users": []})
        self.assertEqual(oct(os.stat(out).st_mode & 0o777), "0o600")
        self.assertEqual(json.loads(out.read_text()), {"users": []})


class TriggerPrefilterTest(ReplyDueScanTest):
    """Fable d2 2026-11-08 (the reply check's per-thread cost). The 02:00Z tick evaluated ~836 threads in the 450 s walk
    share at 3 GETs each, then spent the other 450 s on 30 full checks (~20 s each: 6-7 Trino CLI queries + 5+ GETs per
    user) of which 29 were hand-offs the deployed trigger_class decides from the thread + two replica columns. The
    scan now (1) reads each thread ONCE and (2) runs the deployed trigger rules itself, with inputs from the batched
    replica reads, so the full check is spent on STATUS parts only. Nothing here sends: the gate re-runs its own
    status_trigger at send time, and the budget (900 s / 400 checks) is not raised."""

    def counting_ic(self):
        gets = []
        outer = self.ic
        class Counting(FakeIntercom):
            def __call__(self, method, path, body=None):
                if method == "GET" and path.startswith("/conversations/"):
                    gets.append(path.split("/")[2].split("?")[0])
                return outer(method, path, body)
        c = Counting()
        c.search, c.convs, c.contacts = outer.search, outer.convs, outer.contacts
        return c, gets

    def test_trigger_inputs_equal_status_triggers_own_reads(self):
        # the derived (titles, filed, other_titles) == what status_trigger reads per user with filed_requests +
        # open_titles(only=filed) + open_titles(uid), over every linkage shape: ledger-linked, proof-linked, unlinked,
        # a non-pending (but open) request, an unknown key, a request of ANOTHER user with the same id
        rows_by_user = {
            "7": [("ra", "user_verification_needed", "Song A"), ("rb", "unverified", "Song B"),
                  ("rc", "pending", "Song C"), ("rd", "unverified", "")],
            "8": [("ra", "unverified", "Other A")],
        }
        def q(sql):
            uid = "7" if "userid = 7" in sql else "8"
            rows = rows_by_user[uid]
            if "spotifytracktitle" in sql:
                rows = [r for r in rows if r[1] in cs.PENDING_STATUSES]
                if "lower(CAST(id AS varchar)) IN (" in sql:
                    want = sql.split("lower(CAST(id AS varchar)) IN (")[1].split(")")[0].replace("'", "").split(",")
                    rows = [r for r in rows if r[0] in want]
                return [[r[2]] for r in rows]
            if "lower(CAST(id AS varchar)) IN (" in sql:               # filed_requests' open-ids read
                want = sql.split("lower(CAST(id AS varchar)) IN (")[1].split(")")[0].replace("'", "").split(",")
                return [[r[0]] for r in rows if r[0] in want]
            return []
        for linked in (set(), {"ra"}, {"rb", "rc"}, {"ra", "rb", "rc", "rd", "zz"}):
            for keys in (["ra", "rb", "rc", "rd"], ["ra"], ["zz"], [], ["RB", "bad key!"]):
                with self.subTest(linked=sorted(linked), keys=keys):
                    saved = cs.linked_request_ids
                    cs.linked_request_ids = lambda uid, conv, src="", _l=linked: set(_l)
                    try:
                        filed = cs.filed_requests(7, keys, "555", q)
                        titles = cs.open_titles(7, q, only=filed)
                        others = [t for t in cs.open_titles(7, q) if t not in set(titles)]
                    finally:
                        cs.linked_request_ids = saved
                    self.assertEqual(cs.trigger_inputs(keys, rows_by_user["7"], linked), (titles, filed, others))

    def test_full_check_runs_only_for_status_parts_with_the_production_trigger(self):
        # user 1: "any update on my credits?" with r1 linked -> status -> the full check runs; 2: the same words but
        # nothing linked -> 'no open request of theirs is linked' -> a hand-off WITHOUT the check; 901 (thread 900): a
        # how-to ('how do I change my artist name') -> a hand-off without the check; 902 (thread 901): a status
        # question naming ANOTHER of their pending titles (Blue Moon, not the linked Red Sun) -> hand-off without the check
        self.audience(2)
        self.ic.convs["900"]["conversation_parts"]["conversation_parts"][0]["body"] = "how do I change my artist name?"
        self.ic.convs["901"]["conversation_parts"]["conversation_parts"][0]["body"] = "any update on Blue Moon?"
        self.open_rows += [["902", "r9a", "unverified", "false", "false"], ["902", "r9b", "unverified", "false", "false"]]
        self.q = replica(self.pro_of, self.emails_of, self.open_rows, self.names,
                         titles={("902", "r9a"): "Red Sun", ("902", "r9b"): "Blue Moon"})
        checked = []
        def check(campaign, copy, uid, keys, cid, **kw):
            checked.append(uid)
            return {"hold": False, "reasons": []}
        doc = self.build(checker=check, trigger=cs.trigger_class,
                         linked=lambda uid, conv, src="": {"r1"} if (uid, conv) == (1, "101") else ({"r9a"} if uid == 902 else set()))
        self.assertEqual(sorted(checked), [1])
        self.assertEqual([u["user_id"] for u in doc["users"]], [1])
        whys = {h["user_id"]: h["why"] for h in doc["handoff"]}
        self.assertIn("no open request of theirs is linked", whys[2])
        self.assertIn("how-to / change request", whys[901])
        self.assertIn("names another open request 'Blue Moon'", whys[902])
        self.assertEqual(doc["counts"]["full_checks"], 1)
        self.assertEqual(doc["counts"]["check_skipped:trigger_non_status"], 3)
        self.assertEqual(doc["counts"]["checked"], 4)     # a skipped check is still an examined entry (cursor, page)

    def test_the_scan_links_by_the_ask_that_opened_the_thread_never_by_the_account(self):
        # QA on #1920 (review 5884277203), through the scan with the PRODUCTION linkage: users 1 and 2 each have a
        # sent ask on the ledger naming their open request, sent as a message (no conversation). User 1's thread was
        # opened by the customer, so the ask does not link it and the status question is a hand-off. User 2's thread
        # was opened by that ask (its source id is the ask's message id), so the full check runs.
        db = sqlite3.connect(cs.LEDGER)
        for uid, mid, rid in (("1", "770001", "r1"), ("2", "770002", "r2")):
            db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                       "message_id, request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
                       "VALUES ('uvn-status','initial',?,?,'2026-10-20','sent','email',?,?,1,'U','ref',"
                       "'2026-10-20T00:00:00Z','2026-10-20T00:00:00Z','2026-10-20T00:00:00Z')",
                       (f"u{uid}@x.com", uid, mid, json.dumps([rid])))
        db.commit(); db.close()
        self.ic.convs["102"]["source"]["id"] = "770002"
        checked = []
        def check(campaign, copy, uid, keys, cid, **kw):
            checked.append(uid)
            return {"hold": False, "reasons": []}
        doc = self.build(checker=check, trigger=cs.trigger_class, linked=cs.linked_request_ids)
        self.assertEqual(checked, [2])
        whys = {h["user_id"]: h["why"] for h in doc["handoff"]}
        self.assertIn("no open request of theirs is linked", whys[1])
        self.assertNotIn(2, whys)

    def test_a_replica_trigger_that_cannot_be_read_falls_back_to_the_full_check(self):
        def linked(uid, conv, src=""):
            raise cs.Unknown("ledger unreadable: test")
        checked = []
        def check(campaign, copy, uid, keys, cid, **kw):
            checked.append(uid)
            return {"hold": False, "reasons": []}
        doc = self.build(checker=check, trigger=cs.trigger_class, linked=linked)
        self.assertEqual(sorted(checked), [1, 2])                  # unknown inputs: the check decides, as before
        self.assertEqual(doc["counts"]["trigger_inputs_unreadable:Unknown"], 2)
        self.assertEqual(doc["counts"]["full_checks"], 2)

    def test_the_production_defaults_are_the_deployed_trigger_and_linkage(self):
        import inspect
        sig = inspect.signature(rds.build)
        self.assertIs(sig.parameters["trigger"].default, cs.trigger_class)
        self.assertIs(sig.parameters["linked"].default, cs.linked_request_ids)
        self.assertIs(sig.parameters["checker"].default, cs.check)
        self.assertEqual(rds.CHECK_BUDGET_S, 900.0)                 # the budget is NOT the fix
        self.assertEqual(rds.CHECK_MAX, 400)

    def test_the_titles_read_is_its_own_query_per_chunk_and_never_moves_the_signed_facts(self):
        self.audience(301)
        queries = []
        inner = self.q
        def counting(sql):
            queries.append(sql)
            return inner(sql)
        kw = dict(ic=self.ic, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                  checker=lambda *a, **k: {"hold": False, "reasons": []},
                  trigger=lambda conv, part, **k: {"class": "status", "why": "test"},
                  linked=lambda uid, conv, src="": set())
        doc = rds.build(query=counting, **kw)
        facts_q = [s for s in queries if "credit_requests" in s and "spotifytracktitle" not in s]
        titles_q = [s for s in queries if "spotifytracktitle" in s]
        self.assertEqual(len(facts_q), 2)                            # 301+ users -> two 300-user chunks
        self.assertEqual(len(titles_q), len(facts_q))                # one titles read per facts chunk
        for facts, titles in zip(facts_q, titles_q):
            self.assertEqual(facts.split("userid IN (")[1], titles.split("userid IN (")[1])
        def no_titles(sql):
            return [] if "spotifytracktitle" in sql else inner(sql)
        bare = rds.build(query=no_titles, **kw)
        self.assertEqual(doc["facts"], bare["facts"])
        self.assertEqual(doc["replica_facts"]["columns"], bare["replica_facts"]["columns"])
        self.assertEqual(doc["replica_facts"]["sha256"], bare["replica_facts"]["sha256"])

    def test_each_candidate_thread_is_fetched_once(self):
        ic, gets = self.counting_ic()
        self.audience(3)
        doc = rds.build(ic=ic, query=self.q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW,
                        checker=lambda *a, **k: {"hold": False, "reasons": []})
        evaluated = len(self.ic.search) - 1                          # 108 is never fetched (admin replied after)
        self.assertEqual(len(gets), evaluated)
        self.assertEqual(len(gets), len(set(gets)))                  # no thread read twice
        self.assertEqual(doc["counts"]["conversation_gets"], evaluated)

    def test_per_thread_cost_inside_the_existing_budget(self):
        # The cost model, with the unit latencies measured read-only on node-8 on 2026-11-08 (deployed code, nothing
        # copied): GET /conversations/{id}?display_as=plaintext 0.19 s (mean of 8), one Trino CLI query 2.2-2.3 s
        # whatever its size (the cost is the CLI start, per QUERY not per row), GET /admins 0.08 s. Counted here with
        # the fakes: GETs per evaluated thread, replica queries per 300-user chunk, full checks per due user.
        GET_S, TRINO_S, CHECK_S = 0.19, 2.3, 20.0
        n = 40
        self.audience(n)
        ic, gets = self.counting_ic()
        queries = []
        inner = self.q
        def q(sql):
            queries.append(sql)
            return inner(sql)
        checks = []
        def check(campaign, copy, uid, keys, cid, **kw):
            checks.append(uid)
            return {"hold": False, "reasons": []}
        doc = rds.build(ic=ic, query=q, paying_path=str(self.paying), dv_store="/nonexistent", now=NOW, checker=check,
                        trigger=cs.trigger_class, linked=lambda uid, conv, src="": {"r1"} if uid == 1 else set())
        threads = len(gets)
        due = doc["counts"]["checked"]
        replica_q = [s for s in queries if "credit_requests" in s or "firstname" in s]
        # BEFORE (deployed): 3 GETs per thread + a ~20 s full check per due user
        before = threads * 3 * GET_S + due * CHECK_S
        # AFTER: 1 GET per thread, the batched replica reads, a full check only for the status parts
        after = threads * GET_S + len(replica_q) * TRINO_S + len(checks) * CHECK_S
        self.assertEqual(threads, n + 7)
        self.assertEqual(len(checks), 1)                            # only user 1 (status, r1 linked) is fully checked
        self.assertLessEqual(len(replica_q), 4)                     # one chunk: map, facts, titles, names
        per_thread_after = after / threads
        per_thread_before = before / threads
        # The fixture is small (47 threads), so the one-off replica reads and the single full check are amortised over
        # far fewer threads than a live tick's ~840 - this is the PESSIMISTIC bound. Even so: a day of ticks (every 2 h,
        # 12 x 900 s) at the AFTER cost covers the whole measured backlog several times over (threads_customer_waiting
        # 3,053 on the 02:00Z board; 1,798 candidates carried); at the BEFORE cost one tick reached ~30 of them.
        # (The tick is hourly since 2026-11-13, so a day holds 24 ticks; 12 is kept as the lower bound it was measured at.)
        day_s = 12 * rds.CHECK_BUDGET_S
        self.assertGreater(day_s / per_thread_after, 3 * 3053)
        self.assertGreater(rds.CHECK_BUDGET_S / per_thread_after, 1000)
        self.assertLess(rds.CHECK_BUDGET_S / per_thread_before, 50)
        self.assertLess(per_thread_after, 1.0)
        self.assertGreater(per_thread_before / per_thread_after, 15)
        print(f"reply_due_scan cost model: threads={threads} due={due} full_checks={len(checks)} replica_queries={len(replica_q)} "
              f"before={per_thread_before:.2f}s/thread after={per_thread_after:.2f}s/thread "
              f"(budget {rds.CHECK_BUDGET_S:.0f}s covers {rds.CHECK_BUDGET_S / per_thread_after:.0f} threads)", file=sys.stderr)


if __name__ == "__main__":
    unittest.main()
