"""dup-dsp-absorb rule + the eligible-only merge executor. Everything is faked; nothing merges."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from merge_execute import absorb  # noqa: E402

_spec = importlib.util.spec_from_file_location("merge_execute_cli", ROOT / "scripts" / "merge-execute.py")
mx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mx)  # type: ignore[union-attr]

SV = "11111111-1111-4111-8111-111111111111"   # requester's claimed profile (survivor)
SO = "22222222-2222-4222-8222-222222222222"   # unclaimed linked copy (source)
RAW = "spotify:abc123"


def reading(track, name="Jane Doe", raw=RAW, holder=SO, credit="Songwriter", captured=True, same_run=True):
    return {"track": track, "captured": captured, "same_run": same_run, "credited": [[name, credit, raw, holder]]}


def good(**over):
    f = {"user_id": 77, "survivor": SV, "source": SO, "holds": [],
         "survivor_claims": [{"status": "processed", "user_id": "77", "team_id": "t1"}], "requester_teams": ["t1"],
         "source_claims": [], "source_identity": [],
         "survivor_profile": {"sub_type": "artist", "merged_to": None, "deleted": False, "credits": 10},
         "source_profile": {"sub_type": "artist", "merged_to": None, "deleted": False, "credits": 40},
         "in_flight": False, "person_name": "Jane Doe", "name_collisions": 0,
         "readings": [reading(f"t{i}") for i in range(3)], "source_raw_ids": [RAW]}
    f.update(over)
    return f


class Rule(unittest.TestCase):
    def test_eligible_shape(self):
        v = absorb.decide(good())
        self.assertEqual(v["verdict"], "eligible", v)
        self.assertEqual((v["into"], v["source"], v["n_ties"]), (SV, SO, 3))

    def test_every_gate(self):
        cases = {
            "held": good(holds=["R8_account_hold"]),
            "NOT_REQUESTERS_CLAIM": good(survivor_claims=[{"status": "processed", "user_id": "9", "team_id": "t9"}]),
            "SOURCE_CLAIMED": good(source_claims=[{"status": "pending"}]),
            "SOURCE_IS_IDENTITY": good(source_identity=["9"]),
            "SOURCE_TYPE": good(source_profile={"sub_type": "compilation_profile", "credits": 5}),
            "ORG": good(survivor_profile={"sub_type": "organization", "credits": 5}),
            "MERGED_OR_IN_FLIGHT": good(in_flight=True),
            "SAME_PERSON": good(readings=[reading("t1"), reading("t2")]),
            "UNREAD": good(holds=None),
            "BAD_INPUT": good(source=SV),
        }
        for want, f in cases.items():
            v = absorb.decide(f)
            self.assertTrue(v["code"] == want or v["verdict"] == want, (want, v))
            self.assertNotEqual(v["verdict"], "eligible", want)

    def test_team_claim_of_the_requester_counts_rejected_source_claim_does_not_block(self):
        self.assertEqual(absorb.decide(good(survivor_claims=[{"status": "processed", "user_id": None, "team_id": "t1"}]))["verdict"], "eligible")
        self.assertEqual(absorb.decide(good(source_claims=[{"status": "rejected"}]))["verdict"], "eligible")
        # QA #1556: 'reverted' is core AWAITING_REVIEW; any unknown / missing status is not assumed dead
        for st in ("reverted", "processed", "pending", "intent_pending", "on_hold", "", None):
            self.assertEqual(absorb.decide(good(source_claims=[{"status": "rejected"}, {"status": st}]))["code"],
                             "SOURCE_CLAIMED", st)

    def test_ties_need_captured_same_run_exact_name_and_the_sources_id(self):
        for bad in (reading("t3", captured=False), reading("t3", same_run=False), reading("t3", name="Jane Does"),
                    reading("t3", raw="spotify:other", holder="x")):
            v = absorb.decide(good(readings=[reading("t1"), reading("t2"), bad]))
            self.assertEqual(v["code"], "SAME_PERSON", bad)

    def test_same_track_twice_counts_once(self):
        self.assertEqual(absorb.decide(good(readings=[reading("t1"), reading("t1"), reading("t2")]))["code"], "SAME_PERSON")

    def test_label_publisher_under_the_sources_id_blocks_whatever_the_displayed_name(self):
        # QA #1556: three Jane Doe Songwriter ties + an 'Acme Publishing' Publisher credit under the SAME source id
        f = good(readings=[reading(f"t{i}") for i in range(3)] + [reading("t1", name="Acme Publishing", credit="Publisher")])
        self.assertEqual(absorb.decide(f)["code"], "LABEL_PUBLISHER")
        # a label credit under a DIFFERENT id is not the source's
        f = good(readings=[reading(f"t{i}") for i in range(3)] + [reading("t1", name="Acme", credit="Publisher", raw="spotify:zz", holder=None)])
        self.assertEqual(absorb.decide(f)["verdict"], "eligible")

    def test_common_name_passes_only_without_a_rival_id(self):
        v = absorb.decide(good(name_collisions=4))
        self.assertEqual(v["verdict"], "eligible")
        self.assertTrue(v["common_name"])
        rival = good(name_collisions=4, readings=[reading(f"t{i}") for i in range(3)] + [reading("t9", raw="spotify:zzz", holder=None)])
        self.assertEqual(absorb.decide(rival)["code"], "COMMON_NAME")
        self.assertEqual(absorb.decide(good(person_name="Sissi", readings=[reading(f"t{i}", name="Sissi") for i in range(3)]))["common_name"], True)

    def test_unknown_collisions_is_common(self):
        self.assertTrue(absorb.is_common_name("Jane Doe", None)[0])

    def test_label_roles_never_count_and_block(self):
        f = good(readings=[reading(f"t{i}") for i in range(3)] + [reading("t8", credit="Record Label")])
        self.assertEqual(absorb.decide(f)["code"], "LABEL_PUBLISHER")
        only_label = good(readings=[reading(f"t{i}", credit="Publisher") for i in range(5)])
        self.assertEqual(absorb.decide(only_label)["code"], "SAME_PERSON")


SA2 = "33333333-3333-4333-8333-333333333333"   # a SECOND claimed profile of the same user


def packet(track, person="Jane Doe", holder=SO, raw=RAW, requested_at="2026-11-01T10:00:00Z",
           captured_at="2026-11-01T10:05:00Z", state="CAPTURED"):
    return json.dumps({"capture": {"person_name": person, "requested_at": requested_at,
                                   "roles": {"songwriter": {"sources": {"spotify": {
                                       "state": state, "captured_at": captured_at,
                                       "credited_in_family": [[person, "Songwriter", True, raw, holder]]}}}},
                                   "name_collisions": 0}})


class StorePairs(unittest.TestCase):
    """QA #1556 (critical): DSP evidence must never cross a request."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.store = str(Path(self.dir) / "dsp.sqlite")
        st = __import__("sqlite3").connect(self.store)
        st.executescript("""
            CREATE TABLE dsp_runs (run_id TEXT, kind TEXT);
            CREATE TABLE dsp_verdicts (id INTEGER PRIMARY KEY, run_id TEXT, request_id TEXT, user_id INTEGER,
                profile_id TEXT, track_id TEXT, paid INTEGER, packet_json TEXT, reason_class TEXT, version TEXT);
        """)
        st.execute("INSERT INTO dsp_runs VALUES ('run1','verify')")
        self.st = st

    def add(self, request_id, profile_id, track, **kw):
        self.st.execute("INSERT INTO dsp_verdicts (run_id, request_id, user_id, profile_id, track_id, paid, packet_json,"
                        " reason_class, version) VALUES ('run1',?,77,?,?,1,?,'needs_profile_link','dsp-1')",
                        (request_id, profile_id, track, packet(track, holder=kw.pop("holder", SO), **kw)))

    def pairs(self):
        self.st.commit()
        return {(p["user_id"], p["survivor"]): p for p in mx.store_pairs(self.store)}

    def test_three_ties_for_one_presented_profile_never_leak_into_another(self):
        for t in ("t1", "t2", "t3"):
            self.add(f"req-{t}", SV, t)                  # three requests, all presenting the CLAIMED profile SV
        self.add("req-z", SA2, "t9")                     # a separate request presenting ANOTHER claimed profile
        got = self.pairs()
        a = got[(77, SV)]
        b = got[(77, SA2)]
        self.assertEqual(len(a["readings"]), 3)
        self.assertEqual(len(b["readings"]), 1, "the second presented profile must carry ONLY its own reading")
        self.assertEqual([r["track"] for r in b["readings"]], ["t9"])
        self.assertEqual(b["source_raw_ids"], [RAW], "the holder's ids come from this presented profile only")
        base = {"user_id": 77, "holds": [], "requester_teams": ["t1"],
                "survivor_claims": [{"status": "processed", "user_id": "77", "team_id": "t1"}],
                "source_claims": [], "source_identity": [], "in_flight": False,
                "survivor_profile": {"sub_type": "artist", "credits": 1},
                "source_profile": {"sub_type": "artist", "credits": 9}}
        keys = ("survivor", "source", "person_name", "name_collisions", "readings", "source_raw_ids")
        vb = absorb.decide({**base, **{k: b[k] for k in keys}})
        self.assertEqual((vb["verdict"], vb["code"], vb["n_ties"]), ("needs_evidence", "SAME_PERSON", 1), vb)
        va = absorb.decide({**base, **{k: a[k] for k in keys}})
        self.assertEqual((va["verdict"], va["n_ties"]), ("eligible", 3), va)

    def test_the_pool_is_one_presented_profile_and_every_request_that_presented_it(self):
        self.add("req-1", SV, "t1")
        self.add("req-2", SV, "t2")
        p = self.pairs()[(77, SV)]
        self.assertEqual(sorted(p["request_ids"]), ["req-1", "req-2"])
        self.assertEqual(sorted(r["track"] for r in p["readings"]), ["t1", "t2"])

    def test_a_reading_captured_before_its_own_request_is_not_a_tie(self):
        self.add("req-A", SV, "t1")
        self.add("req-B", SV, "t2", captured_at="2026-11-01T09:00:00Z")   # BEFORE req-B was made
        p = self.pairs()[(77, SV)]
        self.assertEqual({r["track"]: r["same_run"] for r in p["readings"]}, {"t1": True, "t2": False})
        base = {"user_id": 77, "holds": [], "requester_teams": ["t1"],
                "survivor_claims": [{"status": "processed", "user_id": "77", "team_id": "t1"}],
                "source_claims": [], "source_identity": [], "in_flight": False,
                "survivor_profile": {"sub_type": "artist", "credits": 1},
                "source_profile": {"sub_type": "artist", "credits": 9}}
        keys = ("survivor", "source", "person_name", "name_collisions", "readings", "source_raw_ids")
        v = absorb.decide({**base, **{k: p[k] for k in keys}})
        self.assertEqual((v["verdict"], v["n_ties"]), ("needs_evidence", 1), v)


