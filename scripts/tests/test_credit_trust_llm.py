#!/usr/bin/env python3
"""Unit tests for scripts/credit_trust (T01: the tool-less model ladder, the
append-only llm_calls ledger, and server-fetched web evidence).

Stdlib unittest, no network, no codex, no credentials: the codex helper, Jev,
OpenRouter and every HTTP fetch are faked. The bash helper is exercised only
through its pure paths (--print-argv, the rollout census, the quota gate).
Run:
    python3 scripts/tests/test_credit_trust_llm.py
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import warnings
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from credit_review import judge as cr_judge  # noqa: E402
from credit_review.policy import R_APPROVE, combine, facts_from_record  # noqa: E402
from credit_trust import credibility, llm, websearch  # noqa: E402
from credit_trust.ledger import Ledger  # noqa: E402

HELPER = SCRIPTS / "lib" / "codex-judge-exec.sh"
SCHEMA = {"type": "object", "additionalProperties": False, "required": ["answer"],
          "properties": {"answer": {"type": "string"}}}


def events(text, *, usage=None, extra=()):
    lines = [{"type": "thread.started", "thread_id": "t"},
             {"type": "item.completed", "item": {"id": "item_0", "type": "error",
                                                 "message": "Code Mode is unavailable because code-mode host is disabled."}},
             {"type": "turn.started"}, *extra,
             {"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": text}},
             {"type": "turn.completed", "usage": usage or {"input_tokens": 8152, "output_tokens": 549}}]
    return "\n".join(json.dumps(x) for x in lines) + "\n"


UNSUPPORTED = "\n".join(json.dumps(x) for x in [
    {"type": "turn.started"},
    {"type": "error", "message": json.dumps({"type": "error", "status": 400, "error": {
        "message": "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."}})},
    {"type": "turn.failed", "error": {"message": "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."}},
]) + "\n"


class FakeCodex:
    """Stands in for `bash codex-judge-exec.sh ...`: records argv/stdin,
    writes the --meta-out file, returns a scripted (rc, stdout, stderr)."""

    def __init__(self, script):
        self.script = list(script)        # [(rc, stdout, stderr) | callable(argv) -> tuple]
        self.calls = []

    def __call__(self, argv, input=None, **kw):
        self.calls.append({"argv": list(argv), "input": input, "env": kw.get("env")})
        step = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        rc, out, err = step(argv) if callable(step) else step
        if "--meta-out" in argv:
            model = argv[argv.index("--model") + 1]
            Path(argv[argv.index("--meta-out") + 1]).write_text(json.dumps({
                "account": "openai-codex:test@example.com", "model": model, "rc": rc, "safety": "ok",
                "tool_census": {"types": {}, "blocked": ["exec"], "violations": []}, "latency_ms": 1234,
                "argv": ["exec", "--json", "-s", "read-only", "--disable", "shell_tool", "-m", model, "-"]}))
        return subprocess.CompletedProcess(argv, rc, out, err)


def provider(tmp, runner, **kw):
    return llm.Provider(Ledger(str(Path(tmp) / "ledger.sqlite3")), runner=runner, **kw)


class CodexEventParsing(unittest.TestCase):
    def test_final_message_usage_and_warnings(self):
        ev = llm.parse_codex_events(events('{"answer":"Jon Castelli"}'))
        self.assertEqual(ev["text"], '{"answer":"Jon Castelli"}')
        self.assertEqual(ev["usage"]["input_tokens"], 8152)
        self.assertEqual(ev["citations"], [])
        self.assertFalse(ev["unsupported"])
        self.assertTrue(any("Code Mode" in w for w in ev["warnings"]))

    def test_unsupported_model_detected(self):
        ev = llm.parse_codex_events(UNSUPPORTED)
        self.assertTrue(ev["unsupported"])
        self.assertEqual(ev["text"], "")

    def test_engine_citations_only_from_search_structures(self):
        extra = [{"type": "item.completed", "item": {"id": "ws", "type": "web_search", "query": "q",
                                                     "results": [{"url": "https://www.discogs.com/release/1"}]}}]
        stream = events('{"answer":"see https://invented.example/page"}', extra=extra)
        stream = stream.replace('"type": "agent_message", "text"',
                                '"type": "agent_message", "annotations": [{"type": "url_citation", "url": "https://allmusic.com/x"}], "text"')
        ev = llm.parse_codex_events(stream)
        self.assertEqual(sorted(ev["citations"]), ["https://allmusic.com/x", "https://www.discogs.com/release/1"])

    def test_garbage_lines_are_ignored(self):
        ev = llm.parse_codex_events("not json\n[1,2]\n" + events('{"answer":"x"}'))
        self.assertEqual(ev["text"], '{"answer":"x"}')


class CitationRule(unittest.TestCase):
    def test_model_written_urls_are_counted_not_cited(self):
        cits, uncited = llm.split_citations(
            "per https://en.wikipedia.org/wiki/X and https://www.discogs.com/release/1?utm_source=a",
            ["https://discogs.com/release/1"])
        self.assertEqual(cits, ["https://discogs.com/release/1"])
        self.assertEqual(uncited, ["https://en.wikipedia.org/wiki/X"])

    def test_codex_answer_urls_never_become_citations(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeCodex([(0, events('{"answer":"Jon Castelli https://en.wikipedia.org/wiki/BoaF"}'), "")])
            r = provider(tmp, fake, ladder=("codex",)).judge("q", SCHEMA)
            self.assertTrue(r.ok)
            self.assertEqual(r.citations, [])
            self.assertEqual(r.uncited_urls, 1)
            row = r_row(tmp, r.llm_call_id)
            self.assertEqual(json.loads(row["citations_json"]), [])
            self.assertEqual(row["uncited_urls"], 1)


def r_row(tmp, cid):
    db = sqlite3.connect(str(Path(tmp) / "ledger.sqlite3"))
    db.row_factory = sqlite3.Row
    return db.execute("SELECT * FROM llm_calls WHERE id=?", (cid,)).fetchone()


class Ladder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_codex_success_is_zero_cost_and_one_row(self):
        fake = FakeCodex([(0, events('{"answer":"x"}'), "")])
        r = provider(self.tmp, fake, codex_model="gpt-6-sol", codex_fallback_model=None).judge("hello", SCHEMA)
        self.assertTrue(r.ok)
        self.assertEqual((r.provider, r.model, r.cost_usd), ("codex", "gpt-6-sol", 0.0))
        self.assertEqual(len(r.attempts), 1)
        row = r_row(self.tmp, r.llm_call_id)
        self.assertEqual((row["provider"], row["outcome"], row["cost_usd"]), ("codex", "ok", 0.0))
        self.assertEqual(row["prompt_sha256"], hashlib.sha256(b"hello").hexdigest())

    def test_quota_guard_skips_codex_and_no_paid_rung_runs(self):
        fake = FakeCodex([(3, "", "[codex-judge-exec] provider_skipped=codex reason=quota account=a state/load=healthy 85")])
        r = provider(self.tmp, fake).judge("q", SCHEMA)
        self.assertFalse(r.ok)
        self.assertEqual([(a["provider"], a["outcome"], a["reason"]) for a in r.attempts],
                         [("codex", "skipped", "quota"), ("jev", "skipped", "not_applicable")])
        self.assertEqual(len(fake.calls), 1, "a quota skip must not try the fallback model")
        self.assertEqual(Ledger(str(Path(self.tmp) / "ledger.sqlite3")).cost_since("2000-01-01"), 0)

    def test_codex_error_is_reported_not_paid_around(self):
        fake = FakeCodex([(1, events(""), "codex exec failed")])
        r = provider(self.tmp, fake, codex_fallback_model=None).judge("q", SCHEMA)
        self.assertFalse(r.ok)
        self.assertTrue(r.error.startswith("codex: codex_failed"), r.error)
        self.assertEqual([a["provider"] for a in r.attempts], ["codex", "jev"])
        r2 = provider(self.tmp, FakeCodex([(3, "", "kill switch present")])).judge("q", SCHEMA)
        self.assertEqual(r2.attempts[0]["reason"], "kill_switch")
        self.assertIn("no provider served the request", r2.error)

    def test_unsupported_model_falls_back_and_is_remembered(self):
        fake = FakeCodex([(1, UNSUPPORTED, "codex exec failed rc=1"), (0, events('{"answer":"x"}'), ""),
                          (0, events('{"answer":"y"}'), "")])
        p = provider(self.tmp, fake, codex_model="gpt-6.1-sol", codex_fallback_model="gpt-6-sol")
        r = p.judge("q", SCHEMA)
        self.assertEqual(r.model, "gpt-6-sol")
        self.assertEqual([(a["model"], a["reason"]) for a in r.attempts],
                         [("gpt-6.1-sol", "model_unsupported"), ("gpt-6-sol", None)])
        r2 = p.judge("q2", SCHEMA)
        self.assertEqual(r2.attempts[0]["reason"], "model_unsupported_recently")
        self.assertEqual(len(fake.calls), 3, "the refused model is not retried inside the memory window")

    def test_web_request_skips_codex_until_headless_search_exists(self):
        fake = FakeCodex([(0, events('{"answer":"x"}'), "")])
        r = provider(self.tmp, fake).judge("q", SCHEMA, web=True)
        self.assertFalse(r.ok)
        self.assertEqual([a["reason"] for a in r.attempts], ["web_search_unavailable", "no_web_search"])
        self.assertEqual(fake.calls, [])

    def test_tool_and_safety_violations_discard_the_answer(self):
        for rc, reason in ((4, "tool_violation"), (9, "safety_violation")):
            fake = FakeCodex([(rc, events('{"answer":"x"}'), "")])
            r = provider(self.tmp, fake, codex_fallback_model=None).judge("q", SCHEMA)
            self.assertFalse(r.ok)
            self.assertEqual(r.attempts[0]["reason"], reason)
            self.assertIsNone(r.json)

    def test_schema_mismatch_is_an_error(self):
        fake = FakeCodex([(0, events('{"other":"x"}'), "")])
        r = provider(self.tmp, fake, codex_fallback_model=None).judge("q", SCHEMA)
        self.assertFalse(r.ok)
        self.assertIn("schema", r.attempts[0]["reason"])

    def test_image_args_and_prompt_on_stdin(self):
        img = Path(self.tmp) / "proof.png"
        img.write_bytes(b"\x89PNG fake")
        fake = FakeCodex([(0, events('{"answer":"x"}'), "")])
        provider(self.tmp, fake, codex_fallback_model=None).judge("secret claim text", SCHEMA, images=[str(img)])
        argv = fake.calls[0]["argv"]
        self.assertEqual(argv[argv.index("--image") + 1], str(img))
        self.assertIn("--no-web", argv)
        self.assertNotIn("secret claim text", " ".join(argv), "the prompt never goes in argv")
        self.assertEqual(fake.calls[0]["input"], "secret claim text")

    def test_jev_rung_for_evidence_combination(self):
        def jev(argv, **kw):
            self.assertIn("--no-shadow", argv)
            self.assertEqual(kw["env"]["JEV_PROVIDER"], "typesafe")
            return subprocess.CompletedProcess(argv, 0, '{"genuine":{"type":"choice","choice":"no"}}', "")
        p = provider(self.tmp, jev, ladder=("jev",))
        r = p.judge("packet", SCHEMA, jev_questions={"genuine": {"type": "choice"}})
        self.assertEqual((r.provider, r.cost_usd), ("jev", None))
        self.assertEqual(r.json["genuine"]["choice"], "no")
        self.assertEqual(p.judge("packet", SCHEMA, web=True, jev_questions={"q": {}}).attempts[0]["reason"], "no_web_search")

    def test_unknown_provider_rejected(self):
        for rung in ("gpt-direct", "openrouter"):
            with self.assertRaises(ValueError):
                llm.Provider(Ledger(":memory:"), ladder=(rung,))


class PromptHashAndLedger(unittest.TestCase):
    def test_prompt_hash_is_stable_and_matches_raw(self):
        self.assertEqual(llm.prompt_sha256("abc"), llm.prompt_sha256("abc"))
        self.assertEqual(llm.prompt_sha256("abc"), hashlib.sha256(b"abc").hexdigest())
        self.assertEqual(llm.schema_sha256({"b": 1, "a": 2}), llm.schema_sha256({"a": 2, "b": 1}))
        with tempfile.TemporaryDirectory() as tmp:
            r = provider(tmp, FakeCodex([(0, events('{"answer":"x"}'), "")]), codex_fallback_model=None).judge("Ünïcode prompt", SCHEMA)
            row = r_row(tmp, r.llm_call_id)
            raw = json.loads(Path(row["raw_path"]).read_text())
            self.assertEqual(llm.prompt_sha256(raw["prompt"]), row["prompt_sha256"])
            self.assertEqual(os.stat(row["raw_path"]).st_mode & 0o777, 0o600)
            self.assertIn("shell_tool", json.loads(row["meta_json"])["argv"])

    def test_ledger_is_append_only(self):
        led = Ledger(":memory:")
        cid, _ = led.record({"step": "probe", "provider": "codex", "outcome": "ok", "prompt_sha256": "x"})
        with self.assertRaises(sqlite3.DatabaseError):
            led.db.execute("UPDATE llm_calls SET model='forged' WHERE id=?", (cid,))
        with self.assertRaises(sqlite3.DatabaseError):
            led.db.execute("DELETE FROM llm_calls WHERE id=?", (cid,))

    def test_concurrent_judges_on_one_ledger_record_every_attempt(self):
        # The decider fans web judgments over 6 threads that share one Ledger
        # (credit-review.py decide --workers 6). Every attempt must land as its
        # own row with its own id; none may raise or vanish from the audit.
        from concurrent.futures import ThreadPoolExecutor
        with tempfile.TemporaryDirectory() as tmp:
            p = provider(tmp, FakeCodex([(0, events('{"answer":"x"}'), "")]), codex_fallback_model=None)
            with ThreadPoolExecutor(max_workers=6) as pool:
                results = list(pool.map(lambda i: p.judge(f"prompt {i}", SCHEMA), range(120)))
            self.assertTrue(all(r.ok for r in results), [r.error for r in results if not r.ok][:3])
            ids = [r.llm_call_id for r in results]
            self.assertEqual(len(set(ids)), 120)
            db = sqlite3.connect(str(Path(tmp) / "ledger.sqlite3"))
            got = {sha: cid for cid, sha in db.execute("SELECT id, prompt_sha256 FROM llm_calls")}
            self.assertEqual(got, {llm.prompt_sha256(f"prompt {i}"): r.llm_call_id for i, r in enumerate(results)})

    def test_existing_openrouter_judge_records_prompt_hash(self):
        j = cr_judge.Judge("m", web=False)
        j._post = lambda body, res, timeout=None: {"choices": [{"message": {"content": '{"verdict":"SUSPECT","confidence":0.5}'}}]}
        r = j.judge("audit", {"claim": {}})
        self.assertEqual(r.prompt_sha256, cr_judge.messages_sha256(cr_judge.build_messages("audit", {"claim": {}})))
        self.assertIn("prompt_sha256", r.as_dict())


def bash(script, env=None):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          env={**os.environ, **(env or {})}, timeout=60)


class HelperArgv(unittest.TestCase):
    """The tool-less posture lives in the bash helper's argv; grep it."""

    def argv(self, *extra):
        p = subprocess.run(["bash", str(HELPER), "--print-argv", *extra], capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.splitlines()

    def pairs(self, argv):
        return set(zip(argv, argv[1:]))

    def test_shell_off_read_only_always(self):
        for extra in ((), ("--web",), ("--no-web",), ("--image", "/x.png"), ("--keep-session", "/tmp/k")):
            a = self.argv(*extra)
            pr = self.pairs(a)
            self.assertIn(("--disable", "shell_tool"), pr, extra)
            self.assertIn(("--disable", "unified_exec"), pr, extra)
            self.assertIn(("--disable", "code_mode_host"), pr, extra)
            self.assertIn(("-s", "read-only"), pr, extra)
            self.assertIn("--ignore-user-config", a)
            self.assertIn("--ignore-rules", a)
            self.assertIn(("-c", 'approval_policy="never"'), pr)
            self.assertFalse([x for x in a if "dangerously" in x or x == "danger-full-access"], extra)
            self.assertEqual(a[-1], "-", "prompt comes from stdin")

    def test_images_precede_flags_so_stdin_marker_survives(self):
        a = self.argv("--image", "/a.png", "--image", "/b.png")
        self.assertEqual(a[:5], ["exec", "-i", "/a.png", "-i", "/b.png"])
        self.assertTrue(a[5].startswith("--"))

    def test_web_toggle(self):
        self.assertIn(("-c", 'web_search="disabled"'), self.pairs(self.argv("--no-web")))
        self.assertIn(("-c", 'web_search="live"'), self.pairs(self.argv("--web")))

    def test_bad_model_rejected(self):
        p = subprocess.run(["bash", str(HELPER), "--print-argv", "--model", "x;rm -rf /"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


def rollout(*items):
    return "\n".join(json.dumps({"type": "response_item", "payload": i}) for i in items) + "\n"


class RolloutCensus(unittest.TestCase):
    def census(self, content):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "sessions" / "2026" / "10"
            if content is not None:
                d.mkdir(parents=True)
                (d / "rollout-2026-10-15T21-15-35-x.jsonl").write_text(content)
            p = bash(f'. "{HELPER}"; cje_tool_census "{Path(tmp) / "sessions"}"')
            self.assertEqual(p.returncode, 0, p.stderr)
            return json.loads(p.stdout)

    def test_refused_code_mode_exec_is_blocked_not_violation(self):
        c = self.census(rollout({"type": "message"}, {"type": "reasoning"},
                                {"type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "tools.web__run()"},
                                {"type": "custom_tool_call_output", "call_id": "c1", "output": "code-mode host is disabled"}))
        self.assertEqual(c["violations"], [])
        self.assertEqual(c["blocked"], ["exec"])

    def test_a_tool_that_ran_is_a_violation(self):
        c = self.census(rollout({"type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "x"},
                                {"type": "custom_tool_call_output", "call_id": "c1", "output": "{\"results\":[]}"},
                                {"type": "function_call", "call_id": "c2", "name": "shell", "arguments": "{}"},
                                {"type": "function_call_output", "call_id": "c2", "output": "uid=0(root)"}))
        self.assertEqual(sorted(c["violations"]), ["exec", "shell"])

    def test_call_without_output_is_a_violation(self):
        c = self.census(rollout({"type": "local_shell_call", "call_id": "c9", "action": {"command": ["id"]}}))
        self.assertEqual(c["violations"], ["local_shell_call"])

    def test_web_search_call_allowed_and_queries_kept(self):
        c = self.census(rollout({"type": "web_search_call", "action": {"type": "search", "query": "who mixed x"}},
                                {"type": "message"}))
        self.assertEqual(c["violations"], [])
        self.assertEqual(c["web_queries"], ["who mixed x"])

    def test_missing_rollout_is_a_violation(self):
        self.assertEqual(self.census(None)["violations"], ["no_rollout"])


class QuotaGate(unittest.TestCase):
    def gate(self, row):
        with tempfile.TemporaryDirectory() as tmp:
            if row is not None:
                (Path(tmp) / "openai-codex_a_b.c.measure.tsv").write_text(row + "\n")
            p = bash(f'. "{HELPER}"; cje_quota_gate "openai-codex:a@b.c"', {"CODEX_USAGE_ARCHIVE_DIR": tmp})
            return p.returncode, p.stdout

    def test_gate(self):
        now = int(time.time())
        reset = now + 86400
        self.assertEqual(self.gate(f"{now}\t-\t10080\t6\t{reset}\t-\t-\t-\tprobe-live\tpro"), (0, "healthy 6"))
        self.assertEqual(self.gate(f"{now}\t-\t10080\t81\t{reset}\t-\t-\t-\tprobe-live\tpro")[0], 1)
        self.assertEqual(self.gate(f"{now}\t-\t10080\t80\t{reset}\t-\t-\t-\tprobe-live\tpro")[0], 0)
        rc, out = self.gate(f"{now - 7200}\t-\t10080\t6\t{reset}\t-\t-\t-\tprobe-live\tpro")
        self.assertEqual((rc, out.split()[0]), (1, "unknown"), "a stale measurement is not evidence")
        self.assertEqual(self.gate(None)[0], 1, "never measured = unknown = skip")


# ── fetched sources ──────────────────────────────────────────────────────────
def resolver_for(mapping):
    def resolve(host, port):
        if host not in mapping:
            raise socket.gaierror("nx")
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in mapping[host]]
    return resolve


class FetchGuard(unittest.TestCase):
    def test_ssrf_guard(self):
        res = resolver_for({"good.example": ["93.184.216.34"], "lo.example": ["127.0.0.1"],
                            "mix.example": ["93.184.216.34", "10.0.0.8"], "meta.example": ["169.254.169.254"]})
        self.assertEqual(websearch.check_url("https://good.example/x", res), "https://good.example/x")
        for url in ("https://lo.example/", "https://mix.example/", "http://meta.example/latest",
                    "file:///etc/passwd", "https://good.example:8443/", "https://nx.example/", "gopher://good.example/"):
            with self.assertRaises(websearch.FetchRefused, msg=url):
                websearch.check_url(url, res)

    def rebinding_fetch(self, url, answers):
        """http_get(url) with getaddrinfo answering ``answers`` in turn (the
        last one repeats) and every outbound dial recorded, never made."""
        from unittest import mock
        answers, dialed = list(answers), []

        def resolve(host, port, *a, **kw):
            ip = answers.pop(0) if len(answers) > 1 else answers[0]
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0))]

        def dial(address, *a, **kw):
            dialed.append(address)
            raise ConnectionRefusedError("test: no network")
        with mock.patch.object(socket, "getaddrinfo", resolve), \
                mock.patch.object(socket, "create_connection", dial):
            try:
                websearch.http_get(url)
            except Exception as exc:  # noqa: BLE001 - the outcome under test is the dial list
                return exc, dialed
        return None, dialed

    def test_fetch_connects_to_the_checked_address_not_a_rebound_one(self):
        for url, port in (("http://rebind.example/x", 80), ("https://rebind.example/x", 443)):
            exc, dialed = self.rebinding_fetch(url, ["93.184.216.34", "127.0.0.1"])
            self.assertIsInstance(exc, websearch.FetchRefused, url)
            self.assertEqual(dialed, [], f"{url}: a host that rebinds to loopback after the check is never dialed")
            exc, dialed = self.rebinding_fetch(url, ["93.184.216.34"])
            self.assertEqual(dialed, [("93.184.216.34", port)], f"{url}: the dial goes to the checked IP")

    def test_html_to_text_handles_attribute_angles_and_scripts(self):
        t = websearch.html_to_text("<p data-mw='{\"a\":\"<b>x</b> >\"}'>Hello <b>World</b></p><script>evil()</script>"
                                   "<li>Claimant A &ndash; mixing</li>")
        self.assertEqual(t, "Hello World \nClaimant A – mixing")


MB_REC = {"title": "Song One", "artist-credit": [{"name": "Band One", "joinphrase": ""}],
          "releases": [{"title": "Album One"}],
          "relations": [{"type": "mix", "attributes": [], "artist": {"name": "Claimant A"}},
                        {"type": "instrument", "attributes": ["keyboard"], "artist": {"name": "Person C"}}]}


class FakeWeb:
    def __init__(self):
        self.urls = []

    def __call__(self, url, accept="*/*", **kw):
        self.urls.append(url)
        if "/ws/2/isrc/" in url:
            return json.dumps({"recordings": [{"id": "rec-1", "disambiguation": ""},
                                              {"id": "rec-live", "disambiguation": "live"}]}).encode(), "application/json"
        if "/ws/2/recording/rec-1" in url:
            return json.dumps(MB_REC).encode(), "application/json"
        if "w/api.php" in url:
            return json.dumps({"query": {"search": [{"title": "Song One"}]}}).encode(), "application/json"
        if "rest_v1/page/html" in url:
            body = "<p>Lead text about the single.</p>" + "<p>x</p>" * 3 + \
                   "<h2>Personnel</h2><ul><li>Person B – vocals, keyboards</li><li>Person C – keyboards</li>" \
                   "<li>Claimant A – mixing</li></ul>"
            return body.encode(), "text/html"
        raise AssertionError(url)


class Sources(unittest.TestCase):
    def test_gather_snapshots_and_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            web = FakeWeb()
            s = websearch.Searcher(tmp, get=web, sleep=lambda _s: None)
            g = s.gather({"person": "Claimant A", "roles": ["Keyboard"], "track_title": "Song One",
                          "artists": ["Band One"], "isrc": "USWU30200093"})
            self.assertEqual([d.source_id for d in g.docs], ["S1", "S2"])
            self.assertEqual([d.engine for d in g.docs], ["musicbrainz", "wikipedia"])
            self.assertIn("- mix: Claimant A", g.docs[0].text)
            self.assertFalse(any("rec-live" in u for u in web.urls), "live recordings are not this track")
            snap = json.loads(Path(g.docs[0].snapshot_path).read_text())
            self.assertEqual(hashlib.sha256(json.dumps(MB_REC).encode()).hexdigest(), snap["body_sha256"])
            self.assertTrue(any(t["engine"] == "searxng" and "not configured" in t["note"] for t in g.trace))

    def test_one_failing_source_does_not_end_the_check(self):
        def broken(url, **kw):
            if "musicbrainz" in url:
                raise OSError("down")
            return FakeWeb()(url, **kw)
        g = websearch.Searcher(None, get=broken, sleep=lambda _s: None).gather(
            {"track_title": "Song One", "artists": ["Band One"]})
        self.assertEqual([d.engine for d in g.docs], ["wikipedia"])
        self.assertIn("OSError", g.trace[0]["error"])


def docs():
    return websearch.Searcher(None, get=FakeWeb(), sleep=lambda _s: None).gather(
        {"track_title": "Song One", "artists": ["Band One"], "isrc": "USWU30200093"}).docs


class QuoteVerification(unittest.TestCase):
    def test_only_verbatim_quotes_from_listed_sources_survive(self):
        ds = docs()
        kept, dropped = credibility.verify_findings([
            {"source_id": "S2", "quote": "Claimant A  –  MIXING", "says": "mixer", "effect": "contradicts"},
            {"source_id": "S2", "quote": "Claimant A – keyboards", "says": "fake", "effect": "supports"},
            {"source_id": "S9", "quote": "Claimant A – mixing", "says": "x", "effect": "supports"},
            {"source_id": "S1", "quote": "mix", "says": "x", "effect": "supports"},
            "not a dict"], ds)
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["source_url"], ds[1].url)
        self.assertEqual(kept[0]["body_sha256"], ds[1].body_sha256)
        self.assertEqual(sorted(d["why"] for d in dropped),
                         ["quote not in the fetched source", "quote too short", "unknown source_id"])


