"""Behavioral tests for the `bulk-credit-change` drainer.

This drainer EDITS customer credits unattended in batches, so the properties
worth locking are the ones that keep a bad batch from landing:

  * `remove: true` (and the `from_role` spelling of it) is refused BEFORE any
    write, and the whole batch is refused with it.
  * a batch that fails validation writes NOTHING (all-or-nothing at validation).
  * a row that fails AFTER the write boundary stops the batch and the outcome is
    `partial` — never `complete`, and the completed rows stay recorded.
  * nothing in this path writes a ClickUp status, and the customer is never
    messaged: the reconciler is the only close writer.
  * the pre-image (before/after role list) is in the ledger for every write.

No network: the admin API and ClickUp are fakes that record calls.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
import urllib.parse
from unittest import mock

_REPO = pathlib.Path(__file__).resolve().parent.parent
_SCRIPTS = _REPO / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

_SPEC = importlib.util.spec_from_file_location(
    "bulk_credit_change", _SCRIPTS / "clickup_drain" / "bulk_credit_change.py"
)
bcc = importlib.util.module_from_spec(_SPEC)
# dataclasses resolves annotations through sys.modules[cls.__module__], so the
# module has to be registered before exec_module.
sys.modules[_SPEC.name] = bcc
_SPEC.loader.exec_module(bcc)

from clickup_drain import manifest as mf  # noqa: E402
from clickup_drain import write_path as wp  # noqa: E402

T1 = "11111111-1111-4111-8111-111111111111"
T2 = "22222222-2222-4222-8222-222222222222"
P1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
P2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


# --------------------------------------------------------------------------
# fakes
# --------------------------------------------------------------------------
class FakeAdmin:
    """In-memory admin API. Records every mutating call."""

    def __init__(self, *, roles=None, tracks=None, profiles=None, fail_track_read=None,
                 post_status=200, readback_never_shows=False,
                 unavailable_gets=False, unavailable_after_post=False,
                 missing_tracks=(), readback_flaky_after_post=False,
                 fail_comment=False, credits_404=False):
        self.roles = dict(roles or {})            # {profile_id: {track_id: [roles]}}
        self.tracks = set(tracks if tracks is not None else {T1, T2})
        self.profiles = dict(profiles or {P1: {}, P2: {}})
        self.fail_track_read = fail_track_read
        self.post_status = post_status
        self.readback_never_shows = readback_never_shows
        self.unavailable_gets = unavailable_gets
        self.unavailable_after_post = unavailable_after_post
        self.missing_tracks = set(missing_tracks)
        self.readback_flaky_after_post = readback_flaky_after_post
        self.credits_404 = credits_404
        self.on_post = None
        self.post_reads = 0
        self.posts: list[tuple[str, str, str]] = []
        self.deletes: list[tuple[str, str, str]] = []
        self.gets = 0

    # admin protocol ------------------------------------------------------
    def get(self, path, params=None):
        self.gets += 1
        if self.unavailable_gets or (self.unavailable_after_post and self.posts):
            raise wp.Unavailable("admin API is down (HTTP 503)")
        if self.readback_flaky_after_post and self.posts and path.endswith("/credits"):
            # the read-back window is flaky: readable (role not yet visible) then
            # unreadable, ending on a read we could NOT see
            self.post_reads += 1
            if self.post_reads > 1:
                raise wp.Unavailable("admin API is down (HTTP 503)")
        if path.startswith("/admin/track/"):
            track_id = path.rsplit("/", 1)[-1]
            if self.fail_track_read == track_id:
                raise wp.AdminError(f"admin GET {path} returned HTTP 500")
            if track_id not in self.tracks or track_id in self.missing_tracks:
                raise wp.NotFound(path)
            return wp.Envelope(200, {"id": track_id})
        if path == f"/admin/profile/{P1}" or path == f"/admin/profile/{P2}":
            profile_id = path.rsplit("/", 1)[-1]
            if profile_id not in self.profiles:
                raise wp.NotFound(path)
            return wp.Envelope(200, dict(self.profiles[profile_id]))
        if path.endswith("/credits"):
            profile_id = path.split("/")[3]
            if self.credits_404:
                # the profile read succeeded a moment ago; this sub-resource 404s
                raise wp.NotFound(path)
            if profile_id not in self.roles:
                return wp.Envelope(200, {"items": [], "total": 0})
            items = [
                {"id": t, "credits": list(r)} for t, r in sorted(self.roles[profile_id].items())
            ]
            return wp.Envelope(200, {"items": items, "total": len(items)})
        raise wp.AdminError(f"unexpected GET {path}")

    def post(self, path, body):
        track_id = path.split("/")[3]
        profile_id = path.split("/")[5]
        role = body.get("role")
        self.posts.append((track_id, profile_id, role))
        if self.on_post is not None:
            self.on_post()
        if self.post_status != 200:
            return wp.Envelope(self.post_status, {"error": "nope"})
        if not self.readback_never_shows:
            self.roles.setdefault(profile_id, {}).setdefault(track_id, []).append(role)
        return wp.Envelope(200, {"ok": True})

    def delete(self, path, body):
        track_id = path.split("/")[3]
        profile_id = path.split("/")[5]
        role = body.get("role")
        self.deletes.append((track_id, profile_id, role))
        current = self.roles.get(profile_id, {}).get(track_id, [])
        self.roles.setdefault(profile_id, {})[track_id] = [
            r for r in current if r.casefold() != str(role).casefold()
        ]
        return wp.Envelope(200, {"ok": True})


class FakeClickUp:
    """ClickUp task store. Records every mutating call, including any status PUT."""

    def __init__(self, tasks=None, fail_comment=False):
        self.fail_comment = fail_comment
        self.tasks = {t["id"]: json.loads(json.dumps(t)) for t in (tasks or [])}
        self.calls: list[tuple[str, str]] = []
        self.comments: list[tuple[str, str]] = []
        # Set to an exception instance to make the NEXT task GET fail, e.g. a
        # ClickUp outage landing exactly on the post-write re-read.
        self.fail_next_get = None
        # Called before every task GET, so a test can land a rewrite on an exact
        # read (e.g. the one inside replace_customer_outcome).
        self.on_get = None

    def request(self, method, url_or_path, body=None, timeout=60):
        path = url_or_path
        self.calls.append((method, path))
        if path.startswith("/task/") and "/tag/" in path:
            task_id, tag = path.split("/task/")[1].split("/tag/")
            tag = urllib.parse.unquote(tag)  # the caller percent-encodes the colon
            task = self.tasks[task_id]
            tags = [t for t in task.get("tags", []) if t.get("name") != tag]
            if method == "POST":
                tags.append({"name": tag})
            task["tags"] = tags
            return 200, {}
        if path.endswith("/comment") and method == "POST":
            if self.fail_comment:
                raise AssertionError("comment POST failed (HTTP 503)")
            task_id = path.split("/")[2]
            self.comments.append((task_id, body["comment_text"]))
            return 200, {"id": "c1"}
        if path.startswith("/task/"):
            if self.on_get is not None:
                self.on_get()
            if self.fail_next_get is not None:
                exc, self.fail_next_get = self.fail_next_get, None
                raise exc
            return 200, self.tasks[path.split("/")[2]]
        raise AssertionError(f"unexpected ClickUp call {method} {path}")

    def status_writes(self):
        return [(m, p) for m, p in self.calls if m == "PUT"]


def outcome_tags_of(client, task_id):
    """Only the customer-outcome tags — the drainer leaves every other tag alone."""
    return sorted(
        t["name"] for t in client.tasks[task_id]["tags"]
        if t["name"].startswith("customer-outcome:")
    )


def ticket(description, *, task_id="t1", tags=None):
    return {
        "id": task_id,
        "description": description,
        "tags": [{"name": t} for t in (tags if tags is not None else ["hydra-action-request",
                                                                     "action:bulk-credit-change"])],
        "status": {"status": "to do", "type": "open"},
        "date_created": "1700000000000",
    }


def ticket_with_rows(rows, *, task_id="t1", profile_id=P1, extra_details=None):
    details = {"bulk_rows": rows}
    details.update(extra_details or {})
    payload = {
        "action_type": "bulk-credit-change",
        "approval_tier": 2,
        "customer_email": "a@b.com",
        "customer_profile_id": profile_id,
        "details": details,
        "conversation_summary": "customer listed tracks",
    }
    return ticket(
        "## Update credits\n\n---ACTION-REQUEST---\n"
        + json.dumps(payload, indent=2)
        + "\n---END-ACTION-REQUEST---\n",
        task_id=task_id,
    )


def ticket_without_anchor(rows, *, task_id="t0"):
    """A legacy ticket: rows but no customer_profile_id (pre-anchor intake)."""
    payload = {
        "action_type": "bulk-credit-change",
        "approval_tier": 2,
        "details": {"bulk_rows": rows},
    }
    return ticket(
        "## Update credits\n\n---ACTION-REQUEST---\n"
        + json.dumps(payload, indent=2)
        + "\n---END-ACTION-REQUEST---\n",
        task_id=task_id,
    )


def row(track_id=T1, profile_id=P1, role="Mixing", intent="add", **kw):
    return {"track_id": track_id, "profile_id": profile_id, "role": role,
            "intent": intent, **kw}


class DrainTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.ledger = str(self.tmp / "ledger.jsonl")
        self.state = str(self.tmp / "state")
        os.makedirs(self.state, exist_ok=True)
        self.attempts = os.path.join(self.state, "attempts.json")

    def tearDown(self):
        self._tmp.cleanup()

    def make_path(self, dry_run=False, **kw):
        kw.setdefault("kill_files", ())
        kw.setdefault("lock_path", str(self.tmp / "lock"))
        kw.setdefault("ledger_path", self.ledger)
        kw.setdefault("cap_path", str(self.tmp / "writes.json"))
        return wp.WritePath(dry_run=dry_run, **kw)



class OutageAndBudgetTest(DrainTestCase):
    """The failure modes the QA review called out: an outage must never look like
    a verdict about the request, and a corrupt budget must never fail open."""

    def test_transient_outage_writes_nothing_and_tags_nothing(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, unavailable_gets=True)
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        # nothing was written, nothing was tagged, no comment: the ticket is
        # retried on the next run instead of being parked behind `blocked`
        self.assertEqual(admin.posts, [])
        self.assertEqual(path.writes_this_run, 0)
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(client.comments, [])

    def test_readback_outage_leaves_no_tag_and_the_next_run_completes(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, unavailable_after_post=True)
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        # the write happened but we could not prove it: no tag, and the ledger
        # says intent + unverified rather than pretending nothing happened
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        self.assertEqual([e["phase"] for e in entries], ["intent", "result"])
        self.assertEqual(entries[-1]["outcome"], "unverified")

        # recovery: the role is there, so the next run says `already`, adds
        # nothing, and tags the ticket complete
        admin.unavailable_after_post = False
        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r2", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome.rows_written, 0)
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])

    def test_a_past_dated_budget_rolls_over_but_a_future_one_refuses(self):
        # A past date is yesterday's budget: the day rolled over, so today starts
        # at zero. A FUTURE date means the clock moved backwards under a budget
        # that already recorded spend — reading that as zero would hand out
        # another full day on top of writes that really happened.
        path = self.make_path(dry_run=False)
        cap = pathlib.Path(path.cap_path)
        now = path._clock()
        yesterday = wp._utc_today(now - 86400)
        tomorrow = wp._utc_today(now + 86400)

        cap.write_text(json.dumps({"date": yesterday, "used": 100}), encoding="utf-8")
        self.assertEqual(path.writes_used_today(), 0)
        self.assertEqual(path.writes_remaining_today(), wp.MAX_WRITES_PER_DAY)

        cap.write_text(json.dumps({"date": tomorrow, "used": 100}), encoding="utf-8")
        with self.assertRaises(wp.DrainBlocked):
            path.writes_used_today()
        with self.assertRaises(wp.DrainBlocked):
            path.reserve_write()
        # and the refusal names the disagreement, so a human can see the clock
        with self.assertRaises(wp.DrainBlocked) as caught:
            path.writes_used_today()
        self.assertIn(tomorrow, str(caught.exception))
        self.assertIn("future", str(caught.exception))

        # a budget we cannot date is not a budget we may read as zero
        for bad in (None, 20261106, ""):
            cap.write_text(json.dumps({"date": bad, "used": 100}), encoding="utf-8")
            with self.assertRaises(wp.DrainBlocked):
                path.writes_used_today()

    def test_corrupt_write_budget_refuses_to_write(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)
        pathlib.Path(path.cap_path).write_text("{not json", encoding="utf-8")

        with self.assertRaises(wp.DrainBlocked):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        # a budget we cannot read must not read as "zero writes today"
        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(pathlib.Path(path.cap_path).read_text(encoding="utf-8"), "{not json")

    def test_invalid_used_value_refuses_to_write(self):
        path = self.make_path(dry_run=False)
        pathlib.Path(path.cap_path).write_text(
            json.dumps({"date": wp._utc_today(), "used": "many"}), encoding="utf-8")
        with self.assertRaises(wp.DrainBlocked):
            path.reserve_write()

    def test_absent_budget_is_zero_and_a_new_day_resets(self):
        path = self.make_path(dry_run=False)
        self.assertEqual(path.writes_used_today(), 0)
        path.reserve_write()
        self.assertEqual(path.writes_used_today(), 1)
        # yesterday's spend does not follow us into today
        pathlib.Path(path.cap_path).write_text(
            json.dumps({"date": "2000-01-01", "used": 100}), encoding="utf-8")
        self.assertEqual(path.writes_used_today(), 0)
        path.reserve_write()
        self.assertEqual(path.writes_used_today(), 1)

    def test_two_roles_on_one_credit_both_land(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer"),
                                                row(role="Engineer")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        # the second row's compare-and-set accounts for our own first write
        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome.rows_written, 2)
        self.assertEqual(admin.posts, [(T1, P1, "Producer"), (T1, P1, "Engineer")])
        self.assertEqual(sorted(admin.roles[P1][T1]), ["Engineer", "Mix", "Producer"])

    def test_track_404_is_a_contradiction_not_a_verdict(self):
        # The profile's credit list already proved this track is referenced, so a
        # confirmed 404 from /admin/track can only mean that read is broken (it
        # answers 404 when its own catalog read fails). Never a `blocked` tag.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, missing_tracks=(T1,))
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), [])

    def test_read_back_window_that_ends_unreadable_does_not_tag_partial(self):
        # a readable-but-not-yet-visible read followed by failures: the final
        # state was never observed, so tagging `partial` would be a verdict we
        # did not have
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, readback_never_shows=True,
                          readback_flaky_after_post=True)
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"), [])

    def test_comment_precedes_the_tag_so_evidence_cannot_be_lost(self):
        # a tagged ticket is skipped forever: if the comment had not posted, the
        # `partial` would have no explanation and no way to get one
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}, P2: {T2: ["Mix"]}},
                          readback_never_shows=True)
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer")])],
                             fail_comment=True)
        path = self.make_path(dry_run=False)

        with self.assertRaises(Exception):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"), [])


    def test_satisfied_row_still_present_completes_with_no_write(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Mix")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome.rows_written, 0)
        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])

    def test_satisfied_row_whose_role_vanished_is_not_called_complete(self):
        # `satisfied` came from a read that may be minutes old. A human removing
        # the role before the loop reaches the row must not be reported as done.
        class RemovingAdmin(FakeAdmin):
            credit_reads = 0

            def get(self, path, params=None):
                if path.endswith("/credits"):
                    self.credit_reads += 1
                    if self.credit_reads == 2:
                        self.roles[P1][T1] = []
                return super().get(path, params)

        admin = RemovingAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Mix")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_PARTIAL)
        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:partial"])
        self.assertIn("gone now", client.comments[0][1])

    def test_uncertain_post_status_leaves_the_ticket_untagged(self):
        for status in (408, 425, 429, 500, 503):
            with self.subTest(status=status):
                open(self.ledger, "w").close()
                admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, post_status=status)
                client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
                path = self.make_path(dry_run=False)

                with self.assertRaises(wp.Unavailable):
                    bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                   run_id="r1", dry_run=False, sleep=lambda _s: None)

                self.assertEqual(outcome_tags_of(client, "t1"), [])
                with open(self.ledger, encoding="utf-8") as fh:
                    entries = [json.loads(line) for line in fh]
                self.assertEqual([e["phase"] for e in entries], ["intent", "result"])
                self.assertEqual(entries[-1]["outcome"], "unverified")
                self.assertEqual(entries[-1]["http_status"], status)

    def test_unauthorized_post_is_untagged_and_retried(self):
        # 401/403 is OUR credentials failing to answer, not a defect in the row.
        # Tagging `partial` here parks a ticket whose credit was never written.
        for status in (401, 403):
            with self.subTest(status=status):
                open(self.ledger, "w").close()
                admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, post_status=status)
                client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
                path = self.make_path(dry_run=False)

                with self.assertRaises(wp.Unavailable):
                    bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                   run_id="r1", dry_run=False, sleep=lambda _s: None)

                self.assertEqual(outcome_tags_of(client, "t1"), [])
                with open(self.ledger, encoding="utf-8") as fh:
                    entries = [json.loads(line) for line in fh]
                self.assertEqual(entries[-1]["outcome"], "unverified")
                self.assertEqual(entries[-1]["http_status"], status)
                self.assertIn("nothing was written", entries[-1]["detail"])

    def test_unanswerable_status_is_one_predicate_for_reads_and_writes(self):
        # The read path and the write path must agree on what an outage is, or a
        # status that is retryable on a GET becomes a terminal verdict on a POST.
        for status in (401, 403, 408, 425, 429, 500, 503, None):
            self.assertTrue(wp.is_unanswerable_status(status), status)
        for status in (200, 201, 400, 404, 409, 422):
            self.assertFalse(wp.is_unanswerable_status(status), status)

        class Denied(wp.CreditAdmin):
            def __init__(self, status):
                super().__init__(script="/nonexistent")
                self.status = status

            def call(self, method, path, body=None):
                return wp.Envelope(self.status, {"error": "nope"})

        for status in (401, 403):
            with self.assertRaises(wp.Unavailable):
                Denied(status).get(f"/admin/profile/{P1}")

    def test_permanent_post_refusal_is_still_partial(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, post_status=400)
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_PARTIAL)
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:partial"])

    def test_unreadable_pre_write_state_does_not_earn_a_verdict(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}}, unavailable_gets=True)
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome_tags_of(client, "t1"), [])


    def test_non_transient_read_failure_is_unreadable_state_not_a_verdict(self):
        # 401/403 (or any wrapper failure) says nothing about the request: tagging
        # `blocked` would park a valid ticket forever
        class DeniedAdmin(FakeAdmin):
            def get(self, path, params=None):
                if path.startswith("/admin/profile/") and "/credits" not in path:
                    raise wp.AdminError(f"admin GET {path} returned HTTP 403")
                return super().get(path, params)

        admin = DeniedAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(admin.posts, [])

    def test_malformed_credit_list_is_unreadable_state(self):
        class GarbledAdmin(FakeAdmin):
            def get(self, path, params=None):
                if path.endswith("/credits"):
                    return wp.Envelope(200, {"items": "not-a-list", "total": 1})
                return super().get(path, params)

        admin = GarbledAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(admin.posts, [])

    def test_non_object_profile_body_is_unreadable_state(self):
        class OddAdmin(FakeAdmin):
            def get(self, path, params=None):
                if path.startswith("/admin/profile/") and "/credits" not in path:
                    return wp.Envelope(200, ["not", "an", "object"])
                return super().get(path, params)

        admin = OddAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome_tags_of(client, "t1"), [])


# --------------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------------
class ManifestTest(unittest.TestCase):
    def test_happy_path_accepts_track_url_and_id(self):
        parsed = mf.parse_manifest(
            ticket_with_rows([
                {"track_url": f"https://credits.muso.ai/track/{T1}", "profile_id": P1,
                 "role": "Mixing", "intent": "add"},
                row(track_id=T2, role="Mastering"),
            ])["description"]
        )
        self.assertEqual([(r.track_id, r.role) for r in parsed.rows],
                         [(T1, "Mixing"), (T2, "Mastering")])
        self.assertEqual(parsed.customer_profile_id, P1)

    def test_prose_only_is_unparseable(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest("please fix my credits on these 3 tracks thanks")
        self.assertEqual(ctx.exception.reason, mf.REASON_UNPARSEABLE)

    def test_bulk_rows_missing_is_unparseable(self):
        desc = ticket_with_rows([row()])["description"].replace("bulk_rows", "tracks")
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(desc)
        self.assertEqual(ctx.exception.reason, mf.REASON_UNPARSEABLE)

    def test_remove_true_is_a_removal_and_is_refused(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([row(remove=True)])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_REMOVAL_REFUSED)
        self.assertIn(mf.REASON_REMOVAL_REFUSED, mf.REASONS_THAT_TAG_BLOCKED)

    def test_from_role_is_a_removal_in_disguise(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([row(from_role="Mastering")])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_REMOVAL_REFUSED)

    def test_missing_profile_anchor_is_refused(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_without_anchor([row()])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_MISSING_PROFILE)
        self.assertNotIn(mf.REASON_MISSING_PROFILE, mf.REASONS_THAT_TAG_BLOCKED)

    def test_refusal_names_the_keys_the_intake_did_emit(self):
        # Live queue (2026-11-03): 93/99 open tickets carry a JSON block but no
        # `bulk_rows`. The refusal has to say what they DO carry, or the intake
        # fix is invisible.
        prose_details = ticket(
            "---ACTION-REQUEST---\n"
            + json.dumps({"action_type": "bulk-credit-change",
                          "customer_profile_id": P1,
                          "details": {"customer_name": "x",
                                      "tracks": ["https://credits.muso.ai/track/a"],
                                      "requested_role": "Mixing"}})
            + "\n---END-ACTION-REQUEST---"
        )
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(prose_details["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_UNPARSEABLE)
        self.assertIn("tracks", ctx.exception.detail)
        self.assertIn("requested_role", ctx.exception.detail)
        self.assertIn("bulk_rows", ctx.exception.detail)

    def test_refusal_hint_is_bounded_and_flat(self):
        many = {f"key_{i}": i for i in range(20)}
        many["evil\nkey"] = "x"
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket(
                "---ACTION-REQUEST---\n"
                + json.dumps({"customer_profile_id": P1, "details": many})
                + "\n---END-ACTION-REQUEST---"
            )["description"])
        hint = ctx.exception.detail
        self.assertIn("more)", hint)
        self.assertIn("evil_key", hint)
        self.assertNotIn("evil\nkey", hint)
        self.assertLess(len(hint), 500)

    def test_remove_false_is_accepted(self):
        parsed = mf.parse_manifest(ticket_with_rows([row(remove=False)])["description"])
        self.assertEqual(len(parsed.rows), 1)

    def test_unknown_row_key_is_refused(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(
                ticket_with_rows([{**row(), "removal": True}])["description"]
            )
        self.assertEqual(ctx.exception.reason, mf.REASON_ROW_INVALID)

    def test_too_many_rows(self):
        rows = [row(track_id=f"t{i}") for i in range(mf.MAX_ROWS + 1)]
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows(rows)["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_TOO_MANY_ROWS)

    def test_duplicate_row_is_refused(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([row(), row()])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_ROW_INVALID)

    def test_both_track_id_and_url_is_refused(self):
        bad = {**row(), "track_url": f"https://credits.muso.ai/track/{T1}"}
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([bad])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_ROW_INVALID)

    def test_non_muso_track_url_is_refused(self):
        bad = {"track_url": "https://example.com/track/" + T1, "profile_id": P1,
               "role": "Mixing"}
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([bad])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_ROW_INVALID)

    def test_track_url_locale_path_is_accepted(self):
        self.assertEqual(
            mf.track_id_from_url(f"https://muso.ai/en/track/{T1}"), T1
        )

    def test_role_whitespace_is_collapsed(self):
        parsed = mf.parse_manifest(ticket_with_rows([row(role="  Immersive   Mixing ")])["description"])
        self.assertEqual(parsed.rows[0].role, "Immersive Mixing")


# --------------------------------------------------------------------------
# remove: true — refused before any write (definition-of-done case)
# --------------------------------------------------------------------------
class RemovalRefusedBeforeAnyWriteTest(DrainTestCase):
    def test_remove_true_writes_no_credit_and_tags_blocked(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}})
        client = FakeClickUp([ticket_with_rows([row(remove=True)])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_BLOCKED)
        self.assertEqual(admin.posts, [], "no credit write may happen for a removal")
        self.assertEqual(admin.deletes, [])
        self.assertEqual(path.writes_this_run, 0)
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:blocked"])
        self.assertEqual(
            sorted(t["name"] for t in client.tasks["t1"]["tags"]),
            ["action:bulk-credit-change", "customer-outcome:blocked", "hydra-action-request"],
            "the drainer must not disturb the ticket's other tags",
        )
        self.assertEqual(client.status_writes(), [], "the drainer never writes a status")
        self.assertEqual(len(client.comments), 1)


# --------------------------------------------------------------------------
# validation: all-or-nothing, zero writes
# --------------------------------------------------------------------------
class IntentTest(DrainTestCase):
    """A row that names only a role cannot say add-vs-replace.

    "also credit me as Mastering" and "change my Mixing to Mastering" both arrive
    as `role: "Mastering"`. The second is a removal plus an add: adding Mastering
    and reading it back would report `complete` while Mixing still displays — the
    customer's real request half-done and the ticket closed.
    """

    def test_a_replace_intent_is_refused_as_a_removal(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([row(role="Mastering", intent="replace")])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_REMOVAL_REFUSED)
        self.assertIn("removal plus an add", ctx.exception.detail)

    def test_a_change_intent_is_refused_as_a_removal(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([row(role="Mastering", intent="change")])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_REMOVAL_REFUSED)

    def test_a_missing_intent_is_an_intake_defect_not_a_verdict(self):
        # No tag: the intake must fix the manifest, the customer asked for nothing
        # we are declining.
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([
                {"track_id": T1, "profile_id": P1, "role": "Mastering"}
            ])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_ROW_INVALID)
        self.assertIn("intent is missing", ctx.exception.detail)
        self.assertNotIn(mf.REASON_ROW_INVALID, mf.REASONS_THAT_TAG_BLOCKED)

    def test_an_unknown_intent_is_row_invalid(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            mf.parse_manifest(ticket_with_rows([row(intent="upsert")])["description"])
        self.assertEqual(ctx.exception.reason, mf.REASON_ROW_INVALID)

    def test_intent_is_case_and_space_insensitive(self):
        parsed = mf.parse_manifest(ticket_with_rows([row(intent="  ADD ")])["description"])
        self.assertEqual(len(parsed.rows), 1)

    def test_a_change_request_is_blocked_and_never_half_applied(self):
        # The end state the reviewer named: Mixing -> Mastering. The drainer must
        # not add Mastering and call it complete.
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Mastering", intent="replace")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_BLOCKED)
        self.assertEqual(admin.posts, [])
        self.assertEqual(admin.roles[P1][T1], ["Mixing"])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:blocked"])
        self.assertEqual(len(client.comments), 1)


class ValidationTest(DrainTestCase):
    def test_a_credits_404_after_a_good_profile_read_is_an_outage(self):
        # The profile read succeeded a moment ago, so a 404 on its credits is an
        # inconsistent API, not proof the request is wrong. Tagging `blocked`
        # would park a valid ticket that no later run ever retries.
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}}, credits_404=True)
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), [])

    def test_missing_track_refuses_whole_batch_with_no_writes(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}}, tracks={T1})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1), row(track_id=T2)])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_BLOCKED)
        self.assertIn("failed validation", outcome.detail)
        self.assertEqual(admin.posts, [])
        self.assertEqual(path.writes_this_run, 0)

    def test_no_credit_on_track_is_refused(self):
        # The profile holds a credit on T1 only; T2 is a claim, not an edit.
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}}, tracks={T1, T2})
        client = FakeClickUp([ticket_with_rows([row(track_id=T2, role="Mastering")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_BLOCKED)
        self.assertIn("no credit on this track", outcome.detail)
        self.assertEqual(admin.posts, [])

    def test_row_for_another_profile_is_refused(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}, P2: {T1: ["Mixing"]}})
        client = FakeClickUp([ticket_with_rows([row(profile_id=P2)])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_BLOCKED)
        self.assertIn("belongs to", outcome.detail)
        self.assertEqual(admin.posts, [])

    def test_ticket_without_a_profile_anchor_writes_nothing(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}})
        client = FakeClickUp([ticket_without_anchor([row()])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t0"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, mf.REASON_MISSING_PROFILE)
        self.assertEqual(admin.posts, [])
        self.assertEqual(path.writes_this_run, 0)
        # no outcome tag: the ticket stays waiting-on-us and shows up in the
        # SLA digest instead of being closed as dealt-with
        self.assertEqual(outcome_tags_of(client, "t0"), [])

    def test_merged_profile_is_refused(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}},
                          profiles={P1: {"mergedTo": "someone-else"}})
        client = FakeClickUp([ticket_with_rows([row()])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_BLOCKED)
        self.assertEqual(admin.posts, [])


# --------------------------------------------------------------------------
# applying
# --------------------------------------------------------------------------
class ApplyTest(DrainTestCase):
    def test_already_satisfied_row_writes_nothing_and_completes(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mixing"]}})
        client = FakeClickUp([ticket_with_rows([row(role="mixing")])])  # case-insensitive
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome.rows_written, 0)
        self.assertEqual(admin.posts, [])
        self.assertEqual(path.writes_this_run, 0)
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])
        self.assertEqual(client.comments, [])

    def test_missing_role_is_added_verified_and_ledgered(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mastering"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Mixing")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome.rows_written, 1)
        self.assertEqual(admin.posts, [(T1, P1, "Mixing")])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])

        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        # intent BEFORE the request, result after: a crash between them still
        # leaves a trace that we wrote
        self.assertEqual([e["phase"] for e in entries], ["intent", "result"])
        intent, entry = entries
        self.assertEqual(intent["outcome"], "attempted")
        self.assertEqual(entry["action"], "add")
        self.assertEqual(entry["outcome"], "verified")
        self.assertEqual(entry["before_roles"], ["Mastering"])
        self.assertIn("Mixing", entry["after_roles"])
        self.assertEqual(entry["track_id"], T1)
        self.assertEqual(entry["profile_id"], P1)

    def test_rows_are_applied_sequentially_in_order(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer"),
                                                row(track_id=T2, role="Engineer")])])
        path = self.make_path(dry_run=False)

        bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                       run_id="r1", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(admin.posts, [(T1, P1, "Producer"), (T2, P1, "Engineer")])

    def test_readback_failure_stops_batch_and_is_partial_never_complete(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}},
                          readback_never_shows=True)
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer"),
                                                row(track_id=T2, role="Engineer")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_PARTIAL)
        self.assertNotEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        # the batch stopped at the first row that failed to verify
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:partial"])
        self.assertEqual(client.status_writes(), [])
        # one internal comment naming only what did not land
        self.assertEqual(len(client.comments), 1)
        comment = client.comments[0][1]
        self.assertIn("did NOT land", comment)
        self.assertIn(T1, comment)
        # the row the batch never reached is named as unattempted, not silently
        # dropped: the comment has to be the whole story
        tail = comment.split("did NOT land")[1].split("reason:")[0]
        self.assertIn(T2, tail)
        self.assertIn("not attempted", tail)

    def test_concurrent_edit_stops_the_batch(self):
        class RacyAdmin(FakeAdmin):
            credit_reads = 0

            def get(self, path, params=None):
                if path.endswith("/credits"):
                    self.credit_reads += 1
                    # a human edits the credit between validation and the write:
                    # the compare-and-set re-read must see the edit
                    if self.credit_reads == 2:
                        self.roles[P1][T1] = ["Mastering"]
                return super().get(path, params)

        admin = RacyAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(admin.posts, [], "must not write over a concurrent edit")
        self.assertEqual(outcome.bucket, bcc.OUTCOME_PARTIAL)


# --------------------------------------------------------------------------
# caps, kills, locks
# --------------------------------------------------------------------------
class StaleManifestTest(DrainTestCase):
    """A ticket edited mid-run is a different request, not a batch to finish.

    The batch is planned from the scan snapshot. Support can rewrite the ticket
    while validation runs — track A/Producer becomes track B/Mastering — and
    applying the old rows would edit credits nobody asked for, then label the
    NEW request with the OLD outcome.
    """

    def _snapshot_and_client(self, *, new_role="Mastering"):
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))  # what the scan saw
        client.tasks["t1"]["description"] = ticket_with_rows(
            [row(role=new_role)]
        )["description"]
        return client, snapshot

    def test_a_ticket_rewritten_mid_run_is_not_applied(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, sleep=lambda _s: None)

        # nothing was written and nothing was tagged
        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(client.comments, [])

    def test_an_unchanged_ticket_still_applies(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                                 dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])

    def test_a_failed_re_read_is_an_outage_not_a_verdict(self):
        class ReReadFails(FakeClickUp):
            def request(self, method, url_or_path, body=None, timeout=60):
                if method == "GET" and url_or_path == "/task/t1":
                    self.calls.append((method, url_or_path))
                    return 503, {"err": "down"}
                return super().request(method, url_or_path, body, timeout)

        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = ReReadFails([ticket_with_rows([row(role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, sleep=lambda _s: None)

        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), [])

    def test_a_ticket_rewritten_after_the_first_write_is_not_tagged(self):
        # The window is open at both ends. A batch takes real time (a POST plus a
        # read-back per row), so support can rewrite the manifest mid-apply: the
        # rows we just wrote are then the OLD request, and tagging `complete`
        # would let the reconciler close and notify on a request we never ran.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer"),
                                                row(track_id=T2, role="Engineer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        admin.on_post = lambda: client.tasks["t1"].__setitem__(
            "description",
            ticket_with_rows([row(track_id=T1, role="Mastering")])["description"],
        )
        path = self.make_path(dry_run=False)

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, sleep=lambda _s: None)

        # the rows that landed are in the ledger, and the ticket carries no verdict
        self.assertEqual(admin.posts, [(T1, P1, "Producer"), (T2, P1, "Engineer")])
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(client.comments, [])
        rows = [json.loads(line) for line in open(path.ledger_path)]
        self.assertTrue(any(r.get("phase") == "result" and r.get("outcome") == "verified"
                            for r in rows))

    def test_a_post_write_rewrite_parks_the_ticket_for_a_human(self):
        # Untagged is not enough once writes have landed: the next run would apply
        # the NEW manifest and tag `complete` while the old credit is still on the
        # profile. The hold is durable state, so every later run refuses it.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        admin.on_post = lambda: client.tasks["t1"].__setitem__(
            "description",
            ticket_with_rows([row(track_id=T2, role="Mastering")])["description"],
        )
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        recorded = bcc.load_holds(holds)
        self.assertIn("t1", recorded)
        self.assertEqual(recorded["t1"]["run_id"], "r1")
        self.assertEqual([r["role"] for r in recorded["t1"]["rows"]], ["Producer"])

    def test_a_pre_write_rewrite_records_no_hold(self):
        # Nothing was written, so the next run reading the new text is the whole
        # fix. A hold here would park a ticket that needs no human.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        self.assertEqual(bcc.load_holds(holds), {})

    def test_a_held_ticket_is_never_selected_again(self):
        # The reviewer's scenario: run 1 adds Producer, support rewrites to
        # Mastering, run 2 must NOT add Mastering and close the ticket.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        admin.on_post = lambda: client.tasks["t1"].__setitem__(
            "description",
            ticket_with_rows([row(track_id=T2, role="Mastering")])["description"],
        )
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        # run 2: the ticket now carries a valid Mastering manifest, and a naive
        # scan would apply it and tag `complete` over the stray Producer credit.
        admin.on_post = None
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(bcc, "ClickUp", return_value=client), \
                mock.patch.object(bcc, "fetch_open_tickets",
                                  return_value=[client.tasks["t1"]]), \
                mock.patch.object(bcc, "clickup_token", return_value="tok"), \
                mock.patch.object(bcc, "load_attempts", return_value={}), \
                mock.patch.object(bcc, "save_attempts"), \
                mock.patch.object(bcc, "WritePath", return_value=path), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = bcc._run(
                bcc.parse_args(["--apply", "--state-dir", str(self.tmp)]),
                admin, path, run_id="r2", dry_run=False,
                attempts_path=str(self.tmp / "attempts.json"), holds_path=holds,
            )

        self.assertEqual(code, bcc.RUN_EXIT_OK)
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])  # nothing new
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertIn("held for manual reconciliation: 1", out.getvalue())

    def test_a_batch_that_dies_after_a_write_still_parks_a_rewritten_ticket(self):
        # The failure path is where a hold is most likely to be needed and least
        # likely to be reached: apply_batch raises, so the normal post-write check
        # never runs, and the next run would apply the NEW manifest and tag
        # `complete` over the credit the OLD request just added.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([
            ticket_with_rows([row(track_id=T1, role="Producer"),
                              row(track_id=T2, role="Producer")]),
        ])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))

        def rewrite_then_die():
            client.tasks["t1"]["description"] = ticket_with_rows(
                [row(track_id=T2, role="Mastering")]
            )["description"]
            raise wp.Unavailable("admin went away mid-batch")

        admin.on_post = rewrite_then_die
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        recorded = bcc.load_holds(holds)
        self.assertIn("t1", recorded)
        self.assertEqual([r["role"] for r in recorded["t1"]["rows"]], ["Producer"])

    def test_a_later_row_dying_parks_a_ticket_rewritten_after_the_first_write(self):
        # The reviewer's exact shape: row 1 posts, row 2 raises, and the ticket
        # was rewritten in between. The normal post-write check never runs, so
        # without the failure-path hold the next run would apply the new manifest
        # and tag `complete` over row 1's credit.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([
            ticket_with_rows([row(track_id=T1, role="Producer"),
                              row(track_id=T2, role="Producer")]),
        ])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        calls = {"n": 0}

        def rewrite_on_second_post():
            calls["n"] += 1
            if calls["n"] == 2:
                client.tasks["t1"]["description"] = ticket_with_rows(
                    [row(track_id=T2, role="Mastering")]
                )["description"]
                raise wp.Unavailable("admin went away mid-batch")

        admin.on_post = rewrite_on_second_post
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        recorded = bcc.load_holds(holds)
        self.assertIn("t1", recorded)
        self.assertEqual([r["role"] for r in recorded["t1"]["rows"]], ["Producer"])

    def test_an_unreadable_post_write_check_parks_the_ticket(self):
        # We cannot tell "unchanged, ClickUp blipped" from "rewritten while we
        # wrote", and the two have opposite safe answers. Park it: a human
        # clearing an unnecessary hold costs minutes, closing over an unintended
        # credit costs the customer's profile.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))

        def blip_after_the_write():
            client.fail_next_get = wp.Unavailable("ClickUp GET timed out")

        admin.on_post = blip_after_the_write
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        recorded = bcc.load_holds(holds)
        self.assertIn("t1", recorded)
        self.assertEqual([r["role"] for r in recorded["t1"]["rows"]], ["Producer"])
        self.assertEqual(outcome_tags_of(client, "t1"), [])

    def test_an_unreadable_post_write_check_before_any_write_records_no_hold(self):
        # Nothing was written, so there is nothing to reconcile: the next run
        # reads the ticket fresh and does the right thing.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        client.fail_next_get = wp.Unavailable("ClickUp GET timed out")
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        self.assertEqual(bcc.load_holds(holds), {})
        self.assertEqual(admin.posts, [])

    def test_a_rewrite_between_the_pre_tag_check_and_the_tag_is_not_tagged(self):
        # The tag's own read is the last one before the tag, and it is the only
        # place that sees the ticket as it is at tag time. Checking outcome tags
        # alone would tag `complete` for the OLD request on a ticket that now
        # asks for something else.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        gets = {"n": 0}

        def rewrite_on_the_tag_read():
            gets["n"] += 1
            # 1 = pre-write check, 2 = pre-tag check, 3 = the tag's own read
            if gets["n"] == 3:
                client.tasks["t1"]["description"] = ticket_with_rows(
                    [row(track_id=T2, role="Mastering")]
                )["description"]

        client.on_get = rewrite_on_the_tag_read
        path = self.make_path(dry_run=False)
        holds = str(self.tmp / "holds.json")

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, holds_path=holds, sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertIn("t1", bcc.load_holds(holds))

    def test_a_corrupt_hold_file_stops_the_run(self):
        # Reading unreadable holds as "no holds" would release every parked
        # ticket at once, which is the exact failure the hold exists to prevent.
        holds = str(self.tmp / "holds.json")
        with open(holds, "w", encoding="utf-8") as fh:
            fh.write("{not json")

        with self.assertRaises(wp.DrainBlocked):
            bcc.load_holds(holds)

        with open(holds, "w", encoding="utf-8") as fh:
            fh.write("[]")
        with self.assertRaises(wp.DrainBlocked):
            bcc.load_holds(holds)

    def test_a_corrupt_hold_file_blocks_the_scan(self):
        holds = str(self.tmp / "holds.json")
        with open(holds, "w", encoding="utf-8") as fh:
            fh.write("{not json")
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with mock.patch.object(bcc, "ClickUp", return_value=client), \
                mock.patch.object(bcc, "clickup_token", return_value="tok"), \
                mock.patch.object(bcc, "load_attempts", return_value={}), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(wp.DrainBlocked):
                bcc._run(
                    bcc.parse_args(["--apply", "--state-dir", str(self.tmp)]),
                    admin, path, run_id="r1", dry_run=False,
                    attempts_path=str(self.tmp / "attempts.json"), holds_path=holds,
                )

        self.assertEqual(admin.posts, [])

    def test_a_failed_release_audit_leaves_the_hold_in_place(self):
        # Record BEFORE releasing: the other order has a window where the ticket
        # is eligible again and no durable record of who released it exists.
        holds = str(self.tmp / "holds.json")
        bcc.record_hold(holds, "t1", run_id="r1", reason="rewritten", rows=[])

        with mock.patch.object(bcc.WritePath, "record",
                               side_effect=OSError("disk full")), \
                mock.patch.object(bcc, "ClickUp"), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(OSError):
                bcc.main(["--clear-hold", "t1", "--operator", "nick@muso.ai",
                          "--state-dir", str(self.tmp)])

        self.assertIn("t1", bcc.load_holds(holds))

    def test_clearing_a_hold_requires_a_named_operator(self):
        holds = str(self.tmp / "holds.json")
        bcc.record_hold(holds, "t1", run_id="r1", reason="rewritten", rows=[])

        with mock.patch.object(bcc, "ClickUp"), \
                contextlib.redirect_stderr(io.StringIO()):
            code = bcc.main(["--clear-hold", "t1", "--state-dir", str(self.tmp)])
        self.assertEqual(code, bcc.RUN_EXIT_USAGE)
        self.assertIn("t1", bcc.load_holds(holds))

    def test_an_unlisted_but_well_formed_address_cannot_release_a_hold(self):
        # Releasing a hold hands the ticket back to the next armed run, which
        # applies the replacement manifest — the same act as overriding a
        # human's outcome tag, so it needs the same reviewed allowlist.
        # `invented@example.com` is a perfectly well-formed address.
        holds = str(self.tmp / "holds.json")
        bcc.record_hold(holds, "t1", run_id="r1", reason="rewritten", rows=[])

        with mock.patch.object(bcc, "ClickUp"), \
                contextlib.redirect_stderr(io.StringIO()):
            code = bcc.main(["--clear-hold", "t1",
                             "--operator", "invented@example.com",
                             "--state-dir", str(self.tmp)])

        self.assertEqual(code, bcc.RUN_EXIT_USAGE)
        self.assertIn("t1", bcc.load_holds(holds))

    def test_clearing_a_hold_is_audited_and_releases_the_ticket(self):
        holds = str(self.tmp / "holds.json")
        bcc.record_hold(holds, "t1", run_id="r1", reason="rewritten", rows=[])
        ledger = str(self.tmp / "ledger.jsonl")

        with mock.patch.object(bcc, "ClickUp"), \
                contextlib.redirect_stdout(io.StringIO()):
            code = bcc.main(["--clear-hold", "t1", "--operator", "nick@muso.ai",
                             "--state-dir", str(self.tmp)])

        self.assertEqual(code, bcc.RUN_EXIT_OK)
        self.assertEqual(bcc.load_holds(holds), {})
        with open(ledger, encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh]
        self.assertEqual(rows[-1]["phase"], "hold-cleared")
        self.assertEqual(rows[-1]["operator"], "nick@muso.ai")

    def test_a_removal_rewritten_into_an_add_is_not_tagged_blocked(self):
        # The refusal is about the request we READ. If support turns a removal
        # request into a valid add request after the scan, tagging `blocked`
        # answers a request nobody made and the next scan skips the real one.
        client = FakeClickUp([ticket_with_rows([row(role="Producer", remove=True)])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        client.tasks["t1"]["description"] = ticket_with_rows(
            [row(role="Producer")]
        )["description"]
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        path = self.make_path(dry_run=False)

        with self.assertRaises(bcc.TicketChanged):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(client.comments, [])
        self.assertEqual(admin.posts, [])

    def test_a_changed_ticket_is_reported_and_left_untagged(self):
        client, snapshot = self._snapshot_and_client()
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        path = self.make_path(dry_run=False)
        out, err = io.StringIO(), io.StringIO()

        with mock.patch.object(bcc, "ClickUp", return_value=client), \
                mock.patch.object(bcc, "fetch_open_tickets", return_value=[snapshot]), \
                mock.patch.object(bcc, "clickup_token", return_value="tok"), \
                mock.patch.object(bcc, "load_attempts", return_value={}), \
                mock.patch.object(bcc, "save_attempts"), \
                mock.patch.object(bcc, "WritePath", return_value=path), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = bcc._run(
                bcc.parse_args(["--apply", "--state-dir", str(self.tmp)]),
                admin, path, run_id="r1", dry_run=False,
                attempts_path=str(self.tmp / "attempts.json"),
            )

        self.assertEqual(code, bcc.RUN_EXIT_PARTIAL)
        self.assertIn("changed=1", out.getvalue())
        self.assertIn("changed", err.getvalue())
        self.assertEqual(admin.posts, [])
        self.assertEqual(outcome_tags_of(client, "t1"), [])


class ConcurrentHumanOutcomeTest(DrainTestCase):
    """A human labelling the ticket mid-run outranks this drainer.

    The outcome guard is evaluated on the scan snapshot. If a person sets
    `customer-outcome:verification-required` while the batch is being applied,
    the fresh read inside `replace_customer_outcome` sees it — and deleting it
    would let the reconciler announce a case a human deliberately held.
    """

    def _snapshot_and_client(self):
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        snapshot = json.loads(json.dumps(client.tasks["t1"]))  # what the scan saw
        client.tasks["t1"]["tags"].append(
            {"name": "customer-outcome:verification-required"}
        )
        return client, snapshot

    def test_a_human_outcome_set_mid_run_is_never_overwritten(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)

        with self.assertRaises(bcc.OutcomeConflict):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"),
                         ["customer-outcome:verification-required"])
        # the credit itself did land, and the ledger still says so
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])
        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        self.assertEqual(entries[-1]["outcome"], "verified")

    def test_the_operator_override_may_replace_a_tag_it_was_told_about(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                                 dry_run=False, allow_replace=True,
                                 operator="nick@muso.ai", sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])

        # the override is audited: who, which ticket, and what it replaced
        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        override = [e for e in entries if e.get("phase") == "override"]
        self.assertEqual(len(override), 1)
        self.assertEqual(override[0]["operator"], "nick@muso.ai")
        self.assertEqual(override[0]["ticket_id"], "t1")
        self.assertEqual(override[0]["previous_outcomes"],
                         ["customer-outcome:verification-required"])
        self.assertEqual(override[0]["outcome"], "customer-outcome:complete")
        self.assertEqual(override[0]["run_id"], "r1")

    def test_a_tag_already_on_the_ticket_at_selection_is_audited_too(self):
        # The ordinary `--allow-tagged` case: the human's hold was there when the
        # run selected the ticket, so it is not `foreign` — but it is still a
        # decision this run is about to delete, and it must be attributable.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        client.tasks["t1"]["tags"].append(
            {"name": "customer-outcome:verification-required"}
        )
        snapshot = json.loads(json.dumps(client.tasks["t1"]))  # tagged at selection
        path = self.make_path(dry_run=False)

        outcome = bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                                 dry_run=False, allow_replace=True,
                                 operator="nick@muso.ai", sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])
        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        override = [e for e in entries if e.get("phase") == "override"]
        self.assertEqual(len(override), 1)
        self.assertEqual(override[0]["operator"], "nick@muso.ai")
        self.assertEqual(override[0]["previous_outcomes"],
                         ["customer-outcome:verification-required"])
        self.assertEqual(override[0]["outcome"], "customer-outcome:complete")

    def test_the_audit_row_is_written_before_the_tag_is_touched(self):
        # If the tag mutation fails, the record of who authorized it must still
        # exist — an audit written after the fact is an audit that can be lost.
        class TagDeleteFails(FakeClickUp):
            def request(self, method, url_or_path, body=None, timeout=60):
                if method == "DELETE" and "/tag/" in url_or_path:
                    self.calls.append((method, url_or_path))
                    return 500, {"err": "boom"}
                return super().request(method, url_or_path, body, timeout)

        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = TagDeleteFails([ticket_with_rows([row(role="Producer")])])
        client.tasks["t1"]["tags"].append(
            {"name": "customer-outcome:verification-required"}
        )
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        path = self.make_path(dry_run=False)

        with self.assertRaises(RuntimeError):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, allow_replace=True,
                           operator="nick@muso.ai", sleep=lambda _s: None)

        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        override = [e for e in entries if e.get("phase") == "override"]
        self.assertEqual(len(override), 1)
        self.assertEqual(override[0]["operator"], "nick@muso.ai")
        self.assertEqual(override[0]["previous_outcomes"],
                         ["customer-outcome:verification-required"])

    def test_an_override_with_no_ledger_is_refused(self):
        # The audit is not optional: no ledger, no override.
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        client.tasks["t1"]["tags"].append(
            {"name": "customer-outcome:verification-required"}
        )
        with self.assertRaises(RuntimeError) as caught:
            bcc.replace_customer_outcome(
                client, "t1", bcc.OUTCOME_COMPLETE,
                expected_existing=frozenset({"customer-outcome:verification-required"}),
                allow_replace=True, operator="nick@muso.ai",
            )
        self.assertIn("without a ledger", str(caught.exception))
        self.assertEqual(outcome_tags_of(client, "t1"),
                         ["customer-outcome:verification-required"])

    def test_a_failed_add_leaves_the_human_tag_in_place(self):
        # The add happens BEFORE the remove, so a rejected POST cannot erase a
        # live decision: the ticket is exactly as the human left it.
        class TagAddFails(FakeClickUp):
            def request(self, method, url_or_path, body=None, timeout=60):
                if method == "POST" and "/tag/" in url_or_path:
                    self.calls.append((method, url_or_path))
                    return 500, {"err": "boom"}
                return super().request(method, url_or_path, body, timeout)

        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = TagAddFails([ticket_with_rows([row(role="Producer")])])
        client.tasks["t1"]["tags"].append(
            {"name": "customer-outcome:verification-required"}
        )
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        path = self.make_path(dry_run=False)

        with self.assertRaises(RuntimeError):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, allow_replace=True,
                           operator="nick@muso.ai", sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"),
                         ["customer-outcome:verification-required"])
        self.assertEqual(bcc.customer_outcome_of(client.tasks["t1"]),
                         "verification-required")

    def test_a_failed_remove_leaves_two_tags_and_no_verdict(self):
        # If the remove fails after the add landed, the ticket is ambiguous —
        # `customer_outcome_of` returns None, which every consumer fails closed
        # on. Ambiguous is recoverable; a missing tag is a lost decision.
        class TagDeleteFails(FakeClickUp):
            def request(self, method, url_or_path, body=None, timeout=60):
                if method == "DELETE" and "/tag/" in url_or_path:
                    self.calls.append((method, url_or_path))
                    return 500, {"err": "boom"}
                return super().request(method, url_or_path, body, timeout)

        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = TagDeleteFails([ticket_with_rows([row(role="Producer")])])
        client.tasks["t1"]["tags"].append(
            {"name": "customer-outcome:verification-required"}
        )
        snapshot = json.loads(json.dumps(client.tasks["t1"]))
        path = self.make_path(dry_run=False)

        with self.assertRaises(RuntimeError):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, allow_replace=True,
                           operator="nick@muso.ai", sleep=lambda _s: None)

        self.assertEqual(outcome_tags_of(client, "t1"),
                         ["customer-outcome:complete",
                          "customer-outcome:verification-required"])
        self.assertIsNone(bcc.customer_outcome_of(client.tasks["t1"]))

    def test_a_refused_override_writes_no_audit_row(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)

        with self.assertRaises(bcc.OutcomeConflict):
            bcc.run_ticket(admin, client, path, ticket=snapshot, run_id="r1",
                           dry_run=False, sleep=lambda _s: None)

        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        self.assertEqual([e for e in entries if e.get("phase") == "override"], [])

    def test_a_bogus_operator_is_refused_before_anything_runs(self):
        for bogus in ("", "x", "nick", "nick@", "@muso.ai", "nick@muso",
                      "nick @muso.ai", "nick@muso.ai "):
            with self.subTest(operator=bogus):
                self.assertFalse(bcc.valid_operator(bogus))
                self.assertEqual(
                    bcc.main(["--apply", "--ticket", "t1", "--allow-tagged",
                              "--operator", bogus]),
                    bcc.RUN_EXIT_USAGE,
                )
        self.assertTrue(bcc.valid_operator("nick@muso.ai"))

    def test_an_email_shaped_stranger_cannot_authorize_an_override(self):
        # The flag is a claim, not a credential: `invented@example.com` is a
        # perfectly well-formed address and still must not authorize replacing a
        # human's hold. Only the reviewed allowlist may.
        allowlist = frozenset({"nick@muso.ai"})
        self.assertIsNone(bcc.override_operator_error("nick@muso.ai", allowlist))
        self.assertIsNone(bcc.override_operator_error("NICK@Muso.AI", allowlist))
        problem = bcc.override_operator_error("invented@example.com", allowlist)
        self.assertIsNotNone(problem)
        self.assertIn("allowlist", problem)

    def test_a_missing_or_empty_allowlist_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "nope.txt")
            self.assertEqual(bcc.load_override_operators(missing), frozenset())
            empty = os.path.join(tmp, "empty.txt")
            with open(empty, "w", encoding="utf-8") as fh:
                fh.write("# only a comment\n\n")
            self.assertEqual(bcc.load_override_operators(empty), frozenset())
            self.assertIsNotNone(
                bcc.override_operator_error("nick@muso.ai",
                                            bcc.load_override_operators(empty))
            )

    def test_the_shipped_allowlist_names_real_people(self):
        # The file the drainer reads in production must exist and be non-empty,
        # or every override is refused (fail-closed, but silently unusable).
        shipped = bcc.load_override_operators(
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "policies", "credit-override-operators.txt")
        )
        self.assertTrue(shipped)
        self.assertIn("aaron@muso.ai", shipped)
        self.assertIn("nick@muso.ai", shipped)

    def test_an_unlisted_operator_is_refused_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            allow = os.path.join(tmp, "ops.txt")
            with open(allow, "w", encoding="utf-8") as fh:
                fh.write("nick@muso.ai\n")
            with mock.patch.object(bcc, "override_operators_path",
                                   return_value=allow):
                self.assertEqual(
                    bcc.main(["--apply", "--ticket", "t1", "--allow-tagged",
                              "--operator", "invented@example.com"]),
                    bcc.RUN_EXIT_USAGE,
                )

    def test_the_environment_cannot_redirect_the_allowlist(self):
        # An env var would make the reviewed list replaceable at runtime: point
        # it at a file containing invented@example.com and both --allow-tagged
        # and --clear-hold accept an address nobody reviewed.
        with tempfile.TemporaryDirectory() as tmp:
            allow = os.path.join(tmp, "ops.txt")
            with open(allow, "w", encoding="utf-8") as fh:
                fh.write("invented@example.com\n")
            with mock.patch.dict(os.environ,
                                 {"BULK_CREDIT_OVERRIDE_OPERATORS": allow}):
                self.assertNotEqual(bcc.override_operators_path(), allow)
                self.assertNotIn("invented@example.com",
                                 bcc.load_override_operators())
                self.assertEqual(
                    bcc.main(["--apply", "--ticket", "t1", "--allow-tagged",
                              "--operator", "invented@example.com"]),
                    bcc.RUN_EXIT_USAGE,
                )

    def test_a_conflict_is_reported_and_the_ticket_is_left_untagged(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)
        args = bcc.parse_args(["--apply", "--ticket", "t1"])

        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(bcc, "ClickUp", return_value=client), \
                mock.patch.object(bcc, "fetch_open_tickets", return_value=[snapshot]), \
                mock.patch.object(bcc, "clickup_token", return_value="tok"), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = bcc._run(args, admin, path, run_id="r1", dry_run=False,
                            attempts_path=self.attempts)

        self.assertEqual(code, bcc.RUN_EXIT_PARTIAL)
        self.assertIn("conflict", out.getvalue())
        self.assertIn("left alone", err.getvalue())
        self.assertEqual(outcome_tags_of(client, "t1"),
                         ["customer-outcome:verification-required"])

    def test_allow_tagged_without_a_named_ticket_does_not_disable_the_guard(self):
        # `--allow-tagged` only means anything with an explicit `--ticket`; a scan
        # never picks a tagged ticket, so it must not become a blanket override.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client, snapshot = self._snapshot_and_client()
        path = self.make_path(dry_run=False)
        args = bcc.parse_args(["--apply", "--allow-tagged", "--operator", "a@b.com"])

        with mock.patch.object(bcc, "ClickUp", return_value=client), \
                mock.patch.object(bcc, "fetch_open_tickets", return_value=[snapshot]), \
                mock.patch.object(bcc, "clickup_token", return_value="tok"), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            code = bcc._run(args, admin, path, run_id="r1", dry_run=False,
                            attempts_path=self.attempts)

        self.assertEqual(code, bcc.RUN_EXIT_PARTIAL)
        self.assertEqual(outcome_tags_of(client, "t1"),
                         ["customer-outcome:verification-required"])


class SafetyTest(DrainTestCase):
    def test_kill_file_blocks_before_any_work(self):
        kill = self.tmp / "stop.disabled"
        kill.write_text("")
        path = self.make_path(dry_run=False, kill_files=(str(kill),))
        self.assertIn("kill file present", path.kill_reason())
        with self.assertRaises(wp.DrainBlocked):
            path.assert_not_killed()

    def test_a_kill_file_landing_mid_batch_stops_the_next_row(self):
        # A kill file is an emergency stop, and ops creates it while a run is
        # already holding the lock. Checking only at acquisition would let an
        # armed run POST the rest of its batch after the stop was requested.
        kill = self.tmp / "stop.disabled"
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer"),
                                                row(track_id=T2, role="Engineer")])])
        path = self.make_path(dry_run=False, kill_files=(str(kill),))

        original = path.reserve_write
        calls = {"n": 0}

        def reserve_then_kill():
            calls["n"] += 1
            if calls["n"] == 2:
                kill.write_text("")
            original()

        path.reserve_write = reserve_then_kill

        with self.assertRaises(wp.DrainBlocked):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        # the first row landed, the second never left the process
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])
        self.assertEqual(outcome_tags_of(client, "t1"), [])

    def test_either_drainers_kill_file_stops_this_one(self):
        # The correction executor's kill file is ours too: ops reaches for one file.
        kill = self.tmp / "clickup-drain-credit-correction.disabled"
        kill.write_text("")
        path = self.make_path(dry_run=False, kill_files=(str(kill),))
        self.assertIsNotNone(path.kill_reason())

    def test_daily_cap_defers_the_ticket_instead_of_tagging_it(self):
        # A spent budget is a deferral, not a verdict: tagging `partial` here would
        # park a batch that was never written and would never be retried, and the
        # rows that did land would be frozen behind that tag.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer"),
                                                row(track_id=T2, role="Engineer")])])
        path = self.make_path(dry_run=False, max_writes_per_day=1)

        with self.assertRaises(wp.DailyCapReached):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        self.assertEqual(admin.posts, [(T1, P1, "Producer")], "cap stops the second row")
        self.assertEqual(path.writes_used_today(), 1)
        self.assertEqual(outcome_tags_of(client, "t1"), [], "no terminal tag on a deferral")
        with open(self.ledger, encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh]
        self.assertEqual(entries[-1]["outcome"], "deferred")
        self.assertEqual(entries[0]["outcome"], "attempted")  # the write we did keep

    def test_a_deferred_ticket_is_resumed_when_the_budget_resets(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(track_id=T1, role="Producer"),
                                                row(track_id=T2, role="Engineer")])])
        tight = self.make_path(dry_run=False, max_writes_per_day=1)
        with self.assertRaises(wp.DailyCapReached):
            bcc.run_ticket(admin, client, tight, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)

        # next UTC day: fresh budget, the landed row is `already`, the other lands
        tomorrow = self.make_path(
            dry_run=False, max_writes_per_day=1,
            clock=lambda: __import__("time").time() + 86400,
        )
        outcome = bcc.run_ticket(admin, client, tomorrow, ticket=client.tasks["t1"],
                                 run_id="r2", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome.bucket, bcc.OUTCOME_COMPLETE)
        self.assertEqual(outcome.rows_written, 1)
        self.assertEqual(admin.posts, [(T1, P1, "Producer"), (T2, P1, "Engineer")])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])

    def test_a_transient_get_during_validation_does_not_block_the_ticket(self):
        # a 408 on the profile read is a blip, not a verdict about the batch
        class TimeoutAdmin(FakeAdmin):
            def get(self, path, params=None):
                if path.startswith("/admin/profile/") and "/credits" not in path:
                    raise wp.Unavailable(f"admin GET {path} returned HTTP 408")
                return super().get(path, params)

        admin = TimeoutAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=False)

        with self.assertRaises(wp.Unavailable):
            bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                           run_id="r1", dry_run=False, sleep=lambda _s: None)
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        self.assertEqual(admin.posts, [])

    def test_cap_counter_is_per_utc_day(self):
        path = self.make_path(dry_run=False, max_writes_per_day=2)
        path.reserve_write()
        path.reserve_write()
        with self.assertRaises(wp.DailyCapReached):
            path.reserve_write()
        # a new day resets it
        tomorrow = self.make_path(dry_run=False, max_writes_per_day=2,
                                 clock=lambda: __import__("time").time() + 86400)
        self.assertEqual(tomorrow.writes_used_today(), 0)
        tomorrow.reserve_write()

    def test_one_lock_blocks_a_second_run(self):
        first = self.make_path(dry_run=False)
        second = self.make_path(dry_run=False)
        first.acquire()
        try:
            with self.assertRaises(wp.DrainBlocked):
                second.acquire()
        finally:
            first.release()
        second.acquire()
        second.release()

    def test_dry_run_says_would_complete_not_partial(self):
        # A shadow run must not report `partial` for a ticket it simply has not
        # tried yet: that would make every shadow run look broken.
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=True)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=True, sleep=lambda _s: None)

        self.assertEqual(outcome.bucket, "would-complete")
        self.assertEqual(outcome.rows_written, 0)
        self.assertIn("would be written", outcome.detail)

    def test_dry_run_spends_no_budget_and_writes_nothing(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket_with_rows([row(role="Producer")])])
        path = self.make_path(dry_run=True)

        outcome = bcc.run_ticket(admin, client, path, ticket=client.tasks["t1"],
                                 run_id="r1", dry_run=True, sleep=lambda _s: None)

        self.assertEqual(admin.posts, [])
        self.assertEqual(path.writes_used_today(), 0)
        self.assertEqual(client.calls, [], "dry run touches no ticket state")
        self.assertEqual(outcome.rows_written, 0)


# --------------------------------------------------------------------------
# revert
# --------------------------------------------------------------------------
class RevertTest(DrainTestCase):
    def _seed_ledger(self):
        with open(self.ledger, "w", encoding="utf-8") as fh:
            for i, (track, role) in enumerate([(T1, "Producer"), (T2, "Engineer")]):
                fh.write(json.dumps({
                    "run_id": "r1", "ticket_id": "t1", "action": "add",
                    "outcome": "verified", "track_id": track, "profile_id": P1,
                    "role": role, "before_roles": ["Mix"], "after_roles": ["Mix", role],
                    "index": i,
                }) + "\n")

    def test_plan_only_lists_landed_adds(self):
        self._seed_ledger()
        with open(self.ledger, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"run_id": "r1", "ticket_id": "t1", "action": "already",
                                 "outcome": "verified", "track_id": T1,
                                 "profile_id": P1, "role": "Mix"}) + "\n")
            fh.write(json.dumps({"run_id": "r1", "ticket_id": "t1", "action": "add",
                                 "outcome": "failed", "track_id": T1,
                                 "profile_id": P1, "role": "Boom"}) + "\n")
        rows = wp.plan_revert(self.ledger)
        self.assertEqual([r["role"] for r in rows], ["Producer", "Engineer"])

    def test_revert_is_plan_only_and_never_removes_a_credit(self):
        # The deployed muso-admin-api.sh refuses credit-removal DELETEs outright
        # (`enforce_removal_gate`), so an --apply path here could only ever be a
        # command that fails at the wrapper. The plan names what a human removes.
        self._seed_ledger()
        admin = FakeAdmin(roles={P1: {T1: ["Mix", "Producer"], T2: ["Mix", "Engineer"]}})
        rc = bcc.run_revert(admin, self.ledger)
        self.assertEqual(rc, bcc.RUN_EXIT_OK)
        self.assertEqual(admin.deletes, [])
        self.assertEqual(admin.posts, [])

    def test_write_path_has_no_removal_capability_at_all(self):
        # not "we do not call it" — the capability does not exist, so no future
        # edit can quietly start removing credits from a drainer
        self.assertFalse(hasattr(wp, "remove_role"))

    def test_plan_names_the_roles_newest_first_with_current_state(self):
        self._seed_ledger()
        admin = FakeAdmin(roles={P1: {T1: ["Mix", "Producer"], T2: ["Mix", "Engineer"]}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bcc.run_revert(admin, self.ledger)
        printed = out.getvalue()
        self.assertIn("WOULD REMOVE 2 role(s), newest first", printed)
        self.assertIn("remove Engineer (currently ['Mix', 'Engineer'])", printed)
        self.assertIn("remove Producer (currently ['Mix', 'Producer'])", printed)
        self.assertLess(printed.index("Engineer"), printed.index("Producer"))
        self.assertIn("PLAN ONLY", printed)
        self.assertIn("muso-ops-tracks", printed)

    def test_plan_skips_roles_already_absent(self):
        self._seed_ledger()
        admin = FakeAdmin(roles={P1: {T1: ["Mix"], T2: ["Mix", "Engineer"]}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bcc.run_revert(admin, self.ledger)
        printed = out.getvalue()
        self.assertIn("already absent", printed)
        self.assertNotIn("remove Producer", printed)

    def test_a_plan_that_cannot_read_state_says_so_and_keeps_going(self):
        self._seed_ledger()
        admin = FakeAdmin(roles={P1: {T1: ["Mix", "Producer"]}}, unavailable_gets=True)
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = bcc.run_revert(admin, self.ledger)
        self.assertEqual(rc, bcc.RUN_EXIT_OK)
        self.assertIn("cannot read current state", out.getvalue())
        self.assertEqual(admin.deletes, [])

# --------------------------------------------------------------------------
# ticket selection
# --------------------------------------------------------------------------
class AttemptsFingerprintTest(DrainTestCase):
    """`attempts` must not outlive the text it was a verdict about.

    A prose-only ticket is skipped so it cannot eat a slot every run. But support
    can add the `details.bulk_rows` manifest to that same ticket later, and a
    permanent skip would leave a now-executable ticket open and untagged forever.
    """

    def _run(self, admin, client, args):
        with mock.patch.object(bcc, "ClickUp", return_value=client), \
                mock.patch.object(bcc, "fetch_open_tickets",
                                  return_value=list(client.tasks.values())), \
                mock.patch.object(bcc, "clickup_token", return_value="tok"), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return bcc._run(args, admin, self.make_path(dry_run=False), run_id="r1",
                            dry_run=False, attempts_path=self.attempts)

    def test_the_skip_is_keyed_on_the_text_not_just_the_id(self):
        prose = ticket("no manifest here", task_id="t1")
        with_manifest = ticket_with_rows([row(role="Producer")], task_id="t1")
        self.assertNotEqual(bcc.ticket_fingerprint(prose),
                            bcc.ticket_fingerprint(with_manifest))

        attempts = {"t1": {"bucket": "unparseable",
                           "fingerprint": bcc.ticket_fingerprint(prose)}}
        self.assertTrue(bcc.already_tried_this_text(attempts, prose))
        self.assertFalse(bcc.already_tried_this_text(attempts, with_manifest))
        # an entry from before fingerprints existed is re-tried once
        self.assertFalse(bcc.already_tried_this_text({"t1": {"bucket": "x"}}, prose))
        self.assertFalse(bcc.already_tried_this_text({}, prose))

    def test_a_ticket_that_gains_a_manifest_is_picked_up_on_the_next_run(self):
        admin = FakeAdmin(roles={P1: {T1: ["Mix"]}})
        client = FakeClickUp([ticket("prose only, no manifest", task_id="t1")])
        args = bcc.parse_args(["--apply"])

        self.assertEqual(self._run(admin, client, args), bcc.RUN_EXIT_OK)
        self.assertEqual(outcome_tags_of(client, "t1"), [])
        with open(self.attempts, encoding="utf-8") as fh:
            self.assertIn("fingerprint", json.load(fh)["t1"])

        # unchanged text: not re-tried, so it cannot eat a slot every run
        self.assertEqual(self._run(admin, client, args), bcc.RUN_EXIT_OK)
        self.assertEqual(admin.posts, [])

        # support adds the manifest to the same ticket: it is executable now
        client.tasks["t1"]["description"] = ticket_with_rows(
            [row(role="Producer")], task_id="t1")["description"]
        self.assertEqual(self._run(admin, client, args), bcc.RUN_EXIT_OK)
        self.assertEqual(admin.posts, [(T1, P1, "Producer")])
        self.assertEqual(outcome_tags_of(client, "t1"), ["customer-outcome:complete"])


class SelectionTest(unittest.TestCase):
    def test_tickets_carrying_an_outcome_are_not_re_picked(self):
        done = ticket("x", task_id="done", tags=["action:bulk-credit-change",
                                                 "customer-outcome:partial"])
        fresh = ticket("y", task_id="fresh", tags=["action:bulk-credit-change"])
        self.assertTrue(bcc.already_attempted(done))
        self.assertFalse(bcc.already_attempted(fresh))

    def test_invalid_outcome_tag_still_blocks_re_picking(self):
        weird = ticket("x", task_id="w", tags=["action:bulk-credit-change",
                                               "customer-outcome:nonsense"])
        self.assertTrue(bcc.already_attempted(weird))

    def test_explicit_ticket_selection_obeys_the_outcome_guard(self):
        # naming a ticket must not be a way around the guard: this is how someone
        # re-runs one by hand, and `verification-required` is a human decision that
        # must not be overwritten with `complete`
        decided = ticket("x", task_id="decided",
                         tags=["action:bulk-credit-change",
                               "customer-outcome:verification-required"])
        fresh = ticket("y", task_id="fresh", tags=["action:bulk-credit-change"])
        tickets = [decided, fresh]

        selected, skipped = bcc.select_tickets(
            tickets, wanted={"decided", "fresh"})
        self.assertEqual([t["id"] for t in selected], ["fresh"])
        self.assertEqual([t["id"] for t in skipped], ["decided"])

        # the audited escape hatch, which main() only allows with --operator
        selected, skipped = bcc.select_tickets(
            tickets, wanted={"decided"}, allow_tagged=True)
        self.assertEqual([t["id"] for t in selected], ["decided"])
        self.assertEqual(skipped, [])

    def test_a_scan_selects_only_tickets_without_an_outcome(self):
        decided = ticket("x", task_id="decided",
                         tags=["action:bulk-credit-change", "customer-outcome:partial"])
        fresh = ticket("y", task_id="fresh", tags=["action:bulk-credit-change"])
        selected, skipped = bcc.select_tickets([decided, fresh])
        self.assertEqual([t["id"] for t in selected], ["fresh"])
        self.assertEqual(skipped, [])

    def test_closed_tickets_are_filtered(self):
        closed = ticket("x", task_id="c", tags=["action:bulk-credit-change"])
        closed["status"] = {"status": "resolved", "type": "closed"}
        self.assertTrue(bcc._is_closed(closed))

    def test_other_action_types_are_not_picked(self):
        other = ticket("x", task_id="o", tags=["action:credit-correction"])
        self.assertFalse(bcc.has_action_tag(other))


if __name__ == "__main__":
    unittest.main()
