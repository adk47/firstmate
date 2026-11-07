"""decline_close.py: who tells a closed credit request, and who must not (never two declines for one request).

Ruling decline-copy-ruling.md §2.2 / §3.2 (captain 2026-10-29 13:2xZ). The campaign gate ships SILENT
(`DECLINE_CORE_ROUTE_OFF=0`) and, when an operator opens it, asks this module about the ONE user in front of it
before it claims anything (QA #1718 3). Only `hydra_decline` may proceed; `core_email` and `hold` both stop the send.
"""
from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from unittest import mock

from scripts.credit_review import decline_close


def run(argv: list[str], notes=None) -> tuple[int, dict]:
    """Run the CLI, capturing its JSON. `notes` stubs the send-ledger read (None = the real one runs)."""
    buf = io.StringIO()
    kw = {} if notes is None else {"core_notes": lambda users, since, **_: notes}
    with mock.patch.object(sys, "argv", ["decline_close.py", *argv]), redirect_stdout(buf), \
            mock.patch.object(decline_close, "core_notes", kw.get("core_notes", decline_close.core_notes)):
        rc = decline_close._main(argv)
    text = buf.getvalue().strip()
    return rc, (json.loads(text) if text.startswith("{") else {"raw": text})


class LedgerReadIsEvidenceTests(unittest.TestCase):
    """A psql answer is EVIDENCE only if it is clean: rc 0, no stderr, and every line a `user_id|count` row (QA #1718
    A: psql continues past an SQL error and exits 0, so an error would otherwise read as "core told nobody")."""

    class P:
        def __init__(self, out="", err="", rc=0):
            self.stdout, self.stderr, self.returncode = out, err, rc

    def test_a_clean_answer_is_evidence(self):
        p = self.P(out="42|2\n43|1\n")
        self.assertEqual(decline_close._read_notes(p, "2026-11-01T00:00:00Z", 2), ({42: 2, 43: 1},
                         "3 credits_rejected note(s) to 2 of 2 user(s) since 2026-11-01T00:00:00Z"))

    def test_an_empty_answer_is_a_real_zero(self):
        self.assertEqual(decline_close._read_notes(self.P(), "2026-11-01T00:00:00Z", 1)[0], {})

    def test_an_sql_error_on_stderr_is_not_a_zero(self):
        got, why = decline_close._read_notes(
            self.P(err='ERROR:  relation "send.messages" does not exist\n'), "2026-11-01T00:00:00Z", 1)
        self.assertIsNone(got, "the caller must hold: an error is not a measurement")
        self.assertIn("unreadable", why)

    def test_a_nonzero_exit_is_not_a_zero(self):
        self.assertIsNone(decline_close._read_notes(self.P(out="42|1\n", rc=2), "2026-11-01T00:00:00Z", 1)[0])

    def test_unexpected_output_is_not_a_zero(self):
        got, why = decline_close._read_notes(self.P(out="psql: warning: something\n42|1\n"), "2026-11-01T00:00:00Z", 1)
        self.assertIsNone(got)
        self.assertIn("unexpected output", why)

    def test_psql_is_asked_to_stop_on_error(self):
        seen = {}

        outer = self

        class Runner:
            def __call__(self, sql):
                seen["sql"] = sql
                return outer.P(out="42|1\n")

        self.assertEqual(decline_close.core_notes([42], "2026-11-01T00:00:00Z", runner=Runner())[0], {42: 1})
        self.assertIn("credits_rejected", seen["sql"])
        self.assertEqual(decline_close.PSQL_STRICT, ("-v", "ON_ERROR_STOP=1"),
                         "the psql calls append this, so an SQL error exits non-zero instead of reading as no rows")
        # and the command the subprocess actually runs carries it as TWO argv elements (QA #1718, 2026-11-06):
        # psql's getopt takes the rest of the same word as the -v value, so the joined form asks for a variable
        # named " ON_ERROR_STOP" and every real read becomes unreadable.
        argv = []

        class Proc:
            returncode, stderr, stdout = 0, "", "42|1\n"

        import unittest.mock as m
        with m.patch.object(decline_close.subprocess, "run", lambda cmd, **kw: (argv.extend(cmd), Proc())[1]):
            self.assertEqual(decline_close.core_notes([42], "2026-11-01T00:00:00Z")[0], {42: 1})
        self.assertIn("-v", argv)
        self.assertIn("ON_ERROR_STOP=1", argv)
        self.assertNotIn("-v ON_ERROR_STOP=1", argv, "one argv element is the bug: psql rejects the variable name")
        self.assertFalse([a for a in argv if " " in a and a.startswith("-")],
                         f"no option may carry its value in the same word: {argv}")

    @unittest.skipUnless(shutil.which("psql"), "psql is not installed here")
    def test_the_joined_form_really_is_rejected_by_psql(self):
        """The real boundary, not our expectation of it: psql itself refuses the one-element form. This is the
        failure that made every read unreadable and held every eligible decline (QA #1718, 2026-11-06)."""
        joined = subprocess.run(["psql", "-v ON_ERROR_STOP=1", "-c", "select 1"], capture_output=True, text=True)
        self.assertNotEqual(joined.returncode, 0)
        self.assertIn("invalid variable name", joined.stderr)
        split = subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-c", "select 1"], capture_output=True, text=True)
        self.assertNotIn("invalid variable name", split.stderr,
                         "the two-element form is accepted by psql (it may still fail to connect, which is fine)")

    def test_an_unreadable_ledger_holds_the_user_even_when_the_route_is_off(self):
        self.assertEqual(decline_close.plan([42], "2026-11-01T00:00:00Z", route=("off", "file"),
                                            notes=(None, "send ledger unreadable: psql said ERROR"))["users"]["42"]["decision"],
                         "hold")


