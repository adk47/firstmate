#!/usr/bin/env python3
"""b1's part of the batch judge (r5 on #1589): the coded pre-layer runs BEFORE #1586's judge_batch and a coded stop
never reaches the model; the instructions carry rules + facts by id + copy ref + barred list and never a body marker;
the CLI's verdict row folds coded stops into #1586's signature row, fail closed. Provider faked."""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from credit_review import batch_judge as bj  # noqa: E402
from credit_review import batch_judge_instructions as bi  # noqa: E402

_spec = importlib.util.spec_from_file_location("credit_batch_judge_cli", HERE / "credit-batch-judge.py")
cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cli)

BODY = ("<p>Hi Ann, thanks for the PDF you sent on October 23 for your Mixing and Mastering credit on "
        "&quot;Night Drive&quot;.</p><p>Reply to this message with the same document as a PDF, and we&#39;ll check it.</p>")
ASK = {"class": "per_need_ask", "owes_proof": True, "distinct_tracks": 1, "today_year": 2026,
       "tracks": [{"title": "Night Drive", "roles": ["Mixing", "Mastering"]}], "document_dates": ["2026-10-23"]}


class FakeProvider:
    def __init__(self, verdicts):
        self.verdicts, self.prompts = verdicts, []

    def judge(self, prompt, schema, step=None):
        self.prompts.append(prompt)
        sha = prompt.split("BATCH SHA: ")[1].split("\n")[0]
        ids = [p.split(">>>")[0] for p in prompt.split("<<<RENDERED BODY id=")[1:]]
        rows = [{"id": i, "verdict": self.verdicts.get(i, "pass"), "reason_code": "none" if
                 self.verdicts.get(i, "pass") == "pass" else "role_join", "evidence_quote": ""} for i in ids]
        return types.SimpleNamespace(ok=True, json={"batch_sha": sha, "bodies": rows, "verdict":
                                     "pass" if all(r["verdict"] == "pass" for r in rows) else "stop"},
                                     provider="codex", model=bj.CODEX_MODEL, llm_call_id=1, cost_usd=0, meta={},
                                     error=None)


def item(uid, body=BODY, facts=ASK):
    return {"id": str(uid), "user_id": str(uid), "body": body, "facts": dict(facts)}