class Executor(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.kill = os.path.join(self.tmp, "merge-executor.disabled")
        mx.KILL, mx.STATE_DIR, mx.MUSO_CONFIG = self.kill, Path(self.tmp) / "state", Path(self.tmp) / "muso"
        self.calls = []
        self.cat_state = {"after": False}

    def row(self):
        return {"run": "R1", "user_id": 77, "paid": True, "survivor": SV, "source": SO, "verdict": "eligible",
                "person_name": "Jane Doe", "name_collisions": 0, "readings": [reading(f"t{i}") for i in range(3)],
                "source_raw_ids": [RAW]}

    def q(self, sql):
        if "FROM postgresql_core.public.claiming" in sql:
            return [{"p": SV, "status": "processed", "u": "77", "t": "t1"}]
        if "team_users" in sql:
            return [{"t": "t1"}]
        if "profile_merges" in sql and "IN (" in sql and "status IN" in sql:
            return []
        if "profile_merges" in sql:
            return [{"status": "verified"}] if self.cat_state["after"] else []
        return []

    def cat(self, ids):
        if self.cat_state["after"]:
            return {SV: {"sub_type": "artist", "merged_to": None, "deleted": False, "credits": self.cat_state.get("sv_after", 45)},
                    SO: {"sub_type": "artist", "merged_to": SV, "deleted": True, "credits": 40}}
        return {SV: {"sub_type": "artist", "merged_to": None, "deleted": False, "credits": 10},
                SO: {"sub_type": "artist", "merged_to": None, "deleted": False, "credits": 40}}

    def sh(self, cmd, **kw):
        self.calls.append(cmd)
        self.cat_state["after"] = True

        class P:
            returncode, stdout, stderr = 0, "", ""
        return P()

    def pairs(self, rows=None, **over):
        out = []
        for r in rows or [self.row()]:
            out.append({k: r[k] for k in ("user_id", "paid", "survivor", "source", "person_name", "name_collisions",
                                          "readings", "source_raw_ids")} | over)
        return lambda: out

    def go(self, apply=True, rows=None, pairs=None):
        out = StringIO()
        with redirect_stdout(out):
            rc = mx.run(rows or [self.row()], "R1", apply, "captain-1030-131x", q=self.q, cat=self.cat,
                        hold=lambda uid: [], sh=self.sh, sleep=lambda s: None, pairs=pairs or self.pairs(rows))
        return rc, [json.loads(x) for x in out.getvalue().splitlines()]

    def test_dry_run_merges_nothing(self):
        rc, ev = self.go(apply=False)
        self.assertEqual((rc, self.calls), (0, []))
        self.assertEqual(ev[0]["event"], "would_merge")
        self.assertIn("--into " + SV, ev[0]["cmd"])
        self.assertIn("decider-R1|l7-1030", ev[0]["cmd"])

    def test_apply_writes_the_decider_record_then_merges_and_reads_back(self):
        rc, ev = self.go()
        self.assertEqual(rc, 0)
        self.assertEqual(ev[-1]["event"], "merged")
        rec = json.loads((mx.MUSO_CONFIG / "merge-decisions.jsonl").read_text())
        self.assertEqual((rec["run"], rec["into"], rec["from"]), ("R1", SV, [SO]))
        self.assertEqual(self.calls[0][self.calls[0].index("--into") + 1], SV)
        self.assertEqual(self.calls[0][self.calls[0].index("--from") + 1], SO)

    def test_readback_accepts_only_a_verified_ledger_row(self):
        # QA #1556 (important): a redirected source + moved credits with an EMPTY profile_merges read is unverified
        ok, why = mx.readback(self.row(), {SV: {"credits": 10}, SO: {"credits": 40}}, self._q_ledger([]), self.cat,
                              sleep=lambda s: None, budget_s=60)
        self.assertFalse(ok, why)
        self.assertIn("no verified ledger row", why)
        # a pending row is not done either
        ok, why = mx.readback(self.row(), {SV: {"credits": 10}, SO: {"credits": 40}},
                              self._q_ledger([{"status": "callback_received"}]), self.cat, sleep=lambda s: None, budget_s=60)
        self.assertFalse(ok, why)
        self.assertIn("callback_received", why)
        # verified AND the catalogue agrees -> success
        self.cat_state["after"] = True
        ok, why = mx.readback(self.row(), {SV: {"credits": 10}, SO: {"credits": 40}},
                              self._q_ledger([{"status": "verified"}]), self.cat, sleep=lambda s: None, budget_s=60)
        self.assertTrue(ok, why)
        self.assertIn("ledger verified", why)
        # verified but the catalogue disagrees is a contradiction: fail now, do not wait it out
        self.cat_state["sv_after"] = 39
        ok, why = mx.readback(self.row(), {SV: {"credits": 10}, SO: {"credits": 40}},
                              self._q_ledger([{"status": "verified"}]), self.cat, sleep=lambda s: None, budget_s=600)
        self.assertFalse(ok, why)
        self.assertIn("catalogue disagrees", why)

    def _q_ledger(self, rows):
        def q(sql):
            if "profile_merges" in sql and "status IN" not in sql:
                return rows
            return self.q(sql)
        return q

    def test_readback_shortfall_stops_everything_and_writes_the_kill_file(self):
        self.cat_state["sv_after"] = 39   # < max(10, 40)
        rc, ev = self.go(rows=[self.row(), {**self.row(), "user_id": 78}])
        self.assertEqual(rc, 4)
        self.assertEqual(ev[-1]["event"], "surprise")
        self.assertTrue(os.path.exists(self.kill))
        self.assertEqual(len(self.calls), 1, "no second merge after a surprise")

    def test_re_decided_ineligible_is_skipped(self):
        def q(sql):
            if "FROM postgresql_core.public.claiming" in sql:
                return [{"p": SV, "status": "processed", "u": "77", "t": "t1"}, {"p": SO, "status": "pending", "u": "5", "t": "x"}]
            return self.q(sql)
        out = StringIO()
        with redirect_stdout(out):
            rc = mx.run([self.row()], "R1", True, "c", q=q, cat=self.cat, hold=lambda u: [], sh=self.sh, sleep=lambda s: None,
                        pairs=self.pairs())
        self.assertEqual((rc, self.calls), (0, []))
        self.assertIn("SOURCE_CLAIMED", out.getvalue())

    def test_kill_file_and_day_cap(self):
        Path(self.kill).write_text("x")
        rc, ev = self.go()
        self.assertEqual((rc, self.calls, ev[0]["event"]), (0, [], "stopped"))
        os.remove(self.kill)
        mx.STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(mx.STATE_DIR / "ledger.jsonl", "w") as fh:
            for _ in range(mx.DAY_CAP):
                fh.write(json.dumps({"at": mx.now_iso(), "event": "merge_sent"}) + "\n")
        rc, ev = self.go()
        self.assertEqual((self.calls, ev[0]["event"]), ([], "stopped"))

    def test_only_eligible_rows_are_considered(self):
        rc, ev = self.go(rows=[{**self.row(), "verdict": "needs_evidence"}])
        self.assertEqual((rc, ev, self.calls), (0, [], []))

    # --- QA #1556 ----------------------------------------------------------------------------------------------
    def test_stale_shadow_evidence_never_merges(self):
        # shadowed with 3 ties; the DSP store now shows only 1 (a contributor link was corrected)
        rc, ev = self.go(pairs=self.pairs(readings=[reading("t1")]))
        self.assertEqual((rc, self.calls), (0, []))
        self.assertEqual(ev[0]["code"], "SAME_PERSON")
        # the pair is gone from the store entirely
        rc, ev = self.go(pairs=lambda: [])
        self.assertEqual((self.calls, ev[0]["code"]), ([], "EVIDENCE_GONE"))
        # the store cannot be read: stop, merge nothing
        def boom():
            raise RuntimeError("locked")
        rc, ev = self.go(pairs=boom)
        self.assertEqual((self.calls, ev[0]["event"]), ([], "stopped"))

    def test_evidence_is_re_read_before_every_pair_not_once_per_run(self):
        # QA #1556: row 2's link is corrected while row 1 is merging; row 2 must see the corrected store
        r1, r2 = self.row(), {**self.row(), "user_id": 78}
        calls = {"n": 0}
        good_pairs = self.pairs([r1, r2])()

        def pairs():
            calls["n"] += 1
            if calls["n"] == 1:
                return good_pairs
            return [good_pairs[0], {**good_pairs[1], "readings": [reading("t1")]}]   # row 2 now has 1 tie
        rc, ev = self.go(rows=[r1, r2], pairs=pairs)
        self.assertEqual(calls["n"], 2, "the store is read once per pair")
        self.assertEqual(len(self.calls), 1, "row 2 must not merge on the stale snapshot")
        self.assertNotEqual(ev[-1]["event"], "merged")

    def test_a_second_executor_is_refused_while_one_runs(self):
        import fcntl
        mx.STATE_DIR.mkdir(parents=True, exist_ok=True)
        held = open(mx.STATE_DIR / "run.lock", "a+")
        fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc, ev = self.go()
        finally:
            fcntl.flock(held.fileno(), fcntl.LOCK_UN); held.close()
        self.assertEqual((rc, self.calls), (0, []))
        self.assertIn("holds the lock", ev[0]["reason"])

    def test_a_timeout_is_uncertain_writes_the_kill_file_and_stops(self):
        import subprocess as sp

        def slow(cmd, **kw):
            self.calls.append(cmd)
            raise sp.TimeoutExpired(cmd, 120)
        self.sh = slow
        rc, ev = self.go(rows=[self.row(), {**self.row(), "user_id": 78}])
        self.assertEqual(rc, 4)
        self.assertEqual(len(self.calls), 1, "no next merge after an uncertain one")
        self.assertTrue(os.path.exists(self.kill))
        self.assertIn("uncertain", ev[-1]["why"])

    # --- r5 [key=unattended] / #1556: the gate inputs are constants, with NO environment path ---------------------
    GATE_ENV = {
        "MERGE_EXECUTOR_DISABLED_FILE": "/tmp/x.disabled",
        "MERGE_EXECUTOR_DIR": "/tmp/x-state",
        "CREDIT_DSP_VERIFY_STORE": "/tmp/x-store.sqlite",
        "MUSO_BIN": "/tmp/x-muso",
        "MUSO_CONFIG_DIR": "/tmp/x-config",
        "MERGE_EXECUTOR_READBACK_S": "1",
        "MERGE_EXECUTOR_CONFIRMER": "someone-else",
        "MERGE_EXECUTOR_REQUESTER": "someone@else",
    }
    PROBE = ("import json,sys;sys.path.insert(0,sys.argv[1]);import importlib.util as u;"
             "s=u.spec_from_file_location('mx',sys.argv[1]+'/merge-execute.py');m=u.module_from_spec(s);s.loader.exec_module(m);"
             "print(json.dumps({k:str(getattr(m,k)) for k in ('KILL','STATE_DIR','STORE','MUSO','MUSO_CONFIG','READBACK_S',"
             "'CONFIRMER','REQUESTER')}))")

    BATS_FILE = str(ROOT / "scripts" / "tests" / "merge-landing-watchdog.bats")

    def probe(self, env=None, harness=None, bats_file=None, version="1.10.0"):
        e = {k: v for k, v in os.environ.items() if not k.startswith("MERGE_EXECUTOR_") and k != "CREDIT_DSP_VERIFY_STORE"}
        for k in ("BATS_TEST_TMPDIR", "BATS_TEST_FILENAME", "BATS_VERSION"):
            e.pop(k, None)
        e.update(env or {})
        if harness:
            # a REAL bats run sets all three; a shell that fakes one of them is not the harness
            e["BATS_TEST_TMPDIR"] = harness
            e["BATS_TEST_FILENAME"] = bats_file if bats_file is not None else self.BATS_FILE
            if version:
                e["BATS_VERSION"] = version
        r = subprocess.run([sys.executable, "-c", self.PROBE, str(ROOT / "scripts")], env=e, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_no_environment_variable_moves_any_gate_input(self):
        # the red-mutant proof r5 asked for: a plain shell moves NOTHING
        const = self.probe()
        self.assertEqual(const["KILL"], "/etc/hydra/merge-executor.disabled")
        self.assertEqual(const["STATE_DIR"], "/var/lib/hydra/merge-executor")
        self.assertEqual(const["STORE"], "/var/lib/hydra-credit-verify/dsp-verify.sqlite")
        self.assertEqual(const["MUSO"], "muso")
        self.assertEqual(const["MUSO_CONFIG"], "/root/.config/muso")
        self.assertEqual(const["READBACK_S"], "1800")
        self.assertEqual(const["CONFIRMER"], "fable-decider")
        self.assertEqual(const["REQUESTER"], "merge-executor@muso.ai")
        self.assertEqual(self.probe(self.GATE_ENV), const, "an env var moved a gate input")

    def test_a_complete_forged_bats_marker_set_moves_nothing(self):
        """QA #1556 critical: the previous seam trusted caller-set bats markers, which any shell can set.

        This is the red case it asked for: the FULL forged set - BATS_TEST_TMPDIR pointing at a real directory,
        BATS_TEST_FILENAME at an existing .bats file, BATS_VERSION at a real 1.x - plus every old override, in one
        ordinary (non-bats) invocation. Nothing may move, because nothing reads the environment any more.
        """
        const = self.probe()
        forged = self.probe(self.GATE_ENV, harness=self.tmp)
        self.assertEqual(forged, const, "a forged bats marker set moved a gate input")
        # the same forged set a second time, with the marker pointing at the checkout's own .bats file
        self.assertEqual(self.probe(self.GATE_ENV, harness=self.tmp, bats_file=str(ROOT / "README.md")), const)

    def test_the_module_reads_no_environment_at_all(self):
        """The reason the forged set above cannot work: there is no environment read left to forge.

        An AST scan, not a grep: it also catches os.getenv, `from os import environ`, and a lookup built from a string.
        """
        import ast
        src = (ROOT / "scripts" / "merge-execute.py").read_text()
        bad = []
        for node in ast.walk(ast.parse(src)):
            if isinstance(node, ast.Attribute) and node.attr in ("environ", "getenv", "environb", "getenvb"):
                bad.append(f"line {node.lineno}: os.{node.attr}")
            if isinstance(node, ast.ImportFrom) and node.module == "os":
                bad += [f"line {node.lineno}: from os import {a.name}" for a in node.names
                        if a.name in ("environ", "getenv", "environb", "getenvb")]
        self.assertEqual(bad, [], f"a gate input can be moved by the environment again: {bad}")
        self.assertNotIn("HARNESS", src)
        self.assertNotIn("_in_bats", src)

    def test_the_test_seam_is_in_process_rebinding_not_an_invocation_input(self):
        # the identity claims are call parameters with constants as defaults: nothing an call can supply reaches them
        cmd = mx.merge_cmd(self.row(), "R1", "captain-1")
        self.assertEqual(cmd[cmd.index("--confirmed-by") + 1], "fable-decider")
        self.assertEqual(cmd[cmd.index("--requester") + 1], "merge-executor@muso.ai")
        self.assertEqual(mx.merge_cmd(self.row(), "R1", "captain-1", confirmer="c",
                                     requester="r")[cmd.index("--confirmed-by") + 1], "c")
        # setUp()'s seam: a module attribute rebind, which a subprocess cannot perform
        self.assertEqual(mx.KILL, self.kill)
        self.assertNotEqual(mx.KILL, "/etc/hydra/merge-executor.disabled")

    def test_apply_needs_the_captain_ref_as_an_argument_never_an_env_var(self):
        sh = Path(self.tmp) / "shadow.jsonl"
        sh.write_text(json.dumps({**self.row(), "run": "R1"}) + "\n")
        base = ["run", "--shadow", str(sh), "--apply"]

        def cli(extra, env=None):
            e = {k: v for k, v in os.environ.items() if k != "MERGE_EXECUTOR_CAPTAIN_REF"}
            e.pop("MERGE_EXECUTOR_DISABLED_FILE", None)
            e.update(env or {})
            return subprocess.run([sys.executable, str(ROOT / "scripts" / "merge-execute.py")] + base + extra,
                                  env=e, capture_output=True, text=True)
        r = cli([])
        self.assertEqual(r.returncode, 1, r.stderr[-400:])
        self.assertIn("--captain-ref", r.stderr)
        r = cli(["--captain-ref", "fable-1"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("must start with captain-", r.stderr)
        r = cli([], env={"MERGE_EXECUTOR_CAPTAIN_REF": "captain-1"})   # the old env path: refused, not honoured
        self.assertEqual(r.returncode, 1)
        self.assertIn("--captain-ref", r.stderr)
        src = (ROOT / "scripts" / "merge-execute.py").read_text()
        self.assertNotIn("MERGE_EXECUTOR_CAPTAIN_REF", src)

    def test_never_runs_any_command_but_profiles_merge(self):
        self.go()
        self.assertTrue(all(c[3:5] == ["profiles", "merge"] for c in self.calls))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
