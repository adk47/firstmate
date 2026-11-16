"""The stage-2 gap split (credit_review/stage2_gap.py): every `gap_reason` branch is recovered as
its own class, the routing table is the reviewer's ruling of 2026-11-16 and nothing else, and a
held class is never carried into an audience by an armed sibling.

The classifier reads `gap_reason`'s prose, so the first class of tests runs the REAL function for
every branch it can emit. A new branch in `gap_reason` that this module does not recover lands in
`unclassified`, which is held - and `test_every_branch_is_recovered` fails, so it cannot ship
silently. No network, no Trino, no store."""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))

from credit_review import stage2_gap, stage2_verdicts  # noqa: E402
from credit_verify.proof import stage2  # noqa: E402

TITLE = "Midnight Drive"
ROLE = "producer"


def request(title=TITLE):
    return stage2.Request(request_id="r1", user_id=7, status="unverified", roles=[ROLE], title=title,
                          artists=["Neon Hours"], popularity=40, track_id="t1", isrc="US1234567890",
                          release_date="2025-01-01", created_at="2026-01-01T00:00:00Z", names=["Dana"])


def doc(**kw):
    """A `best` document as `gap_reason` reads it. `source_ref` is the three-part Intercom ref."""
    base = {"verdict": "PLAUSIBLE", "proof_id": "p1", "source_ref": "intercom:conv-41214:0",
            "kind": "split_sheet", "track_listed": False, "named": None, "lists": [],
            "soft": [], "signals": []}
    base.update(kw)
    return base


# One `best` document per branch of `gap_reason`, in that function's own order, with the class the
# reviewer's ruling gives it. `None` means HELD.
BRANCHES = (
    ("could not be read", doc(soft=["reject_unaccepted_type"], signals=["reject_unaccepted_type"]),
     stage2_gap.UNREADABLE),
    ("another recording's ISRC", doc(signals=["isrc_other_recording"]), stage2_gap.ISRC_OTHER_RECORDING),
    ("names the track, not the person", doc(track_listed=True, named=False), stage2_gap.NOT_NAMED),
    ("names the track, not the role", doc(track_listed=True, signals=["claimed_role_not_listed"]),
     stage2_gap.ROLE_NOT_LISTED),
    ("names the track, cannot show the role", doc(track_listed=True, signals=["claimed_role_not_expressible"]),
     stage2_gap.ROLE_NOT_EXPRESSIBLE),
    ("shares do not add up", doc(track_listed=True, signals=["split_shares_do_not_add_up"]),
     stage2_gap.SHARES_DO_NOT_ADD_UP),
    ("track only in unrendered text", doc(track_listed=True, signals=["claim_text_not_rendered"]),
     stage2_gap.CLAIM_TEXT_NOT_RENDERED),
    ("names the track, cannot confirm", doc(track_listed=True), stage2_gap.CANNOT_CONFIRM),
    ("covers other tracks", doc(lists=["Neon Hours"]), stage2_gap.COVERS_OTHER_TRACKS),
    ("does not name the track", doc(), stage2_gap.TRACK_NOT_NAMED),
)


