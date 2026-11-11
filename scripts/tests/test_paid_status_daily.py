"""scripts/paid-status/daily.sh, run for real against stub stages and a fake runner (no network, no ledger writes).

Pins the captain's 2026-10-27 01:0xZ order (firstmate 024): no proof ask that offers documents until a returned
document can be accepted. Without ASKS=1 the daily run must send status-only notes: no uvn-status runner call, no
credit_status_uvn_ask email, and no b0_gap (which reads "never messaged" as "ask skipped" only when asks ran;
2026-10-27 01:18Z incident). Also: a missing cs exclusion list refuses the run (fail closed) and the kill switch stops it.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAILY = os.path.join(HERE, "..", "paid-status", "daily.sh")
PARTIAL_ASKS = os.path.join(HERE, "..", "paid-status", "partial_asks.py")

STUBS = {
    "silent_count.py": """
        import json, os, sys
        d = sys.argv[1]; os.makedirs(d, exist_ok=True)
        open(f"{d}/silent-paid.txt", "w").write("1\\n2\\n"); open(f"{d}/silent-free.txt", "w").write("3\\n")
        print(json.dumps({"paid": {"silent_never_messaged_ever": 2}, "free": {"silent_never_messaged_ever": 1}}))
    """,
    "fraud_lens.py": "import sys; open(sys.argv[1] + '/never.txt', 'w').write('1\\n2\\n')",
    "segment.py": """
        import json, os, sys
        if os.environ.get("FAIL_SEGMENT"):
            sys.exit(1)
        D = os.environ["PWR_DIR"]
        json.dump([{"user_id": u, "msg_hold": False, "lens_held": False, "cs_excluded": False, "ask_only": False}
                   for u in (1, 2)], open(f"{D}/segments.json", "w"))
    """,
    "support7d.py": """
        import json, os
        held = os.environ.get("SUPPORT_HELD", "").split()
        json.dump([{"user_id": int(u), "human_7d": True} for u in held],
                  open(os.environ['PWR_DIR'] + '/support7d.json', 'w'))
    """,
    "classify2.py": """
        import json, os, sys
        out = sys.argv[sys.argv.index("--out-dir") + 1]
        users = open(sys.argv[sys.argv.index("--users") + 1]).read().split()
        open(os.environ["PWR_DIR"] + "/CLASSIFIED", "w").write(" ".join(users))
        json.dump([], open(out + "/dry-run-x.json", "w"))
    """,
    "core_notice.py": """
        import json, os, sys
        a = sys.argv
        if os.environ.get("FAIL_CORE_NOTICE"):
            sys.exit(2)
        held = os.environ.get("CORE_NOTICE_HELD", "").split()
        users = open(a[a.index("--users-file") + 1]).read().split()
        open(a[a.index("--out") + 1], "w").write("".join(u + "\\n" for u in users if u in held))
        print(json.dumps({"held": len(held)}))
    """,
    "build_lists.py": """
        import json, os
        D = os.environ["PWR_DIR"]
        u = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        for n in os.environ.get("LISTS", "A B U").split():
            json.dump({"generated_at": "x", "users": u}, open(f"{D}/list-{n}.json", "w"))
        json.dump({"uvn-status": u, "status-team-review": u}, open(f"{D}/email-lists.json", "w"))
        print("lists")
    """,
    "partial_asks.py": """
        import json, sys
        d = sys.argv[1]
        u = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"], "class": "PARTIAL"}]
        json.dump({"generated_at": "x", "users": u}, open(f"{d}/list-P.json", "w"))
        print(json.dumps({"partial_requests": 1, "users": 1, "paid": 1}))
    """,
    "b0_gap.py": """
        import json, os

        def ask_never_delivered(db, email, uid):
            return uid == 99   # the stub ledger: user 99's ask was refused

        if __name__ == "__main__":
            D = os.environ["PWR_DIR"]
            open(f"{D}/B0GAP_RAN", "w").write("1")
            u = [{"user_id": 2, "paid": True, "skip": None, "request_ids": ["r2"]}]
            for n in ("B2", "A3"):
                json.dump({"generated_at": "x", "users": u}, open(f"{D}/list-{n}.json", "w"))
            print("{}")
    """,
    "email_route.py": """
        import json, os, sys
        a = sys.argv; D = os.environ["PWR_DIR"]
        out = a[a.index("--out") + 1]; os.makedirs(out, exist_ok=True)
        mode = a[a.index("--mode") + 1]
        if mode == "dry-run":
            p = out + "/dry-run.json"
            json.dump({"rows": [{"user_id": 1, "campaign": "uvn-status", "decision": "send", "why": ""},
                                {"user_id": 1, "campaign": "status-team-review", "decision": "send", "why": ""},
                                {"user_id": 5, "campaign": "uvn-status", "decision": "skip", "why": "already noted (ledger)"},
                                {"user_id": 99, "campaign": "uvn-status", "decision": "skip", "why": "already noted (ledger)"}]},
                      open(p, "w"))
            print(p)
        else:
            rows = json.load(open(a[a.index("--approved") + 1]))["rows"]
            with open(D + "/EMAIL_APPLIED", "a") as fh:
                for r in rows:
                    if r["decision"] == "send":
                        fh.write(r["campaign"] + "\\n")
            print("applied")
            if os.environ.get("FAIL_EMAIL"):
                sys.exit(4)
    """,
    "health_check.py": "print('{\"verdict\": \"healthy\"}')",
    "receipts.py": """
        import json, os, sys
        if os.environ.get("FAIL_RECEIPTS"):
            print('{"error": "proof_intake unreadable"}'); sys.exit(2)
        out = sys.argv[sys.argv.index("--out-dir") + 1]
        u = lambda i, paid: {"user_id": str(i), "paid": paid, "skip": None, "request_ids": [f"q{i}"], "first_received": "x"}
        json.dump({"generated_at": "x", "users": [u(11, True), u(12, False)]}, open(out + "/receipts-queued.json", "w"))
        json.dump({"generated_at": "x", "users": [u(21, True)]}, open(out + "/receipts-received.json", "w"))
        print('{"counts": {"list_queued_paid": 1}}')
    """,
}
RECEIPT_LISTS = ("list-RQ.json", "list-RR.json")
RUNNER = """
    import os, sys
    with open(os.environ["CALLS"], "a") as fh:
        fh.write(" ".join(sys.argv[1:]) + "\\n")
    print("UVN STATUS (paid): 1 on the list, 0 messaged this run.")
    a = sys.argv
    if os.environ.get("FAIL_CAMPAIGN") == a[a.index("--campaign") + 1] and a[a.index("--mode") + 1] == "apply":
        sys.exit(1)
