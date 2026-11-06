"""scripts/clickup_drain/profile_claim.py: the drainer never writes past its four
determinations, never approves, and never sends anything.

Stdlib unittest, no network: the ClickUp client, the replica runner and the
account gate are all injected/faked, so nothing in this suite can reach the
board, Trino or a claim. The live behaviour these lock, in the order they bit us:

  * a pending claim with nothing submitted and no recorded ask writes NOTHING
    (an "awaiting proof" tag on a customer we never spoke to is a lie);
  * a contradiction is a TRAY ROW, never a reject written here;
  * a human's reject (no executor audit row) is reported, never inferred;
  * the cap is a ceiling, and a write that does not read back stops the run;
  * `--revert` deletes only tags that were absent before AND read back verified,
    so a 200 that applied nothing can never delete a human's later tag;
  * the historical claim read has NO global date cutoff (a predated approved
    claim closes the ticket); the fake replica honours any timestamp predicate.
"""
import ast
import csv
import datetime as dt
import importlib.util
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import tokenize
import unittest
import urllib.error
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from clickup_drain import common  # noqa: E402
from clickup_drain import profile_claim as pc  # noqa: E402

NOW = dt.datetime(2026, 11, 4, 1, 0, tzinfo=dt.UTC)
TICKET_CREATED = int(dt.datetime(2026, 11, 2, 12, 0, tzinfo=dt.UTC).timestamp())
CLAIM_CREATED = int(dt.datetime(2026, 11, 2, 12, 30, tzinfo=dt.UTC).timestamp())


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def task(tid="86a1", *, email="Customer@Example.com", profile="p1", conv="conv-1",
         status="waiting", tags=("action:profile-claim", "hydra-action-request")):
    fields = []
    if email is not None:
        fields.append({"id": pc.common.USER_EMAIL_FIELD, "value": email})
    if profile is not None:
        fields.append({"id": pc.common.PROFILE_ID_FIELD, "value": profile})
    if conv is not None:
        fields.append({"id": pc.common.INTERCOM_LINK_FIELD,
                       "value": f"https://app.intercom.com/a/apps/x/inbox/inbox/1/conversations/{conv}"})
    return {"id": tid, "status": {"status": status}, "date_created": str(TICKET_CREATED * 1000),
            "custom_fields": fields, "tags": [{"name": t} for t in tags]}


def claim(cid=501, *, uid=7, pid="p1", status="pending", created=CLAIM_CREATED, links=None):
    return pc.Claim(id=cid, user_id=uid, profile_id=pid, profile_type="artist", status=status,
                    created_s=created, links=links or {}, reason="")


class FakeClient:
    """A ClickUp board in memory. Records every call; nothing leaves the process."""

    def __init__(self, tasks, *, drop_tag_write=False, drop_tag_delete=False,
                 lose_tag_write_response=False, lose_tag_delete_response=False,
                 fail_read_after_write=False, tag_write_500_after_apply=False):
        self.tasks = {t["id"]: json.loads(json.dumps(t)) for t in tasks}
        self.calls = []
        self.drop_tag_write = drop_tag_write
        self.drop_tag_delete = drop_tag_delete
        # `lose_*_response`: ClickUp APPLIED the change but every response was
        # lost, which is what `clickup_client` turns into a bare RuntimeError
        # after its retries are spent. Distinct from `drop_*`, where nothing
        # changed and a 200 comes back anyway.
        self.lose_tag_write_response = lose_tag_write_response
        self.lose_tag_delete_response = lose_tag_delete_response
        # `fail_read_after_write`: the POST lands, then the read-back GET dies.
        # The ledger keeps `pending` + `http-200` and no `read-back` row — the
        # same on-disk state a process death between the two rows leaves.
        self.fail_read_after_write = fail_read_after_write
        # `tag_write_500_after_apply`: ClickUp COMMITS the tag and then answers
        # 500 (a post-commit server error). A 5xx is not a refusal, so the tag is
        # live even though the write "failed".
        self.tag_write_500_after_apply = tag_write_500_after_apply
        self._wrote = False
        self.list_params = None

    def list_tasks(self, list_id, params, max_pages):
        self.list_params = params
        return [json.loads(json.dumps(t)) for t in self.tasks.values()]

    def tag_names(self, tid):
        return [t["name"] for t in self.tasks[tid].get("tags") or []]

    def request(self, method, path, body=None, timeout=60):
        self.calls.append((method, path))
        if method == "GET":
            if self.fail_read_after_write and self._wrote:
                raise RuntimeError(f"GET {path} failed after 5 attempts: timed out")
            tid = path.rsplit("/", 1)[-1]
            return 200, json.loads(json.dumps(self.tasks[tid]))
        assert "/tag/" in path, path
        tid, tag = path.split("/task/")[1].split("/tag/")
        if method == "POST":
            if not self.drop_tag_write:
                self.tasks[tid].setdefault("tags", []).append({"name": tag})
            if self.lose_tag_write_response:
                raise RuntimeError(f"POST {path} failed after 5 attempts: timed out")
            if self.tag_write_500_after_apply:
                raise urllib.error.HTTPError(path, 500, "Internal Server Error", {}, None)
            self._wrote = True
            return 200, {}
        if method == "DELETE":
            if not self.drop_tag_delete:
                self.tasks[tid]["tags"] = [t for t in self.tasks[tid].get("tags") or []
                                           if t["name"] != tag]
            if self.lose_tag_delete_response:
                raise RuntimeError(f"DELETE {path} failed after 5 attempts: timed out")
            return 204, {}
        raise AssertionError(f"a drainer must never send {method} {path}")


# A replica that HONOURS a `createdat >= timestamp '…'` predicate if the drainer
# ever adds one. Without this the fake answers every claim regardless of the SQL
# and a global cutoff is invisible to the suite — which is exactly how a predated
# approved claim got misclassified as "never claimed" (QA finding, PR #1712).
TIMESTAMP_PREDICATE = re.compile(r"createdat\s*>=\s*timestamp '([^']+)'")


def fake_trino(users=None, claims=()):
    """A replica runner: answers the two reads the drainer makes, nothing else."""
    def run(sql):
        buf = io.StringIO()
        w = csv.writer(buf, quoting=csv.QUOTE_ALL)
        if "from postgresql_core.public.claiming c" in sql:
            cutoff = TIMESTAMP_PREDICATE.search(sql)
            since = None
            if cutoff:
                since = int(dt.datetime.strptime(cutoff.group(1), "%Y-%m-%d %H:%M:%S")
                            .replace(tzinfo=dt.UTC).timestamp())
            for c in claims:
                if since is not None and c.created_s < since:
                    continue          # the replica would not have returned this row
                w.writerow([c.id, c.user_id, c.profile_id, c.profile_type, c.status,
                            iso(c.created_s), json.dumps(c.links), c.reason])
            return buf.getvalue()
        if "from postgresql_core.public.users" in sql:
            for email, uid in (users or {}).items():
                w.writerow([uid, email])
            return buf.getvalue()
        raise AssertionError(f"unexpected replica read: {sql[:120]}")
    return run


def fake_gate(decision="allow", *, reasons=(), watch=False):
    calls = []

    def gate(user_id):
        calls.append(user_id)
        return pc.account_gate.GateResult(decision, tuple(reasons), {"watch": watch})
    gate.calls = calls
    return gate


NO_RULE = lambda _c: pc.RuleVerdict("none")  # noqa: E731


def snapshot_for(c):
    return {"claim": {"id": str(c.id), "userId": str(c.user_id), "profileId": c.profile_id,
                      "profileType": c.profile_type, "status": c.status, "reason": "",
                      "verificationLinks": c.links},
            "profile": {"id": c.profile_id, "name": "Some Artist"}, "others": [],
            "other_profiles": {}, "shared": [], "deceased": False}