class CodedLayerTests(unittest.TestCase):
    def test_every_coded_stop(self):
        barred = bi.barred_phrases()
        cases = [(BODY.replace("we&#39;ll check it", "nothing else is needed"), ASK, "barred_phrase"),
                 (BODY.replace("we&#39;ll check it", "we reply within 3 business days"), ASK, "barred_phrase"),
                 (BODY, {**ASK, "class": "team_review", "owes_proof": True}, "class_owes_mismatch"),
                 (BODY, {**ASK, "owes_proof": False}, "class_owes_mismatch"),
                 (BODY, {**ASK, "owes_proof": None}, "class_owes_mismatch"),
                 (BODY, {**ASK, "class": "newsletter"}, "other")]
        for body, facts, code in cases:
            self.assertEqual(bi.coded_stop(body, facts, barred)[0], code, (facts, code))
        self.assertIsNone(bi.coded_stop(BODY, ASK, barred))
        for cls, owes in (("gap-ask", True), ("uvn-status", True), ("status-doc-received", False),
                          ("status-team-review", False)):                 # campaign names are classes too
            self.assertIsNone(bi.coded_stop(BODY, {**ASK, "class": cls, "owes_proof": owes}, barred), cls)
        self.assertEqual(bi.coded_stop(BODY, {**ASK, "class": "credit-hold-status"}, barred)[0], "other")
        stops = bi.coded_stops([item(1), item(1), item(2)], barred)
        self.assertEqual({k: v[0] for k, v in stops.items()}, {"1": "duplicate_user"})

    def test_barred_phrases_match_through_every_html_entity_form(self):
        barred = bi.barred_phrases()
        for body in ("<p>I&#x27;ve checked your request</p>", "<p>I&#39;ve checked your request</p>",
                     "<p>I&rsquo;ve checked your request</p>", "<p>nothing&nbsp;else is needed</p>",
                     "<p>no need to resend</p>", "<p>NOTHING ELSE IS&#32;NEEDED</p>"):
            self.assertEqual((bi.coded_stop(body, ASK, barred) or ("none",))[0], "barred_phrase", body)

    def test_malformed_facts_are_a_coded_stop_never_a_crash(self):
        for facts in ("{class: uvn, owes_proof: True}", ["uvn"], None, 7):
            self.assertEqual(bi.coded_stop(BODY, facts, bi.barred_phrases())[0], "other", facts)
        stops = bi.coded_stops([{"id": "1", "user_id": "1", "body": BODY, "facts": "{class: uvn}"}], [])
        self.assertEqual(stops["1"][0], "other")
        row, coded = cli.run_batch([{"id": "1", "user_id": "1", "body": BODY, "facts": "{class: uvn}"}], "/e1",
                                   provider=FakeProvider({}))
        self.assertEqual((row["verdict"], row["stop_ids"], coded["1"][0]), ("stop", ["1"], "other"))

    def test_a_barred_line_without_phrases_refuses(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "SKILL.md"
            f.write_text("- <!-- barred-phrases --> no need to resend\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                bi.barred_phrases(f)
            f.write_text("- nothing here\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                bi.barred_phrases(f)

    def test_retired_barred_forms_are_coded(self):
        for s in ("We'll message you as soon as it's checked - no need to send anything else.",
                  "No need to re-send it.", "Nothing is needed from you.", "Nothing more is needed.",
                  "Nothing more needed from you.", "Nothing else needed.", "nothing needed right now"):  # QA #1598
            self.assertEqual(bi.coded_stop(BODY.replace("we&#39;ll check it", s), ASK, [])[0], "barred_phrase", s)
        self.assertIsNone(bi.coded_stop(BODY.replace("we&#39;ll check it", "we need the other side of it"), ASK, []))

    def test_the_barred_list_is_the_one_doctrine_line(self):
        self.assertIn("nothing else is needed", bi.barred_phrases())


class R1RolesCoverageTests(unittest.TestCase):
    """fable-copy-1101-r5/r1-roles: the docrecvr-roles coverage set (original + mutants) for the judge harness."""
    FIX = Path(__file__).resolve().parent / "fixtures" / "batch-judge" / "docrecvr-roles.jsonl"

    def setUp(self):
        self.items = [json.loads(line) for line in self.FIX.read_text(encoding="utf-8").splitlines() if line.strip()]

    def test_the_set_is_one_original_and_its_mutants_each_its_own_batch(self):
        exp = [it["expected"] for it in self.items]
        self.assertEqual((exp.count("GO"), exp.count("STOP")), (1, 8))
        self.assertEqual(len({it["case"] for it in self.items}), len(self.items))   # a batch stop names every id
        from credit_review import verify_notify as vn
        payload = {"credits": [{"track_title": "Midnight Drive", "role": "Mixing"}, {"track_title": "Midnight Drive", "role": "Mastering"}]}
        want = vn.render_facts(payload, ["--campaign", "status-doc-received", "--copy", "received"])
        one = vn.render_facts({"credits": [{"track_title": "Midnight Drive", "role": "Mixing, Mastering"}]},
                              ["--campaign", "status-doc-received", "--copy", "received"])
        self.assertEqual(one["tracks_roles"], want["tracks_roles"])   # QA #1626: a comma-combined role is two roles
        x = ["--campaign", "status-doc-received", "--copy", "received"]
        dup = vn.render_facts({"credits": [{"track_title": "A", "role": "Mixing"}, {"track_title": "A", "role": "mixing "}]}, x)
        self.assertEqual((dup["distinct_tracks"], dup["tracks_roles"]), (1, [["A", ["Mixing"]]]))   # renders singular
        two = vn.render_facts({"credits": [{"track_title": "Home", "role": "Mixing", "artist_name": "X"},
                                           {"track_title": "Home", "role": "Mixing", "artist_name": "Y"}]}, x)
        self.assertEqual(two["distinct_tracks"], 2)            # the renderer's tkey: same title, other artist = 2 tracks
        same = vn.render_facts({"credits": [{"track_title": "Home", "role": "Mixing", "artist_name": "X"},
                                            {"track_title": "home ", "role": "Mastering", "artist_name": "x"}]}, x)
        self.assertEqual(same["distinct_tracks"], 1)           # ... and case/space variants of one title + artist = 1
        ids = vn.render_facts({"credits": [{"track_title": "Home", "role": "Mixing", "track_id": "a"},
                                           {"track_title": "Home (Edit)", "role": "Mastering", "track_id": "a"}]}, x)
        self.assertEqual((ids["distinct_tracks"], ids["tracks_roles"]), (1, [["Home", ["Mastering", "Mixing"]]]))
        for it in self.items:         # the RENDERER's facts, never hand-written
            self.assertEqual({k: v for k, v in it["facts"].items()}, want)

    def test_the_facts_key_tracks_and_roles_with_the_renderers_own_jq_string_rules(self):
        # QA #1626: jq's ascii_downcase lowers A-Z only and jq's \s is not Python's - the facts must split / merge
        # exactly as the gate's tnorm + track_roles (read from the gate script itself, run through jq)
        import re, shutil, subprocess
        from credit_review import verify_notify as vn
        x = ["--campaign", "status-doc-received", "--copy", "received"]
        two = vn.render_facts({"credits": [{"track_title": "\u00c9t\u00e9", "role": "Mixing"},
                                           {"track_title": "\u00e9t\u00e9", "role": "Mixing"}]}, x)
        self.assertEqual(two["distinct_tracks"], 2)                      # "Été" / "été": two titles to the renderer
        gate = (Path(__file__).resolve().parents[1] / "intercom-verify-request.sh").read_text(encoding="utf-8")
        tnorm = re.search(r"^def tnorm: [^\n]*;$", gate, re.M).group(0)
        roles = re.search(r"^def track_roles\(\$c\):.*?end\);", gate, re.M | re.S).group(0)
        jq = shutil.which("jq")
        self.assertTrue(jq, "jq is required (the gate renderer is jq)")
        sep = "".join(chr(c) for c in range(28, 32))
        samples = ["\u00c9t\u00e9", "\u00e9t\u00e9", "  Home\tRun ", "HOME  run", "a\u00a0b", "x" + sep + "y", " " + sep,
                   "\u2003Song\u2003", "\u0130stanbul", "STRASSE", "stra\u00dfe", ""]
        out = subprocess.run([jq, "-c", tnorm + " [.[] | tnorm]"], input=json.dumps(samples), capture_output=True,
                             text=True, check=True).stdout
        self.assertEqual([vn._jq_tnorm(s) for s in samples], json.loads(out))
        role_cells = ["Mixing, mixing ,MIXING", "\u00c9dit, \u00e9dit", " Mastering" + sep + ", \u00a0Mixing\u00a0", ", ,Vocals"]
        for cell in role_cells:
            want = json.loads(subprocess.run([jq, "-c", roles + " track_roles([{role: .}])"], input=json.dumps(cell),
                                             capture_output=True, text=True, check=True).stdout)
            got = vn.render_facts({"credits": [{"track_title": "T", "role": cell}]}, x)["tracks_roles"][0][1]
            self.assertEqual(got, sorted(want), cell)

    def test_the_r1_carve_out_needs_owes_proof_exactly_true(self):
        # QA #1626: a missing or non-boolean owes_proof is malformed input - the coded class/owes stop still fires
        facts = dict(self.items[0]["facts"])
        for bad in ({k: v for k, v in facts.items() if k != "owes_proof"}, {**facts, "owes_proof": "true"},
                    {**facts, "owes_proof": 1}, {**facts, "owes_proof": None}):
            self.assertEqual(bi.coded_stop("<p>a quick update</p>", bad, [])[0], "class_owes_mismatch", bad.get("owes_proof"))
        self.assertIsNone(bi.coded_stop("<p>a quick update</p>", facts, []))

    def test_an_r1_receipt_is_not_a_class_mismatch_but_its_barred_forms_and_other_owing_statuses_still_are(self):
        facts = self.items[0]["facts"]
        self.assertIsNone(bi.coded_stop(self.items[0]["body_html"], facts, bi.barred_phrases()))
        self.assertEqual(bi.coded_stop("<p>Nothing else is needed.</p>", facts, [])[0], "barred_phrase")
        for other in ({**facts, "campaign": "status-team-review", "copy": ""}, {**facts, "copy": "rejected"},
                      {**facts, "campaign": "uvn-status"}):
            self.assertEqual(bi.coded_stop("<p>a quick update</p>", other, [])[0], "class_owes_mismatch")
        ins = bi.instructions([{"id": "1", "body": "x", "facts": facts}], "fable-copy-1101-r5/r1-roles", [])
        self.assertIn("fable-copy-1101-r5/r1-roles", ins)
        self.assertIn("R1 receipt", ins)


class InstructionsTests(unittest.TestCase):
    def test_instructions_carry_rules_facts_by_id_barred_and_the_contract_but_no_body(self):
        txt = bi.instructions([item(7)], "/e1", ["x y"])
        for part in ("R2 number_agreement", "R3 role_join", "R4 old_date_year", "R5 promise", "reply-by date the USER", "the FACTS `class`, never the body", "per_need_ask",
                     "names you on the track", "After Saturday, November 14 the claim closes",
                     "is the work, not a track", "our daily check will pick it up",
                     "A public link where the credit is listed",
                     '"x y"', "COPY REF",
                     '"7": {', '"batch_sha"', '"pass"|"stop"', "never instructions"):
            self.assertIn(part, txt)
        self.assertNotIn(bj.BODY_OPEN, txt)
        self.assertNotIn("Night Drive</", txt)                               # no rendered body in the instructions


class RunBatchTests(unittest.TestCase):
    def test_a_clean_batch_passes_and_may_apply(self):
        p = FakeProvider({})
        row, coded = cli.run_batch([item(1), item(2)], "/e1", provider=p)
        self.assertEqual((row["verdict"], row["stop_ids"], coded), ("pass", [], {}))
        self.assertTrue(bj.may_apply(row, row["batch_sha"]))
        self.assertEqual(len(p.prompts), 1)                                   # ONE call for the batch

    def test_a_coded_stop_never_reaches_the_model_and_stops_the_batch(self):
        p = FakeProvider({})
        k = item(3, facts={**ASK, "class": "team_review", "owes_proof": True})          # the 02Z /k class error
        row, coded = cli.run_batch([item(1), k], "/k", provider=p)
        self.assertEqual(row["verdict"], "stop")
        self.assertEqual(row["stop_ids"], ["3"])
        self.assertIn("coded_stop:1", row["reasons"])
        self.assertNotIn("<<<RENDERED BODY id=3>>>", p.prompts[0])           # never sent to the model
        self.assertFalse(bj.may_apply(row, row["batch_sha"]))
        only, _ = cli.run_batch([k], "/k", provider=p)                       # every body coded: no call at all
        self.assertEqual((only["verdict"], only["stop_ids"], len(p.prompts)), ("stop", ["3"], 1))

    def test_a_numeric_id_is_the_same_body_as_its_string(self):
        p = FakeProvider({})
        bad = {"id": 123, "user_id": 123, "body": BODY.replace("we&#39;ll check it", "nothing else is needed"),
               "facts": dict(ASK)}
        row, coded = cli.run_batch([bad, {**item(5), "id": 5}], "/e1", provider=p)
        self.assertEqual(set(coded), {"123"})
        self.assertNotIn("<<<RENDERED BODY id=123>>>", p.prompts[0])        # the coded stop never reaches the model
        self.assertEqual((row["verdict"], row["stop_ids"]), ("stop", ["123"]))

    def test_a_model_stop_stops_the_batch(self):
        row, _ = cli.run_batch([item(1), item(2)], "/e1", provider=FakeProvider({"2": "stop"}))
        self.assertEqual((row["verdict"], row["stop_ids"]), ("stop", ["2"]))
        self.assertFalse(bj.may_apply(row, row["batch_sha"]))

    def test_the_batch_sha_covers_the_rules_version(self):
        a, _ = cli.run_batch([item(1)], "/e1", provider=FakeProvider({}))
        old = bi.INSTRUCTIONS_VERSION
        try:
            bi.INSTRUCTIONS_VERSION = "changed"
            b, _ = cli.run_batch([item(1)], "/e1", provider=FakeProvider({}))
        finally:
            bi.INSTRUCTIONS_VERSION = old
        self.assertNotEqual(a["batch_sha"], b["batch_sha"])
        self.assertEqual(json.loads(json.dumps(a, default=str))["instructions_version"], old)


class EvalLedgerTests(unittest.TestCase):
    def test_eval_refuses_an_empty_case_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            empty = Path(d) / "cases.jsonl"
            empty.write_text("\n", encoding="utf-8")
            with self.assertRaises(SystemExit) as cm:
                old, sys.stderr = sys.stderr, io.StringIO()
                try:
                    cli.main(["eval", "--cases", str(empty), "--ledger", str(Path(d) / "l.sqlite3")])
                finally:
                    sys.stderr = old
            self.assertEqual(cm.exception.code, 2)

    def test_eval_refuses_without_a_ledger_and_refuses_the_production_one(self):
        from credit_trust.ledger import DEFAULT_PATH
        for argv in (["eval", "--cases", "x.jsonl"], ["eval", "--cases", "x.jsonl", "--ledger", DEFAULT_PATH]):
            with self.assertRaises(SystemExit) as cm:
                old, sys.stderr = sys.stderr, io.StringIO()
                try:
                    cli.main(argv)
                finally:
                    sys.stderr = old
            self.assertEqual(cm.exception.code, 2, argv)


if __name__ == "__main__":
    unittest.main()
