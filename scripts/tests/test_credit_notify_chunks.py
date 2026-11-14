"""notify-tick chunk loop (credit-notify-tick.py + credit_review/notify_chunks.py): a chunk is never abandoned on a
low affirmation count. The affirmed users are told, the others are carried into the next chunk with the reason.

Every case drives the real tick `main()` and, under it, the real `credit-decision-told.py` `main()` in-process
(its rung, its ladder, its day cap, its ledger writes). Faked: the replica, core's route, the list builder.
Temp ledgers. One assertion per test."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from credit_review import decision_told as dt  # noqa: E402
from credit_review import notify_chunks as nc  # noqa: E402
from credit_review import notify_tick as nt  # noqa: E402


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cli = _load("credit_decision_told_cli_for_tick", "credit-decision-told.py")
tick = _load("credit_notify_tick_entry", "credit-notify-tick.py")

SEED_RUN = "decision-told-apply-seed"
SEED_USER = 999
SEED_RUN2 = "decision-told-apply-seed2"          # a later live attempt core never confirmed
SEED_USER2 = 998


def rid(user: int, n: int = 0) -> str:
    return f"{user:08x}-{n:04x}-4111-8111-111111111111"


class World:
    """One node-8 in a temp dir: the two ledgers, the kill file path, the replica, core's route and the pod's list.

    `affirm` is who core's route affirms on a dry run; everyone else gets the outcome in `refuse` (default
    `nothing_owed`, the route's answer with no group). `requests` overrides a user's requests (default: one
    approved request)."""

    def __init__(self, users, affirm, *, refuse=None, requests=None, not_sent=(), affirm_once=(),
                 rung="climbed"):
        d = Path(tempfile.mkdtemp())
        self.ledger, self.verify, self.kill = str(d / "l.sqlite3"), str(d / "v.sqlite3"), str(d / "kill")
        self.tick_kill = str(d / "tick-kill")
        self.after: list = []             # called with argv after every sender call that ran
        self.work, self.status = d / "work", d / "status.txt"
        self.users, self.affirm, self.refuse = list(users), set(affirm), dict(refuse or {})
        self.requests = {u: (requests or {}).get(u, [(rid(u), "approved")]) for u in self.users}
        self.not_sent, self.affirm_once = set(not_sent), set(affirm_once)
        self.calls: list[dict] = []
        self.argvs: list[list[str]] = []
        self.fail: list = []              # predicates on argv: a matching call answers rc 2 without running
        self.logs = ""
        v = sqlite3.connect(self.verify)
        v.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, status TEXT, request_ids_json TEXT, "
                  "day TEXT, sent_at TEXT)")
        v.commit()
        v.close()
        db = sqlite3.connect(self.ledger, isolation_level=None)
        dt.ensure_table(db)
        # The ladder's rungs as an operator leaves them: ONE live send core confirmed, in a run read back, and (once
        # that read back happened) a later live attempt. The tick may only name that run itself when the ledger holds
        # MORE apply attempts than FIRST_LIVE_LIMIT, so the other two rungs are ledgers where it may not.
        seed = [] if rung in ("empty", "sent_only") else [(SEED_USER, SEED_RUN, "attempt")]
        if rung in ("climbed", "first_send", "sent_only"):
            seed.append((SEED_USER, SEED_RUN, "sent"))
        if rung == "climbed":
            seed.append((SEED_USER2, SEED_RUN2, "attempt"))
        for user, run, outcome in seed:
            db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, "
                       "mode, outcome) VALUES (?, '2026-11-01T00:00:00Z', ?, 'w|p', 'decision-approved', '[]', "
                       "'apply', ?)", (run, user, outcome))
        db.close()

    # -- the fakes ---------------------------------------------------------------------------------------------
    def query(self, sql: str):
        return [[r, status, "false", "false", "w", f"p{u}"]
                for u, reqs in self.requests.items() for r, status in reqs if f"'{r}'" in sql]

    def route(self, b):
        self.calls.append(dict(b))
        uid = int(b["userId"])
        rep = {"dryRun": not b["apply"], "userId": str(uid), "copyRef": b["copyRef"], "blockedBy": [],
               "group": {"subjects": list(b["subjectIds"])}, "sent": False}
        if b["apply"]:
            if uid not in self.not_sent:
                rep["sent"], rep["outcome"] = True, "sent"
            return rep
        asked_before = sum(1 for c in self.calls[:-1] if int(c["userId"]) == uid and not c["apply"])
        if uid in self.affirm and not (uid in self.affirm_once and asked_before):
            rep["outcome"] = "would_send"
            return rep
        rep["outcome"] = self.refuse.get(uid, "nothing_owed")
        if rep["outcome"] == "nothing_owed":
            rep["group"] = None
        return rep

    def build(self):
        users = [{"user_id": u, "paid": False, "class": "precedent_v1",
                  "facts": [[r, status, "2026-11-12T22:13:24.530Z"] for r, status in self.requests[u]]}
                 for u in self.users]
        return {"class": "precedent_v1_untold", "counts": {"users": len(users), "requests": len(users)},
                "generated_at": "2026-11-14T01:48:00.000Z", "query_sha": "precedent_v1_untold",
                "ruling": "captain 2026-11-10 no humans", "source": "credit_requests", "users": users}

    def told(self, argv, timeout_s):
        self.argvs.append(list(argv))
        if any(f(argv) for f in self.fail):
            return 2, json.dumps({"refused": "fixture: this call does not run"})
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cli.main(list(argv), query=self.query, caller=self.route, ledger=self.ledger,
                          verify_ledger=self.verify, kill_file=self.kill)
        for f in self.after:
            f(argv)
        return rc, buf.getvalue()

    # -- the run and what it left ------------------------------------------------------------------------------
    def tick(self, *, chunk=25, max_chunks=3, build=None) -> int:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = tick.main(build=build or self.build, told=self.told, ledger=self.ledger, work=self.work,
                           status=self.status, max_chunks=max_chunks, chunk=chunk, kill_file=self.tick_kill)
        self.logs += buf.getvalue()
        return rc

    def summary(self) -> dict:
        return json.loads((self.work / "last-run.json").read_text())

    def live(self, outcome: str) -> set[int]:
        db = sqlite3.connect(self.ledger)
        try:
            return {int(r[0]) for r in db.execute("SELECT DISTINCT user_id FROM decision_told WHERE mode = 'apply' "
                                                  "AND outcome = ? AND user_id <> ?", (outcome, SEED_USER))}
        finally:
            db.close()

    def asked(self, uid: int, apply: bool) -> int:
        return sum(1 for c in self.calls if int(c["userId"]) == uid and c["apply"] is apply)

    def sends(self) -> list[int]:
        return sorted(int(c["userId"]) for c in self.calls if c["apply"])

    def applies(self) -> list[list[str]]:
        return [a for a in self.argvs if a[0] == "apply"]


def newest_sent_run(ledger: str) -> str:
    """The run the last confirmed live send went out in, read from the sender's ledger."""
    db = sqlite3.connect(ledger)
    try:
        return str(db.execute("SELECT run_id FROM decision_told WHERE mode = 'apply' AND outcome = 'sent' "
                              "ORDER BY id DESC LIMIT 1").fetchone()[0])
    finally:
        db.close()


