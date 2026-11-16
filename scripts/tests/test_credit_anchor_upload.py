"""credit-anchors-push: the verifier's built dsp-anchor/1 records -> core rows (Fable l12-approvals-core A)."""
import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import anchor_push_run as apr  # noqa: E402
from credit_review import anchor_upload as au  # noqa: E402
from credit_verify.dspverify import store as dsp_store  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
DRIVER = REPO / "scripts" / "credit-anchors-push.py"

RID = "11111111-1111-4111-8111-111111111111"


def block(src, ids=("cap-1",), at="2026-10-29T12:00:00Z", linked=True):
    return {"source": src, "state": "CAPTURED", "capture_ids": list(ids), "captured_at": at,
            "role_holders": [{"name": "X", "credit": "Producer", "is_claimant_linked_id": linked,
                              "raw_id": "sp:1", "catalog_profile_id": "p-1"}]}


def person(**over):
    r = {"schema": "dsp-anchor/1", "kind": "dsp_anchor", "request_id": RID, "roles": ["Producer"],
         "role_evidence": {"Producer": {"both_read": True, "sources": [block("spotify"), block("tidal")]}},
         "metadata": {"ruling_id": "docs-p1"}}
    r.update(over)
    return r


def label(**over):
    r = {"schema": "dsp-anchor/1", "kind": "dsp_label_line", "request_id": RID, "roles": ["Record Label"],
         "capture_request_id": "capreq-9", "label_lines_read_at": "2026-10-29T11:00:00Z",
         "label_lines": [{"string": "℗ 2024 Acme Records", "source": "spotify"}], "metadata": {"ruling_id": "label-a"}}
    r.update(over)
    return r


class FakeStore:
    def __init__(self, rows):
        self.rows = rows
        self.added = []

    def anchors(self):
        return self.rows

    def add_anchor(self, run_id, request_id, outcome, **kw):
        self.added.append((request_id, outcome, kw.get("sink_response")))


class ConvertTest(unittest.TestCase):
    def test_person_record_makes_one_row_per_role_and_dsp(self):
        rows = au.to_core_records(person())
        self.assertEqual([(r["kind"], r["source"]) for r in rows], [("dsp_anchor", "spotify"), ("dsp_anchor", "tidal")])
        self.assertEqual(rows[0]["roleHolders"][0], {"raw_id": "sp:1", "profile_id": "p-1", "linked": True, "name": "X"})
        self.assertEqual(rows[0]["rulingRef"], "docs-p1")

    def test_label_record(self):
        [r] = au.to_core_records(label())
        self.assertEqual((r["kind"], r["source"], r["labelLine"], r["captureIds"]),
                         ("dsp_label_line", "label_line", "℗ 2024 Acme Records", ["capreq-9"]))

    def test_never_guesses(self):
        for bad, msg in (
            (person(schema="x"), "schema"),
            (person(roles=[]), "no roles"),
            (person(role_evidence={"Producer": {"sources": [block("spotify")]}}), "tidal"),
            (person(role_evidence={"Producer": {"sources": [block("spotify", ids=()), block("tidal")]}}), "spotify"),
            (label(label_lines=[]), "matched line"),
            (label(capture_request_id=None), "capture request"),
            (person(kind="name_match"), "not an anchor kind"),
        ):
            with self.assertRaisesRegex(au.ConvertError, msg):
                au.to_core_records(bad)


def answer(recs, outcome="written", **extra):
    """What core answers: one result per submitted record, echoing requestId/role/kind/source."""
    return {"results": [{"requestId": r["requestId"], "role": r["role"], "kind": r["kind"], "source": r["source"],
                         "outcome": outcome, **extra} for r in recs]}


class PushTest(unittest.TestCase):
    def store(self):
        return FakeStore([
            {"id": 1, "request_id": RID, "outcome": "refused", "record_json": None, "kind": None},
            {"id": 2, "request_id": RID, "outcome": "built", "record_json": json.dumps(person()), "kind": "dsp_anchor",
             "ruling_id": "docs-p1"},
        ])

    def test_a_later_refusal_wins_over_an_earlier_build(self):
        st = FakeStore(self.store().rows + [{"id": 3, "request_id": RID, "outcome": "refused", "record_json": None,
                                             "kind": None}])
        rep = au.push(st, [RID], apply=True, poster=lambda recs: self.fail("must not post"))
        self.assertEqual((rep["with_built_record"], rep["missing_built"]), (0, [RID.lower()]))
        self.assertIn("incomplete", rep["stopped"])

    def test_upload_outcomes_do_not_hide_the_build(self):
        st = FakeStore(self.store().rows + [{"id": 3, "request_id": RID, "outcome": "written", "record_json": None,
                                             "kind": "dsp_anchor"}])
        self.assertEqual(len(au.latest_built(st, [RID])), 1)

    def test_apply_fails_on_any_incomplete_upload(self):
        rep = au.push(self.store(), [RID], apply=True, poster=lambda recs: answer(recs[:1]))   # 1 of 2 answered
        self.assertIn("incomplete: 1/2", rep["stopped"])
        rep = au.push(self.store(), [RID, "22222222-2222-4222-8222-222222222222"], apply=True, poster=answer)
        self.assertIn("missing_built=1", rep["stopped"])

    def test_a_duplicate_answer_never_stands_in_for_a_missing_one(self):
        # QA #1497 @9088c3d9: two results for Spotify and none for Tidal is 2 result entries for 2 submitted rows,
        # which a count reads as complete. Completeness is per submitted key, exactly once.
        st = self.store()
        rep = au.push(st, [RID], apply=True, poster=lambda recs: answer([recs[0], recs[0]]))
        self.assertEqual((rep["written"], rep["missing_results"], rep["duplicate_results"]), (0, 1, 1))
        self.assertIn("incomplete: 0/2", rep["stopped"])
        # A duplicate answer is not a refusal: core never answered the missing key, so this is a retried error.
        self.assertEqual(st.added[0][1], "write_error")

    def test_an_answer_for_a_key_never_submitted_fails_closed(self):
        def extra(recs):
            ans = answer(recs)
            ans["results"].append({**ans["results"][0], "source": "apple_music"})
            return ans
        rep = au.push(self.store(), [RID], apply=True, poster=extra)
        self.assertEqual((rep["written"], rep["unexpected_results"]), (2, 1))
        self.assertIn("unexpected_results=1", rep["stopped"])

    def test_role_case_and_spaces_match_core_normalization(self):
        ans = answer(au.to_core_records(person()))
        for r in ans["results"]:
            r["role"] = "  " + r["role"].upper() + " "
        self.assertEqual(len(au.reconcile(au.to_core_records(person()), ans["results"])["ok"]), 2)

    def test_dry_run_posts_nothing(self):
        called = []
        rep = au.push(self.store(), [RID, "22222222-2222-4222-8222-222222222222"], apply=False,
                      poster=lambda recs: called.append(recs))
        self.assertEqual((rep["with_built_record"], rep["core_rows"], called), (1, 2, []))
        self.assertEqual(rep["missing_built"], ["22222222-2222-4222-8222-222222222222"])

    def test_apply_records_core_answers_in_the_verifier_store(self):
        st = self.store()
        rep = au.push(st, [RID], apply=True, poster=lambda recs: answer(recs, claimantMatch=True))
        self.assertEqual((rep["written"], rep.get("stopped")), (2, None))
        self.assertEqual(st.added[0][:2], (RID, "written"))

    def test_a_refused_row_marks_the_request_write_refused(self):
        st = self.store()
        def half(recs):
            ans = answer(recs)
            ans["results"][1].update(outcome="refused", reason="role_not_claimed")
            return ans
        rep = au.push(st, [RID], apply=True, poster=half)
        self.assertEqual((rep["refused"], st.added[0][1]), ({"role_not_claimed": 1}, "write_refused"))

    def test_the_ids_path_never_splits_an_oversized_request(self):
        roles = [f"Role {n}" for n in range(51)]
        record = person(roles=roles, role_evidence={r: {"both_read": True, "sources": [block("spotify"), block("tidal")]}
                                                    for r in roles})
        st = LiveStore().build(record=record)
        rep = au.push(st, [RID], apply=True, poster=never)
        self.assertEqual(rep["convert_errors"][RID], "102 core rows exceed the 100-row cap for one request")
        self.assertIn("102 core rows exceed the 100-row cap", rep["stopped"])
        self.assertEqual(st.outcomes(), ["built"])

    def test_a_failed_post_stops_and_is_recorded(self):
        st = self.store()

        def boom(recs):
            raise RuntimeError("HTTP 403")
        rep = au.push(st, [RID], apply=True, poster=boom)
        self.assertIn("403", rep["stopped"])
        self.assertEqual(st.added[0][1], "write_error")

    def test_poster_runs_as_the_verifier_identity_with_its_own_flag(self):
        import subprocess
        seen = {}

        def fake_run(argv, **kw):
            seen["argv"], seen["env"] = argv, kw["env"]
            return subprocess.CompletedProcess(argv, 0, json.dumps({"http_status": 200, "body": {"data": {"results": []}}}), "")
        orig = au.subprocess.run
        au.subprocess.run = fake_run
        try:
            au.admin_poster(script="/x.sh")([{"a": 1}])
        finally:
            au.subprocess.run = orig
        self.assertEqual(seen["argv"][2:6], ["--requester", "dsp-evidence-verifier@hydra-ops", "call", "POST"])
        self.assertEqual(seen["argv"][6], "/admin/credit-anchors")
        self.assertEqual((seen["env"]["DSP_ANCHOR_WRITER"], seen["env"]["MUSO_ADMIN_IDENTITY"], seen["env"]["FABLE_DECIDER"]),
                         ("1", "credit-decider", "0"))