class ClassifierTests(unittest.TestCase):
    def test_every_branch_is_recovered(self):
        """Every branch `gap_reason` can emit is classified, and as the class the ruling gives it."""
        for label, best, want in BRANCHES:
            with self.subTest(branch=label):
                reason = stage2.gap_reason(request(), ROLE, best, [])
                self.assertEqual(stage2_gap.classify(reason), want, reason)

    def test_no_branch_lands_in_unclassified(self):
        """`unclassified` is held, so a branch landing there would silently stop being asked."""
        for label, best, _ in BRANCHES:
            with self.subTest(branch=label):
                self.assertNotEqual(stage2_gap.classify(stage2.gap_reason(request(), ROLE, best, [])),
                                    stage2_gap.UNCLASSIFIED)

    def test_the_covers_branch_is_not_read_as_track_not_named(self):
        """Both branches say "does not name"; only the covers branch has the ", not " clause."""
        covers = stage2.gap_reason(request(), ROLE, doc(lists=["Neon Hours"]), [])
        missing = stage2.gap_reason(request(), ROLE, doc(), [])
        self.assertIn(", not ", covers)
        self.assertNotIn(", not ", missing)
        self.assertNotEqual(stage2_gap.classify(covers), stage2_gap.classify(missing))

    def test_a_track_title_cannot_choose_the_class(self):
        """The reason is prose with the request's own title interpolated into it, so a title that
        reads like another branch's fixed wording must not move the row. QA finding on #2088: a
        track called "A could not be read (file type or size); for B" made a held
        `track_not_named` row read as the armed `unreadable` class, and the ask would then have
        opened "we could not read your file" about a file we read."""
        for title in ("A could not be read (file type or size); for B",
                      "A covers X, not Y; for Z",
                      "A names B but does not show your name; we need a document for C",
                      "A names B but not the role you claimed (writer); we need a document for D",
                      "A carries the ISRC of a different recording than B; for C"):
            with self.subTest(title=title):
                reason = stage2.gap_reason(request(title=title), ROLE, doc(), [])
                self.assertEqual(stage2_gap.classify(reason), stage2_gap.TRACK_NOT_NAMED, reason)
                self.assertIsNone(stage2_gap.ROUTES[stage2_gap.classify(reason)])

    def test_a_title_that_reads_like_the_armed_branch_does_not_hold_an_unreadable_row(self):
        """The same anchoring in the other direction: the armed class is still recovered when the
        title is worded like a held branch, so the fix does not cost the one class we may ask."""
        for title in ("A does not name B or its ISRC; for C", "A covers X, not Y; for Z"):
            with self.subTest(title=title):
                reason = stage2.gap_reason(request(title=title), ROLE,
                                           doc(soft=["reject_unaccepted_type"],
                                               signals=["reject_unaccepted_type"]), [])
                self.assertEqual(stage2_gap.classify(reason), stage2_gap.UNREADABLE, reason)

    def test_a_title_that_cannot_be_read_as_one_quoted_token_is_held(self):
        """A title carrying the closing quote breaks the grammar, so the row is `unclassified` -
        held, never sent. The failure direction is "never sent", not "sent with wrong words"."""
        reason = stage2.gap_reason(request(title='A” could not be read (file type or size); for B'),
                                   ROLE, doc(), [])
        self.assertEqual(stage2_gap.classify(reason), stage2_gap.UNCLASSIFIED, reason)
        self.assertIsNone(stage2_gap.ROUTES[stage2_gap.UNCLASSIFIED])

    def test_a_pre_1297_reason_is_unclassified_and_so_held(self):
        """Rows written before #1297 carry the analyzer's own text, not `gap_reason` prose."""
        for old in ("PLAUSIBLE: The document doesn't show your name.; The document can't show the role you claimed.",
                    "SUSPECT: nothing in the document ties it to this track",
                    "INCONSISTENT: Your name doesn't appear in the document.",
                    ""):
            with self.subTest(reason=old):
                self.assertEqual(stage2_gap.classify(old), stage2_gap.UNCLASSIFIED)
                self.assertIsNone(stage2_gap.ROUTES[stage2_gap.UNCLASSIFIED])

    def test_a_request_is_one_class_only_when_every_role_agrees(self):
        """A request whose roles disagree is `mixed`, which is held: one note cannot carry two gaps."""
        same = {"producer": verdict("r1", "producer", reason=stage2.gap_reason(request(), ROLE, doc(), [])),
                "writer": verdict("r1", "writer", reason=stage2.gap_reason(request(), ROLE, doc(), []))}
        self.assertEqual(stage2_gap.request_class(same), stage2_gap.TRACK_NOT_NAMED)
        differ = dict(same)
        differ["writer"] = verdict("r1", "writer",
                                   reason=stage2.gap_reason(request(), ROLE, doc(lists=["Neon Hours"]), []))
        self.assertEqual(stage2_gap.request_class(differ), stage2_gap.MIXED)
        self.assertIsNone(stage2_gap.ROUTES[stage2_gap.MIXED])