"""


class DailyShTest(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.bin = os.path.join(self.t, "bin"); os.makedirs(self.bin)
        for name, src in STUBS.items():
            open(os.path.join(self.bin, name), "w").write(textwrap.dedent(src))
        self.runner = os.path.join(self.t, "runner.py"); open(self.runner, "w").write(textwrap.dedent(RUNNER))
        self.ledger = os.path.join(self.t, "ledger.sqlite3")
        db = sqlite3.connect(self.ledger)
        db.execute("create table verify_messages (account_id text, day text, status text)"); db.commit(); db.close()
        self.env_file = os.path.join(self.t, "main.env"); open(self.env_file, "w").write("")
        self.excl = os.path.join(self.t, "exclude-cs.txt"); open(self.excl, "w").write("0\n")
        self.calls = os.path.join(self.t, "calls.txt"); open(self.calls, "w").write("")
        self.hold = os.path.join(self.t, "hold.txt"); open(self.hold, "w").write("4242\n")
        self.state = os.path.join(self.t, "state")
        self.gate_script = os.path.join(self.t, "gate.sh")
        open(self.gate_script, "w").write("readonly STATUS_RECEIVED_COPY_APPROVED=0\n")

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def run_daily(self, **extra):
        env = {"PATH": os.environ["PATH"], "BIN": self.bin, "RUNNER": self.runner, "LEDGER": self.ledger,
               "MAIN_ENV": self.env_file, "KILL_SWITCH": os.path.join(self.t, "no-kill"), "STATE_ROOT": self.state,
               "EXCLUDE_CS": self.excl, "HOLD_IDS": self.hold,
               "CORE_NOTICE": os.path.join(self.bin, "core_notice.py"),
               "RECEIPTS_PY": os.path.join(self.bin, "receipts.py"), "GATE_SCRIPT": self.gate_script, "CALLS": self.calls, "MODE": "apply", "SEGMENTS": "paid", "EMAIL_ROUTE": "1"}
        env.update(extra)
        p = subprocess.run(["bash", DAILY], env=env, capture_output=True, text=True, timeout=120)
        return p, open(self.calls).read().splitlines()

    def seg_dir(self):
        days = [d for d in os.listdir(self.state) if d[:2] == "20"]
        return os.path.join(self.state, days[0], "paid")

    def campaigns(self, calls, mode="apply"):
        """Campaigns of the segment pass (the receipts stage has its own helper, receipt_calls)."""
        out = []
        for c in calls:
            a = c.split()
            if "--list" in a and a[a.index("--list") + 1] in RECEIPT_LISTS:
                continue
            if "--mode" in a and a[a.index("--mode") + 1] == mode:
                out.append(a[a.index("--campaign") + 1])
        return out

    def lists(self, calls, mode="apply"):
        """The --list values of the segment pass (the receipts stage has its own helper)."""
        out = []
        for c in calls:
            a = c.split()
            if "--list" in a and a[a.index("--list") + 1] in RECEIPT_LISTS:
                continue
            if "--mode" in a and a[a.index("--mode") + 1] == mode:
                out.append(a[a.index("--list") + 1])
        return out

    def receipt_calls(self, calls, mode="apply"):
        out = []
        for c in calls:
            a = c.split()
            if "--mode" in a and a[a.index("--mode") + 1] == mode and "--list" in a \
                    and a[a.index("--list") + 1] in RECEIPT_LISTS:
                out.append((a[a.index("--list") + 1], a[a.index("--segment") + 1], a[a.index("--wording") + 1],
                            a[a.index("--exclude-users") + 1]))
        return out

    def test_receipts_queued_lane_is_retired_and_r1_waits_on_its_lock(self):
        # r5 702 (1) / QA #1603: the queued receipt (docrecvq) is retired - the RQ lane is logged, never sent;
        # R1 (owes proof) is send-locked in the gate: never run, the waiting count is logged.
        p, calls = self.run_daily()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.receipt_calls(calls), [])
        self.assertIn("paid RQ: retired lane", p.stdout)
        self.assertIn("receipts paid: R1 send-locked (STATUS_RECEIVED_COPY_APPROVED=0): 1 owe proof", p.stdout)
        day = sorted(d for d in os.listdir(self.state) if d[:2] == "20")[0]
        excl = open(os.path.join(self.state, day, "receipts", "exclude.txt")).read().split()
        self.assertEqual(excl, ["0", "4242"])   # the cs exclusion list + the hold ids

    def test_receipts_r1_runs_once_the_gate_lock_is_open_and_r1_daily_is_set(self):
        open(self.gate_script, "w").write("readonly STATUS_RECEIVED_COPY_APPROVED=1\n")
        # unlocked, but the cron never sends R1 to the whole list until R1_DAILY=1 (p1: hand-run batches first)
        p, calls = self.run_daily()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn("list-RR.json", [l for l, _s, _w, _ in self.receipt_calls(calls)])
        self.assertIn("receipts paid: R1 unlocked but hand-batched (R1_DAILY=0): 1 owe proof", p.stdout)
        p, calls = self.run_daily(R1_DAILY="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn(("list-RR.json", "paid", "received"), [(l, s, w) for l, s, w, _ in self.receipt_calls(calls)])

    def test_receipts_fail_closed_and_are_skipped_when_off_or_after_a_stop(self):
        p, calls = self.run_daily(FAIL_RECEIPTS="1")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("receipts list failed", p.stdout)
        self.assertIn("STOPPED", p.stdout)
        self.assertEqual(self.receipt_calls(calls), [])
        open(self.calls, "w").write("")
        p, calls = self.run_daily(RECEIPTS="0")
        self.assertEqual((p.returncode, self.receipt_calls(calls)), (0, []))
        open(self.calls, "w").write("")
        p, calls = self.run_daily(FAIL_CAMPAIGN="status-team-review")   # the segment pass stopped first
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.receipt_calls(calls), [])

    def test_core_notice_within_7d_takes_a_user_out_before_classify(self):
        # Fable sender map 2026-10-27 item 2: core told user 2 something lately -> never classified, never listed.
        p, _ = self.run_daily(CORE_NOTICE_HELD="2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(open(os.path.join(self.seg_dir(), "CLASSIFIED")).read().split(), ["1"])
        self.assertIn("paid core_notice_within_7d held 1 of 2 candidates", p.stdout)

    def test_unreadable_core_notice_skips_the_segment_and_fails_the_run(self):
        p, calls = self.run_daily(FAIL_CORE_NOTICE="1")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("core notice check failed: segment skipped (fail closed)", p.stdout)
        self.assertIn("STOPPED", p.stdout)
        self.assertEqual(self.campaigns(calls), [])
        self.assertFalse(os.path.exists(os.path.join(self.seg_dir(), "CLASSIFIED")))

    def test_without_asks_no_document_ask_is_sent_and_b0_gap_never_runs(self):
        p, calls = self.run_daily()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        sent = self.campaigns(calls)
        self.assertNotIn("status-doc-received", sent)               # QA #1603: the A lane is retired
        self.assertIn("paid A: retired lane", p.stdout)
        self.assertIn("status-team-review", sent)
        self.assertNotIn("list-U.json", self.lists(calls))          # no general Intercom ask
        self.assertNotIn("list-U.json", self.lists(calls, "dry-run"))
        d = self.seg_dir()
        self.assertFalse(os.path.exists(os.path.join(d, "B0GAP_RAN")))  # b0_gap not run
        self.assertIn("4242", open(os.path.join(d, "exclude-cs.txt")).read().split())  # held ids are excluded
        self.assertFalse(os.path.exists(os.path.join(d, "email-b0")))   # no email B0 fallback without asks
        emailed = open(os.path.join(d, "EMAIL_APPLIED")).read().split()
        self.assertIn("status-team-review", emailed)
        self.assertNotIn("uvn-status", emailed)                    # no email ask (credit_status_uvn_ask)

    def test_the_per_role_partial_lane_runs_with_its_own_switch(self):
        # captain 2026-11-06 ~17:05Z: the per-role split population is asked through the uvn-status sender
        # while the general ask lane stays off (firstmate 024). Its own switch, not ASKS.
        p, calls = self.run_daily(PARTIAL_ASKS="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("list-P.json", self.lists(calls))
        self.assertIn("paid partials: ", p.stdout)
        self.assertNotIn("list-U.json", self.lists(calls))

    def test_the_per_role_partial_lane_does_not_run_without_its_switch(self):
        p, calls = self.run_daily()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn("list-P.json", self.lists(calls))
        self.assertNotIn("paid partials: ", p.stdout)

    def test_the_per_role_partial_lane_carries_the_segment_holds(self):
        # F1: the P lane must not message a user the segment holds (cs exclusion, support@ 7d, core notice 7d).
        p, calls = self.run_daily(PARTIAL_ASKS="1", SUPPORT_HELD="7", CORE_NOTICE_HELD="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        call = next(c for c in calls if "list-P.json" in c)
        self.assertIn("--exclude-users", call)
        with open(call.split("--exclude-users")[1].split()[0]) as fh:
            ids = set(fh.read().split())
        self.assertEqual(ids, {"0", "4242", "7", "1"})

    def test_with_asks_the_ask_and_b0_gap_run(self):
        p, calls = self.run_daily(ASKS="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("uvn-status", self.campaigns(calls))
        d = self.seg_dir()
        self.assertTrue(os.path.exists(os.path.join(d, "B0GAP_RAN")))
        fb = json.load(open(os.path.join(d, "email-lists-b0.json")))
        self.assertEqual([r["user_id"] for r in fb["status-team-review"]], [5])  # 99's ask was refused: never B0
        self.assertIn("uvn-status", open(os.path.join(d, "EMAIL_APPLIED")).read().split())

    def test_a_failed_intercom_apply_stops_the_run_and_exits_nonzero(self):
        # QA on #1384: a nonzero send must never be followed by later sends and a 'done'.
        p, calls = self.run_daily(FAIL_CAMPAIGN="status-team-review")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.campaigns(calls), ["status-team-review"])    # nothing after the failure
        self.assertIn("apply FAILED", p.stdout)
        self.assertIn("STOPPED (a send failed", p.stdout)
        self.assertNotIn(" done:", p.stdout)

    def test_a_failed_email_apply_stops_the_run_and_exits_nonzero(self):
        p, calls = self.run_daily(FAIL_EMAIL="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("email main apply FAILED rc=4", p.stdout)
        self.assertIn("STOPPED (a send failed", p.stdout)

    def test_a_preprocessing_failure_fails_the_run(self):
        # QA on 40d1cb7c: a lens/segment/support/classify failure must not end in 'done' / exit 0.
        p, calls = self.run_daily(FAIL_SEGMENT="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("segment failed", p.stdout)
        self.assertIn("STOPPED", p.stdout)
        self.assertEqual(self.campaigns(calls), [])

    def test_a_same_day_rerun_never_sends_an_earlier_runs_list(self):
        # QA on 40d1cb7c: the 00:30Z and 15:00Z runs share the dir; a class absent in the later run must not
        # leave the earlier run's list behind to be sent.
        p, calls = self.run_daily()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("status-team-review", self.campaigns(calls))
        open(self.calls, "w").write("")
        p, calls = self.run_daily(LISTS="A")        # a later run with no B class: the earlier B list is never sent
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn("status-team-review", self.campaigns(calls, "dry-run"))
        self.assertNotIn("list-B.json", self.lists(calls))

    def test_a_missing_cs_exclusion_list_refuses_the_run(self):
        os.remove(self.excl)
        p, calls = self.run_daily()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(calls, [])

    def test_the_kill_switch_stops_before_any_send(self):
        ks = os.path.join(self.t, "kill"); open(ks, "w").write("")
        p, calls = self.run_daily(KILL_SWITCH=ks)
        self.assertEqual(calls, [])
        self.assertIn("kill switch present", p.stdout + p.stderr)


class PartialAsksListTest(unittest.TestCase):
    """scripts/paid-status/partial_asks.py: the list the uvn-status sender reads for the per-role split
    population. Built from the decider's ledger (the only place a partial is named) plus the replica's
    owner, ids only."""

    RID = "3f2b8c1e-0a4d-4e6b-9c7a-1d2e3f4a5b6c"
    OTHER = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.ledger = os.path.join(self.t, "ledger.sqlite3")
        self.out = os.path.join(self.t, "out")
        self.trino = os.path.join(self.t, "trino.py")
        with open(self.trino, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport sys\nsql = sys.stdin.read()\n"
                     "if 'group by 1, 2' in sql:\n"
                     f"    print('\"{self.RID}\",\"1\",\"1\"')\n"
                     "else:\n"
                     f"    print('\"{self.RID}\",\"1\"')\n"
                     f"    print('\"{self.OTHER}\",\"1\"')\n")
        os.chmod(self.trino, 0o755)

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def decide(self, decision, pending, mode="apply"):
        sys.path.insert(0, os.path.join(HERE, ".."))
        from credit_review import decide
        db = sqlite3.connect(self.ledger)
        decide.ensure_schema(db)
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, claimed_roles, approved_roles,"
                   " pending_roles, big_track, decision, reason, mode) VALUES ('r1','2026-11-06T17:00:00Z',?,1,"
                   " 'Mixing,Mastering','Mixing',?,0,?,'x',?)", (self.RID, pending, decision, mode))
        db.commit(); db.close()

    def decide_second(self, rid, pending, uid=1):
        """A SECOND split request owned by the same user (two workspaces: one paid, one free)."""
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, claimed_roles, approved_roles,"
                   " pending_roles, big_track, decision, reason, mode) VALUES ('r1','2026-11-06T17:00:00Z',?,?,"
                   " 'Mixing,Mastering','Mixing',?,0,'approve_partial','x','apply')", (rid, uid, pending))
        db.commit(); db.close()

    def trino_rows(self, rows):
        """Rewrite the replica fake so it returns exactly `rows` (rid, uid, paid-as-0/1), in that order."""
        with open(self.trino, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport sys\nsql = sys.stdin.read()\n")
            fh.write("if 'group by 1, 2' in sql:\n")
            for rid, uid, paid in rows:
                fh.write(f"    print('\"{rid}\",\"{uid}\",\"{paid}\"')\n")
            fh.write("else:\n")
            for rid, uid, _ in rows:
                fh.write(f"    print('\"{rid}\",\"{uid}\"')\n")
        os.chmod(self.trino, 0o755)

    def build(self):
        env = dict(os.environ, CREDIT_REVIEW_LEDGER=self.ledger, CREDIT_PROOF_TRINO=self.trino)
        p = subprocess.run([sys.executable, PARTIAL_ASKS, self.out], env=env, capture_output=True, text=True,
                           timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(os.path.join(self.out, "list-P.json")) as fh:
            return json.load(fh), json.loads(p.stdout)

    def test_a_partial_row_becomes_a_list_entry_for_its_owner(self):
        self.decide("approve_partial", "Mastering")
        doc, summary = self.build()
        self.assertEqual([(u["user_id"], u["paid"], u["request_ids"]) for u in doc["users"]],
                         [(1, True, [self.RID])])
        self.assertEqual(summary, {"partial_requests": 1, "users": 1, "paid": 1})

    def test_the_list_is_scoped_to_the_split_requests(self):
        # A separate open request is NOT part of the partial lane: listing it would let this cron ask
        # about it while the general ask lane is off, and the sender scopes PARTIAL entries itself.
        self.decide("approve_partial", "Mastering")
        doc, _ = self.build()
        self.assertNotIn(self.OTHER, doc["users"][0]["request_ids"])

    def test_a_row_with_no_roles_still_pending_is_not_listed(self):
        self.decide("approve_partial", "")
        doc, summary = self.build()
        self.assertEqual((doc["users"], summary["partial_requests"]), ([], 0))

    def test_a_shadow_partial_is_not_listed(self):
        self.decide("approve_partial", "Mastering", mode="shadow")
        doc, _ = self.build()
        self.assertEqual(doc["users"], [])

    def test_a_judge_only_partial_never_reaches_a_customer(self):
        # `judge` is shadow: its ledger row must not name a live ask population.
        self.decide("approve_partial", "Mastering", mode="judge")
        doc, _ = self.build()
        self.assertEqual(doc["users"], [])

    def test_a_paid_workspace_partial_is_paid_whatever_the_trino_row_order(self):
        # QA 2026-11-11 (Important): the user row was built with setdefault, so `paid` was fixed by the FIRST
        # request row returned. A free-workspace partial arriving before the same user's paid-workspace
        # partial marked the user free and ran BOTH requests under the free segment and its cap, breaking
        # paid-first priority. The flag is ORed across the user's rows, so neither order can demote them.
        self.decide("approve_partial", "Mastering")
        self.decide_second(self.OTHER, "Mastering")
        for rows in ([(self.RID, 1, 0), (self.OTHER, 1, 1)],
                     [(self.OTHER, 1, 1), (self.RID, 1, 0)]):
            self.trino_rows(rows)
            doc, summary = self.build()
            self.assertEqual([(u["user_id"], u["paid"]) for u in doc["users"]], [(1, True)], rows)
            self.assertEqual(sorted(doc["users"][0]["request_ids"]), sorted([self.RID, self.OTHER]), rows)
            self.assertEqual(summary["paid"], 1, rows)


if __name__ == "__main__":
    unittest.main()
