#!/usr/bin/env python3

import fcntl
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("uvn_under30_cron", SCRIPTS / "uvn-under30-cron.py")
cron = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cron)

CR_ID = "11111111-1111-4111-8111-111111111111"
CR_ID_2 = "22222222-2222-4222-8222-222222222222"
PROFILE_ID = "33333333-3333-4333-8333-333333333333"


def task(automation_ready=True, ids=True):
    action = {
        "action_type": "credit-verify",
        "customer_profile_id": PROFILE_ID,
        "details": {
            # needs-human is the mainline enrolled population now: the cron's
            # own policy is the gate, not Caroline's untrusted recommendation.
            "recommendation": "needs-human",
        },
    }
    if ids:
        action["details"]["pending_credits"] = [{"cr_id": CR_ID}]
    return {
        "id": "ticket-1",
        "description": f"---ACTION-REQUEST---\n{json.dumps(action)}\n---END-ACTION-REQUEST---",
        "status": {"status": "to do"},
        "tags": [
            {"name": "hydra-action-request"},
            {"name": "action:credit-verify"},
            *([{"name": "automation:uvn-under30"}] if automation_ready else []),
        ],
    }


def credit(status="user_verification_needed", request_id=CR_ID, track="spotify-1"):
    return {
        "id": request_id,
        "profileId": PROFILE_ID,
        "status": status,
        "spotifyTrackId": track,
        "spotifyTrackTitle": f"Song {request_id[:2]}",
        "credits": ["Mixing"],
        "verificationData": {"rule_risk_percent": {}},
    }