T_STORE = 1794758400               # 2026-11-15T16:00:00Z
TICK = 15 * 60                     # the cron's cadence, in seconds


def stamp(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rid_n(n):
    return f"{n:08d}-1111-4111-8111-111111111111"


class LiveStore:
    """A store that keeps what the push appends, so a second run reads the first run's outcomes."""

    def __init__(self, rows=()):
        self.rows = [dict(r) for r in rows]
        self.clock = T_STORE            # epoch seconds; a test moves it to let time pass

    def anchors(self):
        return self.rows

    def anchor_outcomes(self):
        return [{"id": r["id"], "request_id": r["request_id"], "outcome": r["outcome"],
                 "has_record": bool(r.get("record_json")), "at": r.get("at"), "reason": r.get("reason")}
                for r in self.rows]

    def add_anchor(self, run_id, request_id, outcome, **kw):
        rec = kw.get("record")
        self.rows.append({"id": len(self.rows) + 1, "run_id": run_id, "request_id": request_id, "outcome": outcome,
                          "at": stamp(self.clock),
                          "kind": kw.get("kind"), "ruling_id": kw.get("ruling_id"), "reason": kw.get("reason"),
                          "record_json": None if rec is None else json.dumps(rec)})

    def build(self, rid=RID, record=None):
        self.add_anchor("dsp-a", rid, "built", kind="dsp_anchor", ruling_id="docs-p1",
                        record=record or person(request_id=rid))
        return self

    def outcomes(self, rid=RID):
        return [r["outcome"] for r in self.rows if r["request_id"] == rid]


def refuse(recs):
    return answer(recs, outcome="refused", reason="role_not_claimed")


def never(recs):
    raise AssertionError("must not post")


class PendingTest(unittest.TestCase):
    def test_a_built_record_that_never_landed_is_pending(self):
        self.assertEqual(au.pending(LiveStore().build())["pending"], [RID])

    def test_a_record_refused_at_build_is_not_pending(self):
        st = LiveStore()
        st.add_anchor("dsp-a", RID, "refused")
        self.assertEqual(au.pending(st)["pending"], [])

    def test_a_later_refused_build_takes_the_record_out(self):
        st = LiveStore().build()
        st.add_anchor("dsp-a", RID, "refused")
        self.assertEqual(au.pending(st)["pending"], [])

    def test_a_landed_record_is_not_pending(self):
        st = LiveStore().build()
        st.add_anchor("push-1", RID, "written")
        self.assertEqual(au.pending(st)["pending"], [])

    def test_a_landed_record_is_counted_as_landed(self):
        st = LiveStore().build()
        st.add_anchor("push-1", RID, "written")
        self.assertEqual(au.pending(st)["landed"], 1)

    def test_a_newer_build_after_a_landed_one_is_pending_again(self):
        st = LiveStore().build()
        st.add_anchor("push-1", RID, "written")
        st.build()
        self.assertEqual(au.pending(st)["pending"], [RID])

    def test_two_core_refusals_leave_the_record_pending(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS - 1):
            st.add_anchor("push-1", RID, "write_refused")
        self.assertEqual(au.pending(st)["pending"], [RID])

    def test_the_third_core_refusal_exhausts_the_record(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            st.add_anchor("push-1", RID, "write_refused")
        self.assertEqual(au.pending(st)["pending"], [])

    def test_an_exhausted_record_is_named_with_its_reason(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            st.add_anchor("push-1", RID, "write_refused")
        self.assertEqual(au.pending(st)["exhausted"], {RID: "refused_by_core_3_times"})

    def test_a_newer_build_starts_the_refusal_count_again(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            st.add_anchor("push-1", RID, "write_refused")
        st.build()
        self.assertEqual(au.pending(st)["pending"], [RID])

    def test_failed_uploads_exhaust_the_record_at_their_own_cap(self):
        st = LiveStore().build()
        for _ in range(au.MAX_ERRORS):
            st.add_anchor("push-1", RID, "write_error")
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})

    def test_one_failed_upload_leaves_the_record_pending(self):
        st = LiveStore().build()
        st.add_anchor("push-1", RID, "write_error")
        self.assertEqual(au.pending(st)["pending"], [RID])

    def test_the_oldest_build_comes_first(self):
        st = LiveStore().build(rid_n(9)).build(rid_n(1))
        self.assertEqual(au.pending(st)["pending"], [rid_n(9), rid_n(1)])

    def test_the_real_store_lists_outcomes_without_record_bodies(self):
        with tempfile.TemporaryDirectory() as d:
            st = dsp_store.Store(str(Path(d) / "dsp.sqlite"))
            st.add_anchor("dsp-a", RID, "built", kind="dsp_anchor", record=person())
            st.add_anchor("push-1", RID, "write_error", kind="dsp_anchor", reason="POST HTTP 503")
            rows = st.anchor_outcomes()
            self.assertEqual([sorted(r) for r in rows], [["at", "has_record", "id", "outcome", "reason", "request_id"]] * 2)
            self.assertEqual([(r["id"], r["request_id"], r["outcome"], r["has_record"]) for r in rows],
                             [(1, RID, "built", True), (2, RID, "write_error", False)])
            self.assertEqual(rows[1]["reason"], "POST HTTP 503")
            self.assertIsNotNone(au._epoch(rows[1]["at"]))


class RunPendingTest(unittest.TestCase):
    def test_nothing_pending_posts_nothing(self):
        rep = apr.run_pending(LiveStore(), apply=True, poster=never)
        self.assertEqual(rep["outcome"], "nothing_pending")
        self.assertIn(rep["outcome"], apr.SUCCESS_OUTCOMES)

    def test_nothing_pending_exits_zero(self):
        self.assertEqual(apr.run_pending(LiveStore(), apply=True, poster=never)["exit_code"], 0)

    def test_nothing_pending_reports_zero_rows_written(self):
        self.assertEqual(apr.run_pending(LiveStore(), apply=True, poster=never)["written"], 0)

    def test_a_pending_record_is_pushed(self):
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=answer)
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("pushed", 0))

    def test_a_pushed_run_names_the_requests_it_wrote(self):
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=answer)
        self.assertEqual(rep["written_requests"], [RID])

    def test_a_pushed_run_counts_its_core_rows(self):
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=answer)
        self.assertEqual((rep["core_rows"], rep["written"]), (2, 2))

    def test_a_pushed_record_is_written_in_the_store(self):
        st = LiveStore().build()
        apr.run_pending(st, apply=True, poster=answer)
        self.assertEqual(st.outcomes(), ["built", "written"])

    def test_the_run_after_a_push_has_nothing_pending(self):
        st = LiveStore().build()
        apr.run_pending(st, apply=True, poster=answer)
        self.assertEqual(apr.run_pending(st, apply=True, poster=never)["outcome"], "nothing_pending")

    def test_a_record_withdrawn_between_selection_and_read_is_not_a_push(self):
        st = LiveStore().build()
        with mock.patch.object(au, "latest_built", return_value={}):
            rep = apr.run_pending(st, apply=True, poster=never)
        self.assertNotEqual(rep["outcome"], "pushed")
        self.assertEqual(rep["outcome"], "nothing_pending")
        self.assertEqual((rep["written"], rep["exit_code"]), (0, 0))

    def test_a_group_withdrawn_before_its_post_is_not_a_push(self):
        st = LiveStore().build()
        built = au.latest_built(st, [RID])
        with mock.patch.object(au, "latest_built", side_effect=[built, {}]):
            rep = apr.run_pending(st, apply=True, poster=never)
        self.assertNotEqual(rep["outcome"], "pushed")
        self.assertEqual(rep["outcome"], "nothing_pending")
        self.assertEqual((rep["written"], rep["exit_code"]), (0, 0))
        self.assertEqual(rep["withdrawn"], 1)
        self.assertEqual(rep["withdrawn_requests"], [RID])

    def test_one_withdrawn_record_beside_one_that_landed_is_still_a_push(self):
        st = LiveStore().build(rid_n(1)).build(rid_n(2))
        built = au.latest_built(st, [rid_n(1), rid_n(2)])
        with mock.patch.object(au, "latest_built", side_effect=[built, {rid_n(1): built[rid_n(1)]}]):
            rep = apr.run_pending(st, apply=True, poster=answer)
        self.assertEqual(rep["outcome"], "pushed")
        self.assertGreater(rep["written"], 0)
        self.assertEqual(rep["withdrawn"], 1)
        self.assertEqual(rep["withdrawn_requests"], [rid_n(2)])

    def test_a_withdrawn_record_beside_a_failed_upload_is_still_failed(self):
        st = LiveStore().build(rid_n(1)).build(rid_n(2))
        built = au.latest_built(st, [rid_n(1), rid_n(2)])
        with mock.patch.object(au, "latest_built", side_effect=[built, {rid_n(1): built[rid_n(1)]}]):
            rep = apr.run_pending(st, apply=True, poster=boom)
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("failed", 1))
        self.assertEqual(rep["withdrawn"], 1)

    def test_a_core_refusal_is_recorded_and_the_run_exits_zero(self):
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=refuse)
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("refused_by_core", 0))
        self.assertNotIn(rep["outcome"], apr.SUCCESS_OUTCOMES)

    def test_rows_landed_beside_a_core_refusal_are_a_successful_run(self):
        def mixed(recs):
            first = [r for r in recs if r["requestId"] == rid_n(1)]
            rest = [r for r in recs if r["requestId"] != rid_n(1)]
            return {"results": answer(first)["results"]
                    + answer(rest, outcome="refused", reason="role_not_claimed")["results"]}
        st = LiveStore().build(rid_n(1)).build(rid_n(2))
        rep = apr.run_pending(st, apply=True, poster=mixed)
        self.assertEqual(rep["outcome"], "pushed_with_refusals")
        self.assertEqual(rep["exit_code"], 0)
        self.assertEqual(rep["written_requests"], [rid_n(1)])
        self.assertIn(rep["outcome"], apr.SUCCESS_OUTCOMES)

    def test_rows_landed_beside_an_error_are_not_a_successful_run(self):
        def partial(recs):
            first = [r for r in recs if r["requestId"] == rid_n(1)]
            rest = [r for r in recs if r["requestId"] != rid_n(1)]
            return {"results": answer(first)["results"] + answer(rest[:1])["results"]}
        st = LiveStore().build(rid_n(1)).build(rid_n(2))
        rep = apr.run_pending(st, apply=True, poster=partial)
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("failed", 1))
        self.assertNotIn(rep["outcome"], apr.SUCCESS_OUTCOMES)

    def test_a_core_refusal_carries_cores_reason(self):
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=refuse)
        self.assertEqual(rep["refused"], {"role_not_claimed": 2})

    def test_a_refused_record_is_not_posted_a_fourth_time(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            apr.run_pending(st, apply=True, poster=refuse)
        rep = apr.run_pending(st, apply=True, poster=never)
        self.assertEqual((rep["outcome"], rep["exhausted"], rep["exhausted_requests"]), ("deferred_exhausted", 1, [RID]))

    def test_three_partial_answers_leave_the_record_pending_not_refused(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            au.push(st, [RID], apply=True, poster=lambda recs: answer(recs[:1]))
        self.assertEqual(st.outcomes(), ["built", "write_error", "write_error", "write_error"])
        self.assertEqual(au.pending(st)["pending"], [RID])
        self.assertEqual(au.pending(st)["exhausted"], {})

    def test_a_refused_row_beside_a_missing_one_is_an_error_not_a_refusal(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            au.push(st, [RID], apply=True,
                    poster=lambda recs: answer(recs[:1], outcome="refused", reason="role_not_claimed"))
        self.assertEqual(st.outcomes(), ["built", "write_error", "write_error", "write_error"])
        self.assertEqual(au.pending(st)["pending"], [RID])
        self.assertEqual(au.pending(st)["exhausted"], {})

    def test_a_matching_key_with_no_outcome_is_an_error_not_a_refusal(self):
        def malformed(recs):
            ans = answer(recs)
            for r in ans["results"]:
                r.pop("outcome")
            return ans
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            au.push(st, [RID], apply=True, poster=malformed)
        self.assertEqual(st.outcomes(), ["built", "write_error", "write_error", "write_error"])
        self.assertEqual(au.pending(st)["pending"], [RID])
        self.assertEqual(au.pending(st)["exhausted"], {})

    def test_a_matching_key_with_an_unknown_outcome_is_an_error_not_a_refusal(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            au.push(st, [RID], apply=True, poster=lambda recs: answer(recs, outcome="queued"))
        self.assertEqual(st.outcomes(), ["built", "write_error", "write_error", "write_error"])
        self.assertEqual(au.pending(st)["pending"], [RID])
        self.assertEqual(au.pending(st)["exhausted"], {})

    def test_a_written_row_beside_a_refused_one_is_a_refusal(self):
        def half(recs):
            ans = answer(recs)
            ans["results"][1].update(outcome="refused", reason="role_not_claimed")
            return ans
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            au.push(st, [RID], apply=True, poster=half)
        self.assertEqual(st.outcomes(), ["built", "write_refused", "write_refused", "write_refused"])
        self.assertEqual(au.pending(st)["pending"], [])
        self.assertEqual(au.pending(st)["exhausted"], {RID: "refused_by_core_3_times"})

    def test_three_real_core_refusals_exhaust_the_record(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            au.push(st, [RID], apply=True, poster=refuse)
        self.assertEqual(au.pending(st)["pending"], [])
        self.assertEqual(au.pending(st)["exhausted"], {RID: "refused_by_core_3_times"})

    def test_a_failed_upload_fails_the_run(self):
        def boom(recs):
            raise RuntimeError("POST HTTP 503")
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=boom)
        self.assertEqual((rep["outcome"], rep["exit_code"], rep["errors"]), ("failed", 1, 2))

    def test_a_failed_upload_stops_before_the_next_batch(self):
        calls = []

        def boom(recs):
            calls.append(len(recs))
            raise RuntimeError("POST HTTP 503")
        st = LiveStore()
        for n in range(60):
            st.build(rid_n(n))
        apr.run_pending(st, apply=True, poster=boom)
        self.assertEqual(calls, [100])

    def test_reaching_the_error_cap_pages_and_fails_the_run(self):
        def boom(recs):
            raise RuntimeError("POST HTTP 503")
        pages = []
        st = LiveStore().build()
        for _ in range(au.MAX_ERRORS):
            rep = apr.run_pending(st, apply=True, poster=boom, page=lambda msg: pages.append(msg) or True)
        self.assertEqual(len(pages), 1)
        self.assertEqual(rep["exit_code"], 1)
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})

    def test_page_critical_reports_the_real_delivery_result(self):
        orig = apr.subprocess.run
        try:
            apr.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a[0], 0, "", "")
            self.assertTrue(apr.page_critical("x"))
            apr.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a[0], 1, "", "")
            self.assertFalse(apr.page_critical("x"))
        finally:
            apr.subprocess.run = orig

    def test_an_undelivered_page_is_recorded_false_and_the_run_still_fails(self):
        def boom(recs):
            raise RuntimeError("POST HTTP 503")
        orig = apr.subprocess.run
        apr.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a[0], 1, "", "")
        try:
            st = LiveStore().build()
            for _ in range(au.MAX_ERRORS):
                rep = apr.run_pending(st, apply=True, poster=boom, page=apr.page_critical)
        finally:
            apr.subprocess.run = orig
        self.assertFalse(rep["paged"])
        self.assertEqual(rep["exit_code"], 1)

    def test_nothing_pending_does_not_page(self):
        pages = []
        rep = apr.run_pending(LiveStore(), apply=True, poster=never, page=lambda msg: pages.append(msg) or True)
        self.assertEqual((rep["outcome"], rep["exit_code"], pages), ("nothing_pending", 0, []))

    def test_a_failed_upload_is_retried_by_the_next_run(self):
        def boom(recs):
            raise RuntimeError("POST HTTP 503")
        st = LiveStore().build()
        apr.run_pending(st, apply=True, poster=boom)
        self.assertEqual(apr.run_pending(st, apply=True, poster=answer)["outcome"], "pushed")

    def test_an_answer_that_misses_a_row_fails_the_run(self):
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=lambda recs: answer(recs[:1]))
        self.assertEqual((rep["outcome"], rep["exit_code"], rep["missing_results"]), ("failed", 1, 1))

    def test_a_matching_answer_with_no_outcome_fails_the_run(self):
        def malformed(recs):
            ans = answer(recs)
            for r in ans["results"]:
                r.pop("outcome")
            return ans
        rep = apr.run_pending(LiveStore().build(), apply=True, poster=malformed)
        self.assertEqual((rep["outcome"], rep["exit_code"], rep["written"]), ("failed", 1, 0))
        self.assertNotIn(rep["outcome"], apr.SUCCESS_OUTCOMES)

    def test_a_matching_answer_with_an_unknown_outcome_fails_the_run(self):
        rep = apr.run_pending(LiveStore().build(), apply=True,
                              poster=lambda recs: answer(recs, outcome="queued"))
        self.assertEqual((rep["outcome"], rep["exit_code"], rep["written"]), ("failed", 1, 0))
        self.assertNotIn(rep["outcome"], apr.SUCCESS_OUTCOMES)

    def test_a_record_that_cannot_be_converted_fails_the_run(self):
        st = LiveStore().build(record=person(roles=[]))
        rep = apr.run_pending(st, apply=True, poster=never)
        self.assertEqual((rep["outcome"], rep["exit_code"], rep["convert_errors"]), ("failed", 1, 1))

    def test_a_request_over_the_row_cap_is_never_split_across_posts(self):
        roles = [f"Role {n}" for n in range(51)]
        record = person(roles=roles, role_evidence={r: {"both_read": True, "sources": [block("spotify"), block("tidal")]}
                                                    for r in roles})
        st = LiveStore().build(record=record)
        rep = apr.run_pending(st, apply=True, poster=never)
        self.assertEqual((rep["convert_errors"], rep["exit_code"]), (1, 1))
        self.assertEqual(st.outcomes(), ["built", "write_error"])
        self.assertIn("102 core rows exceed the 100-row cap", st.rows[-1]["reason"])

    def test_a_record_that_cannot_be_converted_is_counted_against_the_error_cap(self):
        st = LiveStore().build(record=person(roles=[]))
        apr.run_pending(st, apply=True, poster=never)
        self.assertEqual((st.outcomes(), st.rows[-1]["reason"][:8]), (["built", "write_error"], "convert:"))

    def test_a_bad_record_does_not_stop_the_good_one_beside_it(self):
        st = LiveStore().build(rid_n(1), record=person(request_id=rid_n(1), roles=[])).build(rid_n(2))
        rep = apr.run_pending(st, apply=True, poster=answer)
        self.assertEqual(rep["written_requests"], [rid_n(2)])

    def test_the_run_cap_defers_the_newer_builds(self):
        st = LiveStore().build(rid_n(1)).build(rid_n(2)).build(rid_n(3))
        rep = apr.run_pending(st, apply=True, max_requests=2, poster=answer)
        self.assertEqual((rep["attempted"], rep["deferred"], rep["written_requests"]), (2, 1, [rid_n(1), rid_n(2)]))

    def test_one_post_never_carries_more_than_100_rows(self):
        sizes = []

        def post(recs):
            sizes.append(len(recs))
            return answer(recs)
        st = LiveStore()
        for n in range(51):
            st.build(rid_n(n))
        apr.run_pending(st, apply=True, poster=post)
        self.assertEqual(sizes, [100, 2])

    def test_one_post_never_carries_half_of_a_request(self):
        split = []

        def post(recs):
            per = {}
            for r in recs:
                per[r["requestId"]] = per.get(r["requestId"], 0) + 1
            split.extend(rid for rid, n in per.items() if n != 6)
            return answer(recs)
        three = {role: {"sources": [block("spotify"), block("tidal")]} for role in ("Producer", "Mixer", "Writer")}
        st = LiveStore()
        for n in range(20):                                # 6 rows each: 100 rows is not a whole number of requests
            st.build(rid_n(n), record=person(request_id=rid_n(n), roles=list(three), role_evidence=three))
        apr.run_pending(st, apply=True, poster=post)
        self.assertEqual(split, [])

    def test_a_request_is_landed_only_with_all_of_its_rows(self):
        three = {role: {"sources": [block("spotify"), block("tidal")]} for role in ("Producer", "Mixer", "Writer")}
        st = LiveStore()
        for n in range(20):
            st.build(rid_n(n), record=person(request_id=rid_n(n), roles=list(three), role_evidence=three))
        rep = apr.run_pending(st, apply=True, poster=answer)
        self.assertEqual((rep["written"], len(rep["written_requests"])), (120, 20))

    def test_a_dry_run_posts_nothing(self):
        rep = apr.run_pending(LiveStore().build(), apply=False, poster=never)
        self.assertEqual((rep["outcome"], rep["core_rows"], rep["written"]), ("dry_run", 2, 0))

    def test_a_dry_run_writes_nothing_to_the_store(self):
        st = LiveStore().build()
        apr.run_pending(st, apply=False, poster=never)
        self.assertEqual(st.outcomes(), ["built"])


