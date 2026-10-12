"""Tests for scripts/fallback-local-error-report.py (MUS-6727: count model fallbacks that a
LOCAL runtime error caused, without silencing the Slack notice). Stdlib unittest, no network.

The classifier is structural (MUS-6727, CTO re-brief 12 Oct): error strings churn week to
week, so no test here depends on a list of local error texts. A failure is `provider` when it
carries a provider response; `local` when nothing shows a request left the box."""
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "fallback-local-error-report.py"
_spec = importlib.util.spec_from_file_location("fallback_local_error_report", _SCRIPT)
r = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r)


def decision(date, dec="candidate_failed", provider="openai", model="gpt-6-sol", err="boom",
             h="sha256:aaa", run="run1", attempt=1):
    rec = {"event": "model_fallback_decision", "decision": dec, "runId": run, "attempt": attempt,
           "candidateProvider": provider, "candidateModel": model,
           "errorHash": h if err else "", "errorPreview": err}
    return json.dumps({"0": '{"subsystem":"model-fallback/decision"}', "1": rec,
                       "_meta": {"date": date}})


def fetch(date, kind, provider="openrouter", model="openai/gpt-6-luna", status=None):
    s = f"[model-fetch] {kind} provider={provider} api=openai-completions model={model}"
    if status is not None:
        s += f" status={status} elapsedMs=5"
    return json.dumps({"0": '{"subsystem":"provider-transport-fetch"}', "1": s,
                       "_meta": {"date": date}})


class ClassifyTest(unittest.TestCase):
    def cls(self, lines, i):
        return r.classify_all(r.parse_lines(lines))[i].bucket

    def test_unknown_thrown_string_with_no_request_is_local(self):
        # Intent: a NEW local error must read as local the first day it appears.
        self.assertEqual(self.cls([decision("2026-10-12T10:00:00.000Z", err="brand new local failure xyz")], 0), "local")

    def test_http_status_in_error_is_provider(self):
        for err in ("Request failed with status code 429", "HTTP 503 Service Unavailable",
                    "401 Unauthorized", '{"error":{"code":"rate_limit_exceeded"}}'):
            with self.subTest(err=err):
                self.assertEqual(self.cls([decision("2026-10-12T10:00:00.000Z", err=err)], 0), "provider")

    def test_digits_that_are_not_a_status_stay_local(self):
        # Intent: a port, a pid or an hour count in a local error is not an HTTP status.
        err = "Cannot inspect Codex processes. pid 4291 exceeded its deadline of 500ms"
        self.assertEqual(self.cls([decision("2026-10-12T10:00:00.000Z", err=err)], 0), "local")

    def test_fetch_error_status_before_decision_is_provider(self):
        lines = [fetch("2026-10-12T10:00:00.000Z", "start"),
                 fetch("2026-10-12T10:00:01.000Z", "response", status=500),
                 decision("2026-10-12T10:00:01.500Z", provider="openrouter", model="openai/gpt-6-luna", err="upstream said no")]
        self.assertEqual(self.cls(lines, 0), "provider")

    def test_fetch_ok_status_does_not_make_it_provider(self):
        lines = [fetch("2026-10-12T10:00:00.000Z", "start"),
                 fetch("2026-10-12T10:00:01.000Z", "response", status=200),
                 decision("2026-10-12T10:00:01.500Z", provider="openrouter", model="openai/gpt-6-luna", err="Session changed before writer admission")]
        self.assertEqual(self.cls(lines, 0), "local")

    def test_request_started_without_a_response_is_unclassified(self):
        # Intent: a request left the box and we cannot see how it ended: do not guess.
        lines = [fetch("2026-10-12T10:00:00.000Z", "start"),
                 decision("2026-10-12T10:00:02.000Z", provider="openrouter", model="openai/gpt-6-luna", err="stream ended")]
        self.assertEqual(self.cls(lines, 0), "unclassified")

    def test_fetch_for_another_model_is_ignored(self):
        lines = [fetch("2026-10-12T10:00:00.000Z", "start", model="other/model"),
                 fetch("2026-10-12T10:00:01.000Z", "response", model="other/model", status=500),
                 decision("2026-10-12T10:00:02.000Z", provider="openrouter", model="openai/gpt-6-luna", err="x")]
        self.assertEqual(self.cls(lines, 0), "local")

    def test_fetch_outside_window_is_ignored(self):
        lines = [fetch("2026-10-12T10:00:00.000Z", "response", status=500),
                 decision("2026-10-12T10:05:00.000Z", provider="openrouter", model="openai/gpt-6-luna", err="x")]
        self.assertEqual(self.cls(lines, 0), "local")

    def test_failure_with_no_error_text_is_unclassified(self):
        self.assertEqual(self.cls([decision("2026-10-12T10:00:00.000Z", err="")], 0), "unclassified")

    def test_succeeded_is_classified_by_the_failure_that_caused_it(self):
        # candidate_succeeded has no error of its own; it inherits the bucket of the previous
        # candidate_failed of the same runId.
        lines = [decision("2026-10-12T10:00:00.000Z", err="local thing", run="A"),
                 decision("2026-10-12T10:00:01.000Z", dec="candidate_succeeded", provider="openrouter",
                          model="openai/gpt-6-luna", err="", run="A", attempt=2),
                 decision("2026-10-12T10:00:02.000Z", err="HTTP 429", run="B"),
                 decision("2026-10-12T10:00:03.000Z", dec="candidate_succeeded", provider="openrouter",
                          model="openai/gpt-6-luna", err="", run="B", attempt=2),
                 decision("2026-10-12T10:00:04.000Z", dec="candidate_succeeded", err="", run="C")]
        got = [d.bucket for d in r.classify_all(r.parse_lines(lines))]
        self.assertEqual(got, ["local", "local", "provider", "provider", "none"])

    def test_malformed_and_unrelated_lines_are_counted_not_crashed(self):
        p = r.parse_lines(["not json", json.dumps({"1": "hello"}), decision("2026-10-12T10:00:00.000Z")])
        self.assertEqual(len(p.decisions), 1)
        self.assertEqual(p.malformed, 1)