BIG_TRACK_EVIDENCE = {
    "claim": {"person_or_profile_name": "Claimant A", "claimed_roles": ["Keyboard"]},
    "track": {"title": "Song One", "artists": ["Band One"], "isrc": "USWU30200093",
              "catalog_popularity": 88, "max_artist_popularity": 80, "big_track": True},
    "trusted_catalog_credits_by_role": [{"role": "Keyboard", "status": "UNVERIFIABLE", "trusted_for_profile": [],
                                         "trusted_for_others": []}],
    "profile": {"name": "Claimant A"}, "rule_validator": {"approved": False, "total_risk_percent": 100},
    "claimant_domains": [], "claimant_names": ["Claimant A"],
}


class FreshGatherCache(unittest.TestCase):
    """credibility caches gathered sources per Searcher, keyed by id(); a
    Searcher freed by one test can hand its id (and a cached failed gather)
    to the next test's new Searcher. Production holds one Searcher per
    process; each test starts from an empty cache."""

    def setUp(self):
        credibility._CACHE.clear()


class HighRiskBigTrackFixture(FreshGatherCache):
    """A high-risk big-track claim must never auto-approve -
    not even when the model says APPROVE and quotes sources."""

    def judge_with(self, answer):
        tmp = tempfile.mkdtemp()
        fake = FakeCodex([(0, events(json.dumps(answer)), "")])
        prov = provider(tmp, fake, ladder=("codex",), codex_fallback_model=None)
        j = credibility.FetchedSourcesJudge(prov, websearch.Searcher(None, get=FakeWeb(), sleep=lambda _s: None))
        return j.judge("review", BIG_TRACK_EVIDENCE), fake

    def test_model_approve_with_quotes_is_clamped_on_big_track(self):
        res, fake = self.judge_with({
            "verdict": "APPROVE-RECOMMENDED", "confidence": 0.99, "identity_consistent": True, "rationale": "r",
            "findings": [{"source_id": "S1", "quote": "mix: Claimant A", "says": "credited", "effect": "supports"},
                         {"source_id": "S2", "quote": "Claimant A – mixing", "says": "credited", "effect": "supports"}]})
        self.assertTrue(res.ok)
        self.assertEqual(len(res.findings), 2)
        d = combine(facts_from_record(BIG_TRACK_EVIDENCE, "unverified"), "review", res)
        self.assertNotEqual(d.verdict, R_APPROVE)
        prompt = fake.calls[0]["input"]
        self.assertIn("S2 | wikipedia", prompt)
        self.assertIn("DATA", prompt)

    def test_contradiction_with_verified_quote_rejects(self):
        res, _ = self.judge_with({
            "verdict": "REJECT-RECOMMENDED", "confidence": 0.91, "identity_consistent": True, "rationale": "r",
            "findings": [{"source_id": "S2", "quote": "Person C – keyboards", "says": "keyboards by others",
                          "effect": "contradicts"}]})
        d = combine(facts_from_record(BIG_TRACK_EVIDENCE, "unverified"), "review", res)
        self.assertEqual(d.verdict, "REJECT-RECOMMENDED")
        self.assertEqual(d.basis, "web_contradiction")

    def test_invented_quote_cannot_reject_or_approve(self):
        res, _ = self.judge_with({
            "verdict": "REJECT-RECOMMENDED", "confidence": 0.95, "identity_consistent": None, "rationale": "r",
            "findings": [{"source_id": "S2", "quote": "Keyboards were played by Somebody Else entirely",
                          "says": "x", "effect": "contradicts"}]})
        self.assertEqual(res.findings, [])
        self.assertEqual(len(res.dropped_findings), 1)
        d = combine(facts_from_record(BIG_TRACK_EVIDENCE, "unverified"), "review", res)
        self.assertEqual(d.verdict, "NEEDS-HUMAN")

    def test_no_sources_uses_the_fallback_judge(self):
        class Fallback:
            calls = 0

            def judge(self, mode, ev):
                Fallback.calls += 1
                return cr_judge.JudgeResult(ok=False, error="fallback")

        def nothing(url, **kw):
            raise OSError("offline")
        prov = provider(tempfile.mkdtemp(), FakeCodex([(0, "", "")]), ladder=("codex",))
        j = credibility.FetchedSourcesJudge(prov, websearch.Searcher(None, get=nothing, sleep=lambda _s: None),
                                            fallback=Fallback())
        j.judge("review", BIG_TRACK_EVIDENCE)
        self.assertEqual(Fallback.calls, 1)

    def test_verdict_schema_is_strict(self):
        s = credibility.verdict_schema("review")
        self.assertFalse(s["additionalProperties"])
        self.assertEqual(sorted(s["required"]), sorted(s["properties"]))
        item = s["properties"]["findings"]["items"]
        self.assertEqual(sorted(item["required"]), sorted(item["properties"]))