class RoutingTests(unittest.TestCase):
    def test_the_armed_classes_are_the_reviewers_ruling_and_nothing_else(self):
        """2026-11-16: only the file we could not read. Class 2 was withdrawn for a pending request."""
        self.assertEqual(set(stage2_gap.ARMED), {stage2_gap.UNREADABLE})

    def test_the_held_classes_are_the_reviewers_holds(self):
        """Every class whose document WAS read: the document ask's opening is false for it, and
        class 2 asserts a decided result a pending request does not have."""
        self.assertEqual(set(stage2_gap.HELD),
                         {stage2_gap.NOT_NAMED, stage2_gap.TRACK_NOT_NAMED, stage2_gap.COVERS_OTHER_TRACKS,
                          stage2_gap.ROLE_NOT_LISTED, stage2_gap.ROLE_NOT_EXPRESSIBLE,
                          stage2_gap.SHARES_DO_NOT_ADD_UP, stage2_gap.CLAIM_TEXT_NOT_RENDERED,
                          stage2_gap.ISRC_OTHER_RECORDING, stage2_gap.CANNOT_CONFIRM,
                          stage2_gap.UNCLASSIFIED, stage2_gap.MIXED})

    def test_every_class_is_either_armed_or_held(self):
        """The table is the allowlist: a class missing from it would be sent by being forgotten."""
        every = {code for _, code in stage2_gap.GRAMMAR} | {stage2_gap.COVERS_OTHER_TRACKS,
                                                            stage2_gap.CANNOT_CONFIRM,
                                                            stage2_gap.UNCLASSIFIED, stage2_gap.MIXED}
        self.assertEqual(every, set(stage2_gap.ROUTES))
        self.assertEqual(set(stage2_gap.ARMED) | set(stage2_gap.HELD), set(stage2_gap.ROUTES))
        self.assertFalse(set(stage2_gap.ARMED) & set(stage2_gap.HELD))

    def test_the_unreadable_class_routes_to_the_document_ask(self):
        """The reviewer: need line (c), and {document} reads "the file you sent on ..."."""
        route = stage2_gap.ROUTES[stage2_gap.UNREADABLE]
        self.assertEqual(route.campaign, "proof-need-ask")
        self.assertEqual(route.copy, "proofneed")

    def test_no_class_routes_to_class_2(self):
        """Class 2 is the message for a DECIDED request; every row here is still pending, so
        "{title} was not verified" and "Without it, the result stands" would both be false."""
        for code, route in stage2_gap.ROUTES.items():
            with self.subTest(cls=code):
                self.assertFalse(route is not None and route.campaign == "proof-refusal")
                self.assertFalse(route is not None and route.copy == "refusal")


def verdict(rid, role, *, reason="", user_id=7, paid=1, outcome="need_more", doc_kind="split_sheet"):
    return stage2_verdicts.Verdict(request_id=rid, role=role, user_id=user_id, paid=paid, outcome=outcome,
                                   reason=reason, doc_kind=doc_kind, proof_id="p1", lists=(),
                                   judged_at="2026-11-15T00:00:00Z")


def store(*rows):
    """{request id: {role: Verdict}} from (rid, role, reason, user_id, paid) tuples."""
    out = {}
    for rid, role, reason, user_id, paid in rows:
        out.setdefault(rid, {})[role] = verdict(rid, role, reason=reason, user_id=user_id, paid=paid)
    return out


COVERS = stage2.gap_reason(request(), ROLE, doc(lists=["Neon Hours"]), [])
MISSING = stage2.gap_reason(request(), ROLE, doc(), [])
UNREAD = stage2.gap_reason(request(), ROLE, doc(soft=["reject_unaccepted_type"]), [])
OTHER_ROLE = stage2.gap_reason(request(), ROLE, doc(track_listed=True, signals=["claimed_role_not_listed"]), [])


class SplitTests(unittest.TestCase):
    def test_the_split_counts_requests_users_and_paid_per_class(self):
        v = store(("r1", "producer", MISSING, 7, 1), ("r2", "producer", MISSING, 7, 1),
                  ("r3", "producer", COVERS, 8, 0), ("r4", "producer", UNREAD, 9, 1),
                  ("r5", "producer", OTHER_ROLE, 10, 1))
        rows = stage2_gap.split(v, sorted(v))
        self.assertEqual(rows[stage2_gap.TRACK_NOT_NAMED]["requests"], 2)
        self.assertEqual(rows[stage2_gap.TRACK_NOT_NAMED]["users"], 1)
        self.assertEqual(rows[stage2_gap.TRACK_NOT_NAMED]["paid_requests"], 2)
        self.assertEqual(rows[stage2_gap.COVERS_OTHER_TRACKS]["users"], 1)
        self.assertEqual(rows[stage2_gap.UNREADABLE]["route"], "proof-need-ask")
        self.assertEqual(rows[stage2_gap.TRACK_NOT_NAMED]["route"], "held")
        self.assertEqual(rows[stage2_gap.ROLE_NOT_LISTED]["copy"], "")

    def test_a_held_class_is_never_carried_by_an_armed_sibling(self):
        """A user with one armed and one held request is listed with the armed id only."""
        v = store(("r1", "producer", UNREAD, 7, 1), ("r2", "producer", MISSING, 7, 1))
        rows = stage2_gap.audience(v, sorted(v), [stage2_gap.UNREADABLE])
        self.assertEqual([u["request_ids"] for u in rows], [["r1"]])

    def test_a_user_with_only_held_requests_is_listed_nowhere(self):
        v = store(("r1", "producer", OTHER_ROLE, 7, 1))
        self.assertEqual(stage2_gap.audience(v, sorted(v), list(stage2_gap.ARMED)), [])

    def test_the_audience_is_paid_first_then_by_user_id(self):
        v = store(("r1", "producer", UNREAD, 9, 0), ("r2", "producer", UNREAD, 8, 1),
                  ("r3", "producer", UNREAD, 7, 1))
        rows = stage2_gap.audience(v, sorted(v), [stage2_gap.UNREADABLE])
        self.assertEqual([u["user_id"] for u in rows], [7, 8, 9])
        self.assertEqual([u["paid"] for u in rows], [True, True, False])

    def test_a_request_with_no_verdict_is_not_counted(self):
        v = store(("r1", "producer", MISSING, 7, 1))
        rows = stage2_gap.split(v, ["r1", "r2"])
        self.assertEqual(sum(r["requests"] for r in rows.values()), 1)