def arg(argv: list[str], flag: str) -> str:
    return argv[argv.index(flag) + 1]


#: the captain's case: 25 users in the first chunk and core affirms eight of them; five more behind, two affirmed
USERS_30 = list(range(101, 131))
AFFIRM_10 = {103, 107, 110, 112, 115, 119, 121, 124, 127, 130}
REFUSED_20 = sorted(set(USERS_30) - AFFIRM_10)


class LowAffirmationChunk(unittest.TestCase):
    """30 untold users, 10 affirmed (33%): eight in the first chunk of 25, two among the last five."""

    @classmethod
    def setUpClass(cls):
        cls.w = World(USERS_30, AFFIRM_10)
        cls.rc = cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_run_finished(self):
        self.assertEqual(self.rc, 0)

    def test_every_affirmed_user_was_told(self):
        self.assertEqual(self.w.live("sent"), AFFIRM_10)

    def test_the_route_sent_once_to_each_affirmed_user_and_to_nobody_else(self):
        self.assertEqual(self.w.sends(), sorted(AFFIRM_10))

    def test_the_eight_of_the_first_chunk_were_sent_in_the_first_chunk(self):
        self.assertEqual(self.s["chunks"][0]["sent"], 8)

    def test_the_first_chunk_saw_eight_affirmed(self):
        self.assertEqual(self.s["chunks"][0]["affirmed"], 8)

    def test_the_first_chunk_carried_its_seventeen_others(self):
        self.assertEqual(self.s["chunks"][0]["carried"], 17)

    def test_the_second_chunk_took_the_seventeen_in(self):
        self.assertEqual(self.s["chunks"][1]["carried_in"], 17)

    def test_the_second_chunk_asked_the_carried_and_its_own_five(self):
        self.assertEqual(self.s["chunks"][1]["asked"], 22)

    def test_a_carried_user_was_asked_again_in_the_second_chunk(self):
        self.assertEqual(self.w.asked(101, apply=False), 2)

    def test_the_two_of_the_second_chunk_were_sent(self):
        self.assertEqual(self.s["chunks"][1]["sent"], 2)

    def test_the_run_sent_ten(self):
        self.assertEqual(len(self.s["sent"]), 10)

    def test_the_run_carried_twenty(self):
        self.assertEqual(len(self.s["carried"]), 20)

    def test_the_carried_are_exactly_the_users_not_affirmed(self):
        self.assertEqual(sorted(int(u) for u in self.s["carried"]), REFUSED_20)

    def test_every_carried_user_has_the_routes_reason(self):
        self.assertEqual(set(self.s["carried"].values()), {"route:nothing_owed"})

    def test_nobody_was_left_unasked(self):
        self.assertEqual(self.s["not_reached"], 0)

    def test_no_stop_was_named(self):
        self.assertEqual(self.s["stopped"], "")

    def test_no_carried_user_has_a_live_row(self):
        self.assertEqual(self.w.live("attempt") & set(REFUSED_20), set())

    def test_the_run_accounts_for_every_untold_user(self):
        s = self.s
        self.assertEqual(s["untold"], len(s["sent"]) + len(s["unconfirmed"]) + len(s["carried"]) + s["not_reached"])

    def test_the_status_line_states_sent_and_carried(self):
        self.assertEqual(self.w.status.read_text(),
                         "notify-tick: sent 10 this run, 20 still untold (20 carried, 0 not reached)\n")

    def test_a_healthy_run_records_no_sender_failure(self):
        self.assertEqual(self.s["sender_failures"], [])

    def test_every_send_had_a_signed_dry_run_affirming_everyone_it_asked(self):
        short = []
        for a in self.w.applies():
            dry = json.loads(Path(arg(a, "--signed")).read_text())
            if any(r["outcome"] != "dry_ok" for r in dry["results"]):
                short.append(arg(a, "--signed"))
        self.assertEqual(short, [])

    def test_the_rung_itself_was_not_lowered(self):
        self.assertEqual(dt.MIN_SIGNED_DRY, 10)


