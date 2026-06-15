"""Behavioral tests for skills-all/muso-abuse-block/scripts/abuse-block.py.

This script is CUSTOMER-FACING: tagging a contact's conversations with the
`abuse-block` tag makes the edge gateway silence Caroline for them (and stop
ticketing). The safety that makes that OK to run is locked here:

  - the dry-run gate — NO writes happen without --apply (a stray run must not
    silently block a customer);
  - refuse-on-no-contact — an email with no Intercom contact must NOT no-op
    silently (exit 3), or an operator thinks they blocked someone they didn't;
  - block/unblock asymmetry — block POSTs tags, --remove DELETEs them, and
    --close only ever closes on a block (never on --remove), only for still-open
    convs;
  - the conversation-tag write carries `admin_id` (Intercom rejects it
    otherwise — the one write shape not runtime-exercised in the node-8 smoke
    test, so it is locked here by assertion);
  - per-target write failures are RECORDED (failures[] + exit 3), never
    swallowed into a clean-looking result.

Stdlib unittest + stubs only — no pytest, no network — so it runs under the same
bare `python3 -m unittest` the py-tests CI job already uses.
"""
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

# Hyphenated filename can't be imported by name; load it from its path as `ab`.
_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "skills-all" / "muso-abuse-block" / "scripts" / "abuse-block.py"
)
_spec = importlib.util.spec_from_file_location("abuse_block", _SCRIPT)
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

SEARCHES = ("/contacts/search", "/conversations/search")


class FakeApi:
    """Stub for ab._req: records every call and returns canned responses.

    `fail_on` (method, path) raises like a non-2xx so the per-target
    failure-handling path is exercised.
    """

    def __init__(self, contacts=None, tags=None, convs=None, fail_on=None, tag_create_id="T1"):
        self.calls = []  # (method, path, body)
        self.contacts = [{"id": "C1", "name": "Joe", "email": "joe@x.com"}] if contacts is None else contacts
        self.tags = [{"id": "T1", "name": "abuse-block"}] if tags is None else tags
        self.convs = [{"id": "V1", "state": "open"}] if convs is None else convs
        self.fail_on = fail_on
        self.tag_create_id = tag_create_id  # id returned by POST /tags (None = odd response)

    def __call__(self, method, path, token, body=None, admin_header=False):
        self.calls.append((method, path, body))
        if self.fail_on == (method, path):
            raise RuntimeError(f"{method} {path} -> HTTP 422: simulated")
        if method == "GET" and path == "/tags":
            return 200, {"data": list(self.tags)}
        if method == "POST" and path == "/tags":
            return 200, {"id": self.tag_create_id, "name": (body or {}).get("name")}
        if method == "POST" and path == "/contacts/search":
            return 200, {"data": list(self.contacts)}
        if method == "GET" and path.startswith("/contacts/"):
            return 200, {"id": path.rsplit("/", 1)[-1], "name": "Joe", "email": "joe@x.com"}
        if method == "POST" and path == "/conversations/search":
            return 200, {"conversations": list(self.convs), "pages": {}}
        return 200, {}  # tag/untag/close writes succeed

    def writes(self):
        """POST/DELETE calls that mutate state (search POSTs are reads)."""
        return [(m, p, b) for (m, p, b) in self.calls
                if m in ("POST", "DELETE") and p not in SEARCHES]


class Base(unittest.TestCase):
    def run_main(self, argv, fake=None, with_token=True, extra_env=None):
        fake = fake or FakeApi()
        environ = {}
        if with_token:
            environ["MUSOAI_INTERCOM_TOKEN"] = "tok"
        environ["ABUSE_BLOCK_LOG"] = os.path.join(self._tmp, "audit.jsonl")
        if extra_env:
            environ.update(extra_env)
        out = io.StringIO()
        with mock.patch.object(ab, "_req", fake), \
                mock.patch.object(ab.time, "sleep", lambda *a, **k: None), \
                mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(ab.sys, "argv", ["abuse-block.py", *argv]), \
                redirect_stdout(out), redirect_stderr(io.StringIO()):
            rc = ab.main()
        try:
            summary = json.loads(out.getvalue())
        except ValueError:
            summary = None
        return rc, summary, fake

    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self._tmp = self._td.name
        self.addCleanup(self._td.cleanup)