def decide(rows, *, asked=None, executor=frozenset(), why=None, mode="profile+user", rule=NO_RULE,
           ticket=None):
    return pc.classify(ticket or pc.Ticket.of(task()), rows, mode=mode, why_not=why,
                       asked=asked or {}, executor=set(executor), rule=rule)


class TheLadder(unittest.TestCase):
    """Every branch of the determination, in the order `classify` applies them."""

    def test_no_claim_row_tags_awaiting_user_submission(self):
        d = decide([])
        self.assertEqual(d.bucket, pc.B_AWAITING)
        self.assertEqual(d.tag, pc.DRAIN_TAG)

    def test_processed_claim_is_complete(self):
        d = decide([claim(cid=9, status="processed")])
        self.assertEqual(d.bucket, pc.B_COMPLETE)
        self.assertEqual(d.tag, "customer-outcome:complete")
        self.assertIn("9", d.evidence)

    def test_executor_rejected_claim_is_complete(self):
        d = decide([claim(cid=9, status="rejected")], executor={9})
        self.assertEqual(d.tag, "customer-outcome:complete")
        self.assertIn("claim_executor", d.evidence)

    def test_human_reject_without_audit_row_is_report_only(self):
        d = decide([claim(cid=9, status="rejected")])
        self.assertEqual(d.bucket, pc.B_REJECTED_OUTSIDE)
        self.assertIsNone(d.tag)

    def test_pending_without_proof_and_without_ask_writes_nothing(self):
        """The DoD's case: nothing submitted, nobody asked, so nothing is claimed."""
        d = decide([claim(cid=9, status="pending")])
        self.assertEqual(d.bucket, pc.B_PROOF_NO_ASK)
        self.assertIsNone(d.tag)
        self.assertIn("NO recorded ask", d.evidence)

    def test_pending_after_a_recorded_ask_tags_verification_required(self):
        d = decide([claim(cid=9, status="pending")], asked={9: {"askedAt": "2026-11-03T10:00:00Z"}})
        self.assertEqual(d.bucket, pc.B_VERIFICATION)
        self.assertEqual(d.tag, "customer-outcome:verification-required")
        self.assertIn("2026-11-03", d.evidence)

    def test_pending_with_proof_submitted_is_awaited_not_tagged(self):
        d = decide([claim(cid=9, status="pending", links={"weblinks": "https://x.test/1"})],
                   asked={9: {"askedAt": "2026-11-03T10:00:00Z"}})
        self.assertEqual(d.bucket, pc.B_AWAITING_REVIEW)
        self.assertIsNone(d.tag)

    def test_contradiction_becomes_a_tray_row_and_never_a_tag(self):
        c = claim(cid=9, status="pending")
        verdict = pc.RuleVerdict("decline", "impersonation", "c6-decline-rules-v1:impersonation",
                                 "the claim matches another person's profile", snapshot_for(c))
        d = decide([c], rule=lambda _c: verdict)
        self.assertEqual(d.bucket, pc.B_CONTRADICTION)
        self.assertIsNone(d.tag)
        self.assertEqual(d.tray_row["claim_id"], 9)
        self.assertEqual(d.tray_row["ruling_id"], "c6-decline-rules-v1:impersonation")

    def test_held_account_is_never_queued(self):
        c = claim(cid=9, status="pending")
        verdict = pc.RuleVerdict("held", "impersonation", "c6-decline-rules-v1:impersonation",
                                 "account not cleanly allowed (gate hold)")
        d = decide([c], rule=lambda _c: verdict)
        self.assertEqual(d.bucket, pc.B_HELD)
        self.assertIsNone(d.tag)
        self.assertIsNone(d.tray_row)

    def test_closed_claim_is_report_only(self):
        d = decide([claim(cid=9, status="closed")])
        self.assertEqual(d.bucket, pc.B_CLAIM_CLOSED)
        self.assertIsNone(d.tag)

    def test_no_account_is_never_touched(self):
        d = decide([], why="needs-identity", mode=None,
                   ticket=pc.Ticket.of(task(email=None)))
        self.assertEqual(d.bucket, pc.B_NEEDS_IDENTITY)
        self.assertIsNone(d.tag)

    def test_ambiguous_window_without_profile_id_is_report_only(self):
        d = decide([], why=pc.B_AMBIGUOUS, mode=None)
        self.assertEqual(d.bucket, pc.B_AMBIGUOUS)
        self.assertIsNone(d.tag)


class Matching(unittest.TestCase):
    def test_profile_and_user_and_window(self):
        t = pc.Ticket.of(task(profile="p1"))
        t = pc._with_user(t, 7)
        rows = [claim(cid=1, pid="p1"), claim(cid=2, pid="p2")]
        got, mode, why = pc.match_claims(t, {7: rows})
        self.assertEqual([c.id for c in got], [1])
        self.assertEqual((mode, why), ("profile+user", None))

    def test_a_predated_claim_on_the_same_pair_is_kept_for_a_decision(self):
        t = pc._with_user(pc.Ticket.of(task(profile="p1")), 7)
        old = claim(cid=1, pid="p1", created=TICKET_CREATED - 40 * 86_400)
        got, mode, why = pc.match_claims(t, {7: [old]})
        self.assertEqual([c.id for c in got], [1])
        self.assertEqual((mode, why), ("profile+user-predates", None))
        # approved before the ask: the ask is already satisfied, so it closes
        done = decide([old.__class__(**{**old.__dict__, "status": "processed"})], mode=mode)
        self.assertEqual(done.bucket, pc.B_COMPLETE)
        self.assertIn("approved BEFORE this ticket", done.evidence)
        # still in flight from a previous attempt: reported, never closed
        live = decide([old], mode=mode)
        self.assertEqual(live.bucket, pc.B_OUTSIDE_WINDOW)
        self.assertIsNone(live.tag)

    def test_no_profile_id_matches_only_an_unambiguous_single_claim(self):
        t = pc._with_user(pc.Ticket.of(task(profile=None)), 7)
        one, _m, _w = pc.match_claims(t, {7: [claim(cid=1)]})
        self.assertEqual([c.id for c in one], [1])
        many, mode, why = pc.match_claims(t, {7: [claim(cid=1), claim(cid=2)]})
        self.assertEqual((many, mode, why), ([], None, pc.B_AMBIGUOUS))

    def test_identity_ids_and_the_open_status_query_are_pinned(self):
        self.assertEqual(common.USER_EMAIL_FIELD, "e8618c74-d065-4b75-9a5a-86d658392409")
        self.assertEqual(common.PROFILE_ID_FIELD, "347d23bf-ed7b-40c2-bd10-5bd6ac7210b1")
        self.assertEqual(common.INTERCOM_LINK_FIELD, "c32dbf6e-f680-4ff1-a532-192bb96245c3")
        params = dict(common.open_queue_params("profile-claim"))
        self.assertEqual(params["tags[]"], "action:profile-claim")
        # `include_closed=false` returned 218 already-resolved tickets on the live
        # board; the three statuses are what actually keeps them out.
        self.assertNotIn("include_closed", params)
        self.assertEqual(sorted(k for k, _v in common.open_queue_params("profile-claim")
                                if k == "statuses[]"), ["statuses[]"] * 3)


class Ledgers(unittest.TestCase):
    def test_executor_audit_needs_the_written_outcome_and_a_rejected_after(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "audit.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in [
                {"kind": "claim_decline", "claim_id": 1, "outcome": "written", "after": "rejected"},
                {"kind": "claim_decline", "claim_id": 2, "outcome": "reserved", "after": "pending"},
                {"kind": "claim_decline", "claim_id": 3, "outcome": "written", "after": "pending"},
                {"kind": "credit_close", "claim_id": 4, "outcome": "written", "after": "rejected"},
            ]) + "\n")
            self.assertEqual(pc.executor_rejections(path), {1})

    def test_asked_claims_are_keyed_by_claim_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "asked.jsonl"
            path.write_text('{"id": 9, "askedAt": "2026-11-03T10:00:00Z"}\n')
            self.assertEqual(pc.asked_claims(path)[9]["askedAt"], "2026-11-03T10:00:00Z")

    def test_corrupt_ledger_stops_a_revert_instead_of_skipping_a_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "ledger.jsonl"
            path.write_text('{"ticket_id": "1"}\nnot json\n')
            with self.assertRaises(common.Surprise):
                common.read_jsonl(path)