class TheNextTickStartsWithTheCarried(unittest.TestCase):
    """The carried users are still untold, so the next tick lists them; the told users are gone from the list."""

    @classmethod
    def setUpClass(cls):
        cls.w = World(USERS_30, AFFIRM_10)
        cls.w.tick()
        cls.rc = cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_second_tick_finished(self):
        self.assertEqual(self.rc, 0)

    def test_the_second_tick_lists_the_twenty_carried(self):
        self.assertEqual(self.s["untold"], 20)

    def test_the_second_tick_sent_nobody(self):
        self.assertEqual(self.s["sent"], [])

    def test_the_second_tick_carried_all_twenty_again(self):
        self.assertEqual(len(self.s["carried"]), 20)

    def test_nobody_was_sent_twice(self):
        self.assertEqual(self.w.sends(), sorted(AFFIRM_10))


class ATailOfFive(unittest.TestCase):
    """node-8 2026-11-14T01:48Z: five untold, two affirmed, two `nothing_owed`, one `held_messaging_hold`."""

    @classmethod
    def setUpClass(cls):
        cls.w = World([1, 2, 3, 4, 5], {2, 5}, refuse={4: "held_messaging_hold"})
        cls.rc = cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_two_affirmed_were_told(self):
        self.assertEqual(self.w.live("sent"), {2, 5})

    def test_the_three_others_were_carried_with_their_reasons(self):
        self.assertEqual(self.s["carried"], {"1": "route:nothing_owed", "3": "route:nothing_owed",
                                             "4": "route:held_messaging_hold"})

    def test_one_chunk_was_enough(self):
        self.assertEqual(len(self.s["chunks"]), 1)