def jev_runner(choice=None, rc=0, calls=None):
    def run(argv, **kw):
        if calls is not None:
            calls.append(argv)
        if "--questions-file" in argv:
            q = json.loads(Path(argv[argv.index("--questions-file") + 1]).read_text())
            assert credibility.JEV_QUESTION in q
        out = json.dumps({credibility.JEV_QUESTION: {"type": "choice", "choice": choice}}) if rc == 0 else ""
        return subprocess.CompletedProcess(argv, rc, out, "" if rc == 0 else "JEV unconfigured")
    return run


class JevCombiner(FreshGatherCache):
    """Codex unavailable: Jev reads the fetched sources and can only make the
    row a support request (NEEDS-HUMAN, no findings) or leave it failed."""

    def judge(self, choice=None, rc=0):
        tmp = tempfile.mkdtemp()
        codex = provider(tmp, FakeCodex([(3, "", "reason=quota")]), ladder=("codex",))
        calls = []
        jev = provider(tmp, jev_runner(choice, rc, calls), ladder=("jev",))
        j = credibility.FetchedSourcesJudge(codex, websearch.Searcher(None, get=FakeWeb(), sleep=lambda _s: None),
                                            skip_model_without_sources=True, combiner=jev)
        return j.judge("review", BIG_TRACK_EVIDENCE), calls

    def test_someone_else_or_silent_becomes_needs_human_without_findings(self):
        for choice in ("names_someone_else", "silent"):
            res, calls = self.judge(choice)
            self.assertEqual((res.ok, res.verdict, res.findings, res.provider), (True, "NEEDS-HUMAN", [], "jev"))
            self.assertEqual(len(calls), 1)
            self.assertIsNotNone(res.llm_call_id)

    def test_jev_never_approves(self):
        res, _ = self.judge("names_claimant")
        self.assertFalse(res.ok)
        self.assertIn("names_claimant", res.error)

    def test_unconfigured_jev_leaves_the_row_failed(self):
        res, _ = self.judge(rc=5)
        self.assertFalse(res.ok)


