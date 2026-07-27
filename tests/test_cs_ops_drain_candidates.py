"""Behavioral tests for scripts/cs-ops-drain-candidates.py.

This lister runs UNATTENDED (isolated cron, disabled at ship) and feeds the
cs-ops-drain SKILL. It is READ-ONLY on Intercom and NEVER calls muso-cli; its
ONLY optional side effect is appending to the ops-drain shadow log. The
safety-relevant invariants under test:
  - de-confliction is by CONVERSATION ID only, never contact email (an owned
    id is dropped; a merely email-matching id still surfaces — the returning-
    customer bug the spec §De-confliction is built to prevent);
  - the sibling-state reader never crashes on missing/corrupt files and never
    treats absence as "everything owned";
  - PII (customer email) never leaks un-masked — not the display email, not an
    email quoted inside the excerpt;
  - the shadow log the ops-drain writes is itself read back as a de-confliction
    source (idempotency), so the id key round-trips;
  - --append-record fails CLOSED on an out-of-scope verb, missing args, or off
    node-8 (it must never silently name/record an out-of-scope write);
  - a systematic Intercom contact-lookup failure fails the run loudly.

Stdlib unittest + stubs only — no network. Runs under BOTH `python3 -m
unittest tests.test_cs_ops_drain_candidates` (the CI py-tests convention) and
`python3 -m pytest tests/test_cs_ops_drain_candidates.py` (pytest discovers
unittest.TestCase). All HTTP is monkeypatched; all sibling/shadow state is
written under a per-test tmp dir.
"""
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
import urllib.error
from unittest import mock

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "cs-ops-drain-candidates.py"
)
_spec = importlib.util.spec_from_file_location("cs_ops_drain_candidates", _SCRIPT)
d = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(d)


def conv(cid="c1", email="alice@example.com", lcr=100, created_at=50, source_body=""):
    return {"id": cid, "email": email, "lcr": lcr, "created_at": created_at,
            "source_body": source_body}


class SelfTest(unittest.TestCase):
    def test_inline_self_test_passes(self):
        self.assertTrue(d._self_test())


class DeConfliction(unittest.TestCase):
    def test_owned_id_excluded_others_surface(self):
        convs = [conv("C1"), conv("C2"), conv("C3")]
        owned = {"close-resolved": {"C1"}, "resolve-notify": {"C3"}}
        cands, excl = d.build_candidates(convs, owned)
        self.assertEqual([c["conversation_id"] for c in cands], ["C2"])
        self.assertEqual(excl, {"close-resolved": 1, "resolve-notify": 1})

    def test_email_match_without_id_match_still_surfaces(self):
        # The load-bearing invariant: de-conflict by id, never email. Even
        # though a sibling log may contain this customer's email, the NEW
        # conversation id is not owned, so it must remain a candidate.
        convs = [conv("NEW", email="returning@customer.com")]
        owned = {"close-resolved": set()}  # id not present
        cands, _ = d.build_candidates(convs, owned)
        self.assertEqual([c["conversation_id"] for c in cands], ["NEW"])

    def test_conversation_owned_by_multiple_sources_counts_each(self):
        convs = [conv("C1")]
        owned = {"close-resolved": {"C1"}, "resolve-notify": {"C1"}, "ops-drain-shadow": set()}
        cands, excl = d.build_candidates(convs, owned)
        self.assertEqual(cands, [])
        self.assertEqual(excl["close-resolved"], 1)
        self.assertEqual(excl["resolve-notify"], 1)
        self.assertEqual(excl["ops-drain-shadow"], 0)