class AChunkThatMeetsTheRung(unittest.TestCase):
    """Twelve users, all affirmed: one dry run, one apply, no second list."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(301, 313))
        cls.w = World(cls.users, set(cls.users))
        cls.w.tick()
        cls.s = cls.w.summary()

    def test_everyone_was_told(self):
        self.assertEqual(self.w.live("sent"), set(self.users))

    def test_one_dry_run_and_one_apply(self):
        self.assertEqual([a[0] for a in self.w.argvs], ["dry", "apply"])

    def test_nobody_was_carried(self):
        self.assertEqual(self.s["carried"], {})


class NobodyAffirmed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.w = World([1, 2, 3, 4], set())
        cls.rc = cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_run_finished(self):
        self.assertEqual(self.rc, 0)

    def test_no_apply_was_started(self):
        self.assertEqual(self.w.applies(), [])

    def test_all_four_were_carried(self):
        self.assertEqual(len(self.s["carried"]), 4)

    def test_the_status_line_says_so(self):
        self.assertEqual(self.w.status.read_text(),
                         "notify-tick: sent 0 this run, 4 still untold (4 carried, 0 not reached)\n")


class AUserHeldByThePlan(unittest.TestCase):
    """User 2 has an approved and a rejected request: `decision_told.plan` holds the user, the route is not asked."""

    @classmethod
    def setUpClass(cls):
        cls.w = World([1, 2, 3], {1, 2, 3}, requests={2: [(rid(2, 1), "approved"), (rid(2, 2), "rejected")]})
        cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_two_others_were_told(self):
        self.assertEqual(self.w.live("sent"), {1, 3})

    def test_the_held_user_was_carried_under_the_plans_own_word(self):
        self.assertEqual(self.s["carried"], {"2": "held:mixed_decisions"})

    def test_the_route_was_never_asked_about_the_held_user(self):
        self.assertEqual(self.w.asked(2, apply=False), 0)


class AnAffirmationThatDoesNotHold(unittest.TestCase):
    """User 104 is affirmed by the first dry run and refused by the second: only that user waits."""

    @classmethod
    def setUpClass(cls):
        cls.w = World(list(range(101, 121)), {102, 104, 106, 108, 110, 112, 114, 116}, affirm_once={104})
        cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_seven_who_stayed_affirmed_were_told(self):
        self.assertEqual(self.w.live("sent"), {102, 106, 108, 110, 112, 114, 116})

    def test_the_user_who_was_refused_the_second_time_was_carried(self):
        self.assertEqual(self.s["carried"]["104"], "route:nothing_owed")

    def test_that_user_was_never_sent_a_notice(self):
        self.assertEqual(self.w.asked(104, apply=True), 0)


class ASendCoreDidNotConfirm(unittest.TestCase):
    """The route answers user 3's live call without `sent`: the reservation stands, the user is not carried."""

    @classmethod
    def setUpClass(cls):
        cls.w = World([1, 2, 3, 4], {1, 2, 3, 4}, not_sent={3})
        cls.w.tick()
        cls.s = cls.w.summary()
        cls.w.tick()
        cls.second = cls.w.status.read_text()

    def test_the_three_confirmed_were_told(self):
        self.assertEqual(self.s["sent"], [1, 2, 4])

    def test_the_unconfirmed_user_is_named_as_such(self):
        self.assertEqual(self.s["unconfirmed"], [3])

    def test_the_unconfirmed_user_is_not_carried(self):
        self.assertEqual(self.s["carried"], {})

    def test_the_status_line_does_not_count_it_as_sent(self):
        self.assertIn("sent 3 this run", self.w.logs)

    def test_the_next_tick_has_nothing_left(self):
        self.assertEqual(self.second, "notify-tick: nothing left to notify\n")

    def test_the_unconfirmed_user_got_one_live_call_in_two_ticks(self):
        self.assertEqual(self.w.asked(3, apply=True), 1)