class CronOrchestrationTests(unittest.TestCase):
    def _counted(self, lookup):
        def wrapped(track_id, timeout=None):
            self.lookup_calls += 1
            try:
                return lookup(track_id, timeout=timeout)
            except TypeError:
                return lookup(track_id)
        return wrapped

    def run_main(
        self,
        fraud_ids,
        rows,
        unresolved_ids=None,
        ticket=None,
        popularity=None,
        argv=("--mode", "apply", "--limit", "25"),
        approve_result=None,
        lookup=None,
    ):
        output = io.StringIO()
        ticket = ticket or task()
        popularity = popularity or {}

        self.lookup_calls = 0

        def default_lookup(track_id, timeout=None):
            self.lookup_calls += 1
            value = popularity.get(track_id, 29)
            if value == "not-found":
                return {"found": False}
            return {"found": True, "track": {"popularity": value}}

        with (
            patch.dict(os.environ, {"UVN_SKIP_HOST_GUARD": "1"}),
            patch.object(cron, "KILL_SWITCH_PATH", Path("/nonexistent/uvn-under30-cron.disabled")),
            patch.object(cron, "credit_write_lock", return_value=nullcontext()),
            patch.object(cron, "load_fraud_ids", return_value=fraud_ids),
            patch.object(cron, "load_unresolved_ids", return_value=unresolved_ids or set()),
            patch.object(cron, "list_todo_tickets", return_value=[ticket]),
            patch.object(cron, "get_task_and_comments", return_value=(ticket, [])),
            patch.object(cron, "list_profile_requests", side_effect=rows),
            patch.object(cron, "spotify_lookup", side_effect=self._counted(lookup) if lookup else default_lookup),
            patch.object(cron, "approve_chunk", side_effect=approve_result or (lambda run_id, task_id, ids: set(ids))) as approve,
            patch.object(cron, "update_ticket", side_effect=lambda *args, **kwargs: args[3]) as update,
            patch.object(cron, "shadow_record") as shadow,
            patch.object(cron, "audit"),
            redirect_stdout(output),
        ):
            rc = cron.main(list(argv))
        self.shadow = shadow
        return rc, output.getvalue(), approve, update

    def test_approves_exact_ticket_id_then_resolves_after_authoritative_state(self):
        rc, output, approve, update = self.run_main(
            set(),
            [
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit("approved")},
            ],
        )
        self.assertEqual(rc, 0)
        approve.assert_called_once()
        self.assertEqual(approve.call_args.args[2], [CR_ID])
        update.assert_called_once()
        self.assertTrue(update.call_args.args[3])
        self.assertEqual(
            output.strip(),
            "\n".join([
                "Credit verification check complete.",
                "• Tickets ready for automatic review: 1",
                "• Requests approved after confirming live Spotify popularity below 30: 1",
                "• Tickets resolved: 1",
                "• Tickets still open: 0",
                "No credits were rejected.",
            ]),
        )

    # The live ticket population carries the profile UUID and no cr_ids
    # (39 of 40 measured 2026-09-04). The cron must resolve the pending rows
    # from the backend itself, approve the sub-30 ones, and resolve the ticket
    # only when the profile has nothing left in verification.
    def test_profile_scoped_ticket_approves_every_sub30_row_and_resolves(self):
        pending = {CR_ID: credit(), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        done = {CR_ID: credit("approved"), CR_ID_2: credit("approved", request_id=CR_ID_2, track="spotify-2")}
        rc, output, approve, update = self.run_main(
            set(), [pending, pending, pending, done], ticket=task(ids=False)
        )
        self.assertEqual(rc, 0)
        approve.assert_called_once()
        self.assertEqual(approve.call_args.args[2], [CR_ID, CR_ID_2])
        update.assert_called_once()
        self.assertTrue(update.call_args.args[3])
        self.assertEqual(update.call_args.args[5], None)
        self.assertEqual(update.call_args.args[6], {CR_ID, CR_ID_2})
        self.assertIn("Requests approved after confirming live Spotify popularity below 30: 2", output)

    def test_partial_profile_approves_the_sub30_rows_and_leaves_the_rest_for_a_human(self):
        pending = {CR_ID: credit(), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        after = {CR_ID: credit("approved"), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        rc, output, approve, update = self.run_main(
            set(), [pending, pending, pending, after],
            ticket=task(ids=False), popularity={"spotify-2": 41},
        )
        self.assertEqual(rc, 0)
        self.assertEqual(approve.call_args.args[2], [CR_ID])
        update.assert_called_once()
        self.assertFalse(update.call_args.args[3])
        comment = update.call_args.args[2]
        self.assertIn("approved 1 request", comment)
        self.assertIn("Song 22", comment)
        self.assertIn("popularity 41", comment)
        self.assertIn("Tickets still open: 1", output)

    def test_new_pending_row_after_the_scope_was_taken_blocks_resolution(self):
        pending = {CR_ID: credit()}
        after = {CR_ID: credit("approved"), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        rc, _, approve, update = self.run_main(
            set(), [pending, pending, pending, after], ticket=task(ids=False)
        )
        self.assertEqual(rc, 0)
        approve.assert_called_once()
        self.assertFalse(update.call_args.args[3])

    def test_profile_with_nothing_pending_is_left_alone(self):
        rc, output, approve, update = self.run_main(
            set(), [{CR_ID: credit("approved")}], ticket=task(ids=False)
        )
        self.assertEqual(rc, 0)
        approve.assert_not_called()
        update.assert_not_called()
        self.assertEqual(output.strip(), "NO_REPLY")

    def test_shadow_mode_records_would_approve_rows_and_writes_nothing(self):
        pending = {CR_ID: credit()}
        rc, output, approve, update = self.run_main(
            set(), [pending, pending, pending, pending],
            ticket=task(ids=False), argv=("--mode", "shadow"),
        )
        self.assertEqual(rc, 0)
        approve.assert_not_called()
        update.assert_not_called()
        self.shadow.assert_called_once()
        self.assertEqual(self.shadow.call_args.kwargs["request_ids"], [CR_ID])
        self.assertIn("shadow mode", output)
        self.assertIn("would have been approved", output)
        self.assertIn("No changes were made", output)

    def test_shadow_is_the_default_mode(self):
        pending = {CR_ID: credit()}
        rc, _, approve, update = self.run_main(
            set(), [pending, pending, pending, pending], ticket=task(ids=False), argv=()
        )
        self.assertEqual(rc, 0)
        approve.assert_not_called()
        update.assert_not_called()
        self.shadow.assert_called_once()

    def test_shadow_mode_with_nothing_to_approve_stays_silent(self):
        rc, output, _, _ = self.run_main(
            set(), [{CR_ID: credit()}] * 4, ticket=task(ids=False),
            popularity={"spotify-1": 55}, argv=("--mode", "shadow"),
        )
        self.assertEqual(rc, 0)
        self.shadow.assert_not_called()
        self.assertEqual(output.strip(), "NO_REPLY")

    def test_run_limit_caps_approvals_and_reports_it(self):
        pending = {CR_ID: credit(), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        after = {CR_ID: credit("approved"), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        rc, output, approve, update = self.run_main(
            set(), [pending, pending, pending, after],
            ticket=task(ids=False), argv=("--mode", "apply", "--limit", "1"),
        )
        self.assertEqual(rc, 0)
        self.assertEqual(approve.call_args.args[2], [CR_ID])
        self.assertFalse(update.call_args.args[3])
        self.assertIn("approval cap", output.lower())

    def test_dead_popularity_source_stops_the_run_early_and_loudly(self):
        # Measured 2026-09-04: /admin/spotify/web-lookup answered 502/524 after
        # ~120s for every track. Waiting that out per track would exhaust the
        # cron timeout with no summary; instead the run stops at the first
        # failure, says so, and fails for paging. Nothing is written.
        output = io.StringIO()
        second_ticket = {**task(ids=False), "id": "ticket-2"}
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task(ids=False), second_ticket]),
            patch.object(cron, "get_task_and_comments", return_value=(task(ids=False), [])) as get_task,
            patch.object(cron, "list_profile_requests", return_value={CR_ID: credit()}),
            patch.object(cron, "spotify_lookup", side_effect=cron.LookupUnavailable("HTTP 524")),
            patch.object(cron, "approve_chunk") as approve,
            patch.object(cron, "update_ticket") as update,
            patch.object(cron, "audit"),
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 1)
        approve.assert_not_called()
        update.assert_not_called()
        # ticket-1 is re-read at the scope check; ticket-2 is never touched
        self.assertEqual({call.args[0] for call in get_task.call_args_list}, {"ticket-1"})
        self.assertIn("Live Spotify popularity is unavailable", output.getvalue())
        self.assertIn("No credits were rejected", output.getvalue())

    # The admin route answers {result, code, data} with `data` being the track
    # itself, popularity at the top level (core-backend webLookup.js +
    # spotifyWebLookup.js getTrack). The stub below IS that envelope; the
    # approval gate must read it, or the cron approves nothing in production
    # while every test that fakes spotify_lookup stays green.
    LIVE_ENVELOPE = {
        "http_status": 200,
        "body": {"result": "ok", "code": 200, "data": {"id": "spotify-1", "name": "Song", "popularity": 12}},
    }

    def test_popularity_lookup_is_bounded_and_classifies_answers(self):
        with patch.object(cron, "run_json", side_effect=subprocess.TimeoutExpired("x", 45)) as run_json:
            with self.assertRaises(cron.LookupUnavailable):
                cron.spotify_lookup("spotify-1")
        self.assertEqual(run_json.call_args.kwargs["timeout"], cron.LOOKUP_TIMEOUT_SECS)
        self.assertLess(cron.LOOKUP_TIMEOUT_SECS, 100)
        for outage in ({"http_status": 524, "body": {}}, {"http_status": 200, "body": {"data": None}}):
            with patch.object(cron, "run_json", return_value=outage):
                with self.assertRaises(cron.LookupUnavailable):
                    cron.spotify_lookup("spotify-1")
        # One track Spotify no longer serves is a row-level fact, not an outage.
        # 404 is the ONLY authoritative not-found: webLookup.js maps only
        # `e.response?.status === 404` to NotFound, while its 400s mean our own
        # call was malformed (bad type / missing id) — a bug, never a verdict
        # about the track.
        with patch.object(cron, "run_json", return_value={"http_status": 404, "body": {"result": "error"}}):
            self.assertEqual(cron.spotify_lookup("spotify-1"), {"found": False})
        with patch.object(cron, "run_json", return_value={"http_status": 400, "body": {"result": "error"}}):
            with self.assertRaises(cron.LookupUnavailable):
                cron.spotify_lookup("spotify-1")
        # A 200 carrying no usable popularity is the spclient path degrading:
        # getTrack seeds `popularity: null` and swallows the spclient error, so
        # accepting it would disqualify every row in silence — the exact
        # failure this cron exists to make loud.
        for degraded in (None, "12", True):
            envelope = {"http_status": 200, "body": {"data": {"id": "spotify-1", "popularity": degraded}}}
            with patch.object(cron, "run_json", return_value=envelope):
                with self.assertRaises(cron.LookupUnavailable):
                    cron.spotify_lookup("spotify-1")
        with patch.object(cron, "run_json", return_value=self.LIVE_ENVELOPE):
            live = cron.spotify_lookup("spotify-1")
        self.assertEqual(live["found"], True)
        self.assertEqual(cron.live_popularity(live), 12)

    def test_real_lookup_envelope_reaches_the_approval_gate(self):
        pending = {CR_ID: credit()}
        with patch.object(cron, "admin_raw", return_value=self.LIVE_ENVELOPE) as admin_raw:
            rc, output, approve, update = self.run_main(
                set(), [pending, pending, pending, {CR_ID: credit("approved")}],
                ticket=task(ids=False), lookup=cron.spotify_lookup,
            )
        self.assertEqual(rc, 0)
        self.assertIn("/admin/spotify/web-lookup?", admin_raw.call_args.args[1])
        self.assertEqual(approve.call_args.args[2], [CR_ID])
        self.assertTrue(update.call_args.args[3])

    def test_missing_track_is_row_level_not_an_outage(self):
        pending = {CR_ID: credit(), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        after = {CR_ID: credit("approved"), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        rc, output, approve, update = self.run_main(
            set(), [pending, pending, pending, after],
            ticket=task(ids=False), popularity={"spotify-2": "not-found"},
        )
        self.assertEqual(rc, 0)
        self.assertEqual(approve.call_args.args[2], [CR_ID])
        comment = update.call_args.args[2]
        self.assertIn("track not found on Spotify", comment)
        self.assertIn("Tickets still open: 1", output)

    def test_early_stop_after_a_committed_chunk_still_comments_the_ticket(self):
        ids = [f"{i:08d}-0000-4000-8000-000000000000" for i in range(51)]
        pending = {rid: credit(request_id=rid, track=f"track-{rid[:8]}") for rid in ids}
        calls = {"n": 0}

        def lookup(track_id):
            calls["n"] += 1
            if calls["n"] > 100:  # chunk 1 = 50 warm + 50 write-edge lookups
                raise cron.LookupUnavailable("HTTP 524")
            return {"found": True, "track": {"popularity": 5}}

        rc, output, approve, update = self.run_main(
            set(), [pending] * 6, ticket=task(ids=False), argv=("--mode", "apply", "--limit", "100"), lookup=lookup,
        )
        self.assertEqual(rc, 1)
        approve.assert_called_once()
        self.assertEqual(len(approve.call_args.args[2]), 50)
        update.assert_called_once()
        self.assertFalse(update.call_args.args[3])
        self.assertIn("approved 50 requests", update.call_args.args[2])
        self.assertIn("stopped early", update.call_args.args[2])
        self.assertIn("Live Spotify popularity is unavailable", output)

    def test_cap_truncation_is_explained_on_the_ticket(self):
        pending = {CR_ID: credit(), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        after = {CR_ID: credit("approved"), CR_ID_2: credit(request_id=CR_ID_2, track="spotify-2")}
        rc, _, _, update = self.run_main(
            set(), [pending, pending, pending, after],
            ticket=task(ids=False), argv=("--mode", "apply", "--limit", "1"),
        )
        self.assertEqual(rc, 0)
        comment = update.call_args.args[2]
        self.assertIn("(1 rows)", comment)
        self.assertIn("popularity 29", comment)
        self.assertIn("approval cap for this run was reached", comment)
        self.assertNotIn("need a human", comment)

    def test_shadow_failure_is_announced_not_silenced(self):
        rc, output, approve, update = self.run_main(
            set(), [cron.RunError("admin API returned HTTP 502")], ticket=task(ids=False), argv=("--mode", "shadow"),
        )
        self.assertEqual(rc, 1)
        approve.assert_not_called()
        update.assert_not_called()
        self.assertNotIn("NO_REPLY", output)
        self.assertIn("shadow mode", output)
        self.assertIn("could not be assessed", output)
        self.assertIn("ticket-1", output)

    def test_run_budget_stops_the_run_with_a_summary(self):
        with patch.object(cron, "RUN_BUDGET_SECS", -1):
            rc, output, approve, update = self.run_main(
                set(), [{CR_ID: credit()}] * 4, ticket=task(ids=False), argv=("--mode", "shadow"),
            )
        self.assertEqual(rc, 1)
        approve.assert_not_called()
        update.assert_not_called()
        self.assertIn("time budget", output)
        self.assertIn("shadow mode", output)
        self.assertLess(cron.RUN_BUDGET_SECS, 1200)

    def test_budget_is_enforced_between_lookups_inside_one_chunk(self):
        # One chunk performs up to 100 sequential lookups; checking the budget
        # only between chunks lets the external 1200s runner SIGKILL the process
        # mid-chunk, which is the silent death the budget exists to prevent.
        rows = {f"cr{i}": credit(request_id=f"cr{i}", track=f"spotify-{i}") for i in range(6)}
        clock = iter([0] + [40 * i for i in range(1, 200)])
        with (
            patch.object(cron, "RUN_BUDGET_SECS", 100),
            patch.object(cron.time, "monotonic", side_effect=lambda: next(clock)),
        ):
            rc, output, approve, update = self.run_main(
                set(), [rows] * 4, ticket=task(ids=False), argv=("--mode", "shadow"),
            )
        self.assertEqual(rc, 1)
        approve.assert_not_called()
        self.assertIn("time budget", output)
        self.assertLess(self.lookup_calls, 6)

    def test_lookup_timeout_never_exceeds_the_remaining_budget(self):
        self.assertLessEqual(cron.lookup_timeout(3), 3)
        self.assertEqual(cron.lookup_timeout(10_000), cron.LOOKUP_TIMEOUT_SECS)
        self.assertGreaterEqual(cron.lookup_timeout(0), 1)

    def test_fraud_marker_prevents_approval_and_ticket_write(self):
        rc, output, approve, update = self.run_main(
            {CR_ID},
            [
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
            ],
        )
        self.assertEqual(rc, 0)
        approve.assert_not_called()
        update.assert_not_called()
        self.assertEqual(output.strip(), "NO_REPLY")

    def test_unresolved_partial_commit_keeps_ticket_open(self):
        rc, _, approve, update = self.run_main(
            set(),
            [
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit("approved")},
            ],
            {CR_ID},
        )
        self.assertEqual(rc, 0)
        approve.assert_called_once()
        update.assert_called_once()
        self.assertFalse(update.call_args.args[3])

    def test_ticket_without_automation_eligibility_tag_is_left_for_manual_review(self):
        output = io.StringIO()
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task(automation_ready=False)]),
            patch.object(cron, "get_task_and_comments") as get_task,
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 0)
        self.assertEqual(output.getvalue().strip(), "NO_REPLY")
        get_task.assert_not_called()

    def test_ticket_removed_from_automation_between_list_and_detail_is_ignored(self):
        for current_task in [task(automation_ready=False), {**task(), "status": {"status": "resolved"}}]:
            with self.subTest(current_task=current_task):
                output = io.StringIO()
                with (
                    patch.object(cron, "load_fraud_ids", return_value=set()),
                    patch.object(cron, "list_todo_tickets", return_value=[task()]),
                    patch.object(cron, "get_task_and_comments", return_value=(current_task, [])),
                    patch.object(cron, "update_ticket") as update,
                    redirect_stdout(output),
                ):
                    rc = cron.run_locked("run-1", mode="apply", limit=25)

                self.assertEqual(rc, 0)
                self.assertEqual(output.getvalue().strip(), "NO_REPLY")
                update.assert_not_called()

    def test_ticket_removed_during_scope_recheck_is_ignored(self):
        for current_task in [task(automation_ready=False), {**task(), "status": {"status": "resolved"}}]:
            with self.subTest(current_task=current_task):
                output = io.StringIO()
                with (
                    patch.object(cron, "load_fraud_ids", return_value=set()),
                    patch.object(cron, "list_todo_tickets", return_value=[task()]),
                    patch.object(
                        cron,
                        "get_task_and_comments",
                        side_effect=[(task(), []), (current_task, [])],
                    ),
                    patch.object(cron, "list_profile_requests", return_value={CR_ID: credit()}),
                    patch.object(cron, "update_ticket") as update,
                    redirect_stdout(output),
                ):
                    rc = cron.run_locked("run-1", mode="apply", limit=25)

                self.assertEqual(rc, 0)
                self.assertEqual(output.getvalue().strip(), "NO_REPLY")
                update.assert_not_called()

    def test_mid_run_fraud_truth_failure_still_fails_the_cron(self):
        output = io.StringIO()
        with (
            patch.object(
                cron,
                "load_fraud_ids",
                side_effect=[set(), cron.PolicyError("malformed truth floor")],
            ),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", return_value=(task(), [])),
            patch.object(cron, "list_profile_requests", return_value={CR_ID: credit()}),
            patch.object(cron, "update_ticket"),
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 1)
        self.assertIn("Credit verification automation needs attention.", output.getvalue())

    def test_popularity_is_refreshed_at_write_edge(self):
        output = io.StringIO()
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", return_value=(task(), [])),
            patch.object(cron, "list_profile_requests", return_value={CR_ID: credit()}),
            patch.object(
                cron,
                "spotify_lookup",
                side_effect=[
                    {"found": True, "track": {"popularity": 29}},
                    {"found": True, "track": {"popularity": 30}},
                ],
            ) as spotify_lookup,
            patch.object(cron, "approve_chunk") as approve,
            patch.object(cron, "update_ticket") as update,
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 0)
        self.assertEqual(spotify_lookup.call_count, 2)
        approve.assert_not_called()
        update.assert_not_called()
        self.assertEqual(output.getvalue().strip(), "NO_REPLY")

    def test_policy_failure_posts_a_plain_english_summary_for_manual_review(self):
        output = io.StringIO()
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", return_value=(task(), [])),
            patch.object(cron, "parse_ticket_scope", side_effect=cron.PolicyError("bad scope")),
            patch.object(cron, "update_ticket") as update,
            patch.object(cron, "remove_automation_tag") as remove_tag,
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 0)
        self.assertIn(cron.MANUAL_HANDOFF_MARKER, update.call_args.args[2])
        remove_tag.assert_called_once_with("run-1", "ticket-1")
        self.assertEqual(
            output.getvalue().strip(),
            "\n".join([
                "Credit verification automation needs attention.",
                "1 ticket could not be processed safely and is still open for manual review.",
                "• Tickets ready for automatic review: 1",
                "• Requests approved after confirming live Spotify popularity below 30: 0",
                "• Tickets resolved: 0",
                "• Tickets still open: 1",
                "No credits were rejected.",
            ]),
        )

    def test_runtime_failure_posts_the_summary_and_still_fails_the_cron(self):
        output = io.StringIO()
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", side_effect=cron.RunError("bad scope")),
            patch.object(cron, "update_ticket"),
            patch.object(cron, "remove_automation_tag") as remove_tag,
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 1)
        remove_tag.assert_not_called()
        self.assertEqual(
            output.getvalue().strip(),
            "\n".join([
                "Credit verification automation needs attention.",
                "1 ticket could not be processed safely and is still open for manual review.",
                "• Tickets ready for automatic review: 0",
                "• Requests approved after confirming live Spotify popularity below 30: 0",
                "• Tickets resolved: 0",
                "• Tickets still open: 1",
                "No credits were rejected.",
            ]),
        )

    def test_failed_manual_review_comment_keeps_ticket_enrolled_for_retry(self):
        output = io.StringIO()
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", return_value=(task(), [])),
            patch.object(cron, "parse_ticket_scope", side_effect=cron.PolicyError("bad scope")),
            patch.object(cron, "update_ticket", side_effect=cron.RunError("comment failed")),
            patch.object(cron, "remove_automation_tag") as remove_tag,
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 1)
        remove_tag.assert_not_called()

    def test_existing_manual_handoff_only_removes_tag_on_retry(self):
        output = io.StringIO()
        comments = [{"comment_text": cron.MANUAL_HANDOFF_MARKER}]
        with (
            patch.object(cron, "load_fraud_ids", return_value=set()),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", return_value=(task(), comments)),
            patch.object(cron, "parse_ticket_scope", side_effect=cron.PolicyError("bad scope")),
            patch.object(cron, "update_ticket") as update,
            patch.object(cron, "remove_automation_tag") as remove_tag,
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-2", mode="apply", limit=25)

        self.assertEqual(rc, 0)
        update.assert_not_called()
        remove_tag.assert_called_once_with("run-2", "ticket-1")


class TicketWriteTests(unittest.TestCase):
    def test_policy_handoff_removes_only_the_automation_tag(self):
        with (
            patch.object(cron, "audit") as audit,
            patch.object(cron, "clickup") as clickup,
        ):
            cron.remove_automation_tag("run-1", "ticket-1")

        clickup.assert_called_once_with(
            "DELETE",
            "/task/ticket-1/tag/automation%3Auvn-under30",
        )
        self.assertEqual(audit.call_count, 2)


class SharedLockEntrypointTests(unittest.TestCase):
    def test_startup_failure_summary_is_plain_english(self):
        self.assertEqual(
            cron.render_startup_failure("backend timed out"),
            "\n".join([
                "Credit verification automation needs attention.",
                "The automatic check could not start, so no tickets were reviewed or changed.",
                "No credits were approved or rejected.",
                "Technical details: backend timed out",
            ]),
        )

    def test_initial_dependency_timeout_is_reported_without_a_traceback(self):
        output = io.StringIO()
        with (
            patch.object(cron, "load_required_fraud_ids", return_value=set()),
            patch.object(
                cron,
                "list_todo_tickets",
                side_effect=subprocess.TimeoutExpired(["muso"], 120),
            ),
            redirect_stdout(output),
        ):
            rc = cron.run_locked("run-1", mode="apply", limit=25)

        self.assertEqual(rc, 1)
        self.assertIn("The automatic check could not start", output.getvalue())
        self.assertNotIn("Traceback", output.getvalue())

    def test_real_entrypoint_fails_before_external_boundaries_when_lock_is_held(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lock_path = tmp_path / "credit-status-writes.lock"
            boundary_calls = tmp_path / "boundary.calls"
            boundary_stub = tmp_path / "boundary-stub.sh"
            boundary_stub.write_text(
                "#!/usr/bin/env bash\n"
                'printf "called\\n" >> "$UVN_TEST_BOUNDARY_CALLS"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            boundary_stub.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "UVN_SKIP_HOST_GUARD": "1",
                "CV_CREDIT_WRITE_LOCK_PATH": str(lock_path),
                "CV_CREDIT_WRITE_LOCK_WAIT_SECS": "1",
                "MUSO_BIN": str(boundary_stub),
                "UVN_ADMIN_SCRIPT": str(boundary_stub),
                "UVN_STATUS_VERIFY": str(boundary_stub),
                "UVN_TEST_BOUNDARY_CALLS": str(boundary_calls),
                "UVN_FRAUD_ROOT": str(tmp_path / "fraud-runs"),
                "CV_FRAUD_ATTEMPT_PATH": str(tmp_path / "fraud-attempts.jsonl"),
                "UVN_AUDIT_ROOT": str(tmp_path / "audit"),
                "UVN_UNRESOLVED_PATH": str(tmp_path / "unresolved.json"),
            })

            with lock_path.open("a+", encoding="utf-8") as lock_handle:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(
                    [sys.executable, str(SCRIPTS / "uvn-under30-cron.py"), "--mode", "apply"],
                    capture_output=True,
                    text=True,
                    env=env,
                    timeout=5,
                    check=False,
                )
                # Shadow never writes credit status, so a held lock must not
                # stall it (dispatch-cv-batch.sh applies the same dry-run rule).
                shadow = subprocess.run(
                    [sys.executable, str(SCRIPTS / "uvn-under30-cron.py"), "--mode", "shadow"],
                    capture_output=True,
                    text=True,
                    env=env,
                    timeout=5,
                    check=False,
                )

            self.assertEqual(result.returncode, 1)
            self.assertIn("timed out waiting for the shared credit-write lock", result.stdout)
            self.assertFalse(boundary_calls.exists())
            self.assertNotIn("credit-write lock", shadow.stdout)

    def test_invalid_lock_wait_fails_before_external_boundaries(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            boundary_calls = tmp_path / "boundary.calls"
            boundary_stub = tmp_path / "boundary-stub.sh"
            boundary_stub.write_text(
                "#!/usr/bin/env bash\n"
                'printf "called\\n" >> "$UVN_TEST_BOUNDARY_CALLS"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            boundary_stub.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "UVN_SKIP_HOST_GUARD": "1",
                "CV_CREDIT_WRITE_LOCK_PATH": str(tmp_path / "credit-status-writes.lock"),
                "CV_CREDIT_WRITE_LOCK_WAIT_SECS": "0",
                "MUSO_BIN": str(boundary_stub),
                "UVN_TEST_BOUNDARY_CALLS": str(boundary_calls),
            })

            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "uvn-under30-cron.py"), "--mode", "apply"],
                capture_output=True,
                text=True,
                env=env,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("CV_CREDIT_WRITE_LOCK_WAIT_SECS must be a positive integer", result.stdout)
            self.assertFalse(boundary_calls.exists())


    def _entrypoint(self, extra_env, argv=()):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            boundary_calls = tmp_path / "boundary.calls"
            boundary_stub = tmp_path / "boundary-stub.sh"
            boundary_stub.write_text(
                "#!/usr/bin/env bash\n"
                'printf "called\\n" >> "$UVN_TEST_BOUNDARY_CALLS"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            boundary_stub.chmod(0o755)
            env = dict(os.environ)
            env.pop("UVN_SKIP_HOST_GUARD", None)
            env.update({
                "CV_CREDIT_WRITE_LOCK_PATH": str(tmp_path / "credit-status-writes.lock"),
                "CV_CREDIT_WRITE_LOCK_WAIT_SECS": "1",
                "MUSO_BIN": str(boundary_stub),
                "UVN_ADMIN_SCRIPT": str(boundary_stub),
                "UVN_STATUS_VERIFY": str(boundary_stub),
                "UVN_TEST_BOUNDARY_CALLS": str(boundary_calls),
                "UVN_FRAUD_ROOT": str(tmp_path / "fraud-runs"),
                "UVN_KILL_SWITCH_PATH": str(tmp_path / "absent.disabled"),
            })
            env.update({k: (str(tmp_path / v) if k == "UVN_KILL_SWITCH_PATH" else v) for k, v in extra_env.items()})
            if "UVN_KILL_SWITCH_PATH" in extra_env:
                Path(env["UVN_KILL_SWITCH_PATH"]).write_text("", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "uvn-under30-cron.py"), *argv],
                capture_output=True,
                text=True,
                env=env,
                timeout=5,
                check=False,
            )
            return result, boundary_calls.exists()

    def test_host_guard_refuses_off_node_8_before_external_boundaries(self):
        result, called = self._entrypoint({"UVN_EXPECTED_HOST": "some-other-host"}, ("--mode", "apply"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to run on host", result.stdout)
        self.assertFalse(called)

    def test_kill_switch_file_silences_the_cron_before_external_boundaries(self):
        result, called = self._entrypoint(
            {"UVN_SKIP_HOST_GUARD": "1", "UVN_KILL_SWITCH_PATH": "uvn-under30-cron.disabled"},
            ("--mode", "apply"),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "NO_REPLY")
        self.assertIn("kill switch", result.stderr)
        self.assertFalse(called)

    def test_invalid_mode_or_limit_is_refused(self):
        for argv in (("--mode", "yolo"), ("--limit", "0"), ("--limit", "abc")):
            result, called = self._entrypoint({"UVN_SKIP_HOST_GUARD": "1"}, argv)
            self.assertNotEqual(result.returncode, 0, argv)
            self.assertFalse(called)


class ApprovalReadbackTests(unittest.TestCase):
    def test_non_2xx_partial_commit_is_persisted_and_reported(self):
        with (
            patch.object(cron, "audit"),
            patch.object(cron, "admin_raw", return_value={"http_status": 500, "body": {}}),
            patch.object(cron, "verify_status", return_value={CR_ID}),
            patch.object(cron, "mark_unresolved") as mark_unresolved,
        ):
            with self.assertRaises(cron.ApprovalAttemptError) as raised:
                cron.approve_chunk("run-1", "ticket-1", [CR_ID])

        self.assertEqual(raised.exception.confirmed_ids, {CR_ID})
        self.assertEqual(mark_unresolved.call_count, 2)
        self.assertIn("attempt started", mark_unresolved.call_args_list[0].args[2])

    def test_exact_2xx_and_readback_clears_prior_unresolved_state(self):
        response = {
            "http_status": 200,
            "body": {"data": {"updatedIds": [CR_ID]}},
        }
        with (
            patch.object(cron, "audit"),
            patch.object(cron, "admin_raw", return_value=response),
            patch.object(cron, "verify_status", return_value={CR_ID}),
            patch.object(cron, "mark_unresolved"),
            patch.object(cron, "clear_unresolved") as clear_unresolved,
        ):
            confirmed = cron.approve_chunk("run-1", "ticket-1", [CR_ID])

        self.assertEqual(confirmed, {CR_ID})
        clear_unresolved.assert_called_once_with("run-1", [CR_ID])

    def test_durable_unresolved_marker_precedes_admin_write(self):
        events = []

        def mark(*_args):
            events.append("mark")

        def write(*_args):
            events.append("write")
            raise cron.RunError("transport failed after request")

        with (
            patch.object(cron, "audit"),
            patch.object(cron, "mark_unresolved", side_effect=mark),
            patch.object(cron, "admin_raw", side_effect=write),
            patch.object(cron, "verify_status", return_value=set()),
        ):
            with self.assertRaises(cron.ApprovalAttemptError):
                cron.approve_chunk("run-1", "ticket-1", [CR_ID])

        self.assertEqual(events[:2], ["mark", "write"])

    def test_directory_fsync_failure_refuses_admin_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker_path = Path(tmp) / "unresolved.json"
            with (
                patch.object(cron, "UNRESOLVED_PATH", marker_path),
                patch.object(cron, "audit"),
                patch.object(cron.os, "fsync", side_effect=[None, OSError("directory fsync failed")]),
                patch.object(cron, "admin_raw") as admin_raw,
            ):
                with self.assertRaises(OSError):
                    cron.approve_chunk("run-1", "ticket-1", [CR_ID])

            admin_raw.assert_not_called()

    def test_malformed_readback_cannot_confirm_an_id(self):
        result = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout=json.dumps({
                "expected": "approved",
                "matched": 1,
                "mismatched": [{"actual": "rejected"}],
            }),
            stderr="",
        )
        with patch.object(cron.subprocess, "run", return_value=result):
            with self.assertRaises(cron.RunError):
                cron.verify_status([CR_ID])


class ClickUpBoundaryTests(unittest.TestCase):
    def test_comments_are_paginated_with_both_cursor_fields(self):
        first_page = [
            {"id": f"comment-{index}", "date": str(1000 - index)}
            for index in range(25)
        ]
        with patch.object(
            cron,
            "clickup",
            side_effect=[task(), {"comments": first_page}, {"comments": []}],
        ) as clickup:
            _, comments = cron.get_task_and_comments("ticket-1")

        self.assertEqual(comments, first_page)
        self.assertEqual(
            clickup.call_args_list[2].kwargs["query"],
            ["start=976", "start_id=comment-24"],
        )

    def test_unresolved_id_blocks_status_write_after_final_scope_reread(self):
        with (
            patch.object(cron, "audit"),
            patch.object(cron, "clickup") as clickup,
            patch.object(cron, "assert_ticket_scope"),
            patch.object(cron, "list_profile_requests", return_value={CR_ID: credit("approved")}),
            patch.object(cron, "load_unresolved_ids", return_value={CR_ID}),
        ):
            resolved = cron.update_ticket(
                "run-1",
                "ticket-1",
                "automation comment",
                True,
                PROFILE_ID,
                {CR_ID},
                {CR_ID},
            )

        self.assertFalse(resolved)
        clickup.assert_called_once_with(
            "POST",
            "/task/ticket-1/comment",
            {"comment_text": "automation comment", "notify_all": False},
        )


if __name__ == "__main__":
    unittest.main()