class OneUserSendDecisionTests(unittest.TestCase):
    """The gate's read: one user, one decision word, exit 0 only when hydra is the teller."""

    def test_core_routing_on_means_hydra_sends_nothing(self):
        rc, out = run(["--user-id", "42", "--route", "routed"])
        self.assertEqual((rc, out["decision"]), (3, "core_email"),
                         "core's own credits_rejected email is the decline: hydra must not add a second one")
        self.assertIn("core", out["why"])

    def test_route_off_with_no_core_note_is_the_only_send(self):
        rc, out = run(["--user-id", "42", "--route", "off", "--since", "2026-11-01T00:00:00Z"],
                      notes=({}, "no notes"))
        self.assertEqual((rc, out["decision"]), (0, "hydra_decline"),
                         "rc 0 = the one decision the gate may act on")

    def test_a_core_note_for_this_user_holds_because_it_cannot_be_attributed_to_this_request(self):
        # QA #1718 (2026-11-06): `send.messages` carries no request id, so a note since the close may belong to a
        # DIFFERENT request. Reading it as "core told them about THIS one" leaves this request silently untold, so
        # the answer is a hold a person sees - never a `core_email` claim the ledger cannot support.
        rc, out = run(["--user-id", "42", "--route", "off", "--since", "2026-11-01T00:00:00Z"],
                      notes=({42: 2}, "2 notes"))
        self.assertEqual((rc, out["decision"]), (3, "hold"))
        self.assertIn("2", out["why"])
        self.assertIn("no request id", out["why"])

    def test_an_unknown_route_with_no_note_holds(self):
        rc, out = run(["--user-id", "42", "--route", "unknown", "--since", "2026-11-01T00:00:00Z"],
                      notes=({}, "no notes"))
        self.assertEqual((rc, out["decision"]), (3, "hold"))

    def test_an_unknown_route_with_a_positive_core_note_holds(self):
        # A note is measured fact about the USER, not about this request: with the route unread we cannot say
        # whether core is emailing at all, and the note cannot say whose request it was.
        rc, out = run(["--user-id", "42", "--route", "unknown", "--since", "2026-11-01T00:00:00Z"],
                      notes=({42: 1}, "1 note"))
        self.assertEqual((rc, out["decision"]), (3, "hold"))

    def test_an_unreadable_ledger_holds_both_ways(self):
        for route, expect in (("off", "hold"), ("unknown", "hold"),
                              ("routed", "core_email")):   # routed needs no ledger read: core is the teller anyway
            with self.subTest(route=route):
                rc, out = run(["--user-id", "42", "--route", route, "--since", "2026-11-01T00:00:00Z"],
                              notes=(None, "send ledger unreadable rc=1"))
                self.assertEqual((rc, out["decision"]), (3, expect),
                                 "an unread ledger never becomes a send")

    def test_the_window_defaults_and_is_reported(self):
        rc, out = run(["--user-id", "42", "--route", "off", "--days", "7"], notes=({}, "no notes"))
        self.assertEqual(rc, 0)
        self.assertRegex(out["since"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(out["user_id"], 42)

    def test_the_two_modes_do_not_mix(self):
        self.assertEqual(run(["--user-id", "42", "--users", "42,43", "--since", "2026-11-01T00:00:00Z"])[0], 2)
        self.assertEqual(run(["--users", "42,43"])[0], 2, "a batch plan needs --since")
        self.assertEqual(run(["--user-id", "not-a-number"])[0], 2)

    def test_the_batch_mode_holds_the_user_with_a_note_and_sends_to_the_one_without(self):
        rc, out = run(["--users", "42,43", "--since", "2026-11-01T00:00:00Z", "--route", "off"],
                      notes=({42: 1}, "1 note"))
        self.assertEqual(rc, 3, "42 is held for a person, so the batch is not fully decided")
        self.assertEqual(out["decision"], {"core_email": 0, "hydra_decline": 1, "hold": 1})
        self.assertEqual(decline_close.hydra_users(out), [43],
                         "only the hydra_decline users are fed to the campaign gate")


class TheTemplateIsTheOneTheDeclineIsAboutTests(unittest.TestCase):
    """QA #1718 (2026-11-06): a profile claim is declined by core's `profile_claim_rejected` email, not by
    `credits_rejected`, and the two have their own routes. Judging a claim by the credit route reads "core emails
    credits" as "core told this claimant", so the claimant never gets the decline the copy promises."""

    def test_a_claim_is_judged_by_the_claim_route_not_the_credit_route(self):
        # core emails credits but NOT claims: the claim decline is hydra's, and the credit route must not silence it
        routes = {"credits_rejected": "new", "profile_claim_rejected": "off"}
        with mock.patch.object(decline_close, "route_map", return_value=(routes, "test routes")):
            claim = decline_close.plan([42], "2026-11-01T00:00:00Z", template=decline_close.CLAIM_TEMPLATE,
                                       notes=({}, "no notes"))
            credit = decline_close.plan([42], "2026-11-01T00:00:00Z", notes=({}, "no notes"))
        self.assertEqual(claim["users"]["42"]["decision"], decline_close.HYDRA_DECLINE)
        self.assertEqual(claim["template"], "profile_claim_rejected")
        self.assertEqual(credit["users"]["42"]["decision"], decline_close.CORE_EMAIL)
        self.assertEqual(credit["template"], "credits_rejected")

    def test_the_ledger_read_asks_about_the_chosen_template(self):
        seen = []

        def runner(sql):
            seen.append(sql)
            return LedgerReadIsEvidenceTests.P(out="42|1\n")

        decline_close.core_notes([42], "2026-11-01T00:00:00Z", template=decline_close.CLAIM_TEMPLATE, runner=runner)
        self.assertIn("profile_claim_rejected", seen[0])
        self.assertNotIn("credits_rejected", seen[0])

    def test_an_unknown_template_is_refused_rather_than_guessed(self):
        with self.assertRaises(ValueError):
            decline_close.plan([42], "2026-11-01T00:00:00Z", template="something_else")
        self.assertIsNone(decline_close.core_notes([42], "2026-11-01T00:00:00Z", template="nope")[0],
                          "an unknown template is unreadable, which the caller turns into a hold")

    def test_core_told_answers_for_the_removal_path(self):
        # QA #1718 (2026-11-06): with core's route ON, hydra writes no `decline` row, so the removal decision must ask
        # core or it holds every rejected credit forever. Off = core told nobody, hydra's own row decides; unreadable
        # = None, which holds.
        since = "2026-10-05T12:00:00Z"
        self.assertEqual(decline_close.core_told("a@x.com", "42", ["r1"], since, route="off"), {})
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, route="unknown"))
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, template="nope", route="routed"))
        self.assertEqual(decline_close.core_told("a@x.com", "42", [], since, route="routed"), {})

    def test_a_configured_route_is_not_a_delivery(self):
        # QA #1718 round 5 (2026-11-06): `routed` says core's pipeline handles the template, NOT that a message reached
        # this person - a gateway send can fail and an account can have no deliverable address. Releasing a credit on
        # the route alone would remove it from someone who was never told, so a routed template must also show a row
        # in the send ledger for this user since the close. No row is a HOLD, never a release.
        since = "2026-10-05T12:00:00Z"
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, route="routed", notes={}),
                          "routed but nothing in the send ledger: hold")
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, route="routed", notes={42: 0}),
                          "a zero count is not a delivery")
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, route="routed", notes={7: 3}),
                          "another user's note is not this user's delivery")
        self.assertIsNone(decline_close.core_told("a@x.com", "", ["r1"], since, route="routed", notes={42: 1}),
                          "no account id: the ledger cannot be asked, so hold")
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, route="routed", notes=None),
                          "an unreadable ledger holds")
        # and the real read is asked about the right template and window
        seen = []

        def fake_notes(users, since_arg, *, template=decline_close.CORE_TEMPLATE, runner=None, pg=None):
            seen.append((list(users), since_arg, template))
            return {42: 1}, "test"

        with mock.patch.object(decline_close, "route_state", return_value=("routed", "test")), \
                mock.patch.object(decline_close, "core_notes", side_effect=fake_notes):
            self.assertEqual(decline_close.core_told("a@x.com", "42", ["r1"], since, notes=None), {"r1": False},
                             "a note exists but cannot be attributed to this request")
        self.assertEqual(seen, [([42], since, "credits_rejected")],
                         "the ledger is asked about this user, this close, and the credit template")

    def test_a_user_level_count_is_never_per_request_evidence(self):
        # QA #1718 round 7 (2026-11-06), reproduced verbatim: r1 is rejected twice (two `credits_rejected` messages
        # for r1) while r2 is rejected but its email fails. `notes[uid] == 2` and the old `>= len(ids)` rule returned
        # True for BOTH, so the removal export could remove r2 although no decline for r2 ever reached the user.
        # No store we can read carries a request id - `send.messages` has none, and ClickHouse
        # `messaging.email_events` has none either - so counting rows can never attribute a note to a credit. The
        # answer is therefore never True for a specific request while core is the teller.
        since = "2026-10-05T12:00:00Z"
        for count in (1, 2, 3, 99):
            got = decline_close.core_told("a@x.com", "42", ["r1", "r2"], since, route="routed", notes={42: count})
            self.assertEqual(got, {"r1": False, "r2": False},
                             f"{count} user-level note(s) cannot say which of r1/r2 was told")
        # one credit, one note: still not attributable, because the note may be about a different request entirely
        self.assertEqual(decline_close.core_told("a@x.com", "42", ["r1"], since, route="routed", notes={42: 1}),
                         {"r1": False})
        # and the False is distinguishable from "no note at all", which is what the hold reason keys on
        self.assertIsNone(decline_close.core_told("a@x.com", "42", ["r1"], since, route="routed", notes={42: 0}))


    def test_the_cli_takes_the_template_and_reports_it(self):
        rc, out = run(["--user-id", "42", "--route", "off", "--since", "2026-11-01T00:00:00Z",
                       "--template", "profile_claim_rejected"], notes=({}, "no notes"))
        self.assertEqual((rc, out["decision"], out["template"]), (0, "hydra_decline", "profile_claim_rejected"))
        with self.assertRaises(SystemExit) as caught:   # argparse refuses an unknown template outright
            run(["--user-id", "42", "--template", "nope"])
        self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