class ADryRunThatDoesNotRun(unittest.TestCase):
    """Three chunks of ten, all affirmed; the second chunk's dry run fails. Only that chunk waits, and the failure
    is a run-level fact: the run fails and its own line says which chunk's dry run did not answer."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(101, 131))
        cls.w = World(cls.users, set(cls.users))
        cls.w.fail.append(lambda a: a[0] == "dry" and arg(a, "--list").endswith("c001.json"))
        cls.rc = cls.w.tick(chunk=10)
        cls.s = cls.w.summary()
        cls.line = cls.w.status.read_text()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_the_summary_names_the_failed_chunk_and_call(self):
        self.assertEqual(self.s["sender_failures"], [{"chunk": 1, "call": "dry", "rc": 2}])

    def test_the_status_line_names_the_failed_chunk_and_call_and_rc(self):
        self.assertIn("SENDER FAILED in chunk 1 (dry rc 2)", self.line)

    def test_the_status_line_is_not_the_healthy_line(self):
        self.assertFalse(self.line.startswith("notify-tick: sent "))

    def test_the_first_and_third_chunks_were_told(self):
        self.assertEqual(self.w.live("sent"), set(range(101, 111)) | set(range(121, 131)))

    def test_the_second_chunk_waits_under_its_own_name(self):
        self.assertEqual(self.s["carried"], {str(u): "dry_failed" for u in range(111, 121)})

    def test_the_unread_chunk_was_not_merged_into_the_third(self):
        self.assertEqual(self.s["chunks"][2]["asked"], 10)

    def test_no_run_level_stop_was_named(self):
        self.assertEqual(self.s["stopped"], "")


class AnApplyThatDoesNotRun(unittest.TestCase):
    """The first chunk's apply fails before any send: its ten affirmed users ride into the second chunk, an apply
    never takes more than one chunk's worth of users, and the run fails naming that chunk."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(101, 131))
        cls.w = World(cls.users, set(cls.users))
        cls.w.fail.append(lambda a: a[0] == "apply" and arg(a, "--list").endswith("c000.json"))
        cls.rc = cls.w.tick(chunk=10)
        cls.s = cls.w.summary()
        cls.line = cls.w.status.read_text()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_the_summary_names_the_failed_chunk_and_call(self):
        self.assertEqual(self.s["sender_failures"], [{"chunk": 0, "call": "apply", "rc": 2}])

    def test_the_status_line_names_the_failed_chunk_and_call_and_rc(self):
        self.assertIn("SENDER FAILED in chunk 0 (apply rc 2)", self.line)

    def test_the_status_line_still_states_what_was_sent(self):
        self.assertIn("sent 20 this run", self.line)

    def test_the_status_line_names_only_the_chunk_that_failed(self):
        self.assertNotIn("chunk 1 (", self.line)

    def test_the_first_chunk_sent_nobody(self):
        self.assertEqual(self.s["chunks"][0]["sent"], 0)

    def test_the_second_chunk_asked_twenty(self):
        self.assertEqual(self.s["chunks"][1]["asked"], 20)

    def test_the_second_chunk_sent_one_chunks_worth(self):
        self.assertEqual(self.s["chunks"][1]["sent"], 10)

    def test_the_run_sent_twenty(self):
        self.assertEqual(len(self.s["sent"]), 20)

    def test_the_last_ten_are_carried_as_not_applied(self):
        self.assertEqual(set(self.s["carried"].values()), {"not_applied"})

    def test_ten_are_carried(self):
        self.assertEqual(len(self.s["carried"]), 10)


class EveryApplyThatFails(unittest.TestCase):
    """Both chunks' applies fail: the run fails naming each one, and nobody is counted as sent."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(101, 121))
        cls.w = World(cls.users, set(cls.users))
        cls.w.fail.append(lambda a: a[0] == "apply")
        cls.rc = cls.w.tick(chunk=10)
        cls.s = cls.w.summary()
        cls.line = cls.w.status.read_text()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_the_summary_names_both_chunks(self):
        self.assertEqual([f["chunk"] for f in self.s["sender_failures"]], [0, 1])

    def test_the_status_line_names_both_chunks(self):
        self.assertIn("SENDER FAILED in chunk 0 (apply rc 2), chunk 1 (apply rc 2)", self.line)

    def test_nobody_was_sent(self):
        self.assertEqual(self.s["sent"], [])

    def test_every_user_is_carried(self):
        self.assertEqual(len(self.s["carried"]), 20)


class TheKillFile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.w = World(USERS_30, AFFIRM_10)
        Path(cls.w.kill).write_text("")
        cls.rc = cls.w.tick()
        cls.s = cls.w.summary()

    def test_the_run_ends_cleanly(self):
        self.assertEqual(self.rc, 0)

    def test_the_stop_is_named(self):
        self.assertEqual(self.s["stopped"], "kill_file")

    def test_the_route_was_never_called(self):
        self.assertEqual(self.w.calls, [])

    def test_only_one_chunk_was_started(self):
        self.assertEqual(len(self.s["chunks"]), 1)

    def test_the_users_behind_it_are_counted_as_not_reached(self):
        self.assertEqual(self.s["not_reached"], 5)

    def test_the_status_line_names_the_stop(self):
        self.assertEqual(self.w.status.read_text(), "notify-tick: sent 0 this run, 30 still untold "
                                                    "(25 carried, 5 not reached); stopped: kill_file\n")


class TheTicksOwnKillFile(unittest.TestCase):
    """Present before the run: the tick reads nothing, asks nothing, sends nothing, and says why."""

    @classmethod
    def setUpClass(cls):
        cls.w = World(USERS_30, AFFIRM_10)
        Path(cls.w.tick_kill).write_text("")
        cls.built = []
        cls.rc = cls.w.tick(build=lambda: cls.built.append(1))

    def test_the_run_ends_cleanly(self):
        self.assertEqual(self.rc, 0)

    def test_the_list_was_not_built(self):
        self.assertEqual(self.built, [])

    def test_the_sender_was_not_started(self):
        self.assertEqual(self.w.argvs, [])

    def test_the_status_line_names_the_file(self):
        self.assertEqual(self.w.status.read_text(), f"notify-tick: disabled by kill file {self.w.tick_kill}\n")


class TheTicksOwnKillFileDuringARun(unittest.TestCase):
    """It appears while the first chunk is being applied: that chunk finishes, no further chunk is started."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(101, 131))
        cls.w = World(cls.users, set(cls.users))
        cls.w.after.append(lambda a: a[0] == "apply" and Path(cls.w.tick_kill).write_text(""))
        cls.rc = cls.w.tick(chunk=10)
        cls.s = cls.w.summary()

    def test_the_run_ends_cleanly(self):
        self.assertEqual(self.rc, 0)

    def test_the_first_chunk_was_told(self):
        self.assertEqual(self.w.live("sent"), set(range(101, 111)))

    def test_the_stop_is_named(self):
        self.assertEqual(self.s["stopped"], "kill_file")

    def test_no_second_chunk_was_started(self):
        self.assertEqual(len(self.s["chunks"]), 1)

    def test_the_twenty_behind_it_are_not_reached(self):
        self.assertEqual(self.s["not_reached"], 20)