class StateReader(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_json_state_conv_prefix_keys(self):
        p = self.tmp / "state.json"
        p.write_text(json.dumps({"conv:AAA": 1, "conv:BBB": 2, "other": 3}))
        self.assertEqual(d._ids_from_source(str(p), "json"), {"AAA", "BBB"})

    def test_jsonl_accepts_id_conv_id_and_conversation_id(self):
        p = self.tmp / "shadow.jsonl"
        p.write_text(
            json.dumps({"id": "X1"}) + "\n"
            + json.dumps({"conv_id": "X2"}) + "\n"
            + json.dumps({"conversation_id": "X3"}) + "\n"
            + json.dumps({"nope": "Y"}) + "\n"  # valid JSON, no id field -> ignored
        )
        self.assertEqual(d._ids_from_source(str(p), "jsonl"), {"X1", "X2", "X3"})

    def test_jsonl_tolerates_single_torn_trailing_record(self):
        # A write interrupted mid-append leaves a torn FINAL record with NO
        # trailing newline; that one partial record is tolerated and the
        # earlier records still round-trip.
        p = self.tmp / "torn.jsonl"
        p.write_text(
            json.dumps({"id": "X1"}) + "\n"
            + json.dumps({"id": "X2"}) + "\n"
            + '{"id": "X3", "par')          # torn trailing write, no newline
        self.assertEqual(d._ids_from_source(str(p), "jsonl"), {"X1", "X2"})

    def test_jsonl_newline_terminated_corrupt_final_record_fails_loud(self):
        # A newline-terminated final record is a COMPLETE line, not a torn
        # partial write — if it fails to parse the file is corrupt, so its id
        # must not silently drop from the ownership set. Must raise.
        p = self.tmp / "finalcorrupt.jsonl"
        p.write_text(json.dumps({"id": "X1"}) + "\n" + "not json\n")
        with self.assertRaises(d.SiblingStateUnreadable):
            d._ids_from_source(str(p), "jsonl")

    def test_jsonl_malformed_non_final_record_fails_loud(self):
        # A malformed record that is NOT the last one means the file is corrupt
        # as a whole — the ids of the records after it would silently drop from
        # the ownership set and be re-surfaced to ops-drain (duplicate-action
        # risk). Must raise, never skip-and-continue.
        p = self.tmp / "midcorrupt.jsonl"
        p.write_text(
            json.dumps({"id": "X1"}) + "\n"
            + "not json at all\n"          # malformed NON-final record
            + json.dumps({"id": "X2"}) + "\n")
        with self.assertRaises(d.SiblingStateUnreadable):
            d._ids_from_source(str(p), "jsonl")

    def test_jsonl_multiple_malformed_records_fail_loud(self):
        # More than one malformed record cannot be a single torn tail.
        p = self.tmp / "multicorrupt.jsonl"
        p.write_text("bad one\n" + "bad two\n")
        with self.assertRaises(d.SiblingStateUnreadable):
            d._ids_from_source(str(p), "jsonl")

    def test_missing_files_are_empty_not_crash(self):
        self.assertEqual(d._ids_from_source(str(self.tmp / "nope.json"), "json"), set())
        self.assertEqual(d._ids_from_source(str(self.tmp / "nope.jsonl"), "jsonl"), set())

    def test_corrupt_json_file_fails_loud(self):
        # A file that EXISTS but is unparseable is NOT the same as "missing" —
        # collapsing the two would silently reopen every conversation that
        # source actually owns (close-duplicate PointerStateUnreadable
        # precedent). Must raise, never return an empty set.
        corrupt = self.tmp / "corrupt.json"
        corrupt.write_text("{not valid json")
        with self.assertRaises(d.SiblingStateUnreadable):
            d._ids_from_source(str(corrupt), "json")

    def test_corrupt_jsonl_file_unopenable_fails_loud(self):
        # Whole-file unreadability (e.g. the path exists but can't be opened
        # as a file — here a directory shares the name) is distinct from a
        # single torn trailing line, which stays tolerated (see the
        # id/conv_id/conversation_id test above). Using a directory (rather
        # than a chmod'd file) keeps this portable under a root test runner,
        # where permission bits don't block reads.
        unreadable = self.tmp / "unreadable.jsonl"
        unreadable.mkdir()
        with self.assertRaises(d.SiblingStateUnreadable):
            d._ids_from_source(str(unreadable), "jsonl")

    def test_json_wrong_shape_fails_loud(self):
        # A valid JSON value of the wrong shape (array / null / scalar) is a
        # mispointed or schema-corrupt sibling state — it must FAIL CLOSED, not
        # be treated as an empty ownership set (which would re-surface owned
        # conversations to ops-drain).
        for content in ("[]", "null", "42", '"nope"'):
            for kind in ("json", "json-bare-keys"):
                p = self.tmp / f"wrong-{kind}-{content[:2]}.json"
                p.write_text(content)
                with self.assertRaises(d.SiblingStateUnreadable):
                    d._ids_from_source(str(p), kind)

    def test_json_empty_object_is_legit_empty(self):
        # An empty JSON object is a legitimate "owns nothing" state, distinct
        # from the wrong-shape corruption above — must NOT raise.
        p = self.tmp / "empty.json"
        p.write_text("{}")
        self.assertEqual(d._ids_from_source(str(p), "json"), set())
        self.assertEqual(d._ids_from_source(str(p), "json-bare-keys"), set())

    def test_json_bare_keys_all_top_level_keys_are_conv_ids(self):
        # close-duplicate's pointer-posted.json shape: {"<conv_id>": "pending"
        # | "posted", ...} — every top-level key is a conv id regardless of
        # its status value (a "pending" pointer still means OPEN mid-workflow,
        # not yet safe to re-surface).
        p = self.tmp / "pointer-posted.json"
        p.write_text(json.dumps({"111": "posted", "222": "pending", "333": True}))
        self.assertEqual(d._ids_from_source(str(p), "json-bare-keys"), {"111", "222", "333"})


class IntercomLinkField(unittest.TestCase):
    def test_no_link_when_workspace_id_unset(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(d.intercom_link("123"))
            cands, _ = d.build_candidates([conv("C")], {"s": set()})
        self.assertNotIn("link", cands[0])

    def test_link_present_when_workspace_id_set(self):
        with mock.patch.dict(os.environ, {"INTERCOM_WORKSPACE_ID": "wsid"}, clear=False):
            self.assertEqual(
                d.intercom_link("123"),
                "https://app.intercom.com/a/inbox/wsid/inbox/conversation/123")
            cands, _ = d.build_candidates([conv("C")], {"s": set()})
        self.assertEqual(cands[0]["link"],
                         "https://app.intercom.com/a/inbox/wsid/inbox/conversation/C")


class Excerpt(unittest.TestCase):
    def test_html_stripped_entities_unescaped_whitespace_collapsed(self):
        ex = d.clean_excerpt("<div>hello&nbsp;&amp;  <b>world</b></div>")
        self.assertNotIn("<", ex)
        self.assertNotIn("&amp;", ex)
        self.assertIn("&", ex)          # &amp; -> &
        self.assertNotIn("  ", ex)      # whitespace collapsed

    def test_embedded_email_masked_before_truncation(self):
        ex = d.clean_excerpt("please verify credit for me@artist.com on my track")
        self.assertNotIn("me@artist.com", ex)
        self.assertIn("[email]", ex)

    def test_truncated_to_max(self):
        self.assertEqual(len(d.clean_excerpt("z" * 1000)), d.EXCERPT_MAX)

    def test_display_email_masked_in_candidate(self):
        cands, _ = d.build_candidates([conv("C", email="joe@example.com")], {"s": set()})
        self.assertEqual(cands[0]["masked_email"], "j***@***")
        self.assertEqual(d.build_candidates([conv("C", email="")], {"s": set()})[0][0]["masked_email"],
                         "no email")

    def test_candidate_carries_real_contact_email_for_verification(self):
        # The SKILL's identity gate needs the REAL contact email (to run
        # `muso users search` + compare profile ownership); a masked-only
        # record would force every candidate to EXCLUDE. Real email is
        # verification-only; display/persistence still use masked_email.
        cands, _ = d.build_candidates([conv("C", email="joe@example.com")], {"s": set()})
        self.assertEqual(cands[0]["contact_email"], "joe@example.com")
        self.assertEqual(cands[0]["masked_email"], "j***@***")
        # an unverifiable (empty) contact email surfaces as "" -> Step 2 EXCLUDE.
        empty = d.build_candidates([conv("C", email="")], {"s": set()})[0][0]
        self.assertEqual(empty["contact_email"], "")

    def test_waiting_since_falls_back_to_created_at(self):
        cands, _ = d.build_candidates([conv("C", lcr=0, created_at=999)], {"s": set()})
        self.assertEqual(cands[0]["waiting_since"], 999)


def _fake_conv(cid, email, lcr=0, created_at=0, body=""):
    return {"id": cid, "source": {"author": {"type": "user", "email": email}, "body": body},
            "statistics": {"last_contact_reply_at": lcr}, "created_at": created_at}


class FetchOpenConvs(unittest.TestCase):
    def test_pagination_builds_candidates(self):
        page1 = {"conversations": [
                    _fake_conv("a", "A@x.com", lcr=111, created_at=100, body="<p>hi</p>"),
                    _fake_conv("b", "B@x.com", created_at=200)],
                 "pages": {"next": {"starting_after": "cursor1"}}}
        page2 = {"conversations": [_fake_conv("c", "C@x.com", created_at=300)],
                 "pages": {}}

        def fake_search(token, body):
            return page2 if body["pagination"].get("starting_after") == "cursor1" else page1

        with mock.patch.object(d, "intercom_search", side_effect=fake_search):
            cands, excl, scanned, scan_cap_hit = d.fetch_open_convs("tok", {"s": set()})
        self.assertEqual([c["conversation_id"] for c in cands], ["a", "b", "c"])
        self.assertEqual(cands[0]["masked_email"], "a***@***")   # user fast-path, lowercased
        self.assertEqual(cands[0]["waiting_since"], 111)
        self.assertIn("hi", cands[0]["excerpt"])
        self.assertEqual(scanned, 3)
        self.assertFalse(scan_cap_hit)

    def test_limit_caps_candidates_not_raw_scan(self):
        # The load-bearing regression this fix targets: with a backlog where
        # the leading window is entirely owned, --limit must keep paginating
        # PAST that window rather than stopping at `limit` conversations
        # scanned and returning zero candidates.
        page1 = {"conversations": [_fake_conv("owned1", "o@x.com"),
                                    _fake_conv("owned2", "o2@x.com")],
                 "pages": {"next": {"starting_after": "cursor1"}}}
        page2 = {"conversations": [_fake_conv("cand1", "c@x.com"),
                                    _fake_conv("cand2", "c2@x.com")],
                 "pages": {}}

        def fake_search(token, body):
            return page2 if body["pagination"].get("starting_after") == "cursor1" else page1

        owned = {"close-resolved": {"owned1", "owned2"}}
        with mock.patch.object(d, "intercom_search", side_effect=fake_search):
            cands, excl, scanned, scan_cap_hit = d.fetch_open_convs("tok", owned, limit=1)
        self.assertEqual([c["conversation_id"] for c in cands], ["cand1"])
        self.assertEqual(excl["close-resolved"], 2)
        self.assertEqual(scanned, 3)     # owned1, owned2, cand1 — stopped once 1 candidate found
        self.assertFalse(scan_cap_hit)

    def test_scan_cap_stops_runaway_pagination(self):
        # A backlog with NO candidates at all (everything owned) must not
        # page forever chasing a --limit that will never be reached; the
        # scan-safety cap bounds it and reports scan_cap_hit.
        page1 = {"conversations": [_fake_conv("owned1", "o@x.com")],
                 "pages": {"next": {"starting_after": "cursor1"}}}
        page2 = {"conversations": [_fake_conv("owned2", "o2@x.com")],
                 "pages": {"next": {"starting_after": "cursor2"}}}

        def fake_search(token, body):
            after = body["pagination"].get("starting_after")
            if after == "cursor1":
                return page2
            return page1

        owned = {"close-resolved": {"owned1", "owned2"}}
        with mock.patch.object(d, "intercom_search", side_effect=fake_search):
            cands, excl, scanned, scan_cap_hit = d.fetch_open_convs(
                "tok", owned, limit=5, scan_cap=2)
        self.assertEqual(cands, [])
        self.assertEqual(scanned, 2)
        self.assertTrue(scan_cap_hit)


class ContactLookupFailure(unittest.TestCase):
    def test_401_raises_contact_lookup_failed(self):
        err = urllib.error.HTTPError("u", 401, "no", {}, io.BytesIO(b""))
        with mock.patch.object(d.urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(d.ContactLookupFailed):
                d.get_contact("cid", "tok")

    def test_404_is_benign_none(self):
        err = urllib.error.HTTPError("u", 404, "gone", {}, io.BytesIO(b""))
        with mock.patch.object(d.urllib.request, "urlopen", side_effect=err):
            self.assertIsNone(d.get_contact("cid", "tok"))


class SearchRetryBehavior(unittest.TestCase):
    """intercom_search / _retry_json: a non-retryable 4xx (other than 429)
    must fail immediately (no wasted retries) and land in the documented
    exit-3 handler; 429/5xx keep retrying then raise the same way."""

    def test_401_fails_immediately_no_retry(self):
        err = urllib.error.HTTPError("u", 401, "no", {}, io.BytesIO(b""))
        calls = []

        def fake_urlopen(req, timeout=60):
            calls.append(1)
            raise err

        with mock.patch.object(d.urllib.request, "urlopen", side_effect=fake_urlopen), \
                mock.patch.object(d.time, "sleep"):
            with self.assertRaises(d.IntercomAPIFailed):
                d.intercom_search("tok", {"query": {}})
        self.assertEqual(len(calls), 1)      # no retry burned on a 401

    def test_429_retries_then_raises(self):
        err = urllib.error.HTTPError("u", 429, "rate", {}, io.BytesIO(b""))
        calls = []

        def fake_urlopen(req, timeout=60):
            calls.append(1)
            raise err

        with mock.patch.object(d.urllib.request, "urlopen", side_effect=fake_urlopen), \
                mock.patch.object(d.time, "sleep"):
            with self.assertRaises(d.IntercomAPIFailed):
                d.intercom_search("tok", {"query": {}})
        self.assertEqual(len(calls), 4)      # exhausted all 4 attempts

    def test_contact_lookup_failed_is_an_intercom_api_failed(self):
        self.assertTrue(issubclass(d.ContactLookupFailed, d.IntercomAPIFailed))


class ShadowLog(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.shadow = self.tmp / "cs-ops-drain-shadow.jsonl"
        self._env = mock.patch.dict(os.environ, {
            "OPS_DRAIN_SHADOW_LOG": str(self.shadow),
            "OPS_DRAIN_SKIP_HOST_GUARD": "1",
            "OPS_DRAIN_NOW": "1700000000",
        })
        self._env.start()
        self.addCleanup(self._env.stop)

    def test_sweep_records_round_trip_as_deconfliction_source(self):
        cands = [{"conversation_id": "S1", "masked_email": "a***@***"},
                 {"conversation_id": "S2", "masked_email": "b***@***"}]
        d.append_sweep_records(cands, 1700000000)
        # the id round-trips: the ops-drain's own shadow log is a de-confliction
        # source on the next run (idempotency — never act twice).
        self.assertEqual(d._ids_from_source(str(self.shadow), "jsonl"), {"S1", "S2"})
        recs = [json.loads(l) for l in self.shadow.read_text().splitlines()]
        self.assertEqual(recs[0]["swept_at"], 1700000000)
        self.assertEqual(recs[0]["kind"], "swept")

    def test_classified_record_shape(self):
        d.append_classified_record("K1", "credits-verify", "catalog-corroborated pending credit",
                                    1700000000)
        rec = json.loads(self.shadow.read_text().splitlines()[0])
        self.assertEqual(rec, {"conversation_id": "K1", "verb": "credits-verify",
                               "reason": "catalog-corroborated pending credit",
                               "swept_at": 1700000000, "kind": "classified"})

    def test_append_record_cli_rejects_out_of_scope_verb(self):
        with mock.patch.object(d.sys, "argv",
                               ["p", "--append-record", "--conversation-id", "C",
                                "--verb", "refund", "--reason", "x"]):
            self.assertEqual(d.main(), 1)     # out-of-scope verb -> fail closed
        self.assertFalse(self.shadow.exists())

    def test_append_record_cli_requires_all_args(self):
        with mock.patch.object(d.sys, "argv",
                               ["p", "--append-record", "--conversation-id", "C",
                                "--verb", "credits-verify"]):   # missing --reason
            self.assertEqual(d.main(), 1)
        self.assertFalse(self.shadow.exists())

    def test_append_record_cli_rejects_email_in_reason(self):
        # The shadow-log reason feeds the run summary and is a persisted log —
        # a raw customer email there is a PII leak. contact_email is
        # verification-only; the reason references the conversation by id.
        with mock.patch.object(d.sys, "argv",
                               ["p", "--append-record", "--conversation-id", "C",
                                "--verb", "credits-verify",
                                "--reason", "verified owner joe@example.com"]):
            self.assertEqual(d.main(), 1)     # PII in reason -> fail closed
        self.assertFalse(self.shadow.exists())

    def test_sweep_log_never_persists_raw_email(self):
        # Real candidates now carry contact_email, but the shadow log must
        # persist ONLY masked_email (it is read back as a de-confliction
        # source and is a durable on-disk artifact).
        cands, _ = d.build_candidates([conv("S1", email="joe@example.com")], {"s": set()})
        d.append_sweep_records(cands, 1700000000)
        text = self.shadow.read_text()
        self.assertNotIn("joe@example.com", text)
        self.assertIn("j***@***", text)

    def test_append_record_cli_happy_path(self):
        buf = io.StringIO()
        with mock.patch.object(d.sys, "argv",
                               ["p", "--append-record", "--conversation-id", "C9",
                                "--verb", "profiles-consolidate", "--reason", "own dup"]), \
                mock.patch.object(d.sys, "stdout", buf):
            self.assertEqual(d.main(), 0)
        self.assertEqual(d._ids_from_source(str(self.shadow), "jsonl"), {"C9"})
        out = json.loads(buf.getvalue())
        self.assertEqual(out, {"appended": True, "conversation_id": "C9",
                               "verb": "profiles-consolidate", "shadow_log": str(self.shadow)})

    def test_append_record_exclude_cli_happy_path(self):
        # --exclude records an EXCLUDE adjudication (no verb needed) with a
        # recheck_after = swept_at + recheck_days.
        buf = io.StringIO()
        with mock.patch.dict(os.environ, {"CS_OPS_DRAIN_EXCLUDE_RECHECK_DAYS": "14"}), \
                mock.patch.object(d.sys, "argv",
                                  ["p", "--append-record", "--exclude",
                                   "--conversation-id", "E1", "--reason", "refund, out of scope"]), \
                mock.patch.object(d.sys, "stdout", buf):
            self.assertEqual(d.main(), 0)
        out = json.loads(buf.getvalue())
        self.assertEqual(out["kind"], "excluded")
        self.assertEqual(out["recheck_after"], 1700000000 + 14 * 86400)
        rec = json.loads(self.shadow.read_text().splitlines()[0])
        self.assertEqual(rec["kind"], "excluded")
        self.assertEqual(rec["recheck_after"], 1700000000 + 14 * 86400)

    def test_append_record_exclude_cli_rejects_email_in_reason(self):
        with mock.patch.object(d.sys, "argv",
                               ["p", "--append-record", "--exclude",
                                "--conversation-id", "E1",
                                "--reason", "belongs to joe@example.com"]):
            self.assertEqual(d.main(), 1)     # PII guard applies to excludes too
        self.assertFalse(self.shadow.exists())


class ExcludeAdjudication(unittest.TestCase):
    """Recording EXCLUDE adjudications stops a persistently-rejected leading
    conversation from re-occupying a --limit slot every run and starving later
    candidates. An exclude is owned only until its recheck window elapses."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.shadow = self.tmp / "ops-drain-shadow.jsonl"
        self._env = mock.patch.dict(os.environ, {
            "OPS_DRAIN_SHADOW_LOG": str(self.shadow),
            "OPS_DRAIN_SKIP_HOST_GUARD": "1",
        })
        self._env.start()
        self.addCleanup(self._env.stop)

    def _paths(self):
        return {"ops-drain-shadow": (str(self.shadow), "jsonl-ops-drain")}

    def test_excluded_record_shape(self):
        d.append_excluded_record("E1", "refund, out of scope", 1000, recheck_days=14)
        rec = json.loads(self.shadow.read_text().splitlines()[0])
        self.assertEqual(rec, {"conversation_id": "E1", "kind": "excluded",
                               "swept_at": 1000, "recheck_after": 1000 + 14 * 86400,
                               "reason": "refund, out of scope"})

    def test_excluded_owned_within_window_resurfaces_after(self):
        d.append_excluded_record("E1", "not in scope", 1000, recheck_days=14)
        window_end = 1000 + 14 * 86400
        # within the window -> owned (de-conflicted, not re-surfaced)
        self.assertEqual(
            d._ids_from_source(str(self.shadow), "jsonl-ops-drain", now_epoch=1000), {"E1"})
        self.assertEqual(
            d._ids_from_source(str(self.shadow), "jsonl-ops-drain", now_epoch=window_end - 1),
            {"E1"})
        # at/after the window -> NOT owned (re-surfaces for re-adjudication)
        self.assertEqual(
            d._ids_from_source(str(self.shadow), "jsonl-ops-drain", now_epoch=window_end), set())

    def test_survivor_and_swept_records_owned_permanently(self):
        d.append_classified_record("S1", "credits-verify", "pending credit", 1000)
        d.append_sweep_records([{"conversation_id": "W1", "masked_email": "a***@***"}], 1000)
        # far in the future — survivors/swept stay owned regardless of any window
        owned = d._ids_from_source(str(self.shadow), "jsonl-ops-drain", now_epoch=10**12)
        self.assertEqual(owned, {"S1", "W1"})

    def test_malformed_recheck_after_fails_closed(self):
        # A missing/non-numeric recheck_after must keep the row OWNED (fail
        # closed), not re-surface an already-adjudicated conversation every run.
        self.shadow.write_text(json.dumps(
            {"conversation_id": "E1", "kind": "excluded", "swept_at": 1000}) + "\n")
        self.assertEqual(
            d._ids_from_source(str(self.shadow), "jsonl-ops-drain", now_epoch=10**12), {"E1"})

    def test_later_survivor_record_overrides_elapsed_exclude(self):
        # excluded then (after recheck) re-adjudicated as a survivor -> the
        # survivor record keeps it owned even though the exclude window elapsed.
        d.append_excluded_record("X", "transient", 1000, recheck_days=1)
        d.append_classified_record("X", "credits-verify", "now corroborated", 1000 + 5 * 86400)
        self.assertEqual(
            d._ids_from_source(str(self.shadow), "jsonl-ops-drain", now_epoch=10**12), {"X"})

    def test_two_run_excluded_leading_row_frees_slot_for_later_candidate(self):
        # Run 1: E is a leading candidate the SKILL EXCLUDEs and records.
        # Run 2 (within window): E is de-conflicted so a later qualifying
        # conversation L surfaces in its place instead of E starving the slot.
        now = 1_000_000
        d.append_excluded_record("E", "refund, out of scope", now, recheck_days=14)
        owned = d.owned_ids_by_source(self._paths(), now_epoch=now + 86400)
        self.assertEqual(owned["ops-drain-shadow"], {"E"})
        cands, _ = d.build_candidates([conv("E"), conv("L")], owned)
        self.assertEqual([c["conversation_id"] for c in cands], ["L"])  # E skipped
        # after the recheck window, E re-surfaces for re-adjudication.
        owned_after = d.owned_ids_by_source(self._paths(), now_epoch=now + 15 * 86400)
        self.assertEqual(owned_after["ops-drain-shadow"], set())
        cands2, _ = d.build_candidates([conv("E"), conv("L")], owned_after)
        self.assertEqual({c["conversation_id"] for c in cands2}, {"E", "L"})


class HostGuard(unittest.TestCase):
    def test_write_refused_off_node8(self):
        with mock.patch.dict(os.environ, {"OPS_DRAIN_HOSTNAME_OVERRIDE": "some-laptop"},
                             clear=False):
            os.environ.pop("OPS_DRAIN_SKIP_HOST_GUARD", None)
            self.assertFalse(d._host_guard_ok())

    def test_write_allowed_on_node8(self):
        with mock.patch.dict(os.environ, {"OPS_DRAIN_HOSTNAME_OVERRIDE": "ovh-node-8"},
                             clear=False):
            os.environ.pop("OPS_DRAIN_SKIP_HOST_GUARD", None)
            self.assertTrue(d._host_guard_ok())


class MainList(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def _sibling_env(self, **overrides):
        env = {
            "MUSOAI_INTERCOM_TOKEN": "tok",
            "CLOSE_SHADOW_LOG": str(self.tmp / "nope0"),
            "RESOLVE_NOTIFY_STATE": str(self.tmp / "nope1"),
            "RESOLUTION_STATE_PATH": str(self.tmp / "nope2"),
            "RESOLUTION_SHADOW_LOG": str(self.tmp / "nope3"),
            "OVERDUE_NOTIFY_STATE": str(self.tmp / "nope4"),
            "CLOSE_DUP_SHADOW_LOG": str(self.tmp / "nope5"),
            "CLOSE_DUP_POINTER_STATE": str(self.tmp / "nope5b"),
            "DEDUP_SHADOW_LOG": str(self.tmp / "nope6"),
            "OPS_DRAIN_STATE": str(self.tmp / "nope7"),
            "OPS_DRAIN_SHADOW_LOG": str(self.tmp / "nope8"),
            "CLOSE_STALE_SHADOW_LOG": str(self.tmp / "nope9"),
        }
        env.update(overrides)
        return env

    def test_end_to_end_list_with_deconfliction(self):
        close_log = self.tmp / "close.jsonl"
        close_log.write_text(json.dumps({"id": "owned1"}) + "\n")
        page = {"conversations": [
                    _fake_conv("owned1", "o@x.com", lcr=10, created_at=5),
                    _fake_conv("cand1", "c@x.com", lcr=20, created_at=8,
                               body="verify my credit please")],
                "pages": {}}
        env = self._sibling_env(CLOSE_SHADOW_LOG=str(close_log))
        buf = io.StringIO()
        with mock.patch.dict(os.environ, env, clear=False), \
                mock.patch.object(d, "intercom_search", return_value=page), \
                mock.patch.object(d.sys, "argv", ["p"]), \
                mock.patch.object(d.sys, "stdout", buf):
            rc = d.main()
        self.assertEqual(rc, 0)
        out = json.loads(buf.getvalue())
        self.assertEqual(out["scanned"], 2)
        self.assertEqual(out["candidate_count"], 1)
        self.assertEqual([c["conversation_id"] for c in out["candidates"]], ["cand1"])
        self.assertEqual(out["excluded_counts"]["close-resolved"], 1)
        self.assertEqual(out["candidates"][0]["masked_email"], "c***@***")
        self.assertIn("verify my credit", out["candidates"][0]["excerpt"])
        self.assertFalse(out["scan_cap_hit"])

    def test_missing_token_errors(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(d.sys, "argv", ["p"]):
            self.assertEqual(d.main(), 1)

    def test_corrupt_sibling_state_fails_loud_exit_4(self):
        corrupt = self.tmp / "corrupt.json"
        corrupt.write_text("{not valid json")
        env = self._sibling_env(RESOLVE_NOTIFY_STATE=str(corrupt))
        with mock.patch.dict(os.environ, env, clear=False), \
                mock.patch.object(d.sys, "argv", ["p"]):
            self.assertEqual(d.main(), 4)

    def test_systematic_intercom_failure_exits_3(self):
        env = self._sibling_env()
        with mock.patch.dict(os.environ, env, clear=False), \
                mock.patch.object(d, "intercom_search",
                                  side_effect=d.IntercomAPIFailed("boom")), \
                mock.patch.object(d.sys, "argv", ["p"]):
            self.assertEqual(d.main(), 3)


if __name__ == "__main__":
    unittest.main()