STAGE2_SCHEMA = """CREATE TABLE stage2_shadow (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
  judged_at TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER, paid INTEGER,
  popularity INTEGER, tier TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, verdict TEXT, proof_id TEXT,
  source_ref TEXT, doc_kind TEXT, documents INTEGER NOT NULL, detail_json TEXT NOT NULL, analyzer_version TEXT);"""


def stage2_store(rows, outcome="need_more"):
    """A proof store holding only stage2_shadow, with one row per (rid, role, reason, user, paid, proof)."""
    import sqlite3
    import tempfile
    from credit_verify.proof import FORENSICS_VERSION
    path = tempfile.NamedTemporaryFile(suffix="-proof.sqlite", delete=False).name
    db = sqlite3.connect(path)
    db.execute(STAGE2_SCHEMA)
    for rid, role, reason, uid, paid, proof in rows:
        db.execute("INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, paid, popularity, tier,"
                   " outcome, reason, verdict, proof_id, source_ref, doc_kind, documents, detail_json,"
                   " analyzer_version) VALUES ('run1','2026-11-15T00:00:00Z',?,?,?,?,40,'T1',?,?,"
                   " 'PLAUSIBLE',?,'intercom:conv-1:0','split_sheet',1,'[]',?)",
                   (rid, role, uid, paid, outcome, reason, proof, FORENSICS_VERSION))
    db.commit()
    db.close()
    return path


class CliOutputTests(unittest.TestCase):
    def test_the_written_audience_is_owner_only(self):
        """The audience is a customer list (user ids, request ids, paid flags): never world-readable."""
        import os
        import stat
        import tempfile
        out = os.path.join(tempfile.mkdtemp(), "audience.json")
        path = stage2_store([("r1", "producer", UNREAD, 7, 1, "sha-unread")])
        rc = stage2_gap._main(["--db", path, "audience", "--classes", stage2_gap.UNREADABLE, "--out", out])
        self.assertEqual(rc, 0)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)


class EmptyRunTests(unittest.TestCase):
    def test_an_audience_run_with_no_candidates_writes_nothing_and_exits_zero(self):
        """The first-run path against a store with nothing released must not raise."""
        import json
        import os
        import tempfile
        out = os.path.join(tempfile.mkdtemp(), "audience.json")
        path = stage2_store([("r1", ROLE, UNREAD, 7, 1, "sha-unread")], outcome="review")
        rc = stage2_gap._main(["--db", path, "audience", "--classes", stage2_gap.UNREADABLE, "--out", out])
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(out))
        with open(out, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["users"], [])

    def test_an_empty_released_set_still_counts_every_class(self):
        """Nothing released is a complete table of zeros, not an empty one."""
        path = stage2_store([("r1", ROLE, UNREAD, 7, 1, "sha-unread")], outcome="no_document")
        counted = stage2_gap.counts(path)
        self.assertEqual(counted["released_requests"], 0)
        self.assertEqual(counted["released_users"], 0)
        self.assertEqual(sorted(counted["classes"]), sorted(stage2_gap.ROUTES))
        self.assertEqual(sum(r["requests"] for r in counted["classes"].values()), 0)
        rows = stage2_gap.split({}, set())
        self.assertEqual(sorted(rows), sorted(stage2_gap.ROUTES))
        self.assertEqual([r["users"] for r in rows.values()], [0] * len(rows))
        self.assertEqual(stage2_gap._main(["--db", path, "counts"]), 0)


if __name__ == "__main__":
    unittest.main()