class TestValidation(Base):
    def test_no_token_exits_1_and_does_nothing(self):
        rc, _, fake = self.run_main(["--requester", "nick@muso.ai", "--email", "j@x.com"],
                                    with_token=False)
        self.assertEqual(rc, 1)
        self.assertEqual(fake.calls, [])

    def test_empty_requester_exits_1(self):
        rc, _, fake = self.run_main(["--requester", "  ", "--email", "j@x.com"])
        self.assertEqual(rc, 1)
        self.assertEqual(fake.calls, [])

    def test_requires_exactly_one_target(self):
        # neither
        rc, _, _ = self.run_main(["--requester", "nick@muso.ai"])
        self.assertEqual(rc, 1)
        # both
        rc, _, _ = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "j@x.com", "--contact-id", "C1"])
        self.assertEqual(rc, 1)


class TestDryRunGate(Base):
    def test_dry_run_makes_no_writes(self):
        rc, summary, fake = self.run_main(["--requester", "nick@muso.ai", "--email", "joe@x.com"])
        self.assertEqual(rc, 0)
        self.assertEqual(summary["mode"], "dry-run")
        self.assertEqual(fake.writes(), [], "dry-run must not POST/DELETE anything")
        # the plan still lists what WOULD be tagged
        self.assertEqual(summary["conversations_tagged"], ["V1"])

    def test_refuse_when_no_contact(self):
        fake = FakeApi(contacts=[])
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "ghost@x.com"], fake=fake)
        self.assertEqual(rc, 3)            # not 0 — never a silent no-op
        self.assertIsNone(summary)         # bails before printing a summary
        self.assertEqual(fake.writes(), [])