def boom(recs):
    raise RuntimeError("POST HTTP 503")


def exhaust(st, pages=None):
    """MAX_ERRORS failing runs, one tick apart: the record's upload budget is spent. Returns the last run's report."""
    for _ in range(au.MAX_ERRORS):
        st.clock += TICK
        rep = apr.run_pending(st, apply=True, poster=boom, now_s=lambda: st.clock,
                              page=lambda msg: (pages if pages is not None else []).append(msg) or True)
    return rep


class CooldownTest(unittest.TestCase):
    """Exhaustion on failed uploads is a cooldown, not a tombstone (firstmate 2026-11-15)."""

    def run_once(self, st, *, poster=answer, probe=lambda: True, pages=None):
        return apr.run_pending(st, apply=True, poster=poster, probe=probe, now_s=lambda: st.clock,
                               page=lambda msg: (pages if pages is not None else []).append(msg) or True)

    def test_the_run_that_exhausts_a_record_says_it_is_still_owed(self):
        self.assertEqual(exhaust(LiveStore().build())["retry_owed"], 1)

    def test_a_run_with_nothing_built_owes_no_retry(self):
        rep = apr.run_pending(LiveStore(), apply=True, poster=never)
        self.assertEqual((rep["outcome"], rep["retry_owed"]), ("nothing_pending", 0))

    def test_a_refused_record_is_not_awaiting_a_retry(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            apr.run_pending(st, apply=True, poster=refuse)
        self.assertEqual(au.awaiting_retry(au.pending(st)), [])

    def test_an_unpostable_record_is_not_awaiting_a_retry(self):
        st = LiveStore().build(record=person(roles=[]))
        exhaust(st)
        self.assertEqual(au.awaiting_retry(au.pending(st)), [])

    def test_an_upload_exhausted_record_is_awaiting_a_retry(self):
        st = LiveStore().build()
        exhaust(st)
        self.assertEqual(au.awaiting_retry(au.pending(st)), [RID])

    def test_a_record_with_an_unreadable_exhaustion_time_is_still_owed(self):
        st = LiveStore().build()
        exhaust(st)
        owed = au.pending(st)
        owed["exhausted_at"][RID] = "not a time"
        self.assertEqual((au.awaiting_retry(owed), au.cooled(owed, st.clock + au.RETRY_COOLDOWN_S)), ([RID], []))

    def test_exhaustion_carries_the_time_it_happened_and_pages(self):
        pages = []
        st = LiveStore().build()
        rep = exhaust(st, pages)
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})
        self.assertEqual(au.pending(st)["exhausted_at"], {RID: stamp(T_STORE + au.MAX_ERRORS * TICK)})
        self.assertEqual(rep["exhausted_at"], {RID: stamp(T_STORE + au.MAX_ERRORS * TICK)})
        self.assertEqual(rep["exhausted_requests"], [RID])
        self.assertEqual(len(pages), 1)
        self.assertTrue(rep["paged"])

    def test_a_reachable_core_gets_a_cooled_record_back_in_the_same_run(self):
        st = LiveStore().build()
        exhaust(st)
        st.clock += au.RETRY_COOLDOWN_S
        rep = self.run_once(st)
        self.assertEqual(rep["core_probe"], "ok")
        self.assertEqual(rep["retry_granted_requests"], [RID])
        self.assertEqual(rep["written_requests"], [RID])
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("pushed", 0))
        self.assertEqual(au.pending(st)["landed"], 1)
        self.assertEqual(au.pending(st)["exhausted"], {})

    def test_a_three_hour_outage_then_a_healthy_core_lands_the_anchor(self):
        """QA on #2046: 12 failed ticks, then a healthy poster, and the anchor lands on the schedule's own ticks."""
        st = LiveStore().build()
        exhaust(st)
        outcomes = []
        for _ in range(au.RETRY_COOLDOWN_S // TICK):
            st.clock += TICK
            outcomes.append(self.run_once(st)["outcome"])
        self.assertEqual(outcomes[:-1], ["deferred_exhausted"] * (au.RETRY_COOLDOWN_S // TICK - 1))
        self.assertEqual(outcomes[-1], "pushed")
        self.assertEqual(st.outcomes()[-2:], ["retry_granted", "written"])
        self.assertEqual(au.pending(st)["landed"], 1)
        self.assertEqual(au.pending(st)["pending"], [])
        self.assertEqual(au.pending(st)["exhausted"], {})

    def test_the_retry_does_not_wait_for_an_upload_to_have_worked(self):
        st = LiveStore().build()
        exhaust(st)
        st.clock += au.RETRY_COOLDOWN_S
        self.assertNotIn("written", st.outcomes())
        self.run_once(st, poster=boom)
        self.assertEqual(st.outcomes()[-2:], ["retry_granted", "write_error"])
        self.assertEqual(au.pending(st)["pending"], [RID])

    def test_inside_the_cooldown_nothing_is_asked_and_nothing_is_reset(self):
        probes = []
        st = LiveStore().build()
        exhaust(st)
        st.clock += au.RETRY_COOLDOWN_S - 1
        rep = self.run_once(st, poster=never, probe=lambda: probes.append(1) or True)
        self.assertEqual(probes, [])
        self.assertIsNone(rep["core_probe"])
        self.assertEqual(rep["retry_granted"], 0)
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("deferred_exhausted", 0))
        self.assertNotIn(rep["outcome"], apr.SUCCESS_OUTCOMES)
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})

    def test_an_unreachable_core_leaves_it_exhausted_and_pages_nobody_again(self):
        pages = []
        st = LiveStore().build()
        exhaust(st, pages)
        st.clock += au.RETRY_COOLDOWN_S
        rep = self.run_once(st, poster=never, probe=lambda: False, pages=pages)
        self.assertEqual(rep["core_probe"], "failed")
        self.assertEqual(rep["retry_eligible"], 1)
        self.assertEqual(rep["retry_granted"], 0)
        self.assertNotIn("paged", rep)
        self.assertEqual(len(pages), 1)
        self.assertEqual(st.outcomes().count("retry_granted"), 0)
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})

    def test_a_probe_that_raises_is_an_unreachable_core(self):
        def broken():
            raise OSError("no wrapper")
        st = LiveStore().build()
        exhaust(st)
        st.clock += au.RETRY_COOLDOWN_S
        rep = self.run_once(st, poster=never, probe=broken)
        self.assertEqual(rep["core_probe"], "failed")
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})

    def test_an_unreachable_core_is_asked_again_by_the_next_run(self):
        st = LiveStore().build()
        exhaust(st)
        st.clock += au.RETRY_COOLDOWN_S
        self.run_once(st, poster=never, probe=lambda: False)
        st.clock += TICK
        rep = self.run_once(st)
        self.assertEqual(rep["written_requests"], [RID])

    def test_a_granted_retry_is_a_whole_new_error_budget(self):
        pages = []
        st = LiveStore().build()
        exhaust(st, pages)
        st.clock += au.RETRY_COOLDOWN_S
        self.run_once(st, poster=boom, pages=pages)
        for _ in range(au.MAX_ERRORS - 2):
            st.clock += TICK
            self.run_once(st, poster=boom, pages=pages)
        self.assertEqual(au.pending(st)["pending"], [RID])
        self.assertEqual(len(pages), 1)
        st.clock += TICK
        rep = self.run_once(st, poster=boom, pages=pages)
        self.assertEqual(au.pending(st)["exhausted"], {RID: "upload_failed_12_times"})
        self.assertEqual(len(pages), 2)
        self.assertEqual(rep["exhausted_at"], {RID: stamp(st.clock)})

    def test_a_record_core_refused_is_never_handed_back(self):
        probes = []
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            st.clock += TICK
            self.run_once(st, poster=refuse)
        st.clock += 10 * au.RETRY_COOLDOWN_S
        rep = self.run_once(st, poster=never, probe=lambda: probes.append(1) or True)
        self.assertEqual(probes, [])
        self.assertEqual(rep["retry_eligible"], 0)
        self.assertEqual(au.pending(st)["exhausted"], {RID: "refused_by_core_3_times"})

    def test_a_granted_retry_never_clears_a_refusal(self):
        st = LiveStore().build()
        st.add_anchor("push-1", RID, "write_refused")
        st.add_anchor("push-2", RID, "write_refused")
        st.add_anchor("retry-1", RID, au.RETRY_GRANTED)
        st.add_anchor("push-3", RID, "write_refused")
        self.assertEqual(au.pending(st)["exhausted"], {RID: "refused_by_core_3_times"})

    def test_a_record_that_cannot_be_converted_is_never_handed_back(self):
        probes = []
        st = LiveStore().build(record=person(roles=[]))
        for _ in range(au.MAX_ERRORS):
            st.clock += TICK
            self.run_once(st, poster=never)
        st.clock += 10 * au.RETRY_COOLDOWN_S
        rep = self.run_once(st, poster=never, probe=lambda: probes.append(1) or True)
        self.assertEqual(au.pending(st)["unpostable"], [RID])
        self.assertEqual(probes, [])
        self.assertEqual(rep["retry_eligible"], 0)
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("deferred_exhausted", 0))

    def test_an_exhaustion_time_that_cannot_be_read_is_never_cooled(self):
        owed = {"exhausted": {RID: "upload_failed_12_times"}, "exhausted_at": {RID: "yesterday"}, "unpostable": []}
        self.assertEqual(au.cooled(owed, T_STORE + 10 * au.RETRY_COOLDOWN_S), [])

    def test_a_dry_run_asks_core_nothing_and_grants_nothing(self):
        probes = []
        st = LiveStore().build()
        exhaust(st)
        st.clock += au.RETRY_COOLDOWN_S
        rep = apr.run_pending(st, apply=False, poster=never, probe=lambda: probes.append(1) or True,
                              now_s=lambda: st.clock)
        self.assertEqual(probes, [])
        self.assertEqual(rep["retry_eligible"], 1)
        self.assertEqual(st.outcomes().count("retry_granted"), 0)

    def test_a_run_with_nothing_exhausted_asks_core_nothing(self):
        probes = []
        rep = apr.run_pending(LiveStore(), apply=True, poster=never, probe=lambda: probes.append(1) or True)
        self.assertEqual(probes, [])
        self.assertIsNone(rep["core_probe"])
        self.assertEqual((rep["outcome"], rep["exit_code"]), ("nothing_pending", 0))

    def test_a_newer_build_is_owed_at_once_whatever_the_old_one_spent(self):
        st = LiveStore().build()
        exhaust(st)
        st.build()
        self.assertEqual(au.pending(st)["pending"], [RID])

    def test_the_real_store_takes_the_grant_and_reads_it_back(self):
        clock = [T_STORE]
        orig = dsp_store.utcnow
        dsp_store.utcnow = lambda: stamp(clock[0])
        try:
            with tempfile.TemporaryDirectory() as d:
                st = dsp_store.Store(str(Path(d) / "dsp.sqlite"))
                st.add_anchor("dsp-a", RID, "built", kind="dsp_anchor", ruling_id="docs-p1", record=person())
                for _ in range(au.MAX_ERRORS):
                    clock[0] += TICK
                    apr.run_pending(st, apply=True, poster=boom, page=lambda msg: True, now_s=lambda: clock[0])
                self.assertEqual(au.pending(st)["exhausted_at"], {RID: stamp(clock[0])})
                clock[0] += au.RETRY_COOLDOWN_S
                rep = apr.run_pending(st, apply=True, poster=answer, probe=lambda: True, now_s=lambda: clock[0])
                self.assertEqual(rep["retry_granted_requests"], [RID])
                self.assertEqual(rep["written_requests"], [RID])
                self.assertEqual([r["outcome"] for r in st.anchor_outcomes()][-2:], ["retry_granted", "written"])
        finally:
            dsp_store.utcnow = orig

    def over_cap_store(self):
        """A built record with more write_error rows than the cap, as the --ids --apply path writes them."""
        st = LiveStore().build()
        for _ in range(au.MAX_ERRORS + 8):
            st.clock += TICK
            st.add_anchor("push", RID, "write_error")
        return st

    def test_a_record_past_the_cap_keeps_the_time_its_cap_was_reached(self):
        st = self.over_cap_store()
        owed = au.pending(st)
        self.assertEqual(owed["exhausted"], {RID: f"upload_failed_{au.MAX_ERRORS + 8}_times"})
        self.assertEqual(owed["exhausted_at"], {RID: stamp(T_STORE + au.MAX_ERRORS * TICK)})

    def test_a_record_past_the_cap_cools_down_on_the_cap_time(self):
        st = self.over_cap_store()
        owed = au.pending(st)
        at = T_STORE + au.MAX_ERRORS * TICK
        self.assertEqual(au.cooled(owed, at + au.RETRY_COOLDOWN_S - 1), [])
        self.assertEqual(au.cooled(owed, at + au.RETRY_COOLDOWN_S), [RID])

    def test_a_record_past_the_cap_lands_once_its_cooldown_has_run_out(self):
        st = self.over_cap_store()
        st.clock = T_STORE + au.MAX_ERRORS * TICK + au.RETRY_COOLDOWN_S
        rep = self.run_once(st)
        self.assertEqual(rep["retry_granted_requests"], [RID])
        self.assertEqual(rep["written_requests"], [RID])
        self.assertEqual(au.pending(st)["landed"], 1)