class Writes(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient([task("86a1"), task("86a2")])
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = common.Ledger(pathlib.Path(self.tmp.name) / "ledger.jsonl")

    def writer(self, cap=100, client=None):
        return common.TagWriter(client or self.client, self.ledger, max_writes=cap, run_id="test-run",
                                now=lambda: "2026-11-04T01:00:00Z")

    def test_write_lands_reads_back_and_ledgers_both_rows(self):
        w = self.writer()
        self.assertEqual(w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e"), "written")
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        rows = common.read_jsonl(self.ledger.path)
        self.assertEqual([r["action"] for r in rows], ["add-tag", "add-tag", "read-back"])
        self.assertIs(rows[0]["tag_present_before"], False)
        self.assertEqual(rows[1]["result"], "http-200")
        self.assertEqual(rows[2]["result"], "verified")
        self.assertEqual(w.written, 1)

    def test_a_tag_already_there_is_reported_not_reposted(self):
        self.client.tasks["86a1"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        w = self.writer()
        self.assertEqual(w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e"),
                         "already-present")
        self.assertEqual([c for c in self.client.calls if c[0] == "POST"], [])
        self.assertEqual(w.written, 0)

    def test_the_cap_stops_the_run(self):
        w = self.writer(cap=1)
        w.add("86a1", pc.DRAIN_TAG, bucket=pc.B_AWAITING, evidence="e")
        with self.assertRaises(common.CapReached):
            w.add("86a2", pc.DRAIN_TAG, bucket=pc.B_AWAITING, evidence="e")
        self.assertNotIn(pc.DRAIN_TAG, self.client.tag_names("86a2"))

    def test_a_write_that_does_not_read_back_is_a_surprise(self):
        client = FakeClient([task("86a1")], drop_tag_write=True)
        with self.assertRaises(common.Surprise):
            self.writer(client=client).add("86a1", pc.DRAIN_TAG, bucket=pc.B_AWAITING, evidence="e")
        rows = common.read_jsonl(self.ledger.path)
        self.assertEqual(rows[-1]["action"], "read-back")
        self.assertEqual(rows[-1]["result"], "missing")

    def test_revert_ignores_an_add_that_never_read_back(self):
        """A 200 without a tag is NOT ours to undo — a later human tag would be.

        The API can answer 200 and apply nothing; `add()` raises on the read-back,
        and days later a human adds that same tag for their own reason. Reverting
        on the 200 alone deletes the human's tag (QA finding, PR #1712).
        """
        blind = FakeClient([task("86a1")], drop_tag_write=True)
        with self.assertRaises(common.Surprise):
            self.writer(client=blind).add("86a1", pc.DRAIN_TAG, bucket=pc.B_AWAITING, evidence="e")
        self.assertEqual(common.read_jsonl(self.ledger.path)[-1]["result"], "missing")
        # a human puts the same tag on the ticket afterwards
        blind.tasks["86a1"]["tags"].append({"name": pc.DRAIN_TAG})
        w = self.writer(client=blind)
        dry = common.revert_ledger(self.ledger.path, blind, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 0)
        self.assertEqual(dry["unverified_adds_ignored"], 1)
        common.revert_ledger(self.ledger.path, blind, writer=w, dry_run=False)
        self.assertIn(pc.DRAIN_TAG, blind.tag_names("86a1"))
        self.assertEqual([c for c in blind.calls if c[0] == "DELETE"], [])

    def test_a_5xx_add_that_actually_landed_is_reconciled_not_discarded(self):
        """A 5xx is not a refusal: ClickUp can fail AFTER it committed the write.

        The ledger keeps `pending` + `http-500`. Treating that as "definitely
        absent" made `--revert` report `candidates: 0`, `errors: []` while the
        customer-outcome tag was live (QA finding, PR #1712).
        """
        c = FakeClient([task("86a1")], tag_write_500_after_apply=True)
        w = self.writer(client=c)
        with self.assertRaises(common.Surprise):
            w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        self.assertEqual([r["result"] for r in common.read_jsonl(self.ledger.path)],
                         ["pending", "http-500"])
        self.assertIn(pc.OUTCOME_COMPLETE, c.tag_names("86a1"))
        c.tag_write_500_after_apply = False
        dry = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 1)
        self.assertEqual(dry["ambiguous_reconciled"], 1)
        self.assertEqual(dry["ambiguous_live"], 1)
        self.assertEqual(dry["errors"], [])
        done = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=False)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, c.tag_names("86a1"))

    def test_a_4xx_add_is_still_treated_as_refused(self):
        """The 5xx reconcile must not turn a real refusal into a candidate."""
        c = FakeClient([task("86a1")])
        w = self.writer(client=c)
        real = c.request

        def refuse(method, path, body=None, timeout=60):
            if method == "POST" and "/tag/" in path:
                c.calls.append((method, path))
                raise urllib.error.HTTPError(path, 400, "Bad Request", {}, None)
            return real(method, path, body, timeout)

        c.request = refuse
        with self.assertRaises(common.Surprise):
            w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        self.assertNotIn(pc.OUTCOME_COMPLETE, c.tag_names("86a1"))
        dry = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 0)
        self.assertEqual(dry["ambiguous_reconciled"], 0)
        self.assertEqual(dry["errors"], [])

    def test_an_already_absent_revert_retires_ownership_for_the_next_one(self):
        """verified add -> human removal -> revert -> human re-add -> revert.

        `remove()` used to return `already-absent` without writing a row, so the
        original `read-back: verified` add stayed the newest word on disk and a
        SECOND `--revert` deleted the tag the human had restored (QA finding, PR
        #1712).
        """
        c = FakeClient([task("86a1")])
        w = self.writer(client=c)
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        # a human removes the tag before we ever revert
        c.tasks["86a1"]["tags"] = [t for t in c.tasks["86a1"]["tags"]
                                   if t["name"] != pc.OUTCOME_COMPLETE]
        first = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=False)
        self.assertEqual(first["already_absent"], 1)
        self.assertEqual(first["errors"], [])
        # the terminal fact is on disk, not just in the return value
        self.assertIn(("remove-tag", "already-absent"),
                      [(r.get("action"), r.get("result"))
                       for r in common.read_jsonl(self.ledger.path)])
        # ...and a human re-adds it for their own reason
        c.tasks["86a1"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        dry = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 0)
        second = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=False)
        self.assertEqual(second["removed"], 0)
        self.assertIn(pc.OUTCOME_COMPLETE, c.tag_names("86a1"))

    def test_a_2xx_add_with_no_read_back_is_reconciled_not_ignored(self):
        """The POST landed, then the read-back GET died: the tag is still ours.

        The ledger keeps `pending` + `http-200` and no `read-back` row — the same
        on-disk state a process death between the two rows leaves. Counting that
        as "ignored" made `--revert` report `candidates: 0`, `errors: []` while
        the customer-outcome tag was live (QA finding, PR #1712).
        """
        c = FakeClient([task("86a1")], fail_read_after_write=True)
        w = self.writer(client=c)
        with self.assertRaises(RuntimeError):
            w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        self.assertEqual([r["result"] for r in common.read_jsonl(self.ledger.path)],
                         ["pending", "http-200"])
        self.assertIn(pc.OUTCOME_COMPLETE, c.tag_names("86a1"))
        c.fail_read_after_write = False
        dry = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 1)
        self.assertEqual(dry["ambiguous_reconciled"], 1)
        self.assertEqual(dry["ambiguous_live"], 1)
        self.assertEqual(dry["unverified_adds_ignored"], 0)
        self.assertEqual(dry["errors"], [])
        done = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=False)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, c.tag_names("86a1"))

    def test_an_unreadable_reconcile_of_an_interrupted_add_fails_the_revert(self):
        """A board we cannot read is not permission to call the rollback done."""
        c = FakeClient([task("86a1")], fail_read_after_write=True)
        w = self.writer(client=c)
        with self.assertRaises(RuntimeError):
            w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        # the board stays unreadable, so the reconcile cannot decide
        dry = common.revert_ledger(self.ledger.path, c, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 0)
        self.assertEqual(len(dry["errors"]), 1)
        self.assertIn("cannot reconcile", dry["errors"][0])
        self.assertEqual([x for x in c.calls if x[0] == "DELETE"], [])

    def test_a_failed_retry_retires_the_earlier_verified_add(self):
        """verified add -> human removal -> failed retry -> human restore -> revert.

        `tag_present_before: false` on a new attempt is PROOF the tag was absent at
        that instant, so the earlier verified add is stale ownership. Keeping it let
        a retry that ClickUp answered 200-without-applying leave the OLD verified row
        standing, so a tag a human later restored was deleted by `--revert` as ours
        (QA finding, PR #1712).
        """
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        # a human removes the tag for their own reason
        self.client.tasks["86a1"]["tags"] = [t for t in self.client.tasks["86a1"]["tags"]
                                              if t["name"] != pc.OUTCOME_COMPLETE]
        # the next run retries; ClickUp answers 200 and applies nothing
        self.client.drop_tag_write = True
        with self.assertRaises(common.Surprise):
            w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        self.client.drop_tag_write = False
        # ...and a human restores the tag afterwards
        self.client.tasks["86a1"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        dry = common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 0)
        self.assertEqual(dry["unverified_adds_ignored"], 1)
        done = common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=False)
        self.assertEqual(done["removed"], 0)
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertEqual([c for c in self.client.calls if c[0] == "DELETE"], [])

    def test_an_add_whose_response_was_lost_is_reconciled_not_escaped(self):
        """ClickUp applied the tag but every response was lost.

        `clickup_client` spends its transport retries and then raises a bare
        `RuntimeError`, which the old handler did not catch: the ledger stopped at
        `pending`, and `revert_ledger` — which only trusts an `http-2xx` add —
        reported `candidates: 0` while the customer-outcome tag was live on the
        ticket (QA finding, PR #1712).
        """
        lost = FakeClient([task("86a1")], lose_tag_write_response=True)
        with self.assertRaises(common.Surprise):
            self.writer(client=lost).add("86a1", pc.OUTCOME_COMPLETE,
                                         bucket=pc.B_COMPLETE, evidence="e")
        # the tag DID land, and the ledger records that the outcome is unknown
        self.assertIn(pc.OUTCOME_COMPLETE, lost.tag_names("86a1"))
        rows = common.read_jsonl(self.ledger.path)
        self.assertEqual([(r["action"], r["result"]) for r in rows],
                         [("add-tag", "pending"),
                          ("add-tag", "ambiguous:RuntimeError")])
        dry = common.revert_ledger(self.ledger.path, lost,
                                   writer=self.writer(client=lost), dry_run=True)
        self.assertEqual(dry["candidates"], 1)
        self.assertEqual(dry["ambiguous_reconciled"], 1)
        self.assertEqual(dry["ambiguous_live"], 1)
        done = common.revert_ledger(self.ledger.path, lost,
                                    writer=self.writer(client=lost), dry_run=False)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, lost.tag_names("86a1"))

    def test_a_lost_add_that_never_landed_is_not_a_candidate(self):
        """The mirror case: the response was lost AND the tag never landed.

        Only the live read can tell these apart, which is why an ambiguous row is
        reconciled instead of assumed either way.
        """
        lost = FakeClient([task("86a1")], drop_tag_write=True,
                          lose_tag_write_response=True)
        with self.assertRaises(common.Surprise):
            self.writer(client=lost).add("86a1", pc.DRAIN_TAG, bucket=pc.B_AWAITING,
                                         evidence="e")
        dry = common.revert_ledger(self.ledger.path, lost,
                                   writer=self.writer(client=lost), dry_run=True)
        self.assertEqual(dry["candidates"], 0)
        self.assertEqual(dry["ambiguous_reconciled"], 1)
        self.assertEqual(dry["ambiguous_absent"], 1)
        self.assertEqual([c for c in lost.calls if c[0] == "DELETE"], [])

    def test_a_pending_add_row_from_a_crashed_run_is_reconciled(self):
        """A process death between the POST and the ledger update looks like this.

        There is no terminal row at all, only the pre-call `pending` intent, so the
        ledger alone can never say whether the tag landed.
        """
        self.ledger.write({"ts": "t", "run_id": "dead", "ticket_id": "86a1",
                           "tag": pc.OUTCOME_COMPLETE, "action": "add-tag",
                           "result": "pending", "tag_present_before": False,
                           "bucket": pc.B_COMPLETE, "evidence": "e"})
        self.client.tasks["86a1"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        done = common.revert_ledger(self.ledger.path, self.client,
                                    writer=self.writer(), dry_run=False)
        self.assertEqual(done["ambiguous_live"], 1)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))

    def test_an_unreadable_ambiguous_row_is_an_error_not_a_complete_rollback(self):
        """If the board cannot be read, the rollback is unproven — exit non-zero."""
        self.ledger.write({"ts": "t", "run_id": "dead", "ticket_id": "86a1",
                           "tag": pc.OUTCOME_COMPLETE, "action": "add-tag",
                           "result": "pending", "tag_present_before": False,
                           "bucket": pc.B_COMPLETE, "evidence": "e"})
        client = FakeClient([task("86a1")])

        def broken_get(method, path, body=None, timeout=60):
            assert method == "GET", method
            return 500, {}
        client.request = broken_get
        out = common.revert_ledger(self.ledger.path, client, writer=self.writer(),
                                   dry_run=True)
        self.assertEqual(out["candidates"], 0)
        self.assertEqual(out["ambiguous_reconciled"], 0)
        self.assertEqual(len(out["errors"]), 1)
        self.assertIn("cannot reconcile", out["errors"][0])

    def test_a_lost_delete_response_leaves_the_removal_retryable(self):
        """A DELETE whose response was lost is not an undo, even when it landed."""
        lost = FakeClient([task("86a1")])
        w = self.writer(client=lost)
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        lost.lose_tag_delete_response = True
        out = common.revert_ledger(self.ledger.path, lost, writer=w, dry_run=False)
        self.assertEqual(out["removed"], 0)
        self.assertEqual(len(out["errors"]), 1)
        self.assertIn("ambiguously", out["errors"][0])
        self.assertNotIn(pc.OUTCOME_COMPLETE, lost.tag_names("86a1"))   # it did land
        # the add is still ours; the retry reads the ticket and converges
        lost.lose_tag_delete_response = False
        again = common.revert_ledger(self.ledger.path, lost, writer=w, dry_run=False)
        self.assertEqual(again["candidates"], 1)
        self.assertEqual(again["already_absent"], 1)

    def test_a_lost_add_after_a_verified_remove_is_still_reconciled(self):
        """A verified removal supersedes the add it removed, not a LATER add.

        Reverting an add leaves a marker so the same add is not undone twice. But
        the next run can add the tag again and lose the response: the marker then
        hid the live tag, and the revert reported `candidates: 0` with clean
        errors while the customer-outcome tag was on the ticket (QA finding, QA
        round 10).
        """
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        self.assertEqual(
            common.revert_ledger(self.ledger.path, self.client, writer=w,
                                 dry_run=False)["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        # a later run asks for the tag again and dies between POST and ledger
        self.ledger.write({"ts": "t", "run_id": "dead", "ticket_id": "86a1",
                           "tag": pc.OUTCOME_COMPLETE, "action": "add-tag",
                           "result": "pending", "tag_present_before": False,
                           "bucket": pc.B_COMPLETE, "evidence": "e"})
        self.client.tasks["86a1"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        dry = common.revert_ledger(self.ledger.path, self.client,
                                   writer=self.writer(), dry_run=True)
        self.assertEqual(dry["ambiguous_reconciled"], 1)
        self.assertEqual(dry["ambiguous_live"], 1)
        self.assertEqual(dry["candidates"], 1)
        self.assertEqual(dry["skipped_already_reverted"], 0)
        self.assertEqual(dry["errors"], [])
        done = common.revert_ledger(self.ledger.path, self.client,
                                    writer=self.writer(), dry_run=False)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))

    def test_an_applying_revert_refuses_while_the_writer_holds_the_lock(self):
        """A rollback that cannot serialize must not run at all.

        `--revert --apply` scanned the ledger and deleted tags with no lock while
        the hourly writer held one. Started mid-batch it removed the tags it had
        seen, returned `errors: []`, and left the tags the writer appended after
        its scan live — a rollback that reports complete and is not (QA finding,
        PR #1712).
        """
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        lock = pathlib.Path(self.tmp.name) / "writes.lock"
        with common.shared_write_lock(lock):
            with self.assertRaises(common.LockHeld):
                pc.revert_with_lock(self.ledger.path, self.client, apply=True,
                                    run_id="r1", lock_path=lock)
        # nothing was deleted while the writer was live
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertEqual([c for c in self.client.calls if c[0] == "DELETE"], [])
        # and the same call converges once the lock is free
        out = pc.revert_with_lock(self.ledger.path, self.client, apply=True,
                                  run_id="r2", lock_path=lock)
        self.assertEqual(out["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))

    def test_a_dry_run_revert_takes_no_lock(self):
        """The pre-apply check must stay runnable while the hourly writer works."""
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        lock = pathlib.Path(self.tmp.name) / "writes.lock"
        with common.shared_write_lock(lock):
            out = pc.revert_with_lock(self.ledger.path, self.client, apply=False,
                                      run_id="r1", lock_path=lock)
        self.assertEqual(out["candidates"], 1)
        self.assertEqual([c for c in self.client.calls if c[0] == "DELETE"], [])
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))

    def test_a_second_revert_does_not_delete_a_tag_a_human_restored(self):
        """Removals must land in the SOURCE ledger, or the next revert re-deletes.

        `--revert` used to record its `remove-tag` rows in `<ledger>.revert`, so
        the source ledger kept the verified add and no removal. If a human then
        restored the tag, a second `--revert` treated it as still ours, deleted
        it, and reported the human's tag as our own undo (QA finding, PR #1712).
        """
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        first = common.revert_ledger(
            self.ledger.path, self.client,
            writer=pc.revert_writer(self.client, self.ledger.path, run_id="r2"), dry_run=False)
        self.assertEqual(first["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertEqual(common.read_jsonl(self.ledger.path)[-1]["action"], "remove-read-back")
        self.assertEqual(common.read_jsonl(self.ledger.path)[-1]["result"], "verified")
        # a human restores the tag for their own reason
        self.client.tasks["86a1"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        second = common.revert_ledger(
            self.ledger.path, self.client,
            writer=pc.revert_writer(self.client, self.ledger.path, run_id="r3"), dry_run=False)
        self.assertEqual(second["candidates"], 0)   # the remove-tag row retires the add
        self.assertEqual(second["removed"], 0)
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))

    def test_a_delete_that_answers_2xx_without_removing_is_not_success(self):
        """A revert must not report an undo it cannot see.

        ClickUp can answer 204 and leave the tag. Recording that as `removed`
        would make the rollback look complete, leave the customer-outcome tag live,
        and suppress the candidate on every later revert (QA finding, PR #1712).
        """
        blind = FakeClient([task("86a1")], drop_tag_delete=True)
        bl = common.Ledger(self.ledger.path)
        w = common.TagWriter(blind, bl, max_writes=10, run_id="r1", now=lambda: "x")
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        out = common.revert_ledger(self.ledger.path, blind, writer=w, dry_run=False)
        self.assertEqual(out["removed"], 0)
        self.assertEqual(len(out["errors"]), 1)
        self.assertIn("still on 86a1", out["errors"][0])
        self.assertEqual([r["action"] for r in common.read_jsonl(self.ledger.path)][-2:],
                         ["remove-tag", "remove-read-back"])
        # the removal did not land, so the tag is still OUR candidate on the next run
        self.assertIn(pc.OUTCOME_COMPLETE, blind.tag_names("86a1"))
        dry = common.revert_ledger(self.ledger.path, blind, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 1)

    def test_a_ticket_closed_after_the_scan_is_not_tagged(self):
        """The decision is derived from the scan; a human may have closed it since.

        Tagging a closed ticket `customer-outcome:complete` hands a resolved
        ticket to the downstream customer-outcome path (QA finding, PR #1712).
        """
        w = self.writer()
        self.client.tasks["86a1"]["status"] = {"status": "resolved"}
        self.assertEqual(w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE,
                               evidence="e", extra={"queue": pc.ACTION, "profile_id": "p1"}),
                         "stale")
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertEqual([c for c in self.client.calls if c[0] == "POST"], [])
        rows = common.read_jsonl(self.ledger.path)
        self.assertEqual(rows[-1]["action"], "stale-skip")
        self.assertIn("status moved to resolved", rows[-1]["reason"])
        self.assertEqual(w.written, 0)

    def test_a_reassigned_profile_after_the_scan_is_not_tagged(self):
        w = self.writer()
        self.client.tasks["86a1"]["custom_fields"] = [
            {"id": pc.common.PROFILE_ID_FIELD, "value": "someone-else"}]
        self.assertEqual(w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e",
                               extra={"queue": pc.ACTION, "profile_id": "p1"}), "stale")
        self.assertEqual([c for c in self.client.calls if c[0] == "POST"], [])

    def test_revert_sees_a_tag_added_again_after_an_earlier_revert(self):
        """add -> verified -> remove -> add -> verified: the new add is a candidate.

        A stale `removed` marker hid the second add, so a revert reported
        `candidates: 0` and left the tag it owned in place (QA finding, PR #1712).
        """
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=False)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        dry = common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 1)
        self.assertEqual(dry["skipped_already_reverted"], 0)
        done = common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=False)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))

    def test_revert_deletes_only_tags_this_ledger_added(self):
        w = self.writer()
        w.add("86a1", pc.OUTCOME_COMPLETE, bucket=pc.B_COMPLETE, evidence="e")
        self.client.tasks["86a2"]["tags"].append({"name": pc.OUTCOME_COMPLETE})
        dry = common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=True)
        self.assertEqual(dry["candidates"], 1)
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        done = common.revert_ledger(self.ledger.path, self.client, writer=w, dry_run=False)
        self.assertEqual(done["removed"], 1)
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a2"))