class TheDayCap(unittest.TestCase):
    """decision_told's day cap, set to three for the test: three are told, the run stops, nobody is dropped."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(101, 121))
        cls.w = World(cls.users, set(cls.users))
        with mock.patch.object(dt, "FIRST_DAY_CAP", 3):
            cls.w.tick(chunk=10)
        cls.s = cls.w.summary()

    def test_three_were_told(self):
        self.assertEqual(self.s["sent"], [101, 102, 103])

    def test_the_stop_is_named(self):
        self.assertEqual(self.s["stopped"], "day_cap")

    def test_the_seven_affirmed_and_unsent_are_carried_under_that_name(self):
        self.assertEqual(self.s["carried"], {str(u): "stopped:day_cap" for u in range(104, 111)})

    def test_the_second_chunk_was_not_started(self):
        self.assertEqual(len(self.s["chunks"]), 1)

    def test_the_second_chunks_users_are_not_reached(self):
        self.assertEqual(self.s["not_reached"], 10)


class TheLadderWithoutAReadBack(unittest.TestCase):
    """One confirmed first send and nothing else: the tick may not certify the read back for itself, so it sends
    nothing, says what blocked the run and which run a person has to read back."""

    @classmethod
    def setUpClass(cls):
        cls.users = list(range(1, 13))
        cls.w = World(cls.users, set(cls.users), rung="first_send")
        cls.rc = cls.w.tick()
        cls.s = cls.w.summary()
        cls.line = cls.w.status.read_text()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_the_stop_is_named(self):
        self.assertEqual(self.s["stopped"], "readback_required")

    def test_nobody_was_sent_a_notice(self):
        self.assertEqual(self.w.sends(), [])

    def test_all_twelve_are_carried(self):
        self.assertEqual(len(self.s["carried"]), 12)

    def test_the_status_line_names_the_stop(self):
        self.assertIn("readback_required", self.line)

    def test_the_status_line_names_the_count_it_blocked(self):
        self.assertIn("12 of 12 untold users blocked", self.line)

    def test_the_status_line_names_the_run_to_read_back(self):
        self.assertIn(f"run {SEED_RUN} back", self.line)

    def test_an_environment_knob_cannot_certify_the_read_back(self):
        w = World(self.users, set(self.users), rung="first_send")
        with mock.patch.dict("os.environ", {"NOTIFY_READBACK_OK": SEED_RUN}):
            w.tick()
        self.assertEqual(w.sends(), [])

    def test_an_environment_knob_does_not_fail_the_run_open(self):
        w = World(self.users, set(self.users), rung="first_send")
        with mock.patch.dict("os.environ", {"NOTIFY_READBACK_OK": SEED_RUN}):
            self.assertNotEqual(w.tick(), 0)


class AFirstLiveWriteCoreNeverConfirmed(unittest.TestCase):
    """An attempt and no confirmed send: the ladder says the first live write is one user, the tick names the run
    that made it and still sends nothing."""

    @classmethod
    def setUpClass(cls):
        cls.w = World([1, 2], {1, 2}, rung="first_attempt")
        cls.rc = cls.w.tick()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_the_stop_is_named(self):
        self.assertEqual(self.w.summary()["stopped"], "first_live_write_is_one_user")

    def test_nobody_was_sent_a_notice(self):
        self.assertEqual(self.w.sends(), [])

    def test_the_status_line_names_the_run_that_made_the_unconfirmed_write(self):
        self.assertIn(f"run {SEED_RUN} back", self.w.status.read_text())


class AFirstLiveRunNamesItsOwnRun(unittest.TestCase):
    """An empty ledger: the run writes the first live send, the ladder then makes that the run to read back, and the
    status line names the run those bytes went out in — never `unknown`."""

    @classmethod
    def setUpClass(cls):
        cls.users = [101, 102, 103]
        cls.w = World(cls.users, set(cls.users), rung="empty")
        cls.rc = cls.w.tick()
        cls.line = cls.w.status.read_text()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_exactly_one_user_was_sent(self):
        self.assertEqual(len(self.w.live("sent")), 1)

    def test_the_stop_is_named(self):
        self.assertEqual(self.w.summary()["stopped"], "readback_required")

    def test_the_status_line_names_the_run_that_send_went_out_in(self):
        self.assertIn(f"run {newest_sent_run(self.w.ledger)} back", self.line)

    def test_the_status_line_never_calls_the_run_unknown(self):
        self.assertNotIn("unknown", self.line)


class AStaleConfirmedSendIsNotWhatGetsNamed(unittest.TestCase):
    """A ledger holding a confirmed send from before this run: the run writes a newer one, and the line names the
    newer run — the id comes from the ledger AFTER the run, never from the value read before it."""

    @classmethod
    def setUpClass(cls):
        cls.users = [201, 202, 203]
        cls.w = World(cls.users, set(cls.users), rung="sent_only")
        cls.rc = cls.w.tick()
        cls.line = cls.w.status.read_text()

    def test_the_run_failed(self):
        self.assertNotEqual(self.rc, 0)

    def test_this_run_sent_one_user(self):
        self.assertEqual(len(self.w.live("sent")), 1)

    def test_the_status_line_names_the_newer_run(self):
        self.assertIn(f"run {newest_sent_run(self.w.ledger)} back", self.line)

    def test_the_status_line_does_not_name_the_run_it_read_before_the_run(self):
        self.assertNotIn(f"run {SEED_RUN} back", self.line)


class AReadBackThatCannotBeReadIsNotMeasured(unittest.TestCase):
    """The ledger has to be read back after the run to name the run. If that read fails the line says the run was
    not measured: a stale or `unknown` id is never printed as if it had been read."""

    def test_the_status_line_says_the_run_was_not_measured(self):
        w = World([301, 302], {301, 302}, rung="empty")
        real, reads = nc.ladder_state, []

        def state(db):
            reads.append(1)
            if len(reads) > 1:
                raise nt.NotifyTickError("fixture: the ledger went away after the run")
            return real(db)

        with mock.patch.object(nc, "ladder_state", state):
            w.tick()
        self.assertIn("run not measured", w.status.read_text())

    def test_a_run_it_cannot_read_back_fails(self):
        w = World([303, 304], {303, 304}, rung="empty")
        real, reads = nc.ladder_state, []

        def state(db):
            reads.append(1)
            if len(reads) > 1:
                raise nt.NotifyTickError("fixture: the ledger went away after the run")
            return real(db)

        with mock.patch.object(nc, "ladder_state", state):
            self.assertNotEqual(w.tick(), 0)


class TheListBuildFromThePod(unittest.TestCase):
    """The class is the host's query copied into a core-backend pod. A copy that fails, or a pod lookup that fails,
    stops the build: the pod can still hold an older revision of the query, and running it would classify users by a
    predicate nobody deployed."""

    def setUp(self):
        self.js = Path(tempfile.mkdtemp()) / "mklist2.js"
        self.calls: list[list[str]] = []

    def build(self, *answers, js_text="// the class\n"):
        self.js.write_text(js_text)
        answers = list(answers)

        def run(argv, **kw):
            self.calls.append(list(argv))
            return answers.pop(0) if answers else subprocess.CompletedProcess(argv, 0, "", "")

        with mock.patch.object(tick, "LIST_JS", self.js), mock.patch.object(tick.subprocess, "run", run):
            return tick.build_list()

    def execs(self):
        return [a for a in self.calls if "exec" in a]

    def pod(self):
        return subprocess.CompletedProcess([], 0, "core-api-0\n", "")

    def test_the_pods_answer_is_the_list(self):
        doc = self.build(self.pod(), subprocess.CompletedProcess([], 0, "", ""),
                         subprocess.CompletedProcess([], 0, json.dumps({"users": []}), ""))
        self.assertEqual(doc, {"users": []})

    def test_a_failed_copy_stops_the_build(self):
        doc = self.build(self.pod(), subprocess.CompletedProcess([], 1, "", "tar: not found"))
        self.assertIsNone(doc)

    def test_a_failed_copy_never_runs_what_the_pod_already_holds(self):
        self.build(self.pod(), subprocess.CompletedProcess([], 1, "", "tar: not found"))
        self.assertEqual(self.execs(), [])

    def test_a_failed_copy_of_a_revision_never_runs_the_one_before_it(self):
        self.build(self.pod(), subprocess.CompletedProcess([], 0, "", ""),
                   subprocess.CompletedProcess([], 0, json.dumps({"users": []}), ""), js_text="// v1\n")
        self.calls.clear()
        self.build(self.pod(), subprocess.CompletedProcess([], 1, "", "tar: not found"), js_text="// v2\n")
        self.assertEqual(self.execs(), [])

    def test_a_failed_pod_lookup_stops_the_build(self):
        self.assertIsNone(self.build(subprocess.CompletedProcess([], 1, "", "connection refused")))

    def test_a_failed_pod_lookup_never_copies_or_executes(self):
        self.build(subprocess.CompletedProcess([], 1, "", "connection refused"))
        self.assertEqual(self.calls[1:], [])


class WhatTheTickCannotRead(unittest.TestCase):
    def test_a_list_that_could_not_be_built_fails_the_run(self):
        w = World([1], {1})
        self.assertEqual(w.tick(build=lambda: None), 1)

    def test_a_list_that_could_not_be_built_is_said_so(self):
        w = World([1], {1})
        w.tick(build=lambda: None)
        self.assertEqual(w.status.read_text(), "notify-tick: list build failed\n")

    def test_a_list_of_the_wrong_shape_fails_the_run(self):
        w = World([1], {1})
        self.assertEqual(w.tick(build=lambda: {"users": [{"user_id": 1}]}), 1)

    def test_a_missing_ledger_fails_the_run(self):
        w = World([1], {1})
        w.ledger = str(Path(tempfile.mkdtemp()) / "absent.sqlite3")
        self.assertEqual(w.tick(), 1)

    def test_a_missing_ledger_asks_core_nothing(self):
        w = World([1], {1})
        w.ledger = str(Path(tempfile.mkdtemp()) / "absent.sqlite3")
        w.tick()
        self.assertEqual(w.argvs, [])

    def test_an_empty_class_ends_cleanly(self):
        w = World([], set())
        self.assertEqual(w.tick(), 0)

    def test_an_empty_class_is_said_so(self):
        w = World([], set())
        w.tick()
        self.assertEqual(w.status.read_text(), "notify-tick: nothing left to notify\n")

    def test_live_outcomes_refuses_a_ledger_without_the_table(self):
        with self.assertRaises(nt.NotifyTickError):
            nc.live_outcomes(sqlite3.connect(":memory:"), [1])


class TheFileAsTheTimerRunsIt(unittest.TestCase):
    """The unit runs the file by path. Its imports and its sender must resolve from the file's own location."""

    def test_the_file_loads_when_run_by_path(self):
        p = subprocess.run([sys.executable, "-I", "-c", "import runpy, sys; runpy.run_path(sys.argv[1], run_name='t')",
                            str(SCRIPTS / "credit-notify-tick.py")], capture_output=True, text=True, timeout=120)
        self.assertEqual(p.returncode, 0, p.stderr[-400:])

    def test_the_sender_it_names_is_the_one_beside_it(self):
        self.assertEqual(tick.SCRIPT, SCRIPTS / "credit-decision-told.py")

    def test_the_real_runner_starts_the_real_sender(self):
        rc, _ = tick.told(["--help"], 120)
        self.assertEqual(rc, 0)

    def test_the_real_runner_returns_the_senders_stdout(self):
        _, out = tick.told(["--help"], 120)
        self.assertIn("--readback-ok", out)


if __name__ == "__main__":
    unittest.main()