class TestApplyBlock(Base):
    def test_block_tags_contact_and_conversation_with_admin_id(self):
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(summary["failures"], [])
        self.assertEqual(summary["contacts_tagged"], ["C1"])
        self.assertEqual(summary["conversations_tagged"], ["V1"])
        writes = dict(((m, p), b) for (m, p, b) in fake.writes())
        # contact tag: id only
        self.assertEqual(writes[("POST", "/contacts/C1/tags")], {"id": "T1"})
        # conversation tag MUST carry admin_id (Intercom rejects it otherwise)
        self.assertEqual(writes[("POST", "/conversations/V1/tags")],
                         {"id": "T1", "admin_id": "5763097"})
        # block must NOT close by default
        self.assertNotIn(("POST", "/conversations/V1/parts"),
                         [(m, p) for (m, p, _) in fake.writes()])

    def test_creates_tag_when_missing(self):
        fake = FakeApi(tags=[])  # GET /tags finds nothing
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"], fake=fake)
        self.assertEqual(rc, 0)
        self.assertIn(("POST", "/tags", {"name": "abuse-block"}), fake.calls)

    def test_close_flag_closes_open_conv(self):
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--close", "--apply"])
        self.assertEqual(summary["conversations_closed"], ["V1"])
        self.assertIn(("POST", "/conversations/V1/parts"),
                      [(m, p) for (m, p, _) in fake.writes()])

    def test_close_skips_already_closed_conv(self):
        fake = FakeApi(convs=[{"id": "V1", "state": "closed"}])
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--close", "--apply"], fake=fake)
        self.assertEqual(summary["conversations_closed"], [])
        self.assertNotIn(("POST", "/conversations/V1/parts"),
                         [(m, p) for (m, p, _) in fake.writes()])

    def test_failure_is_recorded_not_swallowed(self):
        fake = FakeApi(fail_on=("POST", "/conversations/V1/tags"))
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"], fake=fake)
        self.assertEqual(rc, 3)
        self.assertTrue(any(f["target"] == "conv:V1" for f in summary["failures"]))

    def test_apply_aborts_when_tag_unresolved(self):
        # apply-block where the tag is missing AND create returns no id: must
        # FAIL LOUD (exit 3) and tag NOTHING — never report a false "blocked".
        fake = FakeApi(tags=[], tag_create_id=None)
        rc, _, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"], fake=fake)
        self.assertEqual(rc, 3)
        wrote = [(m, p) for (m, p, _) in fake.writes()]
        self.assertNotIn(("POST", "/contacts/C1/tags"), wrote)
        self.assertNotIn(("POST", "/conversations/V1/tags"), wrote)

    def test_api_error_during_resolution_exits_3_not_traceback(self):
        # A transient Intercom failure while resolving the target must become a
        # clean exit 3, not an uncaught RuntimeError/traceback.
        fake = FakeApi(fail_on=("POST", "/contacts/search"))
        rc, _, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"], fake=fake)
        self.assertEqual(rc, 3)
        self.assertEqual(fake.writes(), [])

    def test_contact_id_apply_path_tags_via_get_contact(self):
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--contact-id", "C1", "--apply"])
        self.assertEqual(rc, 0)
        wrote = [(m, p) for (m, p, _) in fake.writes()]
        self.assertIn(("POST", "/contacts/C1/tags"), wrote)
        self.assertIn(("POST", "/conversations/V1/tags"), wrote)

    def test_apply_fails_closed_before_any_mutation_incl_tag_create(self):
        # Audit opens BEFORE ensure_tag (QA #522): an unopenable log must abort
        # (exit 1) before ANY Intercom mutation — including POST /tags when the tag
        # is missing. tags=[] would force a create if the ordering ever regressed.
        fake = FakeApi(tags=[])
        with mock.patch.object(ab, "open_shadow_log", lambda: (None, None)):
            rc, _, fake = self.run_main(
                ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"], fake=fake)
        self.assertEqual(rc, 1)
        self.assertNotIn(("POST", "/tags"), [(m, p) for (m, p, _) in fake.calls])
        self.assertEqual(fake.writes(), [])

    def test_conversation_lookup_failure_is_recorded_not_raised(self):
        # An Intercom error listing a contact's conversations must be recorded as a
        # failure (exit 3) and not throw past the outcome-audit write. (QA #522)
        fake = FakeApi(fail_on=("POST", "/conversations/search"))
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--apply"], fake=fake)
        self.assertEqual(rc, 3)
        self.assertTrue(any(f["target"] == "contact:C1" and "list conversations" in f["error"]
                            for f in summary["failures"]))
        self.assertNotIn(("POST", "/conversations/V1/tags"),
                         [(m, p) for (m, p, _) in fake.writes()])


class TestRemove(Base):
    def test_remove_uses_delete_and_never_posts_tags(self):
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--remove", "--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(summary["action"], "unblock")
        methods = [(m, p) for (m, p, _) in fake.writes()]
        self.assertIn(("DELETE", "/contacts/C1/tags/T1"), methods)
        self.assertIn(("DELETE", "/conversations/V1/tags/T1"), methods)
        self.assertFalse([1 for (m, p) in methods if m == "POST" and p.endswith("/tags")],
                         "unblock must not POST any tag")

    def test_remove_never_closes_even_with_close_flag(self):
        rc, summary, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com",
             "--remove", "--close", "--apply"])
        self.assertEqual(summary["conversations_closed"], [])
        self.assertNotIn(("POST", "/conversations/V1/parts"),
                         [(m, p) for (m, p, _) in fake.writes()])

    def test_remove_noops_when_tag_missing(self):
        # Removing a tag that doesn't exist is a clean no-op (exit 0) — and must
        # NOT create the tag just to detach it, nor issue any DELETE.
        fake = FakeApi(tags=[])
        rc, _, fake = self.run_main(
            ["--requester", "nick@muso.ai", "--email", "joe@x.com", "--remove", "--apply"], fake=fake)
        self.assertEqual(rc, 0)
        self.assertEqual(fake.writes(), [])  # no POST /tags create, no DELETE detach


if __name__ == "__main__":
    unittest.main()