class TheRun(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = pathlib.Path(self.tmp.name)
        self.client = FakeClient([task("86a1", profile="p1"), task("86a2", profile="p2")])
        self.USERS = {"customer@example.com": 7}

    def two_accounts(self):
        """Give 86a2 its own account: core claims are keyed by account, so a shared
        email would make both tickets read the same fresh claim list."""
        self.client.tasks["86a2"]["custom_fields"][0]["value"] = "other@example.com"
        return {**self.USERS, "other@example.com": 8}

    def collect(self, claims, *, users=None, asked=None, executor=None, **kw):
        return pc.collect(client=self.client, now=NOW,
                          run=fake_trino(users or {"customer@example.com": 7}, claims),
                          ask_path=self._write("asked.jsonl", asked or []),
                          executor_path=self._write("audit.jsonl", executor or []),
                          max_gate_calls=kw.pop("max_gate_calls", 25), **kw)

    def _write(self, name, rows):
        path = self.dir / name
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return path

    def test_dry_run_writes_nothing_and_counts_every_bucket(self):
        report = self.collect([claim(cid=1, pid="p1", status="processed")])
        self.assertEqual(report.tickets, 2)
        self.assertEqual(report.buckets[pc.B_COMPLETE], 1)
        self.assertEqual(report.buckets[pc.B_AWAITING], 1)
        self.assertEqual([c for c in self.client.calls if c[0] != "GET"], [])
        self.assertIn("would-close (1)", pc.digest(report))

    def test_apply_tags_the_ladder_and_skips_the_report_only(self):
        report = self.collect([claim(cid=1, pid="p1", status="processed")])
        ledger = common.Ledger(self.dir / "ledger.jsonl")
        report = pc.apply_plan(report, client=self.client, ledger=ledger, run_id="run1",
                               max_writes=100, now_iso=lambda: "2026-11-04T01:00:00Z",
                               tray_dir=self.dir / "trays")
        self.assertEqual(report.written, 2)
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertIn(pc.DRAIN_TAG, self.client.tag_names("86a2"))

    def test_a_rerun_is_a_no_op_because_the_tag_is_already_on_the_ticket(self):
        report = self.collect([claim(cid=1, pid="p1", status="processed")])
        ledger = common.Ledger(self.dir / "ledger.jsonl")
        first = pc.apply_plan(report, client=self.client, ledger=ledger, run_id="r1", max_writes=100,
                              now_iso=lambda: "x", tray_dir=self.dir / "trays")
        self.assertEqual(first.written, 2)
        again = pc.apply_plan(self.collect([claim(cid=1, pid="p1", status="processed")]),
                              client=self.client, ledger=ledger, run_id="r2", max_writes=100,
                              now_iso=lambda: "x", tray_dir=self.dir / "trays")
        self.assertEqual(again.written, 0)
        self.assertEqual(again.already_present, 2)
        self.assertIn("already tagged by an earlier run: 2", pc.digest(again))

    def test_a_claim_outside_the_oldest_ticket_window_still_closes(self):
        """The historical read must be COMPLETE, not windowed.

        Oldest ticket is Nov 2; the account's approved claim on the same profile is
        Oct 20. A global `createdat >= min(ticket) - 1d` hides it, so the ticket was
        tagged `drain:awaiting-user-submission` ("you never submitted anything") for
        a profile the customer already owns. `fake_trino` honours the predicate, so
        re-introducing a cutoff here fails (QA finding, PR #1712).
        """
        late = int(dt.datetime(2026, 10, 20, 9, 0, tzinfo=dt.UTC).timestamp())
        report = self.collect([claim(cid=1, pid="p1", status="processed", created=late)])
        by_ticket = {d.ticket.id: d for d in report.decisions}
        self.assertEqual(by_ticket["86a1"].bucket, pc.B_COMPLETE)
        self.assertEqual(by_ticket["86a1"].tag, pc.OUTCOME_COMPLETE)
        # 86a2 is a different account with genuinely no claim; it stays awaiting
        self.assertEqual(by_ticket["86a2"].bucket, pc.B_AWAITING)

    def test_a_processed_claim_reverted_after_the_scan_is_not_tagged_complete(self):
        """`complete` is a statement about core; core is re-read before it is written."""
        users = self.two_accounts()
        report = self.collect([claim(cid=501, status="processed")], users=users)
        d = {x.ticket.id: x for x in report.decisions}["86a1"]
        self.assertEqual(d.bucket, pc.B_COMPLETE)
        ledger = common.Ledger(self.dir / "ledger.jsonl")

        def recheck(user_ids):
            self.assertEqual(len(user_ids), 1)    # read per write, for THAT account only
            uid = next(iter(user_ids))
            return {uid: [claim(cid=501, status="reverted")] if uid == 7 else []}

        report = pc.apply_plan(report, client=self.client, ledger=ledger, run_id="r1",
                               max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays",
                               claims_recheck=recheck)
        self.assertEqual(report.skipped_stale, 1)      # 86a1: the claim is open again
        self.assertEqual(report.written, 1)            # 86a2 is genuinely unclaimed
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        stale = [r for r in common.read_jsonl(self.dir / "ledger.jsonl")
                 if r["action"] == "stale-skip"]
        self.assertEqual(len(stale), 1)
        self.assertIn("not approved or executor-rejected", stale[0]["reason"])

    def test_a_claim_that_appeared_after_the_scan_is_not_labelled_absent(self):
        """`drain:awaiting-user-submission` on a claim submitted mid-run is a lie."""
        users = self.two_accounts()
        report = self.collect([], users=users)      # neither account has a claim right now
        ledger = common.Ledger(self.dir / "ledger.jsonl")
        appeared = claim(cid=999, uid=8, pid="p2")   # the customer submits mid-run

        def recheck(user_ids):
            uid = next(iter(user_ids))
            self.assertEqual(len(user_ids), 1)
            return {uid: [appeared] if uid == 8 else []}

        report = pc.apply_plan(report, client=self.client, ledger=ledger, run_id="r1",
                               max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays",
                               claims_recheck=recheck)
        self.assertNotIn(pc.DRAIN_TAG, self.client.tag_names("86a2"))
        self.assertEqual(report.skipped_stale, 1)
        self.assertEqual(report.written, 1)     # 86a1 still gets its tag
        self.assertIn("86a2: skipped", " ".join(report.notes))

    def test_an_undated_ticket_attributes_no_claim_at_all(self):
        """No readable `date_created` = no window = every old claim would qualify.

        `cutoff` fell back to `-86400`, so a profile-less undated ticket matched one
        unrelated 2023 `processed` claim as "user-window" and could be tagged
        `complete` for the wrong request (QA finding, PR #1712).
        """
        old = int(dt.datetime(2023, 8, 31, 12, 0, tzinfo=dt.UTC).timestamp())
        task = dict(self.client.tasks["86a1"])
        task["date_created"] = None
        task["custom_fields"] = [f for f in task["custom_fields"]
                                 if f["id"] != pc.common.PROFILE_ID_FIELD]
        self.client.tasks["86a1"] = task
        report = self.collect([claim(cid=501, pid="p9", status="processed", created=old)])
        d = {x.ticket.id: x for x in report.decisions}["86a1"]
        self.assertEqual(d.bucket, pc.B_UNDATED)
        self.assertIsNone(d.tag)
        pc.apply_plan(report, client=self.client,
                      ledger=common.Ledger(self.dir / "ledger.jsonl"), run_id="r1",
                      max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays")
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertNotIn(pc.DRAIN_TAG, self.client.tag_names("86a1"))

    def test_a_profile_less_ticket_with_an_old_claim_is_ambiguous_not_unclaimed(self):
        """No Profile ID + only historical claims must never become "never claimed".

        `match_claims` used to drop every claim outside the window when the ticket
        names no profile, so an account with an already-`processed` historical claim
        was tagged `drain:awaiting-user-submission` — telling a customer who has a
        claim that they never started one (QA finding, PR #1712).
        """
        self.client.tasks["86a1"]["custom_fields"] = [
            f for f in self.client.tasks["86a1"]["custom_fields"]
            if f["id"] != pc.common.PROFILE_ID_FIELD]      # strip the Profile ID
        old = int(dt.datetime(2026, 10, 20, 12, 0, tzinfo=dt.UTC).timestamp())
        report = self.collect([claim(cid=501, pid="p1", status="processed", created=old)])
        d = {x.ticket.id: x for x in report.decisions}["86a1"]
        self.assertEqual(d.bucket, pc.B_AMBIGUOUS)
        self.assertIn("older than it", d.evidence)
        pc.apply_plan(report, client=self.client,
                      ledger=common.Ledger(self.dir / "ledger.jsonl"), run_id="r1",
                      max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays")
        self.assertNotIn(pc.DRAIN_TAG, self.client.tag_names("86a1"))

    def test_a_second_pending_claim_gaining_proof_stops_verification_required(self):
        """The scan's predicate is ALL pending claims unproven, so re-check all of them.

        Re-checking only the claim the ask named let a second pending claim on the
        same profile submit proof and still be tagged `verification-required`
        (QA finding, PR #1712).
        """
        snap = snapshot_for(claim(cid=501, pid="p1"))
        with mock.patch.object(pc, "_snapshot_batch", lambda ids, run=None: {501: snap, 502: snap}):
            report = self.collect([claim(cid=501, pid="p1", status="pending"),
                                   claim(cid=502, pid="p1", status="pending")],
                                  users={"customer@example.com": 7, "other@example.com": 8},
                                  asked=[{"id": 501, "askedAt": "2026-11-03T10:00:00Z"}],
                                  gate=fake_gate("allow"))
        d = {x.ticket.id: x for x in report.decisions}["86a1"]
        self.assertEqual(d.bucket, pc.B_VERIFICATION)
        self.assertEqual(d.basis, (501,))
        # the OTHER pending claim submits identity proof between the scan and the POST
        proven = claim(cid=502, pid="p1", status="pending", links={"weblinks": "https://x/me"})
        report = pc.apply_plan(
            report, client=self.client, ledger=common.Ledger(self.dir / "ledger.jsonl"),
            run_id="r1", max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays",
            claims_recheck=lambda ids: {u: [claim(cid=501, pid="p1", status="pending"), proven]
                                        for u in ids},
            ask_path=self._write("asked.jsonl",
                                 [{"id": 501, "askedAt": "2026-11-03T10:00:00Z"}]))
        self.assertEqual(report.skipped_stale, 1)
        self.assertNotIn(pc.OUTCOME_VERIFICATION, self.client.tag_names("86a1"))
        stale = [r for r in common.read_jsonl(self.dir / "ledger.jsonl")
                 if r["action"] == "stale-skip"]
        self.assertIn("identity proof now", stale[0]["reason"])

    def test_a_claim_reverted_between_two_writes_is_not_tagged_complete(self):
        """Core is re-read before EACH write, not once per batch.

        86a1's claim is still `processed` when its tag goes on; 86a2's claim is
        reverted while the run is between the two writes. A batch-level read would
        still stamp 86a2 `complete` (QA finding, PR #1712).
        """
        users = self.two_accounts()
        report = self.collect([claim(cid=501, pid="p1", status="processed"),
                               claim(cid=502, uid=8, pid="p2", status="processed")],
                              users=users)
        self.assertEqual({d.ticket.id: d.bucket for d in report.decisions},
                         {"86a1": pc.B_COMPLETE, "86a2": pc.B_COMPLETE})
        reads = []

        def recheck(user_ids):
            uid = next(iter(user_ids))
            reads.append(uid)
            return {uid: [claim(cid=501 if uid == 7 else 502, uid=uid,
                                pid="p1" if uid == 7 else "p2",
                                status="processed" if len(reads) == 1 else "reverted")]}

        report = pc.apply_plan(report, client=self.client,
                               ledger=common.Ledger(self.dir / "ledger.jsonl"), run_id="r1",
                               max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays",
                               claims_recheck=recheck)
        self.assertEqual(reads, [7, 8])          # once per write, in write order
        self.assertEqual(report.written, 1)
        self.assertEqual(report.skipped_stale, 1)
        self.assertIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a2"))

    def test_the_recheck_budget_stops_the_run_instead_of_overrunning_it(self):
        users = self.two_accounts()
        report = self.collect([claim(cid=501, pid="p1", status="processed"),
                               claim(cid=502, uid=8, pid="p2", status="processed")],
                              users=users)
        fresh = {7: [claim(cid=501, status="processed")],
                 8: [claim(cid=502, uid=8, pid="p2", status="processed")]}
        report = pc.apply_plan(report, client=self.client,
                               ledger=common.Ledger(self.dir / "ledger.jsonl"), run_id="r1",
                               max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays",
                               claims_recheck=lambda ids: {u: fresh[u] for u in ids},
                               recheck_budget_s=1.0,
                               clock=iter([0.0, 5.0, 5.0, 5.0]).__next__)
        self.assertEqual(report.written, 1)      # the first write used the whole budget
        self.assertEqual(report.skipped_stale, 0)
        self.assertIn("recheck budget", " ".join(report.notes))

    def test_an_unrelated_processed_claim_does_not_vouch_for_this_ticket(self):
        """`complete` rests on THIS ticket's claim, not on any claim the account has."""
        report = self.collect([claim(cid=501, status="processed")])
        ledger = common.Ledger(self.dir / "ledger.jsonl")
        other = claim(cid=777, pid="some-other-profile", status="processed")

        report = pc.apply_plan(report, client=self.client, ledger=ledger, run_id="r1",
                               max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays",
                               claims_recheck=lambda ids: {u: [other] for u in ids})
        self.assertEqual(report.skipped_stale, 1)      # 86a1 only
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        # 86a2 is about profile `p2`; the account's claim is on another profile, so it
        # is still genuinely unclaimed and its tag is written.
        self.assertIn(pc.DRAIN_TAG, self.client.tag_names("86a2"))
        stale = [r for r in common.read_jsonl(self.dir / "ledger.jsonl")
                 if r["action"] == "stale-skip"]
        self.assertEqual(len(stale), 1)
        self.assertIn("claim 501 is no longer in core", stale[0]["reason"])

    def test_a_malformed_claim_row_is_a_surprise_not_an_absent_claim(self):
        """A 7-column row must never become `drain:awaiting-user-submission`."""
        def broken(sql):
            if "from postgresql_core.public.claiming c" in sql:
                return '"501","7","p1","muso_artist","processed","2026-10-20T00:00:00Z","{}"'
            return fake_trino({"customer@example.com": 7})(sql)

        with self.assertRaises(pc.Surprise) as caught:
            pc.collect(client=self.client, now=NOW, run=broken,
                       ask_path=self._write("asked.jsonl", []),
                       executor_path=self._write("audit.jsonl", []))
        self.assertIn("7-column row", str(caught.exception))
        self.assertEqual([c for c in self.client.calls if c[0] == "POST"], [])

    def test_unreadable_verification_links_is_a_surprise(self):
        """Malformed links JSON reads as "no proof" -> `verification-required`. Refuse."""
        def broken(sql):
            if "from postgresql_core.public.claiming c" in sql:
                return ('"501","7","p1","muso_artist","pending","2026-10-20T00:00:00Z",'
                        '"not-json",' '"waiting"')
            return fake_trino({"customer@example.com": 7})(sql)

        with self.assertRaises(pc.Surprise) as caught:
            pc.collect(client=self.client, now=NOW, run=broken,
                       ask_path=self._write("asked.jsonl", []),
                       executor_path=self._write("audit.jsonl", []))
        self.assertIn("verificationlinks", str(caught.exception))

    def test_apply_never_writes_a_clickup_status(self):
        report = self.collect([claim(cid=1, pid="p1", status="processed")])
        pc.apply_plan(report, client=self.client, ledger=common.Ledger(self.dir / "l.jsonl"),
                      run_id="run1", max_writes=100, now_iso=lambda: "x", tray_dir=self.dir / "trays")
        self.assertEqual({m for m, _p in self.client.calls}, {"GET", "POST"})
        self.assertEqual([p for m, p in self.client.calls if m == "POST" and "/tag/" not in p], [])

    def test_a_contradiction_writes_a_tray_and_tags_nothing(self):
        snap = snapshot_for(claim(cid=1, pid="p1"))
        with mock.patch.object(pc, "_snapshot_batch", lambda ids, run=None: {1: snap}), \
                mock.patch.object(pc.decline_rules, "reproduce",
                                  lambda s: pc.decline_rules.Decision(
                                      1, "decline", "impersonation",
                                      "c6-decline-rules-v1:impersonation", "claim matches another's profile")):
            report = pc.collect(client=self.client, now=NOW,
                                run=fake_trino({"customer@example.com": 7}, [claim(cid=1, pid="p1")]),
                                gate=fake_gate("allow"),
                                ask_path=self.dir / "none.jsonl",
                                executor_path=self.dir / "none2.jsonl")
            self.assertEqual(report.buckets[pc.B_CONTRADICTION], 1)
            report = pc.apply_plan(report, client=self.client, ledger=common.Ledger(self.dir / "l.jsonl"),
                                   run_id="run2", max_writes=100, now_iso=lambda: "x",
                                   tray_dir=self.dir / "trays")
        self.assertEqual(len(report.trays), 1)
        tray = json.loads(pathlib.Path(report.trays[0]["path"]).read_text())
        self.assertEqual(tray["action"], "reject_claim")
        self.assertEqual([r["claim_id"] for r in tray["rows"]], [1])
        self.assertIn("credit-fable-execute.py", report.trays[0]["executor_command"])
        self.assertNotIn(pc.OUTCOME_COMPLETE, self.client.tag_names("86a1"))
        self.assertNotIn(pc.DRAIN_TAG, self.client.tag_names("86a1"))
        self.assertEqual([p for m, p in self.client.calls if m != "GET" and p.startswith("/task/86a1")], [])

    def test_a_held_account_never_reaches_the_tray(self):
        snap = snapshot_for(claim(cid=1, pid="p1"))
        with mock.patch.object(pc, "_snapshot_batch", lambda ids, run=None: {1: snap}), \
                mock.patch.object(pc.decline_rules, "reproduce",
                                  lambda s: pc.decline_rules.Decision(
                                      1, "decline", "impersonation",
                                      "c6-decline-rules-v1:impersonation", "claim matches another's profile")):
            report = pc.collect(client=self.client, now=NOW,
                                run=fake_trino({"customer@example.com": 7}, [claim(cid=1, pid="p1")]),
                                gate=fake_gate("hold", reasons=("held",)),
                                ask_path=self.dir / "none.jsonl",
                                executor_path=self.dir / "none2.jsonl")
        self.assertEqual(report.buckets[pc.B_HELD], 1)
        self.assertEqual(report.trays, [])

    def test_a_gate_budget_shortfall_holds_rather_than_queues(self):
        snap = snapshot_for(claim(cid=1, pid="p1"))
        with mock.patch.object(pc, "_snapshot_batch", lambda ids, run=None: {1: snap}), \
                mock.patch.object(pc.decline_rules, "reproduce",
                                  lambda s: pc.decline_rules.Decision(
                                      1, "decline", "impersonation",
                                      "c6-decline-rules-v1:impersonation", "claim matches another's profile")):
            report = pc.collect(client=self.client, now=NOW,
                                run=fake_trino({"customer@example.com": 7}, [claim(cid=1, pid="p1")]),
                                gate=fake_gate("allow"), max_gate_calls=1,
                                ask_path=self.dir / "none.jsonl",
                                executor_path=self.dir / "none2.jsonl")
        self.assertEqual(report.buckets[pc.B_CONTRADICTION], 1)

    def test_an_unreadable_replica_read_never_reads_as_no_claim_row(self):
        def boom(_sql):
            raise pc.Surprise("replica read failed rc=1")
        with self.assertRaises(pc.Surprise):
            pc.collect(client=self.client, now=NOW, run=boom,
                       ask_path=self.dir / "none.jsonl", executor_path=self.dir / "none2.jsonl")


FORBIDDEN_IN_DRAINER = ("/admin/claiming", "/verify", "claiming/", "PUT", "PATCH")


def executable_source(src: str) -> str:
    """`src` with every comment and every docstring blanked out.

    The no-approval assertion has to look at the WHOLE file, and it has to look at
    code only: the module docstring legitimately names `POST /admin/claiming/:id/verify`
    to say the drainer must never call it, and a comment may name it too. An earlier
    version sliced the source on the triple-quote delimiter and kept only the text
    between the module docstring and the NEXT docstring — which discarded every
    function body, so an approval call added in `main()` passed CI (QA finding,
    PR #1712). Docstrings are found with `ast` (so a triple quote inside a string
    cannot shift the window) and comments with `tokenize` (so a `#` inside a string
    is not mistaken for one).
    """
    lines = src.splitlines()
    blank = set()
    for node in ast.walk(ast.parse(src)):
        body = getattr(node, "body", None)
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)) or not body:
            continue
        first = body[0]
        if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            blank.update(range(first.lineno, (first.end_lineno or first.lineno) + 1))
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type == tokenize.COMMENT:
            row, col = tok.start
            lines[row - 1] = lines[row - 1][:col]
    return "\n".join("" if i in blank else line for i, line in enumerate(lines, 1))


class TheExecutorKillSwitch(unittest.TestCase):
    """The drainer must name EVERY file that stops the executor, not just one.

    `fable_executor` honours both the current kill-file name and the legacy one,
    so a note that names only one of them tells a human to remove a file that
    does not exist while the executor keeps refusing the tray. The tuple is read
    from the executor module, so an upstream rename cannot leave this stale.
    """

    def test_the_drainer_reads_the_executors_whole_kill_set(self):
        from credit_review import fable_executor as fx
        self.assertIsInstance(pc.EXECUTOR_KILL, tuple)
        self.assertEqual(pc.EXECUTOR_KILL, tuple(fx.KILL_FILES))
        self.assertGreaterEqual(len(pc.EXECUTOR_KILL), 2)

    def test_the_env_override_replaces_the_whole_set(self):
        env = dict(os.environ, CLICKUP_DRAIN_EXECUTOR_KILL="/tmp/only-this.disabled")
        out = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, 'scripts');"
             "from clickup_drain import profile_claim as pc; print(pc.EXECUTOR_KILL)"],
            cwd=ROOT, env=env, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "('/tmp/only-this.disabled',)")


