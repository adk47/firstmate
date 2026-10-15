"""Behavioral tests for scripts/paperclip-intake.py.

Hydra agents file Paperclip cards through this script instead of DMing Nick.
The value is the dedupe: one card per DISTINCT problem, with a counter. The
invariants under test:

  - normalize()/fingerprint() are ported byte-for-byte in behavior from
    hydra#1002 plugins/tracker (scrub order URL > UUID > ISO ts > path > hex >
    clock > number; a purely decimal run is <N>, never <ID>), because the
    fingerprint IS the dedupe contract;
  - filing the same problem twice yields ONE card with `Occurrences: 2`, and a
    different problem yields a SECOND card;
  - a search candidate is bumped only if its description carries the EXACT
    `fp:<hash>` token. Search is relevance-ranked, so a near-match (one hex
    digit off, or a longer hash with the same prefix) comes back; bumping it
    would hide a real problem;
  - the key is read from a FILE at call time, never from the environment;
  - the pre-check prints nothing and wakes nobody on an empty queue, and the
    30-minute escalation only touches intake cards that are still untouched.

The Paperclip API is a real stdlib HTTP server on localhost: the tests assert
what goes over the wire, not what a mock was told to return.

Stdlib unittest only — no network beyond 127.0.0.1. Runs under
`python3 -m unittest tests.test_paperclip_intake`.
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "paperclip-intake.py"
_spec = importlib.util.spec_from_file_location("paperclip_intake", SCRIPT)
pi = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pi)

COMPANY = "co-1"
KEY = "pcp_test_key_123"


class FakePaperclip:
    """Just enough of the Paperclip API: /agents/me, search, issues, comments,
    labels. Records every request so tests can assert on the wire."""

    def __init__(self):
        self.issues = {}
        self.labels = {}
        self.requests = []
        self.search_hook = None  # optional: override the search result list
        self.fail_once = []  # (method, path suffix) pairs that 500 on their next request
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body):
                raw = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}")

            def _handle(self, method):
                path, _, qs = self.path.partition("?")
                outer.requests.append(
                    {"method": method, "path": path, "qs": qs,
                     "auth": self.headers.get("Authorization"),
                     "body": self._body() if method in ("POST", "PATCH") else None}
                )
                req = outer.requests[-1]
                for rule in outer.fail_once:
                    if rule[0] == method and path.endswith(rule[1]):
                        outer.fail_once.remove(rule)
                        return self._send(500, {"error": "boom"})
                if path == "/api/agents/me":
                    return self._send(200, {"id": "agent-1", "companyId": COMPANY})
                if path == f"/api/companies/{COMPANY}/search":
                    # the live API's caps (checked 9 Oct): limit 1..50, offset 0..200
                    sq = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
                    if not 1 <= int(sq.get("limit", 20)) <= 50:
                        return self._send(400, {"error": "limit must be between 1 and 50"})
                    if not 0 <= int(sq.get("offset", 0)) <= 200:
                        return self._send(400, {"error": "offset must be between 0 and 200"})
                    return self._send(200, {"results": outer._search(qs)})
                if path == f"/api/companies/{COMPANY}/agents":
                    return self._send(200, [{"id": "pilot-agent-id", "name": "oc-scout", "urlKey": "oc-scout"}])
                if path == f"/api/companies/{COMPANY}/labels":
                    if method == "POST":
                        lab = {"id": f"lab-{len(outer.labels)+1}", "name": req["body"]["name"]}
                        outer.labels[lab["id"]] = lab
                        return self._send(201, lab)
                    return self._send(200, list(outer.labels.values()))
                if path == f"/api/companies/{COMPANY}/issues" and method == "GET":
                    # live: filters status/q, plain limit/offset, no 250 ceiling (checked 12 Oct)
                    lq = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
                    term = lq.get("q", "").replace("%3A", ":").replace("+", " ").lower()
                    rows = [i for i in outer.issues.values()
                            if (not lq.get("status") or i.get("status") == lq["status"])
                            and term in (i.get("description", "") + i.get("title", "")).lower()]
                    off, lim = int(lq.get("offset", 0)), int(lq.get("limit", 500))
                    return self._send(200, rows[off:off + lim])
                if path == f"/api/companies/{COMPANY}/issues" and method == "POST":
                    n = len(outer.issues) + 1
                    iss = {"id": f"iss-{n}", "identifier": f"PIL-{n}", "status": "todo",
                           "assigneeAgentId": None, "labelIds": [],
                           "createdAt": datetime.now(timezone.utc).isoformat(),
                           "updatedAt": datetime.now(timezone.utc).isoformat(),
                           **req["body"]}
                    outer.issues[iss["id"]] = iss
                    return self._send(201, iss)
                m = re.fullmatch(r"/api/issues/([\w-]+)(/comments)?", path)
                if m and m.group(1) in outer.issues:
                    iss = outer.issues[m.group(1)]
                    if m.group(2) and method == "POST":
                        return self._send(201, {"id": "c-1"})
                    if method == "PATCH":
                        iss.update(req["body"])
                        iss["updatedAt"] = datetime.now(timezone.utc).isoformat()
                        return self._send(200, iss)
                    return self._send(200, iss)
                self._send(404, {"error": "not found"})

            def do_GET(self):
                self._handle("GET")

            def do_POST(self):
                self._handle("POST")

            def do_PATCH(self):
                self._handle("PATCH")

        self.server = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def _search(self, qs):
        if self.search_hook:
            return self.search_hook(qs)
        q = dict(p.split("=", 1) for p in qs.split("&") if "=" in p)
        term = q.get("q", "").replace("%3A", ":").replace("+", " ")
        hits = [{"id": i["id"], "type": "issue", "title": i["title"]}
                for i in self.issues.values()
                if term and term.lower() in (i.get("description", "") + i["title"]).lower()
                and (not q.get("status") or i["status"] == q["status"])]
        offset = int(q.get("offset", 0))  # like the real API: a page of `limit`, from `offset`
        return hits[offset:offset + int(q.get("limit", 20))]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Base(unittest.TestCase):
    def setUp(self):
        self.api = FakePaperclip()
        self.tmp = tempfile.TemporaryDirectory()
        self.keyfile = pathlib.Path(self.tmp.name) / "hydra-intake"
        self.keyfile.write_text(KEY + "\n")
        self.keyfile.chmod(0o600)
        self.env = {"PAPERCLIP_INTAKE_URL": self.api.url,
                    "PAPERCLIP_INTAKE_KEY_FILE": str(self.keyfile),
                    "PAPERCLIP_INTAKE_STATE": str(pathlib.Path(self.tmp.name) / "wake-state")}
        self.wakes = []
        real = pi.wake_job
        pi.wake_job = self.wakes.append
        self.addCleanup(setattr, pi, "wake_job", real)
        self.addCleanup(self.api.close)
        self.addCleanup(self.tmp.cleanup)

    def run_cli(self, *argv, env=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = pi.main(list(argv), env=env if env is not None else self.env)
        return rc, out.getvalue(), err.getvalue()

    def file(self, title, component="deploy", agent="operations", body="it broke"):
        return self.run_cli("file", "--agent", agent, "--component", component,
                            "--title", title, "--body", body)


class NormalizeTests(unittest.TestCase):
    def test_lowercases_and_collapses_whitespace(self):
        self.assertEqual(pi.normalize("  Deploy   FAILED  "), "deploy failed")

    def test_strips_punctuation_but_keeps_placeholder_brackets(self):
        self.assertEqual(pi.normalize("deploy failed!! (again)"), "deploy failed again")

    def test_clock_times_become_ts(self):
        self.assertEqual(pi.normalize("deploy failed at 14:02"), pi.normalize("deploy failed at 14:09"))
        self.assertIn("<TS>", pi.normalize("deploy failed at 14:02"))

    def test_iso_timestamps_become_ts(self):
        a = pi.normalize("job died 2026-09-21T14:02:11Z")
        self.assertEqual(a, pi.normalize("job died 2026-01-02T03:04:05Z"))
        self.assertIn("<TS>", a)

    def test_uuids_become_id(self):
        a = pi.normalize("profile 5c3209be-1111-2222-3333-444455556666 missing")
        self.assertEqual(a, pi.normalize("profile 99999999-aaaa-bbbb-cccc-dddddddddddd missing"))
        self.assertIn("<ID>", a)

    def test_hex_runs_become_id(self):
        self.assertEqual(pi.normalize("commit c26c28d7ab99 reverted"),
                         pi.normalize("commit 4909b8e25361 reverted"))

    def test_urls_become_url(self):
        a = pi.normalize("fetch https://api.muso.ai/v3/profile?id=7 failed")
        self.assertEqual(a, pi.normalize("fetch https://api.muso.ai/v3/credits?id=9 failed"))
        self.assertIn("<URL>", a)

    def test_paths_become_path(self):
        a = pi.normalize("cannot read /etc/openclaw/main.env")
        self.assertEqual(a, pi.normalize("cannot read /etc/openclaw/edge.env"))
        self.assertIn("<PATH>", a)

    def test_purely_decimal_run_is_n_not_id(self):
        # Ordering regression: if HEX ran before NUM without the a-f guard,
        # an epoch would be <ID> and a small batch number <N>: never dedupes.
        self.assertEqual(pi.normalize("batch 1789156623 stalled"), pi.normalize("batch 42 stalled"))
        self.assertIn("<N>", pi.normalize("batch 1789156623 stalled"))
        self.assertNotIn("<ID>", pi.normalize("batch 1789156623 stalled"))

    def test_none_is_empty(self):
        self.assertEqual(pi.normalize(None), "")

    def test_different_problems_stay_different(self):
        self.assertNotEqual(pi.normalize("deploy failed"), pi.normalize("cron failed"))


class FingerprintTests(unittest.TestCase):
    def test_is_16_hex(self):
        self.assertRegex(pi.fingerprint("anything"), r"^[0-9a-f]{16}$")

    def test_stable_across_volatile_wording(self):
        self.assertEqual(pi.fingerprint("deploy failed at 14:02", "deploy"),
                         pi.fingerprint("Deploy FAILED at 14:09!", "deploy"))

    def test_nul_separator_stops_boundary_collisions(self):
        self.assertNotEqual(pi.fingerprint("x failed", "deploy"), pi.fingerprint("failed", "deploy x"))

    def test_differs_by_component(self):
        self.assertNotEqual(pi.fingerprint("timeout", "cron"), pi.fingerprint("timeout", "deploy"))

    def test_absent_component_is_empty_component(self):
        self.assertEqual(pi.fingerprint("timeout"), pi.fingerprint("timeout", ""))

    def test_matches_the_ported_ts_vector(self):
        # sha256("deploy\0deploy failed at <TS>")[:16], computed from the
        # #1002 TS implementation's definition (spec §4).
        import hashlib
        want = hashlib.sha256("deploy\x00deploy failed at <TS>".encode()).hexdigest()[:16]
        self.assertEqual(pi.fingerprint("deploy failed at 14:02", "deploy"), want)


class FileTests(Base):
    def test_same_problem_twice_is_one_card_with_counter_two(self):
        self.assertEqual(self.file("deploy failed at 14:02")[0], 0)
        rc, out, _ = self.file("Deploy FAILED at 14:09!")
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.api.issues), 1)
        card = next(iter(self.api.issues.values()))
        self.assertIn("Occurrences: 2", card["description"])
        self.assertEqual(json.loads(out)["action"], "bumped")
        comments = [r for r in self.api.requests if r["path"].endswith("/comments")]
        self.assertEqual(len(comments), 1)

    def _occurrences(self):
        return int(re.search(r"Occurrences: (\d+)", next(iter(self.api.issues.values()))["description"]).group(1))

    def test_failed_comment_leaves_the_counter_alone_so_a_retry_counts_once(self):
        self.file("deploy failed")
        self.api.fail_once.append(("POST", "/comments"))
        rc, _, _ = self.file("deploy failed")
        self.assertNotEqual(rc, 0)
        self.assertEqual(self._occurrences(), 1)  # nothing counted for the lost occurrence
        self.assertEqual(self.file("deploy failed")[0], 0)
        self.assertEqual(self._occurrences(), 2)

    def test_failed_counter_bump_after_the_comment_still_retries_to_the_right_count(self):
        self.file("deploy failed")
        self.api.fail_once.append(("PATCH", "-1"))
        rc, _, _ = self.file("deploy failed")
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.file("deploy failed")[0], 0)
        self.assertEqual(self._occurrences(), 2)

    def test_different_problem_is_a_second_card(self):
        self.file("deploy failed")
        self.file("cron failed")
        self.assertEqual(len(self.api.issues), 2)
        fps = {re.search(r"fp:([0-9a-f]{16})", i["description"]).group(1) for i in self.api.issues.values()}
        self.assertEqual(len(fps), 2)

    def test_card_carries_agent_name_fp_token_and_intake_marker(self):
        self.file("deploy failed", component="operations", agent="operations")
        card = next(iter(self.api.issues.values()))
        self.assertIn("Filed by: operations", card["description"])
        self.assertIn(f"fp:{pi.fingerprint('deploy failed', 'operations')}", card["description"])
        self.assertIn(pi.INTAKE_MARKER, card["description"])
        self.assertEqual(card["status"], "todo")

    def test_fingerprint_component_is_the_filing_agent_when_omitted(self):
        self.run_cli("file", "--agent", "operations", "--title", "deploy failed", "--body", "x")
        card = next(iter(self.api.issues.values()))
        self.assertIn(f"fp:{pi.fingerprint('deploy failed', 'operations')}", card["description"])

    def test_near_match_candidate_is_not_bumped(self):
        fp = pi.fingerprint("deploy failed", "deploy")
        near = fp[:-1] + ("0" if fp[-1] != "0" else "1")
        self.api.issues["iss-9"] = {"id": "iss-9", "title": "other", "status": "todo",
                                    "description": f"fp:{near}\nOccurrences: 1"}
        self.api.search_hook = lambda qs: [{"id": "iss-9", "type": "issue", "title": "other"}]
        self.file("deploy failed")
        self.assertIn("Occurrences: 1", self.api.issues["iss-9"]["description"])
        self.assertEqual(len(self.api.issues), 2, "near-match must be a NEW card, not a bump")

    def test_longer_hash_with_same_prefix_is_not_bumped(self):
        fp = pi.fingerprint("deploy failed", "deploy")
        self.api.issues["iss-9"] = {"id": "iss-9", "title": "other", "status": "todo",
                                    "description": f"fp:{fp}ab\nOccurrences: 1"}
        self.api.search_hook = lambda qs: [{"id": "iss-9", "type": "issue", "title": "other"}]
        self.file("deploy failed")
        self.assertEqual(len(self.api.issues), 2)

    def test_comment_and_document_hits_are_ignored(self):
        fp = pi.fingerprint("deploy failed", "deploy")
        self.api.issues["iss-9"] = {"id": "iss-9", "title": "x", "status": "todo",
                                    "description": f"fp:{fp}\nOccurrences: 1"}
        self.api.search_hook = lambda qs: [{"id": "iss-9", "type": "comment"}]
        self.file("deploy failed")
        self.assertEqual(len(self.api.issues), 2)

    def test_search_uses_issue_scope_and_never_lists_all_issues(self):
        self.file("deploy failed")
        paths = [(r["method"], r["path"]) for r in self.api.requests]
        self.assertNotIn(("GET", f"/api/companies/{COMPANY}/issues"), paths)
        search = next(r for r in self.api.requests if r["path"].endswith("/search"))
        self.assertIn("scope=issues", search["qs"])

    def test_key_is_read_from_the_file_at_call_time_not_the_environment(self):
        self.file("deploy failed")
        self.assertTrue(all(r["auth"] == f"Bearer {KEY}" for r in self.api.requests))
        self.keyfile.write_text("rotated\n")
        self.file("cron failed")
        self.assertEqual(self.api.requests[-1]["auth"], "Bearer rotated")
        # A key in the environment is ignored.
        env = {**self.env, "PAPERCLIP_API_KEY": "from-env", "PAPERCLIP_INTAKE_KEY": "from-env"}
        self.run_cli("file", "--agent", "a", "--title", "t", "--body", "b", env=env)
        self.assertNotIn("Bearer from-env", [r["auth"] for r in self.api.requests])

    def test_missing_key_file_fails_loud_and_makes_no_request(self):
        self.keyfile.unlink()
        rc, _, err = self.file("deploy failed")
        self.assertNotEqual(rc, 0)
        self.assertIn("key file", err)
        self.assertEqual(self.api.requests, [])

    def test_loose_key_file_permissions_are_refused(self):
        self.keyfile.chmod(0o644)
        rc, _, err = self.file("deploy failed")
        self.assertNotEqual(rc, 0)
        self.assertIn("permissions", err)
        self.assertEqual(self.api.requests, [])

    def test_key_never_appears_in_output(self):
        rc, out, err = self.file("deploy failed")
        self.assertNotIn(KEY, out + err)

    def test_secret_in_body_is_refused(self):
        rc, _, err = self.file("deploy failed", body="token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123")
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.api.issues, {})


class ClosedTwinTests(Base):
    def _recur_after(self, status):
        self.file("deploy failed")
        next(iter(self.api.issues.values()))["status"] = status
        rc, out, _ = self.file("deploy failed")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["action"], "created")
        self.assertEqual(len(self.api.issues), 2)
        new = self.api.issues["iss-2"]
        self.assertIn("Occurrences: 1", new["description"])
        self.assertIn("Occurrences: 1", self.api.issues["iss-1"]["description"])

    def test_recurrence_after_done_is_a_new_card(self):
        self._recur_after("done")

    def test_recurrence_after_cancelled_is_a_new_card(self):
        self._recur_after("cancelled")


class PrecheckTests(Base):
    def test_empty_queue_prints_nothing_and_wakes_nobody(self):
        rc, out, _ = self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")
        self.assertEqual(self.wakes, [])

    def test_waiting_card_wakes_the_triage_job_once(self):
        self.file("deploy failed")
        self.file("cron failed")
        rc, out, _ = self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(rc, 0)
        self.assertEqual(self.wakes, ["job-1"])
        self.assertEqual(json.loads(out)["waiting"], 2)

    def test_triaged_cards_do_not_wake(self):
        self.file("deploy failed")
        next(iter(self.api.issues.values()))["status"] = "in_progress"
        self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(self.wakes, [])

    def test_does_not_rewake_inside_the_window_while_clio_is_working(self):
        self.file("deploy failed")
        self.run_cli("precheck", "--wake-job", "job-1")
        rc, out, _ = self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(self.wakes, ["job-1"])
        self.assertFalse(json.loads(out)["woke"])

    def test_a_card_filed_after_the_queue_drained_wakes_inside_the_window(self):
        self.file("deploy failed")
        self.run_cli("precheck", "--wake-job", "job-1")
        next(iter(self.api.issues.values()))["status"] = "in_progress"  # Clio triaged it
        self.run_cli("precheck", "--wake-job", "job-1")  # empty queue
        self.file("cron failed")
        self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(self.wakes, ["job-1", "job-1"])

    def test_a_new_card_beside_one_already_woken_for_wakes_again(self):
        self.file("deploy failed")
        self.run_cli("precheck", "--wake-job", "job-1")
        self.file("cron failed")
        self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(self.wakes, ["job-1", "job-1"])

    def test_a_wake_stamped_in_the_future_does_not_suppress_triage(self):
        # Clock stepped backward after a wake: the stored ts is ahead of now.
        self.file("deploy failed")
        card_id = next(iter(self.api.issues))
        pathlib.Path(self.env["PAPERCLIP_INTAKE_STATE"]).write_text(
            json.dumps({"ts": time.time() + 86400, "ids": [card_id]}))
        rc, out, _ = self.run_cli("precheck", "--wake-job", "job-1")
        self.assertEqual(rc, 0)
        self.assertEqual(self.wakes, ["job-1"])
        self.assertTrue(json.loads(out)["woke"])

    def test_search_failure_exits_nonzero_and_does_not_wake(self):
        env = {**self.env, "PAPERCLIP_INTAKE_URL": "http://127.0.0.1:1"}
        rc, _, err = self.run_cli("precheck", "--wake-job", "job-1", env=env)
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.wakes, [])

    def test_precheck_makes_no_agent_turn(self):
        # Zero-token: the script is stdlib HTTP only and its only wake is the
        # `cron run` argv, which is injected here.
        src = SCRIPT.read_text()
        self.assertNotIn("agentTurn", src.replace("`agentTurn`", ""))
        self.assertNotRegex(src, r"openclaw[^\n]*\bagent\b")


class WaitingTests(Base):
    def test_lists_only_untriaged_intake_cards(self):
        self.file("deploy failed")
        self.file("cron failed")
        list(self.api.issues.values())[1]["assigneeAgentId"] = "someone"
        rc, out, _ = self.run_cli("waiting")
        self.assertEqual([c["title"] for c in json.loads(out)["waiting"]], ["deploy failed"])


class PaginationTests(Base):
    def test_a_waiting_card_beyond_the_first_page_is_still_found(self):
        # 60 already-triaged cards fill the first pages; the one waiting card is the 61st hit.
        for n in range(60):
            self.file(f"triaged problem {chr(97 + n // 26)}{chr(97 + n % 26)}")
        for card in self.api.issues.values():
            card["assigneeAgentId"] = "someone"
        self.file("brand new problem")
        rc, out, _ = self.run_cli("waiting")
        self.assertEqual([c["title"] for c in json.loads(out)["waiting"]], ["brand new problem"])

    def test_escalate_reaches_an_untriaged_card_beyond_the_first_page(self):
        for n in range(60):
            self.file(f"triaged problem {chr(97 + n // 26)}{chr(97 + n % 26)}")
        for card in self.api.issues.values():
            card["assigneeAgentId"] = "someone"
        self.file("brand new problem")
        last = list(self.api.issues.values())[-1]
        last["createdAt"] = (datetime.now(timezone.utc) - timedelta(minutes=45)).isoformat()
        self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        self.assertEqual(last["assigneeAgentId"], "pilot-agent-id")


class BeyondSearchCeilingTests(Base):
    def test_a_waiting_card_behind_more_than_250_triaged_cards_is_still_found(self):
        # search_issues stops at 250 hits; the waiting queue must not be bounded by it.
        for n in range(260):
            self.api.issues[f"old-{n}"] = {"id": f"old-{n}", "title": f"old {n}", "status": "todo",
                                           "assigneeAgentId": "someone",
                                           "description": f"{pi.INTAKE_MARKER}\nfp:{n:016x}"}
        self.file("brand new problem")
        rc, out, _ = self.run_cli("waiting")
        self.assertEqual([c["title"] for c in json.loads(out)["waiting"]], ["brand new problem"])


class SearchCapTests(Base):
    def test_a_query_with_more_hits_than_the_api_pages_returns_the_first_250_and_does_not_raise(self):
        for n in range(260):
            self.api.issues[f"iss-{n}"] = {"id": f"iss-{n}", "title": f"hydra-intake {n}", "status": "todo"}
        client = pi.Client(self.env)
        self.assertEqual(len(client.search_issues("hydra-intake")), 250)


class EscalateTests(Base):
    def old(self, minutes):
        return (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()

    def test_untouched_card_over_30_minutes_goes_to_the_pilot_agent_with_a_label(self):
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(45)
        rc, out, _ = self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        self.assertEqual(rc, 0)
        self.assertEqual(card["assigneeAgentId"], "pilot-agent-id")
        self.assertEqual(len(card["labelIds"]), 1)
        self.assertEqual(next(iter(self.api.labels.values()))["name"], "intake-escalated")
        self.assertEqual(json.loads(out)["escalated"], 1)

    def test_pilot_agent_is_resolved_by_name(self):
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(45)
        self.run_cli("escalate", "--to-agent", "oc-scout")
        self.assertEqual(card["assigneeAgentId"], "pilot-agent-id")

    def test_unknown_pilot_agent_fails_loud_and_assigns_nobody(self):
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(45)
        rc, _, err = self.run_cli("escalate", "--to-agent", "ghost")
        self.assertEqual(rc, 1)
        self.assertIsNone(card["assigneeAgentId"])

    def test_unknown_pilot_agent_fails_loud_even_with_nothing_to_escalate(self):
        # The lookup used to sit after the age check, so a wrong --to-agent only
        # surfaced when a card reached 30 minutes: the cron exited 0 until then.
        rc, _, err = self.run_cli("escalate", "--to-agent", "ghost")
        self.assertEqual(rc, 1)
        self.assertIn("ghost", err)
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(10)
        rc, _, _ = self.run_cli("escalate", "--to-agent", "ghost")
        self.assertEqual(rc, 1)

    def test_fresh_card_is_left_alone(self):
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(10)
        self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        self.assertIsNone(card["assigneeAgentId"])

    def test_already_escalated_card_is_not_escalated_twice(self):
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(45)
        self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        card["createdAt"] = self.old(45)
        rc, out, _ = self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        self.assertEqual(json.loads(out)["escalated"], 0)

    def test_refiling_does_not_reset_the_escalation_clock(self):
        # Clio down: a cron agent re-files every 10 min; each bump moves updatedAt.
        self.file("deploy failed")
        card = next(iter(self.api.issues.values()))
        card["createdAt"] = self.old(45)
        self.file("deploy failed")
        self.assertEqual(len(self.api.issues), 1)
        rc, out, _ = self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        self.assertEqual(json.loads(out)["escalated"], 1)
        self.assertEqual(card["assigneeAgentId"], "pilot-agent-id")

    def test_report_counts_escalations(self):
        self.file("deploy failed")
        next(iter(self.api.issues.values()))["createdAt"] = self.old(45)
        self.run_cli("escalate", "--to-agent", "pilot-agent-id")
        rc, out, _ = self.run_cli("escalations")
        self.assertEqual(json.loads(out)["escalated"], 1)


if __name__ == "__main__":
    unittest.main()