class SourceOutage(FreshGatherCache):
    def test_failed_fetch_with_no_sources_is_not_a_search_result(self):
        def mb_down(url, **kw):
            if "musicbrainz" in url:
                raise OSError("503")
            return json.dumps({"query": {"search": []}}).encode(), "application/json"

        class Prov:
            codex_model = "gpt-6-sol"

            def judge(self, *a, **k):
                raise AssertionError("no model call without sources")
        j = credibility.FetchedSourcesJudge(Prov(), websearch.Searcher(None, get=mb_down, sleep=lambda _s: None),
                                            skip_model_without_sources=True)
        r = j.judge("review", {"claim": {}, "track": {"title": "x", "artists": ["y"]}})
        self.assertFalse(r.ok)
        self.assertIn("musicbrainz", r.error)

    def test_searched_and_nothing_found_is_needs_human(self):
        def empty(url, **kw):
            if "musicbrainz" in url:
                return json.dumps({"recordings": []}).encode(), "application/json"
            return json.dumps({"query": {"search": []}}).encode(), "application/json"
        class Prov:
            codex_model = "gpt-6-sol"
        j = credibility.FetchedSourcesJudge(Prov(), websearch.Searcher(None, get=empty, sleep=lambda _s: None),
                                            skip_model_without_sources=True)
        r = j.judge("review", {"claim": {}, "track": {"title": "x", "artists": ["y"]}})
        self.assertEqual((r.ok, r.verdict, r.findings), (True, "NEEDS-HUMAN", []))


class ProbeCli(unittest.TestCase):
    def test_has_pair(self):
        sys.path.insert(0, str(SCRIPTS))
        import importlib.util
        spec = importlib.util.spec_from_file_location("ct_cli", SCRIPTS / "credit-trust.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertTrue(mod._has_pair(["-s", "read-only"], "-s", "read-only"))
        self.assertFalse(mod._has_pair(["-s", "workspace-write"], "-s", "read-only"))


if __name__ == "__main__":
    # Fixtures open many short-lived SQLite ledgers; their ResourceWarnings are noise.
    warnings.filterwarnings("ignore", category=ResourceWarning)
    unittest.main(verbosity=1, warnings="")