class ReportTest(unittest.TestCase):
    def build(self, n_local, n_provider=0, day="2026-10-12"):
        lines = []
        for i in range(n_local):
            lines.append(decision(f"{day}T10:{i // 60:02d}:{i % 60:02d}.000Z", err="local thing", h="sha256:L", run=f"l{i}"))
        for i in range(n_provider):
            lines.append(decision(f"{day}T11:{i // 60:02d}:{i % 60:02d}.000Z", err="HTTP 429", h="sha256:P", run=f"p{i}"))
        return r.classify_all(r.parse_lines(lines))

    def test_counts_by_bucket_and_decision(self):
        ds = self.build(3, 2)
        rep = r.summarise(ds)
        self.assertEqual(rep["2026-10-12"]["counts"][("local", "candidate_failed")], 3)
        self.assertEqual(rep["2026-10-12"]["counts"][("provider", "candidate_failed")], 2)

    def test_alert_fires_on_local_only(self):
        self.assertTrue(r.alerts(r.summarise(self.build(5)), threshold=5))
        self.assertFalse(r.alerts(r.summarise(self.build(4)), threshold=5))
        # Intent: the provider bucket never alerts, the existing notice owns it.
        self.assertFalse(r.alerts(r.summarise(self.build(0, 500)), threshold=5))

    def test_default_threshold_is_above_the_post_fix_baseline_and_below_9_oct(self):
        # 9 Oct: 309 local candidate_failed. A well-under-100 floor would be noise.
        self.assertGreaterEqual(r.DEFAULT_THRESHOLD, 100)
        self.assertLess(r.DEFAULT_THRESHOLD, 309)

    def test_unclassified_prefixes_are_printed_not_absorbed(self):
        lines = [decision("2026-10-12T10:00:00.000Z", err="")]
        # a started-but-unanswered request
        lines += [fetch("2026-10-12T10:01:00.000Z", "start"),
                  decision("2026-10-12T10:01:01.000Z", provider="openrouter", model="openai/gpt-6-luna", err="stream ended oddly 123")]
        ds = r.classify_all(r.parse_lines(lines))
        text = r.render(r.summarise(ds), threshold=10)
        self.assertIn("unclassified", text)
        self.assertIn("stream ended oddly", text)
        rep = r.summarise(ds)
        self.assertEqual(rep["2026-10-12"]["counts"].get(("provider", "candidate_failed"), 0), 0)

    def test_top_hashes_and_openrouter_success_split(self):
        lines = [decision("2026-10-12T10:00:00.000Z", err="local thing", h="sha256:L", run="A"),
                 decision("2026-10-12T10:00:01.000Z", dec="candidate_succeeded", provider="openrouter",
                          model="m", err="", run="A", attempt=2)]
        rep = r.summarise(r.classify_all(r.parse_lines(lines)))["2026-10-12"]
        self.assertEqual(rep["top_hashes"]["local"][0][0], "sha256:L")
        self.assertEqual(rep["openrouter_succeeded"]["local"], 1)

    def test_latch_is_visible_as_turns_vs_decisions(self):
        # Intent: MUS-7789 may find one error latching an hour of traffic; distinct turns vs
        # decisions lets us see it without changing the counter.
        lines = [decision("2026-10-12T10:00:00.000Z", err="x", run="A", attempt=1),
                 decision("2026-10-12T10:00:01.000Z", err="x", run="A", attempt=2)]
        rep = r.summarise(r.classify_all(r.parse_lines(lines)))["2026-10-12"]
        self.assertEqual(rep["turns"]["local"], 1)

    def test_alert_message_names_what_it_is_and_does_not_page_provider(self):
        text = r.render(r.summarise(self.build(200)), threshold=150)
        self.assertIn("ALERT", text)
        self.assertIn("local", text)

    def test_quiet_day_has_no_alert_line(self):
        self.assertNotIn("ALERT", r.render(r.summarise(self.build(3)), threshold=150))


class CliTest(unittest.TestCase):
    def test_main_reads_log_file_dry_and_exits_by_alert(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "openclaw-main-2026-10-12.log")
            with open(p, "w") as fh:
                fh.write("\n".join(decision(f"2026-10-12T10:00:{i % 60:02d}.000Z", run=f"r{i}", err="local") for i in range(6)))
            self.assertEqual(r.main(["--log", p, "--threshold", "5"]), 10)
            self.assertEqual(r.main(["--log", p, "--threshold", "7"]), 0)
            self.assertEqual(r.main(["--log", os.path.join(d, "missing.log")]), 1)


if __name__ == "__main__":
    unittest.main()
