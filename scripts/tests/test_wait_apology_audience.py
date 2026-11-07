"""The wait-apology audience builder (fable driver's ruling, 2026-11-04 23:20 + 2026-11-05 02:2xZ).

One test per exclusion. The point of each is not that the filter runs but that the USER IS ABSENT from
the list the worker will read — an excluded user still in the list is the whole bug class, and the
"inert" arms are the other half: an unreadable source must produce NO audience rather than an
unfiltered one.
"""
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1]))

from credit_review import wait_apology_audience as W  # noqa: E402

NOW = datetime(2026, 11, 5, 3, 0, tzinfo=timezone.utc)


def mkplan(chunk="wait-apology", **kw):
    """A paid-status segment run dir: cls/dry-run-*.json + segments.json."""
    d = tempfile.mkdtemp()
    os.makedirs(f"{d}/cls", exist_ok=True)
    rows = chunk if isinstance(chunk, list) else []
    segs = [{"user_id": u["user_id"], "msg_hold": "", "lens_held": False, "cs_excluded": False,
             "identity_hold": False, "forbidden": False} for u in rows]
    with open(f"{d}/cls/dry-run-1.json", "w") as f:
        json.dump(rows, f)
    with open(f"{d}/segments.json", "w") as f:
        json.dump(segs, f)
    return d


def ledger(path, rows):
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE verify_messages (campaign TEXT, status TEXT, user_key TEXT, account_id TEXT, "
               "sent_at TEXT, updated_at TEXT)")
    for campaign, status, key, uid, at in rows:
        db.execute("INSERT INTO verify_messages VALUES (?,?,?,?,?,?)", (campaign, status, key, uid, at, at))
    db.commit()
    db.close()
    return path


def bands(path, users, ts="2026-11-05T02:50:00Z"):
    with open(path, "w") as f:
        json.dump({"generated_at": ts, "users": {str(k): {"decision": v} for k, v in users.items()}}, f)
    return path


def api(tags=("legal",), convs=None):
    """A stand-in for the Intercom tag + conversation-search API, on the DOCUMENTED contract.

    QA #1788 r11: the previous mock accepted the undocumented `tag_id` field and answered with a
    `data` array, so it agreed with the bug instead of the API. Conversation search documents
    `tag_ids` as the filter field and answers with a `conversations` array (the `data` array is the
    CONTACT search's shape). This mock now rejects anything else the way the real API does, so a
    regression to the old contract fails here rather than silently going INERT in production.
    https://developers.intercom.com/docs/references/rest-api/api.intercom.io/conversations/searchconversations
    """
    def call(method, path, body=None):
        if path == "/tags":
            return 200, {"data": [{"id": "11", "name": t} for t in tags]}
        if path == "/conversations/search":
            q = (body or {}).get("query") or {}
            if q.get("field") != "tag_ids":
                # the real API answers 400 invalid_field for an unsearchable field
                return 400, {"type": "error.list", "errors": [{"code": "invalid_field"}]}
            tid = str(q.get("value"))
            return 200, {"type": "conversation.list",
                         "conversations": list((convs or {}).get(tid, [])),
                         "pages": {"next": None}}
        return 404, {}
    return call


def query_for(team_users=(), seats=(), pids=None, auths=None):
    seen = []
    def query(sql):
        seen.append(sql)
        if "team_users" in sql:
            return [{"1": u} and (u,) for u in team_users]
        if "roster_seats" in sql:
            return [(s,) for s in seats]
        if "neptune" in sql.lower():
            # the identity read now carries the Auth0 subject too (QA #1788 finding 4: the legal-tag set holds
            # external_id / contact ids, which are the professional id or the Auth0 subject, never the numeric id)
            return [(k, v, (auths or {}).get(k, "")) for k, v in (pids or {}).items()]
        raise AssertionError(sql)
    return query


class WaitApologyAudienceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_a_user_waited_less_than_the_bar_is_absent_from_the_audience(self):
        d = mkplan([{"user_id": 1, "paid": True, "oldest_pending": "2026-11-04", "request_ids": ["r1"]},
                    {"user_id": 2, "paid": True, "oldest_pending": "2026-09-01", "request_ids": ["r2"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(), api=api(), now=NOW)
        self.assertEqual([u["user_id"] for u in aud], [2], "the 1-day-old request is still inside the wait")
        self.assertIn("still inside the wait bar", counts)

    def test_a_user_messaged_in_the_last_7_days_is_absent_by_their_id(self):
        d = mkplan([{"user_id": 7, "paid": True, "oldest_pending": "2026-09-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [("uvn-status", "sent", "x@y.z", "7", "2026-11-02T10:00:00Z")])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(), api=api(), now=NOW)
        self.assertEqual(aud, [], "a note three days ago is contact: the apology must never be the second")
        self.assertIn("messaged in the last 7 days", counts)

    def test_a_contact_write_to_a_different_address_of_the_same_account_still_counts(self):
        # verify_ledger._same_user: the same Muso user id counts as the same user even when the row's
        # user_key is an address this plan row never names (an account that changed its email).
        d = mkplan([{"user_id": 8, "paid": True, "oldest_pending": "2026-09-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [("status-team-review", "sent", "old@y.z", "8", "2026-10-30T10:00:00Z")])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                              query=query_for(), api=api(), now=NOW)
        self.assertEqual(aud, [], "same account, older address: still contact inside the window")
        self.assertIn("messaged in the last 7 days", counts)

    def test_a_user_already_apologised_is_absent_forever(self):
        d = mkplan([{"user_id": 9, "paid": True, "oldest_pending": "2026-06-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [("wait-apology", "sent", "q@y.z", "9", "2026-09-20T10:00:00Z")])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(), api=api(), now=NOW)
        self.assertEqual(aud, [], "one per user ever, even six weeks later")
        self.assertIn("already apologised (one per user, ever)", counts)

    def test_a_user_with_any_approval_hold_is_absent(self):
        d = mkplan([{"user_id": 11, "paid": True, "oldest_pending": "2026-08-01", "request_ids": ["r"]},
                    {"user_id": 12, "paid": True, "oldest_pending": "2026-08-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {11: "hold"})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(), api=api(), now=NOW)
        self.assertEqual([u["user_id"] for u in aud], [12])
        self.assertIn("approval hold (774: any hold is excluded)", counts)

    def test_a_user_in_a_conversation_tagged_legal_is_absent(self):
        d = mkplan([{"user_id": 21, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        convs = {"11": [{"contacts": {"contacts": [{"external_id": "21"}]}}]}
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(), api=api(convs=convs), now=NOW)
        self.assertEqual(aud, [], "a legal-tagged conversation excludes the user (774)")
        self.assertIn("legal tag in Intercom (774)", counts)

    def test_a_legal_tag_on_the_professional_id_excludes_the_numeric_user(self):
        """QA #1788 finding 4: the legal-tag set holds Intercom external_id / contact ids, which are the account's
        professional id or Auth0 subject - NOT its numeric user id. Comparing only the numeric id let a contact tagged
        legal with external_id=pro41 through for user 41."""
        d = mkplan([{"user_id": 41, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        convs = {"11": [{"contacts": {"contacts": [{"external_id": "pro41"}]}}]}
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                              query=query_for(pids={41: "pro41"}), api=api(convs=convs), now=NOW)
        self.assertEqual(aud, [], "the professional id is an identity form the send gate matches on")
        self.assertIn("legal tag in Intercom (774)", counts)

    def test_a_legal_tag_on_the_auth0_subject_excludes_the_numeric_user(self):
        d = mkplan([{"user_id": 42, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        convs = {"11": [{"contacts": {"contacts": [{"external_id": "auth0|abc42"}]}}]}
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                              query=query_for(pids={42: ""}, auths={42: "auth0|abc42"}), api=api(convs=convs), now=NOW)
        self.assertEqual(aud, [], "the Auth0 subject is the other identity form the gate matches on")
        self.assertIn("legal tag in Intercom (774)", counts)

    def test_a_legal_tag_that_matches_no_conversation_excludes_nobody(self):
        d = mkplan([{"user_id": 22, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        aud, _ = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                          query=query_for(), api=api(convs={}), now=NOW)
        self.assertEqual([u["user_id"] for u in aud], [22])

    def test_the_legal_tag_search_sends_the_documented_tag_ids_field(self):
        """QA #1788 r11: conversation search documents `tag_ids` as the filter field. The builder used to send
        `tag_id`, which the API rejects with 400 invalid_field - so with a legal tag configured the audience
        builder went INERT and the family could never send. Pin the field name on the wire."""
        d = mkplan([{"user_id": 23, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        sent = []
        inner = api(convs={})

        def recording(method, path, body=None):
            if path == "/conversations/search":
                sent.append(body)
            return inner(method, path, body)

        W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                query=query_for(), api=recording, now=NOW)
        self.assertTrue(sent, "the legal tag must actually be searched")
        for body in sent:
            self.assertEqual(body["query"]["field"], "tag_ids",
                             "conversation search documents tag_ids; tag_id is rejected with 400 invalid_field")
            self.assertNotIn("tag_id", body["query"], "the undocumented singular field must never be sent")

    def test_a_data_shaped_search_response_is_a_missing_source_not_an_empty_audience(self):
        """QA #1788 r11: a successful conversation search answers with `conversations`; `data` is the CONTACT
        search's shape. Reading `data` turned a 200 into an unreadable response, so the builder refused the whole
        audience. A `data`-shaped body must be a MISSING SOURCE (loud), never silently 'nobody is legal-tagged'."""
        d = mkplan([{"user_id": 24, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})

        def contact_shaped(method, path, body=None):
            if path == "/tags":
                return 200, {"data": [{"id": "11", "name": "legal"}]}
            if path == "/conversations/search":
                return 200, {"data": [{"contacts": {"contacts": [{"external_id": "24"}]}}]}
            return 404, {}

        with self.assertRaises(W.SourceMissing):
            W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                    query=query_for(), api=contact_shaped, now=NOW)

    def test_a_user_in_core_team_users_is_absent(self):
        d = mkplan([{"user_id": 31, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(team_users=[31]), api=api(), now=NOW)
        self.assertEqual(aud, [], "an org seat holder is never cold-emailed (774)")
        self.assertIn("org seat (774: never cold-emailed)", counts)

    def test_a_user_with_an_active_roster_seat_is_absent_by_professional_id(self):
        d = mkplan([{"user_id": 41, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(seats=["pro41"], pids={41: "PRO41"}), api=api(), now=NOW)
        self.assertEqual(aud, [], "the roster seat is keyed on the professional id, lowercased")
        self.assertIn("org seat (774: never cold-emailed)", counts)

    def test_the_builder_never_hands_the_sender_more_than_its_cap(self):
        # d2's batch size (FIRST_CAP 100 paid, then 250 a tick) belongs to the TICK's shared-first machinery,
        # which is the one place that must stay true when a third segment is added. The builder's job is the
        # membership + order; this arm proves it cannot silently exceed the ceiling it was given.
        rows = [{"user_id": 1000 + i, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}
                for i in range(300)]
        d = mkplan(rows)
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        first, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                                query=query_for(), api=api(), now=NOW, cap=100)
        self.assertEqual(len(first), 100, "a 100 ceiling yields 100")
        self.assertIn("over this batch's cap", counts)
        later, _ = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                           query=query_for(), api=api(), now=NOW, cap=250)
        self.assertEqual(len(later), 250, "the dated cap yields 250")

    def test_the_pipelines_holds_are_respected_and_a_user_absent_from_segments_is_never_messaged(self):
        d = mkplan([{"user_id": 51, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]},
                    {"user_id": 52, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        # drop user 51's segment row entirely: absent from the run's own read = held
        with open(f"{d}/segments.json") as f:
            segs = [r for r in json.load(f) if r["user_id"] != 51]
        with open(f"{d}/segments.json", "w") as f:
            json.dump([dict(s, identity_hold=True) if s["user_id"] == 52 else s for s in segs], f)
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                               query=query_for(), api=api(), now=NOW)
        self.assertEqual(aud, [], "not_in_segments and identity_hold both exclude")
        self.assertEqual(counts.get("not_in_segments"), 1)
        self.assertEqual(counts.get("identity_hold"), 1)

    def test_the_audience_keeps_the_pipelines_order_paid_then_oldest(self):
        d = mkplan([{"user_id": 61, "paid": True, "oldest_pending": "2026-08-01", "request_ids": ["a"]},
                    {"user_id": 62, "paid": True, "oldest_pending": "2026-06-01", "request_ids": ["b"]},
                    {"user_id": 63, "paid": False, "oldest_pending": "2026-01-01", "request_ids": ["c"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        aud, counts = W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                              query=query_for(), api=api(), now=NOW)
        # the pipeline's order is authoritative and is NOT re-sorted here; the free user is the other segment
        self.assertEqual([u["user_id"] for u in aud], [61, 62])
        self.assertIn("other segment", counts)

    # -- inert arms: a missing source must produce NO audience, never an unfiltered one ------------

    def test_an_unreadable_approval_scan_builds_nothing(self):
        d = mkplan([{"user_id": 71, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        with self.assertRaises(W.SourceMissing) as cm:
            W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=self.tmp + "/nope.json",
                    query=query_for(), api=api(), now=NOW)
        self.assertIn("approval-hold scan", str(cm.exception))

    def test_a_stale_approval_scan_builds_nothing(self):
        d = mkplan([{"user_id": 72, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {}, ts="2026-11-04T00:00:00Z")
        with self.assertRaises(W.SourceMissing):
            W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                    query=query_for(), api=api(), now=NOW)

    def test_an_unwired_intercom_source_builds_nothing(self):
        d = mkplan([{"user_id": 73, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        with self.assertRaises(W.SourceMissing):
            W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                    query=query_for(), api=None, now=NOW)

    def test_a_failed_intercom_tag_read_builds_nothing(self):
        d = mkplan([{"user_id": 74, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})

        def broken(method, path, body=None):
            return 503, {}

        with self.assertRaises(W.SourceMissing):
            W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                    query=query_for(), api=broken, now=NOW)

    def test_an_unwired_org_seat_source_builds_nothing(self):
        d = mkplan([{"user_id": 75, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        l = ledger(self.tmp + "/l.sqlite3", [])
        b = bands(self.tmp + "/b.json", {})
        with self.assertRaises(W.SourceMissing):
            W.build(plan_dir=d, segment="paid", ledger_path=l, bands_path=b,
                    query=None, api=api(), now=NOW)

    def test_the_cli_default_bands_path_is_the_one_the_fraud_lens_actually_writes(self):
        """QA #1788 finding 3 (carried twice): the default was /var/lib/hydra/credit-review/account_bands.json, a path
        nothing writes, and the tick passes no --bands - so every build would have exited 2 (INERT) forever while the
        family looked wired. The default must be the file comm_state's R8 reads at send time, and it must be the same
        constant, not a copy of the string."""
        from credit_review import comm_state
        self.assertEqual(W.DEFAULT_BANDS, comm_state.ACCOUNT_BANDS)
        self.assertEqual(W.DEFAULT_BANDS, "/opt/firstmate/fraud-lens/out/account_bands.json")
        # and the CLI's own default is that value, not a second literal that can drift
        import argparse
        seen = {}
        real = argparse.ArgumentParser.add_argument

        def spy(self_, *a, **kw):
            if a and a[0] == "--bands":
                seen["default"] = kw.get("default")
            return real(self_, *a, **kw)

        argparse.ArgumentParser.add_argument = spy
        try:
            with self.assertRaises(SystemExit):
                W.main(["--help"])
        finally:
            argparse.ArgumentParser.add_argument = real
        self.assertEqual(seen.get("default"), comm_state.ACCOUNT_BANDS,
                         "the tick passes no --bands: the CLI default IS the production path")

    def test_an_unreadable_ledger_builds_nothing(self):
        d = mkplan([{"user_id": 76, "paid": True, "oldest_pending": "2026-07-01", "request_ids": ["r"]}])
        b = bands(self.tmp + "/b.json", {})
        with self.assertRaises(W.SourceMissing) as cm:
            W.build(plan_dir=d, segment="paid", ledger_path=self.tmp + "/missing.sqlite3", bands_path=b,
                    query=query_for(), api=api(), now=NOW)
        self.assertIn("does not exist", str(cm.exception), "an absent ledger cannot prove who was contacted")


if __name__ == "__main__":
    unittest.main()
