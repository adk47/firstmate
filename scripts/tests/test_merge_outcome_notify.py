"""merge-outcome-notify.py: the fixed in-thread outcome message for merge tickets
(Fable ops-takeover 2026-10-19 §4 step 4). Network is faked; nothing is sent."""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("merge_outcome_notify", ROOT / "scripts" / "merge-outcome-notify.py")
mon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mon)  # type: ignore[union-attr]

EMAIL = "jane@example.com"


class FakeClickUp(mon.clickup_client.ClickUp):
    """The real client's paging/dedupe on top of a faked transport."""

    def __init__(self, http):
        super().__init__("k")
        self._http = http

    def request(self, method, url, body=None, timeout=60):
        return self._http(method, url if url.startswith("http") else self.base + url, {}, body)


def load_legacy():
    spec = importlib.util.spec_from_file_location(
        "notify_merged_customers", ROOT / "scripts" / "dedup" / "sweeps" / "notify-merged-customers.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    mod._merge_outcome_notify = lambda: mon
    return mod


def day(days_ago=0):
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).strftime("%Y-%m-%d")


def task(tid="t1", kind="profile-merge", outcomes=("merged",), extra_tags=(), prio=None, created=1000,
         email=EMAIL, conv="900", at=None, updated=None):
    at_tags = [] if at == "" else [f"merge-outcome-at:{at or day()}"]
    tags = ["hydra-action-request", f"action:{kind}", *[f"merge-outcome:{o}" for o in outcomes], *at_tags,
            *extra_tags]
    ar = {"action_type": kind, "customer_email": email, "details": {}}
    return {"id": tid, "tags": [{"name": t} for t in tags], "date_created": str(created),
            **({"date_updated": str(int(updated * 1000))} if updated is not None else {}),
            "priority": {"orderindex": str(prio)} if prio else None,
            "description": f"**Conversation:** https://app.intercom.com/a/inbox/x/inbox/conversation/{conv}\n"
                           f"---ACTION-REQUEST---\n{json.dumps(ar)}\n---END-ACTION-REQUEST---"}


def conv(email=EMAIL, state="open", last_admin=None, assignee=None, last_body="x"):
    parts = ([{"author": {"type": "admin", "id": last_admin}, "body": last_body, "created_at": int(time.time())}]
             if last_admin else [])
    return {"source": {"author": {"email": email}}, "state": state, "tags": {"tags": []},
            "admin_assignee_id": assignee, "conversation_parts": {"conversation_parts": parts}}


class Fake:
    def __init__(self, tasks, convs):
        self.tasks, self.convs, self.posts, self.tags, self.skip_tags, self.untags = tasks, convs, [], [], [], []
        self.untag_status = 204

    def http(self, method, url, headers, body=None, **_):
        if method == "GET" and "/task?" in url:
            kind = url.split("tags%5B%5D=action%3A")[1].split("&")[0]
            page = int(url.split("page=")[1].split("&")[0])
            return 200, {"tasks": [t for t in self.tasks if {"name": f"action:{kind}"} in t["tags"]] if page == 0 else [],
                         "last_page": True}
        if method == "POST" and "/tag/" in url:
            tid, tag = url.split("/task/")[1].split("/tag/")
            (self.tags if tag == mon.NOTIFIED_TAG else self.skip_tags).append(tid)
            for t in self.tasks:
                if t["id"] == tid:
                    t["tags"].append({"name": tag})
            return 200, {}
        if method == "DELETE" and "/tag/" in url:
            tid, tag = url.split("/task/")[1].split("/tag/")
            self.untags.append((tid, tag))
            if self.untag_status != 204:
                return self.untag_status, {"err": "boom"}
            for t in self.tasks:
                if t["id"] == tid:
                    t["tags"] = [x for x in t["tags"] if x["name"] != tag]
            return 204, None
        if method == "POST" and url.endswith("/reply"):
            self.posts.append((url.split("/conversations/")[1].split("/")[0], body["admin_id"], body["body"]))
            return 200, {}
        raise AssertionError(url)

    def get_conversation(self, cid, token):
        return self.convs[cid]


class MergeOutcomeNotifyTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="merge-outcome-"))
        os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t",
                           "MERGE_OUTCOME_STATE": str(self.dir / "state.json"),
                           "MERGE_KEEP_CONFLICT_SPOOL": str(self.dir / "spool")})
        self._shared, self.cu = mon.clickup_client.shared, None
        mon.clickup_client.shared = lambda key, base=None: self.cu
        self._orig = (mon.rn.http, mon.rn.get_conversation, mon.rn.urllib.request.urlopen, mon.rn.time.sleep,
                      mon.MERGE_OUTCOME_COPY_APPROVED, mon.rn.post_slack)
        self.slack, self.slack_ok = [], True

        def post_slack(text, channel, config_path, account):
            self.slack.append((channel, account, text))
            return self.slack_ok
        mon.rn.post_slack = post_slack

    def tearDown(self):
        mon.clickup_client.shared = self._shared
        (mon.rn.http, mon.rn.get_conversation, mon.rn.urllib.request.urlopen, mon.rn.time.sleep,
         mon.MERGE_OUTCOME_COPY_APPROVED, mon.rn.post_slack) = self._orig

    def wire(self, tasks, convs):
        f = Fake(tasks, convs)
        mon.rn.http, mon.rn.get_conversation = f.http, f.get_conversation
        self.cu = FakeClickUp(f.http)
        return f

    def state(self):
        return {k: v["state"] for k, v in json.loads((self.dir / "state.json").read_text())["tickets"].items()}

    def reasons(self):
        return {k: v["reason"] for k, v in json.loads((self.dir / "state.json").read_text())["tickets"].items()
                if "reason" in v}

    def run_main(self, argv):
        out = StringIO()
        with redirect_stdout(out):
            rc = mon.main(argv)
        return rc, out.getvalue()

    def test_every_kind_and_outcome_has_fixed_copy_without_placeholders_or_dashes(self):
        self.assertEqual(len(mon.COPY), 9)
        for text in mon.COPY.values():
            self.assertNotIn("{", text)
            self.assertNotIn("\u2014", text)
            for bad in ("fraud", "ticket", "days", "hours", "guarantee", "undo it", "two different people"):
                self.assertNotIn(bad, text.lower())
        for kind in ("profile-merge", "track-merge"):
            self.assertIn("we'll take another look", mon.COPY[(kind, "merged")])
        self.assertEqual(mon.COPY[("profile-merge", "not-merged")],
                         "Hi! We looked at both profiles carefully, and we couldn't confirm both profiles belong "
                         "to you, so we haven't merged them. If they are both yours, reply here with something "
                         "that shows it, for example a Spotify for Artists or Apple Music for Artists link, and "
                         "we'll take another look.")

    def test_every_clickup_page_is_read_until_the_last_page_even_past_50(self):
        pages = 51
        requested = []

        def http(method, url, headers, body=None, **_):
            kind = url.split("tags%5B%5D=action%3A")[1].split("&")[0]
            page = int(url.split("page=")[1].split("&")[0])
            requested.append((kind, page))
            return 200, {"tasks": [{"id": f"{kind}-{page}"}], "last_page": page == pages - 1}
        self.cu = FakeClickUp(http)
        ids = {t["id"] for t in mon.fetch_merge_tasks("k", "list9")}
        self.assertEqual(ids, {f"{k}-{p}" for k in mon.KINDS for p in range(pages)})
        self.assertEqual(len(requested), pages * len(mon.KINDS))

    def test_approved_as_committed_and_apply_refused_when_unapproved(self):
        self.assertTrue(mon.MERGE_OUTCOME_COPY_APPROVED)
        mon.MERGE_OUTCOME_COPY_APPROVED = False
        f = self.wire([task()], {"900": conv()})
        self.assertEqual(mon.main(["--apply"]), 1)
        self.assertEqual(f.posts, [])

    def test_an_outcome_older_than_7_days_or_undated_is_never_messaged_and_listed_for_a_human(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        tasks = [task("old", conv="901", at=day(8)), task("undated", conv="902", at=""),
                 task("bad-date", conv="903", at="last-tuesday"), task("week", conv="904", at=day(6))]
        f = self.wire(tasks, {c: conv() for c in ("901", "902", "903", "904")})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual([p[0] for p in f.posts], ["904"])
        self.assertIn('stale outcome, for a human: ["bad-date", "old", "undated"]', out)
        self.assertEqual(self.state(), {"week": "sent", "old": "skipped-tags", "undated": "skipped-tags",
                                        "bad-date": "skipped-tags"})
        self.assertEqual(sorted(f.skip_tags), ["bad-date", "old", "undated"])
        self.assertEqual(len(self.slack), 1)
        channel, account, text = self.slack[0]
        self.assertEqual((channel, account), ("C0BBTAVP44X", "operations"))
        for line in ("bad-date> profile-merge/merged (undated)", "old> profile-merge/merged (stale)",
                     "undated> profile-merge/merged (undated)"):
            self.assertIn(line, text)
        self.assertNotIn(EMAIL, text)
        self.assertNotIn("week", text)

    def test_tickets_it_will_never_send_are_marked_skipped_and_the_legacy_path_takes_them(self):
        legacy = load_legacy()
        tasks = [task("seeded", conv="901", at=day(3)), task("no-conv", conv="", at=day(0)),
                 task("held", conv="903", at=day(0)), task("sent", conv="904", at=day(0))]
        f = self.wire(tasks, {"903": conv(assignee="12345"), "904": conv()})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual([p[0] for p in f.posts], ["904"])
        self.assertEqual(sorted(f.skip_tags), ["no-conv", "seeded"])
        self.assertEqual(self.state(), {"seeded": "seeded", "no-conv": "skipped", "sent": "sent"})
        self.assertIn("notify-merged-customers.py", self.slack[0][2])
        owns = {t["id"]: legacy.merge_outcome_notifier_owns(t) for t in tasks}
        self.assertEqual(owns, {"seeded": False, "no-conv": False, "held": True, "sent": True})
        for t in tasks:
            t["tags"] = [x for x in t["tags"] if x["name"] != mon.SKIPPED_TAG]
        self.assertFalse(legacy.merge_outcome_notifier_owns(tasks[0]))
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(sorted(f.skip_tags), ["no-conv", "no-conv", "seeded", "seeded"])
        self.assertEqual(len(f.posts), 1)

    def test_an_undated_outcome_settles_for_30_minutes_before_it_is_skipped(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        t = task("undated", conv="901", at="", updated=time.time())
        f = self.wire([t], {"901": conv()})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertIn('"settling": 1', out)
        self.assertEqual((self.state(), f.skip_tags, self.slack, f.posts), ({}, [], [], []))
        t["date_updated"] = str(int((time.time() - 31 * 60) * 1000))
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {"undated": "skipped-tags"})
        self.assertEqual(f.skip_tags, ["undated"])
        self.assertEqual(len(self.slack), 1)
        self.assertEqual(f.posts, [])

    def test_a_never_flagged_tag_skipped_ticket_that_gains_a_valid_fresh_date_is_sent_once(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        t = task("late-date", conv="901", at="")
        f = self.wire([t], {"901": conv()})
        self.slack_ok = False
        self.assertEqual(mon.main(["--apply"]), 3)
        self.slack_ok = True
        self.assertEqual(self.state(), {"late-date": "skipped-tags"})
        legacy = load_legacy()
        self.assertFalse(legacy.merge_outcome_notifier_owns(t))
        t["tags"].append({"name": f"merge-outcome-at:{day()}"})
        self.assertTrue(legacy.merge_outcome_notifier_owns(t))
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["901"])
        self.assertEqual(f.untags, [("late-date", mon.SKIPPED_TAG)])
        self.assertEqual(self.state(), {"late-date": "sent"})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(f.posts), 1)

    def test_a_flagged_ticket_is_never_auto_sent_after_a_human_handled_it(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        t = task("ev", conv="901", at="", outcomes=("needs-evidence",), updated=time.time() - 31 * 60)
        f = self.wire([t], {"901": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {"ev": "skipped-tags"})
        self.assertIn("ev> profile-merge/needs-evidence (undated): for a human reply", self.slack[0][2])
        f.convs["901"]["conversation_parts"]["conversation_parts"] = [
            {"author": {"type": "admin", "id": "12345"}, "body": "could you send a Spotify for Artists link?"},
            {"author": {"type": "user", "email": EMAIL}, "body": "here it is"}]
        t["tags"].append({"name": f"merge-outcome-at:{day()}"})
        self.assertFalse(load_legacy().merge_outcome_notifier_owns(t))
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertIn('flagged earlier, left with the human: ["ev"]', out)
        self.assertEqual(self.state(), {"ev": "skipped"})
        rc, out = self.run_main(["--apply"])
        self.assertIn('flagged earlier, left with the human: []', out)
        self.assertEqual((f.posts, f.untags, len(self.slack)), ([], [], 1))

    def test_a_skip_is_cleared_only_after_the_untag_succeeds(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {"late": "skipped-tags"}}))
        t = task("late", conv="901", extra_tags=(mon.SKIPPED_TAG,))
        f = self.wire([t], {"901": conv()})
        f.untag_status = 500
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertEqual(self.state(), {"late": "skipped-tags"})
        self.assertEqual(f.posts, [])
        f.untag_status = 204
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {"late": "sent"})
        self.assertEqual(len(f.posts), 1)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(f.posts), 1)

    def test_a_permanently_skipped_ticket_stays_skipped(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        t = task("no-conv", conv="")
        f = self.wire([t], {})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {"no-conv": "skipped"})
        self.assertEqual((f.untags, f.posts, len(self.slack)), ([], [], 1))

    def test_an_email_mismatch_is_marked_skipped_and_flagged_never_sent(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        t = task("mismatch", conv="901")
        f = self.wire([t], {"901": conv(email="someone-else@example.com")})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(f.posts, [])
        self.assertEqual(self.state(), {"mismatch": "skipped"})
        self.assertEqual(f.skip_tags, ["mismatch"])
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 <https://app.clickup.com/t/mismatch|mismatch> profile-merge/merged "
                      "(email mismatch): for a human reply\n", self.slack[0][2] + "\n")
        self.assertNotIn("(email mismatch): legacy", self.slack[0][2])
        self.assertNotIn("someone-else", self.slack[0][2])
        self.assertFalse(load_legacy().merge_outcome_notifier_owns(t))
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual((f.posts, len(self.slack)), ([], 1))

    def test_an_email_mismatch_keeps_its_line_when_the_first_slack_post_fails(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        f = self.wire([task("mismatch", conv="901")], {"901": conv(email="someone-else@example.com")})
        self.slack_ok = False
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertEqual((self.state(), self.reasons()), ({"mismatch": "skipped"}, {"mismatch": "email mismatch"}))
        self.slack_ok = True
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 2)
        retry = self.slack[1][2]
        self.assertIn("\u2022 <https://app.clickup.com/t/mismatch|mismatch> profile-merge/merged "
                      "(email mismatch): for a human reply\n", retry + "\n")
        self.assertNotIn("legacy merge-complete note\n", retry + "\n")
        self.assertEqual(f.posts, [])

    def test_plain_string_state_entries_are_read_and_rewritten_as_records(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {"old": "sent", "s": "seeded"}, "flagged": ["s"]}))
        f = self.wire([task("old", conv="901"), task("new", conv="902")], {"901": conv(), "902": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["902"])
        raw = json.loads((self.dir / "state.json").read_text())
        self.assertEqual(raw["tickets"], {"old": {"state": "sent"}, "s": {"state": "seeded"},
                                          "new": {"state": "sent", "outcomes": ["merged"]}})
        self.assertEqual(raw["flagged"], ["s"])

    def test_a_sent_or_attempted_ticket_that_turns_ambiguous_keeps_its_state(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {"att": "attempted"}}))
        tasks = [task("sent", conv="901"), task("att", conv="902", outcomes=("merged", "not-merged"))]
        f = self.wire(tasks, {"901": conv(), "902": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        tasks[0]["tags"].append({"name": "merge-outcome:not-merged"})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {"sent": "sent", "att": "attempted"})
        self.assertEqual((f.skip_tags, self.slack, len(f.posts)), ([], [], 1))
        self.assertTrue(load_legacy().merge_outcome_notifier_owns(tasks[1]))

    def test_the_slack_post_names_the_legacy_note_only_for_profile_merge_merged(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        tasks = [task("pm", conv="", kind="profile-merge"), task("um", conv="", kind="unmerge-request"),
                 task("tm", conv="", kind="track-merge"), task("pe", conv="", outcomes=("needs-evidence",))]
        self.wire(tasks, {})
        self.assertEqual(mon.main(["--apply"]), 0)
        text = self.slack[0][2]
        self.assertIn("pm> profile-merge/merged (no conversation): legacy merge-complete note", text)
        for line in ("um> unmerge-request/merged (no conversation): for a human reply",
                     "tm> track-merge/merged (no conversation): for a human reply",
                     "pe> profile-merge/needs-evidence (no conversation): for a human reply"):
            self.assertIn(line, text)

    def test_tickets_for_a_human_are_posted_to_slack_once_each(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        f = self.wire([task("old", conv="901", at=day(8))], {"901": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)
        f.tasks.append(task("undated", conv="902", at=""))
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 2)
        self.assertIn("undated>", self.slack[1][2])
        self.assertNotIn("old>", self.slack[1][2])
        self.assertEqual(f.posts, [])

    def test_a_failed_slack_post_fails_the_run_and_is_retried_next_run(self):
        f = self.wire([task("two-days", conv="902", at=day(2))], {"902": conv()})
        self.slack_ok = False
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertEqual(self.state(), {"two-days": "seeded"})
        self.slack_ok = True
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 2)
        self.assertIn("two-days> profile-merge/merged (seeded)", self.slack[1][2])
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 2)
        self.assertEqual(f.posts, [])

    def test_first_run_seeds_outcomes_older_than_24h_and_sends_newer_ones(self):
        tasks = [task("fresh", conv="901"), task("two-days", conv="902", at=day(2)),
                 task("stale", conv="903", at=day(9))]
        f = self.wire(tasks, {c: conv() for c in ("901", "902", "903")})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertIn('SEEDED (first run, outcome older than 24h, not messaged): 2 ["stale", "two-days"]', out)
        self.assertEqual([p[0] for p in f.posts], ["901"])
        self.assertEqual(self.state(), {"fresh": "sent", "stale": "seeded", "two-days": "seeded"})
        self.assertEqual(len(self.slack), 1)
        self.assertIn("stale> profile-merge/merged (seeded)", self.slack[0][2])
        self.assertIn("two-days> profile-merge/merged (seeded)", self.slack[0][2])
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(f.posts), 1)
        self.assertEqual(len(self.slack), 1)

    def test_seeding_happens_only_once_and_a_dry_run_writes_no_seed(self):
        f = self.wire([task("two-days", conv="902", at=day(2))], {"902": conv()})
        rc, out = self.run_main([])
        self.assertIn('WOULD SEED (first run, outcome older than 24h, not messaged): 1 ["two-days"]', out)
        self.assertFalse((self.dir / "state.json").exists())
        self.assertEqual(self.slack, [])
        f.tasks = []
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {})
        f.tasks = [task("two-days", conv="902", at=day(2))]
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["902"])

    def test_dry_run_lists_without_posting_or_tagging(self):
        f = self.wire([task()], {"900": conv()})
        self.assertEqual(mon.main([]), 0)
        self.assertEqual((f.posts, f.tags), ([], []))

    def test_unlocked_posts_once_per_ticket_ever_as_caroline_then_tags(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        f = self.wire([task()], {"900": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(f.posts, [("900", "5763097", mon.COPY[("profile-merge", "merged")])])
        self.assertEqual(f.tags, ["t1"])
        self.assertEqual(self.state(), {"t1": "sent"})
        self.assertEqual(mon.main(["--apply"]), 0)  # the state file remembers it
        self.assertEqual(len(f.posts), 1)

    def test_a_timed_out_post_is_tried_once_recorded_and_never_retried(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        f = self.wire([task()], {"900": conv()})
        real_http = self._orig[0]
        mon.rn.http = lambda method, url, *a, **k: (real_http(method, url, *a, **k) if url.endswith("/reply")
                                                   else f.http(method, url, *a, **k))
        opened = []

        def timeout(req, timeout=None):
            opened.append(req.full_url)
            raise socket.timeout("timed out")
        mon.rn.urllib.request.urlopen = timeout
        mon.rn.time.sleep = lambda s: None
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0].endswith("/conversations/900/reply"))
        self.assertEqual(self.state(), {"t1": "attempted"})
        self.assertEqual(f.tags, [])
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(opened), 1)

    def test_the_ticket_is_recorded_attempted_before_the_post(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        f = self.wire([task()], {"900": conv()})
        seen = []
        fake_http = f.http

        def http(method, url, *a, **k):
            if url.endswith("/reply"):
                seen.append(self.state())
            return fake_http(method, url, *a, **k)
        mon.rn.http = http
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(seen, [{"t1": "attempted"}])
        self.assertEqual(self.state(), {"t1": "sent"})

    def test_a_concurrent_run_is_refused(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        f = self.wire([task()], {"900": conv()})
        held = mon.rn._acquire_state_lock(str(self.dir / "state.json"))
        try:
            self.assertEqual(mon.main(["--apply"]), 1)
        finally:
            held.close()
        self.assertEqual(f.posts, [])

    def test_gates_refuse_ambiguous_or_unsafe_tickets(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        tasks = [task("a", outcomes=()), task("b", outcomes=("merged", "not-merged")),
                 task("c", outcomes=("approved",)), task("d", extra_tags=("merge-outcome-notified",)),
                 task("e", email="", conv="905"), task("f", conv="906"), task("g", conv="907"),
                 task("h", conv="908"), task("i", conv="909")]
        convs = {"906": conv(email="other@example.com"), "907": conv(state="closed", assignee="12345"),
                 "908": conv(last_admin="12345"), "909": conv(last_admin="5763097")}
        f = self.wire(tasks, convs)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["909"])  # only the one where Caroline spoke last

    def test_a_closed_or_snoozed_thread_gets_the_reply_a_human_assigned_one_does_not(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        tasks = [task("closed", conv="901"), task("snoozed", conv="902", email="sam@example.com"),
                 task("assigned", conv="903")]
        f = self.wire(tasks, {"901": conv(state="closed"), "902": conv(email="sam@example.com", state="snoozed"),
                              "903": conv(assignee="12345")})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(sorted(p[0] for p in f.posts), ["901", "902"])
        self.assertEqual(sorted(f.tags), ["closed", "snoozed"])

    def test_a_customer_already_told_by_the_legacy_merge_note_is_never_told_again(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        legacy = ("hi! just confirming your profile merge request is done. the credits we found are now "
                  "consolidated under your main profile. let me know if anything's off.")
        tasks = [task("tagged", conv="901", extra_tags=("customer-outcome:complete",)),
                 task("legacy-note", conv="902"),
                 task("fresh", conv="903")]
        convs = {"901": conv(), "902": conv(state="closed", last_admin="5763097", last_body=legacy),
                 "903": conv(last_admin="5763097", last_body="thanks, I've filed it for the team")}
        f = self.wire(tasks, convs)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["903"])
        self.assertEqual(f.tags, ["fresh"])
        self.assertEqual(self.state(), {"fresh": "sent"})

    def next_day(self):
        raw = json.loads((self.dir / "state.json").read_text())
        raw["users"] = {u: day(1) for u in raw.get("users", {})}
        (self.dir / "state.json").write_text(json.dumps(raw))

    def test_a_needs_evidence_ask_is_followed_by_its_outcome_note_once(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        for final in ("merged", "not-merged"):
            with self.subTest(final=final):
                tid = f"ev-{final}"
                t = task(tid, conv=f"9{len(final)}", outcomes=("needs-evidence",))
                f = self.wire([t], {t["description"].split("conversation/")[1].split("\n")[0]: conv()})
                self.assertEqual(mon.main(["--apply"]), 0)
                self.assertEqual([p[2] for p in f.posts], [mon.COPY[("profile-merge", "needs-evidence")]])
                t["tags"] = [x for x in t["tags"] if x["name"] != "merge-outcome:needs-evidence"]
                t["tags"].append({"name": f"merge-outcome:{final}"})
                legacy = load_legacy()
                self.assertTrue(legacy.merge_outcome_notifier_owns(t))
                rc, out = self.run_main(["--apply"])
                self.assertEqual(rc, 0)
                self.assertIn('"same-user-today": 1', out)
                self.assertEqual(len(f.posts), 1)
                self.next_day()
                self.assertEqual(mon.main(["--apply"]), 0)
                self.assertEqual([p[2] for p in f.posts], [mon.COPY[("profile-merge", "needs-evidence")],
                                                           mon.COPY[("profile-merge", final)]])
                self.assertTrue(legacy.merge_outcome_notifier_owns(t))
                self.next_day()
                self.assertEqual(mon.main(["--apply"]), 0)
                self.assertEqual(len(f.posts), 2)
                raw = json.loads((self.dir / "state.json").read_text())["tickets"][tid]
                self.assertEqual(raw, {"state": "sent", "outcomes": ["needs-evidence", final]})
                self.assertEqual(self.slack, [])

    def test_no_other_outcome_change_sends_a_second_note(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        tasks = [task("m", conv="901"), task("n", conv="902", outcomes=("not-merged",), email="bo@example.com"),
                 task("e", conv="903", outcomes=("needs-evidence",), email="cy@example.com")]
        f = self.wire(tasks, {"901": conv(), "902": conv(email="bo@example.com"),
                              "903": conv(email="cy@example.com")})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(f.posts), 3)
        for t, nxt in zip(tasks, ("needs-evidence", "merged", "needs-evidence")):
            t["tags"] = [x for x in t["tags"] if not x["name"].startswith("merge-outcome:")]
            t["tags"].append({"name": f"merge-outcome:{nxt}"})
        self.next_day()
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertIn('"already-notified": 3', out)
        self.assertEqual((len(f.posts), self.slack), (3, []))

    def test_a_plain_sent_entry_gets_no_follow_up(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {"old": "sent"}}))
        f = self.wire([task("old", conv="901", extra_tags=(mon.NOTIFIED_TAG,))], {"901": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(f.posts, [])

    def test_a_stale_follow_up_goes_to_a_human_once_never_to_the_legacy_note(self):
        (self.dir / "state.json").write_text(json.dumps(
            {"tickets": {"ev": {"state": "sent", "outcomes": ["needs-evidence"]}}}))
        t = task("ev", conv="901", at=day(8), extra_tags=(mon.NOTIFIED_TAG,))
        f = self.wire([t], {"901": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 <https://app.clickup.com/t/ev|ev> profile-merge/merged "
                      "(follow-up after needs-evidence, stale): for a human reply\n", self.slack[0][2] + "\n")
        self.assertTrue(load_legacy().merge_outcome_notifier_owns(t))
        t["tags"] = [x for x in t["tags"] if not x["name"].startswith("merge-outcome-at:")]
        t["tags"].append({"name": f"merge-outcome-at:{day()}"})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual((f.posts, f.skip_tags, len(self.slack)), ([], [], 1))
        self.assertEqual(self.state(), {"ev": "sent"})

    def test_one_message_per_customer_per_utc_day_across_tickets(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        tasks = [task("a", conv="901", created=1), task("b", conv="902", created=2, kind="track-merge")]
        f = self.wire(tasks, {"901": conv(), "902": conv()})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual([p[0] for p in f.posts], ["901"])
        self.assertIn('"same-user-today": 1', out)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(f.posts), 1)
        self.next_day()
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["901", "902"])
        self.assertNotIn(EMAIL, (self.dir / "state.json").read_text())

    def test_an_older_legacy_note_in_the_thread_does_not_block_a_later_ticket(self):
        legacy = ("hi! just confirming your profile merge request is done. the credits we found are now "
                  "consolidated under your main profile.")
        now = time.time()
        old_note = {"author": {"type": "admin", "id": "5763097"}, "body": legacy, "created_at": int(now - 86400)}
        tasks = [task("un", conv="901", kind="unmerge-request", outcomes=("needs-evidence",),
                      created=int(now * 1000)),
                 task("pm2", conv="902", created=int(now * 1000), email="bo@example.com"),
                 task("pm1", conv="903", created=int((now - 2 * 86400) * 1000), email="cy@example.com")]
        convs = {c: conv(email=e) for c, e in (("901", EMAIL), ("902", "bo@example.com"), ("903", "cy@example.com"))}
        for c in convs.values():
            c["conversation_parts"]["conversation_parts"] = [dict(old_note)]
        f = self.wire(tasks, convs)
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(p[0] for p in f.posts), ["901", "902"])
        self.assertIn('"already-told": 1', out)

    def test_a_keep_conflict_pair_is_held_until_both_tags_are_gone(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        x = task("x", conv="901", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}y"))
        y = task("y", conv="902", email="bo@example.com", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}x"))
        f = self.wire([x, y], {"901": conv(), "902": conv(email="bo@example.com")})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertIn('"keep-conflict-held": 2', out)
        self.assertIn('keep-conflict held: ["x", "y"]', out)
        self.assertEqual((f.posts, f.tags, f.skip_tags, self.state()), ([], [], [], {}))
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 two merge requests with different profiles to keep in one conversation: "
                      "<https://app.clickup.com/t/x|x>, <https://app.clickup.com/t/y|y>\n", self.slack[0][2] + "\n")
        self.assertFalse(load_legacy().merge_outcome_notifier_owns(x))
        x["tags"] = [t for t in x["tags"] if t["name"] != mon.KEEP_CONFLICT_TAG]
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual((f.posts, len(self.slack)), ([], 1))
        y["tags"] = [t for t in y["tags"] if t["name"] != mon.KEEP_CONFLICT_TAG]
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(p[0] for p in f.posts), ["901", "902"])
        self.assertEqual(len(self.slack), 1)
        self.assertIn("keep-conflict held: [], keep-conflict tagging incomplete: []", out)

    def test_a_closed_rejected_sibling_no_longer_holds_the_kept_ticket(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        kept = task("kept", conv="901", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}rej"))
        rej = task("rej", conv="902", outcomes=(), extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}kept"))
        f = self.wire([kept, rej], {"901": conv(), "902": conv()})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(f.posts, [])
        rej["status"] = {"status": "closed", "type": "closed"}
        kept["tags"] = [t for t in kept["tags"] if t["name"] != mon.KEEP_CONFLICT_TAG]
        self.assertTrue(load_legacy().merge_outcome_notifier_owns(kept))
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(f.posts, [("901", "5763097", mon.COPY[("profile-merge", "merged")])])
        self.assertIn("keep-conflict held: [\"rej\"], keep-conflict tagging incomplete: []", out)
        self.assertEqual(len(self.slack), 1)

    def test_a_pair_reconciled_before_it_was_posted_is_never_posted_or_listed(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        x = task("x", conv="901", extra_tags=(f"{mon.KEEP_CONFLICT_WITH}y",))
        y = task("y", conv="902", email="bo@example.com", outcomes=(), extra_tags=(f"{mon.KEEP_CONFLICT_WITH}x",),
                 )
        f = self.wire([x, y], {"901": conv(), "902": conv(email="bo@example.com")})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.slack, [])
        self.assertIn("keep-conflict held: [], keep-conflict tagging incomplete: []", out)
        self.assertEqual([p[0] for p in f.posts], ["901"])

    def spool(self, name, rec):
        d = self.dir / "spool"
        d.mkdir(exist_ok=True)
        (d / f"{name}.json").write_text(json.dumps(rec))

    def test_a_spooled_unflagged_keep_conflict_is_posted_once_and_only_once(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        self.spool("r1", {"ticket_ids": ["abc123"], "conversation_id": "777", "action_type": "profile-merge",
                          "at": "2026-10-21T00:00:00Z"})
        self.wire([], {})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 keep-conflict could not be flagged in ClickUp: tickets "
                      "<https://app.clickup.com/t/abc123|abc123> and the customer's new request (not filed), "
                      "conversation 777; held for a human (r1)", self.slack[0][2])
        self.assertEqual(list((self.dir / "spool").iterdir()), [])
        self.assertEqual(mon.main(["--apply"]), 0)
        self.spool("r1", {"ticket_ids": ["abc123"]})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)

    def test_the_spool_is_posted_even_when_the_clickup_read_fails(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        self.spool("r1", {"ticket_ids": ["abc123"], "conversation_id": "777"})
        f = self.wire([task("t1", conv="901")], {"901": conv()})
        fake_http = f.http
        self.cu = FakeClickUp(lambda method, url, *a, **k: (503, {"err": "down"}) if method == "GET" and "/task?" in url
                              else fake_http(method, url, *a, **k))
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertEqual(len(self.slack), 1)
        self.assertIn("keep-conflict could not be flagged in ClickUp: tickets <https://app.clickup.com/t/abc123|abc123>",
                      self.slack[0][2])
        self.assertFalse((self.dir / "spool" / "r1.json").exists())
        self.assertEqual(json.loads((self.dir / "state.json").read_text())["spool_posted"], ["r1"])
        self.assertEqual(f.posts, [])
        self.cu = FakeClickUp(fake_http)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual((len(self.slack), [p[0] for p in f.posts]), (1, ["901"]))

    def test_a_first_run_spool_post_does_not_end_seeding_when_the_read_fails(self):
        self.spool("r1", {"ticket_ids": ["abc123"]})
        f = self.wire([task("old", conv="901", at=day(2))], {"901": conv()})
        fake_http = f.http
        self.cu = FakeClickUp(lambda method, url, *a, **k: (503, {}) if method == "GET" and "/task?" in url
                              else fake_http(method, url, *a, **k))
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertFalse((self.dir / "state.json").exists())
        self.cu = FakeClickUp(fake_http)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(self.state(), {"old": "seeded"})
        self.assertEqual(f.posts, [])
        self.assertEqual(len([m for m in self.slack if "abc123" in m[2]]), 1)

    def test_a_spooled_left_held_ticket_is_named_once_for_a_human(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        self.spool("r3", {"ticket_ids": ["k9"], "conversation_id": "777", "left_held": ["k9"]})
        self.wire([], {})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 ticket <https://app.clickup.com/t/k9|k9> left held (merge-keep-conflict) by a failed merge "
                      "filing, please check, conversation 777 (r3)", self.slack[0][2])
        self.assertNotIn("not filed", self.slack[0][2])

    def test_a_two_conflict_rollback_record_names_every_ticket_in_one_line(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        self.spool("r4", {"ticket_ids": ["k1", "k2"], "conversation_id": "777", "left_held": ["k1"]})
        self.wire([], {})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 ticket <https://app.clickup.com/t/k1|k1> left held (merge-keep-conflict) by a failed merge "
                      "filing, please check; keep-conflict could not be flagged in ClickUp: "
                      "tickets <https://app.clickup.com/t/k2|k2> and the customer's new request (not filed), "
                      "conversation 777; held for a human (r4)\n", self.slack[0][2] + "\n")

    def test_a_spooled_unwritten_intake_is_posted_once_held_or_not(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        self.spool("r5", {"ticket_ids": ["t7"], "conversation_id": "777", "intake_unwritten": True, "held": True})
        self.spool("r6", {"ticket_ids": ["t8"], "conversation_id": "778", "intake_unwritten": True, "held": False})
        self.wire([], {})
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 1)
        self.assertIn("\u2022 ticket <https://app.clickup.com/t/t7|t7>: the follow-up's merge targets could not be written "
                      "to the description; held for a human (merge-intake-stale), conversation 777 (r5)\n",
                      self.slack[0][2] + "\n")
        self.assertIn("\u2022 ticket <https://app.clickup.com/t/t8|t8>: the follow-up's merge targets could not be written "
                      "to the description; NOT held: tag it merge-intake-stale by hand, conversation 778 (r6)\n",
                      self.slack[0][2] + "\n")
        self.assertNotIn("keep-conflict could not be flagged", self.slack[0][2])

    def test_a_merge_intake_stale_ticket_is_held_until_a_human_removes_the_tag(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        x = task("x", conv="901", extra_tags=(mon.INTAKE_STALE_TAG,))
        f = self.wire([x], {"901": conv()})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertIn('"keep-conflict-held": 1', out)
        self.assertEqual((f.posts, f.tags, self.slack), ([], [], []))
        legacy = load_legacy()
        self.assertTrue(legacy.keep_conflict_held(x, "key"))
        self.assertFalse(legacy.merge_outcome_notifier_owns(x))
        x["tags"] = [t for t in x["tags"] if t["name"] != mon.INTAKE_STALE_TAG]
        self.assertFalse(legacy.keep_conflict_held(x, "key"))
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["901"])

    def test_a_spooled_record_is_kept_until_its_post_succeeds(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        self.spool("r1", {"ticket_ids": ["abc123"], "conversation_id": "777"})
        self.wire([], {})
        self.slack_ok = False
        rc, out = self.run_main([])
        self.assertIn("WOULD FLAG UNFLAGGED KEEP CONFLICTS", out)
        self.assertEqual(mon.main(["--apply"]), 3)
        self.assertTrue((self.dir / "spool" / "r1.json").exists())
        self.slack_ok = True
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 2)
        self.assertFalse((self.dir / "spool" / "r1.json").exists())
        self.assertEqual(json.loads((self.dir / "state.json").read_text())["spool_posted"], ["r1"])

    def test_an_incompletely_tagged_pair_is_held_and_reported(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        x = task("x", conv="901", kind="track-merge", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}y"))
        y = task("y", conv="902", kind="track-merge", email="bo@example.com")
        f = self.wire([x, y], {"901": conv(), "902": conv(email="bo@example.com")})
        rc, out = self.run_main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(f.posts, [])
        self.assertIn('keep-conflict tagging incomplete: ["x|y"]', out)
        self.assertIn("different tracks to keep in one conversation: <https://app.clickup.com/t/x|x>, "
                      "<https://app.clickup.com/t/y|y> (tagging incomplete: tag both merge-keep-conflict by hand)",
                      self.slack[0][2])

    def test_a_failed_keep_conflict_post_fails_the_run_and_is_retried(self):
        (self.dir / "state.json").write_text(json.dumps({"tickets": {}}))
        x = task("x", conv="901", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}y"))
        y = task("y", conv="902", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}x"))
        self.wire([x, y], {"901": conv(), "902": conv()})
        self.slack_ok = False
        self.assertEqual(mon.main(["--apply"]), 3)
        self.slack_ok = True
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(mon.main(["--apply"]), 0)
        self.assertEqual(len(self.slack), 2)
        self.assertEqual(json.loads((self.dir / "state.json").read_text())["keep_conflict_pairs"], ["x|y"])

    def test_the_legacy_merge_note_is_held_for_either_ticket_of_a_keep_conflict_pair(self):
        legacy = load_legacy()
        tickets = {"x": task("x", outcomes=(), at="", extra_tags=(f"{mon.KEEP_CONFLICT_WITH}y",)),
                   "y": task("y", outcomes=(), at="", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}x"))}
        legacy.get_ticket = lambda tid, key: tickets[tid]
        looked_up = []
        legacy.find_intercom_conv = lambda email, tok: looked_up.append(email)
        args = type("A", (), {"apply": True})()
        env = {"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t", "ADMIN_ID": legacy.CAROLINE_ADMIN_ID}
        legacy.parse_merge_at = lambda ticket: datetime.now(timezone.utc)
        legacy.process("x", args, env)
        legacy.process("y", args, env)
        self.assertEqual(looked_up, [])
        tickets["y"]["tags"] = [t for t in tickets["y"]["tags"] if t["name"] != mon.KEEP_CONFLICT_TAG]
        legacy.process("x", args, env)
        self.assertEqual(looked_up, [EMAIL])

    def test_a_closed_tagged_sibling_does_not_hold_the_legacy_merge_note(self):
        legacy = load_legacy()
        tickets = {"kept": task("kept", outcomes=(), at="", extra_tags=(f"{mon.KEEP_CONFLICT_WITH}rej",)),
                   "rej": task("rej", outcomes=(), at="", extra_tags=(mon.KEEP_CONFLICT_TAG, f"{mon.KEEP_CONFLICT_WITH}kept"))}
        tickets["rej"]["status"] = {"status": "closed", "type": "closed"}
        legacy.get_ticket = lambda tid, key: tickets[tid]
        looked_up = []
        legacy.find_intercom_conv = lambda email, tok: looked_up.append(email)
        legacy.parse_merge_at = lambda ticket: datetime.now(timezone.utc)
        env = {"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t", "ADMIN_ID": legacy.CAROLINE_ADMIN_ID}
        legacy.process("kept", type("A", (), {"apply": True})(), env)
        self.assertEqual(looked_up, [EMAIL])

    def test_paid_first_then_oldest_and_one_per_conversation(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        b = "bo@example.com"
        tasks = [task("old-free", created=1, conv="901"), task("new-paid", prio=1, created=9, conv="902", email=b),
                 task("same-conv", prio=1, created=10, conv="902", kind="track-merge", email=b)]
        f = self.wire(tasks, {"901": conv(), "902": conv(email=b)})
        self.assertEqual(mon.main(["--apply", "--limit", "5"]), 0)
        self.assertEqual([p[0] for p in f.posts], ["902", "901"])
        self.assertEqual(f.tags, ["new-paid", "old-free"])

    def test_cap_holds_the_rest_for_the_next_run(self):
        mon.MERGE_OUTCOME_COPY_APPROVED = True
        f = self.wire([task("a", conv="901"), task("b", conv="902", created=2, email="bo@example.com")],
                      {"901": conv(), "902": conv(email="bo@example.com")})
        mon.main(["--apply", "--limit", "1"])
        self.assertEqual(len(f.posts), 1)
        mon.main(["--apply", "--limit", "1"])
        self.assertEqual(len(f.posts), 2)

    def test_unreadable_state_refuses(self):
        (self.dir / "state.json").write_text("not json")
        self.wire([task()], {"900": conv()})
        with self.assertRaises(SystemExit):
            mon.main([])


if __name__ == "__main__":
    unittest.main()