STUB_PROBE = """#!/usr/bin/env bash
# stands in for muso-admin-api.sh on the reachability read: logs what it was asked, answers what the test set
printf '%s\\n' "$DSP_ANCHOR_WRITER $MUSO_ADMIN_IDENTITY $*" >> "$STUB_LOG"
[ -n "$STUB_RC" ] && exit "$STUB_RC"
printf '%s\\n' "$STUB_ANSWER"
"""


class ProbeTest(unittest.TestCase):
    """The reachability read, through the real probe function with only the admin wrapper stubbed."""

    def probe(self, answer_line='{"http_status": 200, "body": {"data": {"items": []}}}', rc=""):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = Path(tmp.name)
        stub, self.log = d / "admin.sh", d / "stub.log"
        stub.write_text(STUB_PROBE)
        saved = {k: os.environ.get(k) for k in ("STUB_LOG", "STUB_ANSWER", "STUB_RC")}
        os.environ.update({"STUB_LOG": str(self.log), "STUB_ANSWER": answer_line, "STUB_RC": rc})
        try:
            return au.admin_probe(script=str(stub))()
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)

    def test_a_2xx_read_is_a_reachable_core(self):
        self.assertTrue(self.probe())

    def test_it_is_one_read_as_the_verifier_and_never_a_post(self):
        self.probe()
        self.assertEqual(self.log.read_text().splitlines(),
                         ["1 credit-decider --requester dsp-evidence-verifier@hydra-ops call GET "
                          "/admin/credit-requests?status=unverified&limit=1"])

    def test_a_5xx_read_is_not_reachable(self):
        self.assertFalse(self.probe('{"http_status": 503, "body": null}'))

    def test_a_wrapper_that_fails_is_not_reachable(self):
        self.assertFalse(self.probe(rc="7"))

    def test_an_answer_that_is_not_json_is_not_reachable(self):
        self.assertFalse(self.probe("<html>bad gateway</html>"))

    def test_a_wrapper_that_is_missing_is_not_reachable(self):
        self.assertFalse(au.admin_probe(script="/nonexistent/admin.sh")())


class ScheduledRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def run_it(self, store, **kw):
        kw.setdefault("switches", ())
        kw.setdefault("poster", answer)
        return apr.scheduled_run(lambda: store, apply=True, state_dir=self.dir, **kw)

    def lines(self):
        return [json.loads(x) for x in (Path(self.dir) / "runs.jsonl").read_text().splitlines()]

    def test_every_run_appends_exactly_one_record(self):
        self.run_it(LiveStore())
        self.run_it(LiveStore())
        self.assertEqual(len(self.lines()), 2)

    def test_the_record_is_the_run_that_was_returned(self):
        rec = self.run_it(LiveStore().build())
        self.assertEqual(self.lines()[-1]["run_id"], rec["run_id"])

    def test_the_record_carries_the_exit_code(self):
        self.run_it(LiveStore().build())
        self.assertEqual(self.lines()[-1]["exit_code"], 0)

    def test_the_record_carries_what_was_pushed(self):
        self.run_it(LiveStore().build())
        self.assertEqual(self.lines()[-1]["written_requests"], [RID])

    def test_the_record_carries_start_and_end(self):
        clock = iter([1794757000000, 1794757002500])
        self.run_it(LiveStore(), now_ms=lambda: next(clock))
        rec = self.lines()[-1]
        self.assertEqual((rec["started_at"], rec["finished_at"]),
                         ("2026-11-15T15:36:40.000Z", "2026-11-15T15:36:42.500Z"))

    def test_the_record_says_apply(self):
        self.run_it(LiveStore())
        self.assertEqual(self.lines()[-1]["mode"], "apply")

    def test_a_kill_file_stops_the_run_before_the_store_is_opened(self):
        kill = Path(self.dir) / "kill.disabled"
        kill.write_text("stop")

        def opened():
            raise AssertionError("the store must not be opened")
        rec = apr.scheduled_run(opened, apply=True, state_dir=self.dir, switches=(str(kill),), poster=never)
        self.assertEqual((rec["outcome"], rec["exit_code"], rec["kill_file"]), ("killed", 0, str(kill)))

    def test_a_killed_run_still_leaves_its_record(self):
        kill = Path(self.dir) / "kill.disabled"
        kill.write_text("stop")
        self.run_it(LiveStore().build(), switches=(str(kill),), poster=never)
        self.assertEqual(self.lines()[-1]["outcome"], "killed")

    def test_a_second_run_under_a_held_lock_posts_nothing(self):
        Path(self.dir).mkdir(exist_ok=True)
        with open(Path(self.dir) / "lock", "a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            rec = self.run_it(LiveStore().build(), poster=never)
        self.assertEqual((rec["outcome"], rec["exit_code"]), ("busy", 0))

    def test_a_store_that_cannot_be_opened_is_a_failed_run_with_a_record(self):
        def opened():
            raise sqlite3.OperationalError("unable to open database file")
        apr.scheduled_run(opened, apply=True, state_dir=self.dir, switches=(), poster=never)
        rec = self.lines()[-1]
        self.assertEqual((rec["outcome"], rec["exit_code"], rec["error"][:16]), ("failed", 1, "OperationalError"))

    def test_the_record_holds_no_command_line(self):
        self.run_it(LiveStore())
        self.assertEqual(sorted(self.lines()[-1]["invoked_by"]), ["gateway_child", "parent_comm", "tty"])


# Column lists measured on node-8's /root/.openclaw-main/state/openclaw.sqlite (openclaw 2026.8.35,
# 2026-11-15T16:16Z); re-verify them on every openclaw bump.
GATEWAY_DDL = """
CREATE TABLE cron_jobs (store_key TEXT, job_id TEXT, declaration_key TEXT, owner_agent_id TEXT, name TEXT,
                        description TEXT, enabled INTEGER, agent_id TEXT, payload_kind TEXT, job_json TEXT,
                        state_json TEXT, runtime_updated_at_ms INTEGER, schedule_identity TEXT, sort_order INTEGER,
                        updated_at INTEGER);
CREATE TABLE cron_run_receipts (receipt_id TEXT, store_key TEXT, job_id TEXT, config_revision TEXT, agent_id TEXT,
                                request_run_id TEXT, status TEXT, owner_pid INTEGER, owner_start_time TEXT,
                                started_at_ms INTEGER, finished_at_ms INTEGER, error_text TEXT);
"""
T0 = 1794757020000          # 2026-11-15T15:37:00Z, a minute the schedule names
QUARTER = 15 * 60 * 1000


class SchedulerRunsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name
        self.db_path = str(Path(self.dir) / "openclaw.sqlite")
        self.db = sqlite3.connect(self.db_path)
        self.db.executescript(GATEWAY_DDL)
        self.job("7,22,37,52 * * * *")
        self.n = 0

    def job(self, expr, name=apr.JOB_NAME):
        self.db.execute("DELETE FROM cron_jobs WHERE name=?", (name,))
        self.db.execute("INSERT INTO cron_jobs (store_key, job_id, name, enabled, job_json) VALUES ('k', ?, ?, 1, ?)",
                        ("job-" + name, name, json.dumps(
                            {"schedule": {"kind": "cron", "expr": expr, "tz": "UTC"}})))
        self.db.commit()

    def receipt(self, start, status="ok", took=2000, finished=True, job="job-" + apr.JOB_NAME):
        self.n += 1
        self.db.execute("INSERT INTO cron_run_receipts (receipt_id, store_key, job_id, status, started_at_ms,"
                        " finished_at_ms, error_text) VALUES (?,?,?,?,?,?,?)",
                        (f"r{self.n}", "k", job, status, start, start + took if finished else None,
                         None if status == "ok" else "cron: job execution timed out"))
        self.db.commit()

    def record(self, start, **over):
        rec = {"schema": apr.SCHEMA, "run_id": f"apr-{start}", "started_at_ms": start + 400, "exit_code": 0,
               "mode": "apply", "outcome": "nothing_pending", "written": 0}
        rec.update(over)
        apr.append_record(rec, self.dir)

    def read(self, n=2):
        return apr.scheduler_runs(n, state_db=self.db_path, state_dir=self.dir)

    def two_good(self):
        for start in (T0, T0 + QUARTER):
            self.receipt(start)
            self.record(start)

    def test_two_scheduled_ok_runs_with_their_records_count(self):
        self.two_good()
        self.assertTrue(self.read()["consecutive_ok"])

    def test_the_newest_run_is_listed_first(self):
        self.two_good()
        self.assertEqual([r["started_at"] for r in self.read()["runs"]],
                         ["2026-11-15T15:52:00.000Z", "2026-11-15T15:37:00.000Z"])

    def test_each_run_carries_its_run_record(self):
        self.two_good()
        self.assertEqual([r["run_record"]["run_id"] for r in self.read()["runs"]],
                         [f"apr-{T0 + QUARTER}", f"apr-{T0}"])

    def test_a_run_that_pushed_counts(self):
        self.receipt(T0)
        self.record(T0, outcome="pushed", written=2)
        self.assertTrue(self.read(1)["consecutive_ok"])

    def idle_exhausted(self, **over):
        for start in (T0, T0 + QUARTER):
            self.receipt(start)
            self.record(start, outcome="deferred_exhausted", exhausted=1, **over)
        return self.read()["consecutive_ok"]

    def test_cooldown_runs_are_not_successful_acceptance_evidence(self):
        """QA on #2046: an exhausted anchor's cooldown ticks push nothing, so they cannot count as two successes."""
        self.assertFalse(self.idle_exhausted(retry_owed=1))

    def test_idle_runs_whose_exhausted_records_are_all_terminal_count(self):
        """firstmate 2026-11-15: a record core refused must not make the evidence unreachable for good."""
        self.assertTrue(self.idle_exhausted(retry_owed=0))

    def test_an_idle_exhausted_run_with_no_count_does_not_count(self):
        self.assertFalse(self.idle_exhausted())

    def test_an_idle_exhausted_run_with_an_unreadable_count_does_not_count(self):
        self.assertFalse(self.idle_exhausted(retry_owed=None))

    def test_a_false_count_is_not_a_zero(self):
        self.assertFalse(self.idle_exhausted(retry_owed=False))

    def test_an_idle_exhausted_dry_run_does_not_count(self):
        self.assertFalse(self.idle_exhausted(retry_owed=0, mode="dry-run"))

    def test_an_idle_exhausted_run_that_exited_1_does_not_count(self):
        self.assertFalse(self.idle_exhausted(retry_owed=0, exit_code=1))

    def test_one_cooldown_run_among_terminal_ones_breaks_the_pair(self):
        self.receipt(T0)
        self.record(T0, outcome="deferred_exhausted", exhausted=2, retry_owed=1)
        self.receipt(T0 + QUARTER)
        self.record(T0 + QUARTER, outcome="deferred_exhausted", exhausted=1, retry_owed=0)
        self.assertFalse(self.read()["consecutive_ok"])

    def test_a_failed_run_does_not_count_whatever_its_count_says(self):
        self.receipt(T0)
        self.record(T0, outcome="failed", exit_code=1, retry_owed=0)
        self.assertFalse(self.read(1)["consecutive_ok"])

    def scheduled(self, st, start, poster=None):
        """One scheduler tick: the receipt, and the record the REAL run writes into its window."""
        self.receipt(start)
        st.clock = start // 1000
        apr.scheduled_run(lambda: st, apply=True, state_dir=self.dir, switches=(), poster=poster or never,
                          now_ms=lambda: start + 400, probe=lambda: False)

    def test_idle_runs_after_a_core_refusal_pass_the_evidence(self):
        st = LiveStore().build()
        for _ in range(au.MAX_REFUSALS):
            apr.run_pending(st, apply=True, poster=refuse)
        self.scheduled(st, T0)
        self.scheduled(st, T0 + QUARTER)
        got = self.read()
        self.assertEqual([r["run_record"]["outcome"] for r in got["runs"]], ["deferred_exhausted"] * 2)
        self.assertEqual([r["run_record"]["retry_owed"] for r in got["runs"]], [0, 0])
        self.assertTrue(got["consecutive_ok"])

    def test_idle_runs_after_an_unpostable_record_pass_the_evidence(self):
        st = LiveStore().build(record=person(roles=[]))
        for _ in range(au.MAX_ERRORS):
            apr.run_pending(st, apply=True, poster=never, page=lambda msg: True)
        self.scheduled(st, T0)
        self.scheduled(st, T0 + QUARTER)
        got = self.read()
        self.assertEqual([r["run_record"]["retry_owed"] for r in got["runs"]], [0, 0])
        self.assertTrue(got["consecutive_ok"])

    def test_idle_ticks_inside_an_upload_cooldown_do_not_pass_the_evidence(self):
        st = LiveStore().build()
        st.clock = T0 // 1000 - au.MAX_ERRORS * TICK
        exhaust(st, [])
        self.scheduled(st, T0)
        self.scheduled(st, T0 + QUARTER)
        got = self.read()
        self.assertEqual([r["run_record"]["outcome"] for r in got["runs"]], ["deferred_exhausted"] * 2)
        self.assertEqual([r["run_record"]["retry_owed"] for r in got["runs"]], [1, 1])
        self.assertFalse(got["consecutive_ok"])

    def test_a_cooled_record_an_unreachable_core_keeps_is_still_owed(self):
        st = LiveStore().build()
        st.clock = T0 // 1000 - au.MAX_ERRORS * TICK - au.RETRY_COOLDOWN_S
        exhaust(st, [])
        self.scheduled(st, T0)
        self.scheduled(st, T0 + QUARTER)
        got = self.read()
        self.assertEqual([r["run_record"]["core_probe"] for r in got["runs"]], ["failed", "failed"])
        self.assertEqual([r["run_record"]["retry_owed"] for r in got["runs"]], [1, 1])
        self.assertFalse(got["consecutive_ok"])

    def test_a_run_with_a_record_it_did_not_land_does_not_pass_the_evidence(self):
        st = LiveStore().build()
        self.scheduled(st, T0, poster=boom)
        got = self.read(1)
        self.assertEqual(got["runs"][0]["run_record"]["outcome"], "failed")
        self.assertEqual(got["runs"][0]["run_record"]["retry_owed"], 0)
        self.assertFalse(got["consecutive_ok"])

    def test_a_terminal_record_beside_a_cooling_one_does_not_pass_the_evidence(self):
        st = LiveStore().build().build(rid_n(2))
        for _ in range(au.MAX_REFUSALS):
            apr.run_pending(st, apply=True, max_requests=1, poster=refuse)
        st.clock = T0 // 1000 - au.MAX_ERRORS * TICK
        exhaust(st, [])
        self.scheduled(st, T0)
        got = self.read(1)
        self.assertEqual((got["runs"][0]["run_record"]["exhausted"], got["runs"][0]["run_record"]["retry_owed"]), (2, 1))
        self.assertFalse(got["consecutive_ok"])

    def test_one_run_is_not_two(self):
        self.receipt(T0)
        self.record(T0)
        self.assertFalse(self.read()["consecutive_ok"])

    def test_no_run_at_all_is_not_proof(self):
        self.assertFalse(self.read()["consecutive_ok"])

    def test_a_failed_receipt_between_breaks_the_pair(self):
        self.two_good()
        self.receipt(T0 + 2 * QUARTER, status="error")
        self.assertFalse(self.read()["consecutive_ok"])

    def test_a_receipt_with_no_run_record_does_not_count(self):
        self.two_good()
        self.receipt(T0 + 2 * QUARTER)
        self.assertFalse(self.read()["consecutive_ok"])

    def test_a_dry_run_record_does_not_count(self):
        self.receipt(T0)
        self.record(T0, mode="dry-run", outcome="dry_run")
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_run_that_exited_non_zero_does_not_count(self):
        self.receipt(T0)
        self.record(T0, exit_code=1, outcome="failed")
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_killed_run_does_not_count(self):
        self.receipt(T0)
        self.record(T0, outcome="killed")
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_run_core_refused_does_not_count(self):
        self.receipt(T0)
        self.record(T0, outcome="refused_by_core")
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_run_that_pushed_beside_refusals_counts(self):
        self.receipt(T0)
        self.record(T0, outcome="pushed_with_refusals", written=2)
        self.assertTrue(self.read(1)["consecutive_ok"])

    def test_a_start_off_the_schedule_does_not_count(self):
        self.receipt(T0 - 22 * 60 * 1000)
        self.record(T0 - 22 * 60 * 1000)
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_start_off_the_schedule_is_reported_as_such(self):
        self.receipt(T0 - 22 * 60 * 1000)
        self.record(T0 - 22 * 60 * 1000)
        self.assertIs(self.read(1)["runs"][0]["started_on_schedule"], False)

    def test_a_start_ninety_seconds_after_a_slot_is_on_schedule(self):
        for start in (T0 + 90_000, T0 + QUARTER + 90_000):
            self.receipt(start)
            self.record(start)
        self.assertIs(self.read()["runs"][0]["started_on_schedule"], True)
        self.assertTrue(self.read()["consecutive_ok"])

    def test_a_start_exactly_three_hundred_seconds_after_a_slot_is_on_schedule(self):
        self.receipt(T0 + 300_000)
        self.record(T0 + 300_000)
        self.assertIs(self.read(1)["runs"][0]["started_on_schedule"], True)

    def test_a_start_three_hundred_and_one_seconds_after_a_slot_is_not_on_schedule(self):
        self.receipt(T0 + 301_000)
        self.record(T0 + 301_000)
        self.assertIs(self.read(1)["runs"][0]["started_on_schedule"], False)

    def test_a_start_at_an_unnamed_minute_outside_the_window_is_not_on_schedule(self):
        self.receipt(T0 - 22 * 60 * 1000)
        self.record(T0 - 22 * 60 * 1000)
        self.assertIs(self.read(1)["runs"][0]["started_on_schedule"], False)
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_start_before_a_slot_is_judged_against_the_previous_slot(self):
        self.receipt(T0 - 30_000)
        self.record(T0 - 30_000)
        got = self.read(1)["runs"][0]
        self.assertEqual(got["start_delay_s"], 14 * 60 + 30)
        self.assertIs(got["started_on_schedule"], False)

    def test_a_five_minute_schedule_gets_half_its_gap_as_the_window(self):
        self.job("*/5 * * * *")
        self.receipt(T0)
        self.record(T0)
        self.assertEqual(self.read(1)["start_window_s"], 150)

    def test_the_strict_minute_match_is_reported_beside_the_window(self):
        self.receipt(T0)
        self.record(T0)
        self.receipt(T0 + QUARTER + 90_000)
        self.record(T0 + QUARTER + 90_000)
        at_slot, delayed = self.read()["runs"][1], self.read()["runs"][0]
        self.assertIs(at_slot["started_on_minute"], True)
        self.assertIs(delayed["started_on_minute"], False)
        self.assertIs(delayed["started_on_schedule"], True)

    def test_a_start_before_the_first_slot_is_readable_and_off_schedule(self):
        start = T0 + 26 * 60 * 1000                # 16:03:00Z, before the first slot of that hour
        self.receipt(start)
        self.record(start)
        got = self.read(1)
        self.assertEqual(got["runs"][0]["start_delay_s"], 660)
        self.assertIs(got["runs"][0]["started_on_schedule"], False)
        self.assertFalse(got["consecutive_ok"])

    def test_an_unreadable_runs_file_is_unreadable_not_empty(self):
        os.mkdir(Path(self.dir) / "runs.jsonl")
        with self.assertRaises(apr.SchedulerUnreadable):
            apr.read_records(self.dir)

    def test_a_hand_run_outside_every_receipt_is_paired_with_none(self):
        self.receipt(T0)
        self.record(T0 + 5 * 60 * 1000)                    # a run record no receipt covers
        self.assertEqual(self.read(1)["runs"][0]["run_records_in_window"], 0)

    def test_two_records_inside_one_receipt_do_not_count(self):
        self.receipt(T0)
        self.record(T0)
        self.record(T0, run_id="apr-second", started_at_ms=T0 + 900)
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_another_jobs_receipts_are_not_read(self):
        self.receipt(T0, job="job-other")
        self.record(T0)
        self.assertEqual(self.read(1)["finished_receipts"], 0)

    def test_a_run_still_in_flight_is_counted_apart(self):
        self.two_good()
        self.receipt(T0 + 2 * QUARTER, finished=False)
        self.assertEqual((self.read()["unfinished_receipts"], self.read()["consecutive_ok"]), (1, True))

    def test_a_schedule_this_reader_cannot_measure_is_not_proof(self):
        self.job("7 */2 * * *")
        self.receipt(T0)
        self.record(T0)
        self.assertIs(self.read(1)["runs"][0]["started_on_schedule"], None)

    def test_an_unmeasured_schedule_never_counts(self):
        self.job("7 */2 * * *")
        self.receipt(T0)
        self.record(T0)
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_missing_gateway_db_is_unreadable_not_empty(self):
        with self.assertRaises(apr.SchedulerUnreadable):
            apr.scheduler_runs(2, state_db=str(Path(self.dir) / "absent.sqlite"), state_dir=self.dir)

    def test_a_gateway_db_without_the_cron_tables_is_unreadable(self):
        other = str(Path(self.dir) / "other.sqlite")
        sqlite3.connect(other).execute("CREATE TABLE t (x)").connection.commit()
        with self.assertRaises(apr.SchedulerUnreadable):
            apr.scheduler_runs(2, state_db=other, state_dir=self.dir)

    def test_a_job_the_gateway_does_not_hold_is_not_scheduled(self):
        self.db.execute("DELETE FROM cron_jobs")
        self.db.commit()
        self.assertEqual((self.read()["scheduled"], self.read()["consecutive_ok"]), (False, False))

    def test_two_jobs_under_the_name_are_unreadable(self):
        self.db.execute("INSERT INTO cron_jobs (store_key, job_id, name, enabled, job_json)"
                        " VALUES ('k2', 'job-twin', ?, 1, '{}')", (apr.JOB_NAME,))
        self.db.commit()
        with self.assertRaises(apr.SchedulerUnreadable):
            self.read()

    def test_a_failed_receipt_does_not_count_whatever_its_run_record_says(self):
        self.receipt(T0, status="error")
        self.record(T0)
        self.assertFalse(self.read(1)["consecutive_ok"])

    def test_a_torn_last_line_is_not_a_run_record(self):
        self.record(T0)
        with open(Path(self.dir) / "runs.jsonl", "a") as fh:
            fh.write('{"schema": "anchors-push-run/1", "started')
        self.assertEqual(len(apr.read_records(self.dir)), 1)


class ScheduleMinutesTest(unittest.TestCase):
    def test_a_minute_list(self):
        self.assertEqual(apr._minutes("7,22,37,52 * * * *"), {7, 22, 37, 52})

    def test_a_step(self):
        self.assertEqual(apr._minutes("*/15 * * * *"), {0, 15, 30, 45})

    def test_an_hour_field_is_not_measured(self):
        self.assertIsNone(apr._minutes("7 */2 * * *"))

    def test_a_range_is_not_measured(self):
        self.assertIsNone(apr._minutes("0-10 * * * *"))

    def test_a_start_at_the_hour_slot_has_no_delay(self):
        self.assertEqual(apr._start_delay_s(datetime(2026, 11, 15, 15, 0, 0, tzinfo=timezone.utc), {0}), 0)

    def test_a_start_after_the_hour_rolls_back_to_the_previous_slot(self):
        self.assertEqual(apr._start_delay_s(datetime(2026, 11, 15, 15, 59, 30, tzinfo=timezone.utc), {0}), 3570)


STUB_ADMIN = """#!/usr/bin/env bash
# stands in for muso-admin-api.sh: answers every submitted row as written, and logs what it was asked
printf '%s\\n' "$DSP_ANCHOR_WRITER $MUSO_ADMIN_IDENTITY $*" >> "$STUB_LOG"
python3 - "${@: -1}" <<'EOF'
import json, sys
recs = json.loads(sys.argv[1])["records"]
print(json.dumps({"http_status": 200, "body": {"data": {"results": [
    {"requestId": r["requestId"], "role": r["role"], "kind": r["kind"], "source": r["source"], "outcome": "written"}
    for r in recs]}}}))
EOF
"""


class RealEntrypointTest(unittest.TestCase):
    """The file the cron runs, on a real verifier store, with only the admin wrapper stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name)
        self.store, self.state, self.log = str(d / "dsp.sqlite"), str(d / "state"), d / "stub.log"
        stub = d / "admin.sh"
        stub.write_text(STUB_ADMIN)
        self.env = {**os.environ, "CREDIT_ANCHORS_PUSH_STATE": self.state, "CREDIT_REVIEW_ADMIN_SCRIPT": str(stub),
                    "CREDIT_ANCHORS_PUSH_KILL_SWITCH": str(d / "no-kill"), "CREDIT_VERIFY_KILL_SWITCH": str(d / "no-kill-2"),
                    "STUB_LOG": str(self.log)}

    def cron(self):
        argv = cron_job()["payload"]["argv"]
        proc = subprocess.run([sys.executable, str(DRIVER), *argv[2:], "--store", self.store],
                              capture_output=True, text=True, env=self.env, check=False)
        return proc.returncode, json.loads(proc.stdout or "{}"), proc.stderr

    def build(self):
        dsp_store.Store(self.store).add_anchor("dsp-a", RID, "built", kind="dsp_anchor", ruling_id="docs-p1",
                                                verdict_id=1, record=person())

    def records(self):
        return [json.loads(x) for x in (Path(self.state) / "runs.jsonl").read_text().splitlines()]

    def test_the_cron_argv_on_an_empty_store_exits_zero(self):
        self.assertEqual(self.cron()[0], 0)

    def test_the_cron_argv_on_an_empty_store_says_nothing_pending(self):
        self.assertEqual(self.cron()[1]["outcome"], "nothing_pending")

    def test_the_cron_argv_on_an_empty_store_calls_no_admin_api(self):
        self.cron()
        self.assertFalse(self.log.exists())

    def test_the_cron_argv_leaves_one_run_record_per_run(self):
        self.cron()
        self.cron()
        self.assertEqual([r["mode"] for r in self.records()], ["apply", "apply"])

    def test_the_cron_argv_pushes_a_built_record(self):
        self.build()
        rc, rec, err = self.cron()
        self.assertEqual((rc, rec["outcome"], rec["written"], rec["written_requests"]), (0, "pushed", 2, [RID]), err)

    def test_the_push_goes_out_as_the_verifier_on_the_anchors_route(self):
        self.build()
        self.cron()
        self.assertEqual(self.log.read_text().split(" {")[0],
                         "1 credit-decider --requester dsp-evidence-verifier@hydra-ops call POST /admin/credit-anchors")

    def test_the_landed_record_is_in_the_verifier_store(self):
        self.build()
        self.cron()
        self.assertEqual([r["outcome"] for r in dsp_store.Store(self.store).anchor_outcomes()], ["built", "written"])

    def test_the_second_run_does_not_push_the_same_record_again(self):
        self.build()
        self.cron()
        self.cron()
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_a_kill_file_stops_the_cron_argv(self):
        Path(self.env["CREDIT_ANCHORS_PUSH_KILL_SWITCH"]).write_text("stop")
        self.build()
        self.assertEqual(self.cron()[1]["outcome"], "killed")

    def test_scheduler_runs_on_an_unreadable_gateway_store_exits_two(self):
        proc = subprocess.run([sys.executable, str(DRIVER), "--scheduler-runs", "--state-db",
                               str(Path(self.tmp.name) / "absent.sqlite")], capture_output=True, text=True,
                              env=self.env, check=False)
        self.assertEqual(proc.returncode, 2)


def cron_job(name=apr.JOB_NAME):
    jobs = [j for j in json.loads((REPO / "cron-jobs.json").read_text())["jobs"] if j.get("name") == name]
    assert len(jobs) == 1, f"{len(jobs)} cron jobs named {name}"
    return jobs[0]


class WiringTest(unittest.TestCase):
    def test_the_cron_runs_the_driver_on_the_pending_records_for_real(self):
        self.assertEqual(cron_job()["payload"]["argv"],
                         ["python3", "/opt/hydra/scripts/credit-anchors-push.py", "--pending", "--apply"])

    def test_the_cron_is_a_command_never_an_agent_turn(self):
        self.assertEqual(cron_job()["payload"]["kind"], "command")

    def test_the_cron_is_enabled(self):
        self.assertIs(cron_job()["enabled"], True)

    def test_the_schedule_is_one_the_reader_can_measure(self):
        self.assertEqual(apr._minutes(cron_job()["schedule"]["expr"]), {7, 22, 37, 52})

    def test_the_schedule_is_utc(self):
        self.assertEqual(cron_job()["schedule"]["tz"], "UTC")

    def test_the_registry_names_the_cron(self):
        reg = json.loads((REPO / "policies" / "credit-approval-automation.json").read_text())["automations"]
        self.assertEqual(reg["credit-anchors-push"]["cron_names"], [apr.JOB_NAME])

    def test_the_registry_scope_is_upload_only(self):
        reg = json.loads((REPO / "policies" / "credit-approval-automation.json").read_text())["automations"]
        self.assertEqual(reg["credit-anchors-push"]["scope"], "anchor-upload-only")

    def test_the_executor_that_reads_the_anchors_stays_unscheduled(self):
        text = (REPO / "cron-jobs.json").read_text()
        self.assertNotIn("credit-fable-execute.py", " ".join(
            " ".join(map(str, j.get("payload", {}).get("argv") or [])) for j in json.loads(text)["jobs"]))


if __name__ == "__main__":
    unittest.main()
