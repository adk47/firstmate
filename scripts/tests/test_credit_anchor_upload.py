"""credit-anchors-push: the verifier's built dsp-anchor/1 records -> core rows (Fable l12-approvals-core A)."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import anchor_upload as au  # noqa: E402

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
        self.assertEqual(st.added[0][1], "write_refused")

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


if __name__ == "__main__":
    unittest.main()