class ThereIsNoApprovalPath(unittest.TestCase):
    """The spec's hardest line: this file must not be able to approve a claim."""

    def test_source_has_no_approval_route_and_no_reject_write(self):
        src = (ROOT / "scripts" / "clickup_drain" / "profile_claim.py").read_text()
        code = executable_source(src)
        for forbidden in FORBIDDEN_IN_DRAINER:
            self.assertNotIn(forbidden, code,
                             f"{forbidden} must not appear in the drainer's code")

    def test_the_no_approval_check_catches_a_call_added_anywhere_in_the_file(self):
        """A false-green guard is worse than no guard: prove the check can fail.

        The forbidden call is inserted AFTER the module docstring and after the
        first function, i.e. exactly in the region the old triple-quote-split
        window threw away (QA finding, PR #1712).
        """
        src = (ROOT / "scripts" / "clickup_drain" / "profile_claim.py").read_text()
        lines = src.splitlines()
        anchor = next(i for i, l in enumerate(lines) if l.startswith("def main("))
        injected = "\n".join(lines[:anchor + 1] + [
            '    client.request("POST", f"/admin/claiming/{cid}/verify")',
        ] + lines[anchor + 1:])
        code = executable_source(injected)
        self.assertIn("/admin/claiming", code)
        self.assertIn("/verify", code)
        # ...and the same insertion is invisible to the old window, which is why
        # this test exists.
        old_window = injected.split('"""')[2]
        self.assertNotIn("/admin/claiming", old_window)

    def test_the_drainer_imports_the_executors_rules_rather_than_copying_them(self):
        src = (ROOT / "scripts" / "clickup_drain" / "profile_claim.py").read_text()
        self.assertIn("from claim_verify import decline_rules", src)
        self.assertIn("from credit_review import claim_executor as cx", src)
        self.assertNotIn("another_persons_profile", src)   # the class names live in one place

    def test_the_tray_command_goes_through_the_executor_cli(self):
        cmd = pc.executor_command("/tmp/tray.json")
        self.assertIn("credit-fable-execute.py /tmp/tray.json --apply", cmd)
        self.assertNotIn("--approve", cmd)


if __name__ == "__main__":
    unittest.main()
