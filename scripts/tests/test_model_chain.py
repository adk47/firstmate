#!/usr/bin/env python3
"""Unit tests for the shared model chain (scripts/lib/model_chain.py) and its
watchdog (scripts/model-chain-watchdog.py).

The point of the chain: when the subscription tier fails, the DeepSeek tier
answers. These tests FORCE the primary to fail (quota, 429, 5xx, auth, tool
violation) and assert exactly which tier served the call, what the ledger says,
and what the watchdog would page.

Stdlib unittest, no network, no codex, no credentials: the codex helper, the
OpenRouter opener, the clock and sleep are all faked; the ledger is a temp file.
Run:
    python3 scripts/tests/test_model_chain.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.request
import urllib.error
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from lib import model_chain as mc  # noqa: E402

# Hermetic: never read (or need) the host's real OpenRouter key. PR Validation
# runs on node-8, where /opt/hydra/secrets/llm-provider-keys.json exists.
mc.load_key = lambda *a, **k: "test-key"  # noqa: E731

SCHEMA = {"type": "object", "required": ["verdict"],
          "properties": {"verdict": {"type": "string"}}}

_TMPDIR: tempfile.TemporaryDirectory | None = None


def setUpModule() -> None:  # noqa: N802 (unittest API)
    """Point the default ledger at a temp file. The spend cap now fails CLOSED
    when the ledger cannot be read, so a test that inherited the host's
    /var/lib/hydra would refuse the metered tier (correctly) and prove nothing."""
    global _TMPDIR
    _TMPDIR = tempfile.TemporaryDirectory(prefix="model-chain-ledger.")
    # Every UsageLedger() instance — including the ones docverify's _chain builds
    # per call — reads this at construction.
    os.environ["MODEL_CHAIN_LEDGER_PATH"] = str(Path(_TMPDIR.name) / "calls.jsonl")


def tearDownModule() -> None:  # noqa: N802
    if _TMPDIR is not None:
        _TMPDIR.cleanup()


def codex_events(text: str, usage: dict | None = None) -> str:
    return "\n".join(json.dumps(x) for x in [
        {"type": "turn.started"},
        {"type": "item.completed", "item": {"type": "agent_message", "text": text}},
        {"type": "turn.completed", "usage": usage or {"input_tokens": 900, "output_tokens": 40}},
    ]) + "\n"


class FakeCodex:
    """Stands in for `bash codex-judge-exec.sh ...`."""

    def __init__(self, script):
        self.script = list(script)          # [(rc, stdout, stderr)]
        self.calls = []

    def __call__(self, argv, input=None, **kw):
        self.calls.append({"argv": list(argv), "input": input})
        step = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        rc, out, err = step
        return subprocess.CompletedProcess(argv, rc, out, err)


class FakeOpenRouter:
    """Stands in for urllib.request.urlopen against OpenRouter."""

    def __init__(self, script):
        self.script = list(script)          # [dict body | (status, body_text) | OSError]
        self.requests = []

    @staticmethod
    def _ok(body: dict):
        class _Resp:
            def __init__(self, payload):
                self._raw = json.dumps(payload).encode()

            def read(self, *a):
                return self._raw

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        return _Resp(body)

    def __call__(self, req, timeout=None):
        self.requests.append({"url": req.full_url, "body": json.loads(req.data.decode()),
                              "timeout": timeout})
        step = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        if isinstance(step, Exception):
            raise step
        if isinstance(step, tuple):
            status, text = step
            raise urllib.error.HTTPError(req.full_url, status, text, {}, io.BytesIO(text.encode()))
        return self._ok(step)


def openrouter_ok(content: str, *, cost=0.0003, model="deepseek/deepseek-v4.1-flash-1017"):
    return {"model": model, "usage": {"prompt_tokens": 700, "completion_tokens": 30, "cost": cost},
            "choices": [{"finish_reason": "stop", "message": {"content": content}}]}


class ChainBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger_path = Path(self.tmp.name) / "calls.jsonl"
        self.lines: list[str] = []
        self.sleeps: list[float] = []

    def chain(self, **kw):
        return mc.ModelChain(
            "test-surface", ledger=mc.UsageLedger(self.ledger_path),
            sleep=lambda s: self.sleeps.append(s), log=self.lines.append,
            codex_helper=Path(__file__),  # exists() is what call_subscription checks
            **kw)

    def rows(self):
        return mc.read_calls(self.ledger_path)


class TestPrimaryServes(ChainBase):
    def test_subscription_answers_first_and_deepseek_is_never_called(self):
        codex = FakeCodex([(0, codex_events('{"verdict": "ok"}'), "")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "fallback"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call("judge this", schema=SCHEMA)

        self.assertTrue(res.ok)
        self.assertEqual(res.tier, mc.TIER_SUBSCRIPTION)
        self.assertEqual(res.json, {"verdict": "ok"})
        self.assertEqual(res.cost_usd, 0.0)          # the subscription is $0
        self.assertEqual(orouter.requests, [])       # the metered tier never ran
        self.assertFalse(res.served_by_fallback)

        rows = self.rows()
        self.assertEqual([(r["tier"], r["outcome"]) for r in rows], [(mc.TIER_SUBSCRIPTION, "ok")])
        self.assertEqual(rows[0]["surface"], "test-surface")
        self.assertEqual(rows[0]["cost_usd"], 0.0)
        # the log line names the tier that served the call
        self.assertTrue(any("tier=subscription" in line and "outcome=ok" in line for line in self.lines))


class TestFallbackServes(ChainBase):
    """The requirement: force the primary to fail, DeepSeek answers."""

    def _assert_deepseek_served(self, res, why: str):
        self.assertTrue(res.ok, f"{why}: chain returned {res.error}")
        self.assertEqual(res.tier, mc.TIER_FALLBACK)
        self.assertEqual(res.model, "deepseek/deepseek-v4.1-flash-1017")
        self.assertEqual(res.json, {"verdict": "ok"})
        self.assertTrue(res.served_by_fallback)
        self.assertEqual(res.attempts[0]["tier"], mc.TIER_SUBSCRIPTION)
        self.assertEqual(res.attempts[-1]["tier"], mc.TIER_FALLBACK)
        rows = self.rows()
        served = [r for r in rows if r["outcome"] == "ok"]
        self.assertEqual([(r["tier"], r["outcome"]) for r in served], [(mc.TIER_FALLBACK, "ok")])
        self.assertNotEqual(rows[0]["outcome"], "ok")
        self.assertGreater(served[0]["cost_usd"] or 0, 0)
        # the release is the LAST row, i.e. the charge was durable first
        self.assertEqual(rows[-1]["outcome"], "settle")
        self.assertTrue(any("tier=deepseek" in line and "outcome=ok" in line for line in self.lines))

    def test_quota_exhausted_falls_back(self):
        # rc 3 = the helper refused to call: the measured quota row says capped.
        codex = FakeCodex([(3, "", "provider_skipped=codex reason=quota account=a@muso.ai state/load=100%")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call("judge this", schema=SCHEMA)
        self._assert_deepseek_served(res, "quota")
        self.assertEqual(res.attempts[0]["kind"], mc.QUOTA)
        self.assertEqual(self.rows()[0]["kind"], mc.QUOTA)

    def test_auth_expired_falls_back(self):
        codex = FakeCodex([(1, codex_events(""), "{\"message\":\"Your access token could not be refreshed: 401\"}")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call("judge this", schema=SCHEMA)
        self._assert_deepseek_served(res, "auth")
        self.assertEqual(res.attempts[0]["kind"], mc.AUTH_EXPIRED)

    def test_429_on_the_fallback_retries_then_fails_over_tiers(self):
        # primary 429s once (retryable), 429s again, then DeepSeek answers.
        codex = FakeCodex([
            (1, "", "429 rate limit exceeded"),
            (1, "", "429 rate limit exceeded"),
        ])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter, retries=2).call(
            "judge this", schema=SCHEMA)
        self._assert_deepseek_served(res, "429")
        self.assertEqual(len(codex.calls), 2)        # retried the same tier
        self.assertEqual(len(self.sleeps), 1)        # with one backoff
        before = self.rows()[:2]
        self.assertEqual([r["attempt"] for r in before], [1, 2])
        self.assertEqual({r["kind"] for r in before}, {mc.RATE_LIMITED})

    def test_5xx_then_success_on_the_same_tier_does_not_spend(self):
        codex = FakeCodex([(1, "", "503 upstream server error"), (0, codex_events('{"verdict": "ok"}'), "")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "fallback"}')])
        res = self.chain(subscription_runner=codex, opener=orouter, retries=2).call(
            "judge this", schema=SCHEMA)
        self.assertTrue(res.ok)
        self.assertEqual(res.tier, mc.TIER_SUBSCRIPTION)
        self.assertEqual(orouter.requests, [])
        self.assertEqual([(r["tier"], r["outcome"]) for r in self.rows()],
                         [(mc.TIER_SUBSCRIPTION, "error"), (mc.TIER_SUBSCRIPTION, "ok")])

    def test_unusable_primary_answer_falls_back(self):
        codex = FakeCodex([(0, codex_events("I cannot answer in JSON"), "")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call("judge this", schema=SCHEMA)
        self._assert_deepseek_served(res, "bad answer")
        self.assertEqual(res.attempts[0]["kind"], mc.BAD_ANSWER)

    def test_web_requests_skip_the_subscription_and_use_the_web_plugin(self):
        codex = FakeCodex([(0, codex_events('{"verdict": "never"}'), "")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call(
            "judge this", schema=SCHEMA, web=True, exclude_domains=["muso.ai", "imdb.com"])
        self.assertTrue(res.ok)
        self.assertEqual(res.tier, mc.TIER_FALLBACK)
        self.assertEqual(codex.calls, [])  # a tier that cannot search must not answer blind
        body = orouter.requests[0]["body"]
        self.assertEqual(body["plugins"][0]["id"], "web")
        self.assertEqual(body["plugins"][0]["exclude_domains"], ["muso.ai", "imdb.com"])
        # user data must never be trainable: the deny filter rides on every call
        self.assertEqual(body["provider"], {"data_collection": "deny"})
        self.assertEqual(self.rows()[0]["outcome"], "skipped")
        self.assertEqual(self.rows()[0]["kind"], mc.UNAVAILABLE)


class TestBothTiersFail(ChainBase):
    def test_chain_exhausted_is_recorded_and_reported(self):
        codex = FakeCodex([(3, "", "reason=quota")])
        orouter = FakeOpenRouter([(429, "rate limited"), (429, "rate limited")])
        res = self.chain(subscription_runner=codex, opener=orouter, retries=2).call(
            "judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, mc.CHAIN_EXHAUSTED)
        self.assertIn("chain exhausted", res.error)
        rows = self.rows()
        self.assertEqual(rows[-1]["outcome"], mc.CHAIN_EXHAUSTED)
        self.assertEqual(rows[-1]["tier"], "none")
        counts = mc.tier_counts(rows)
        self.assertEqual(counts[mc.CHAIN_EXHAUSTED], 1)
        self.assertEqual(counts["served"], 0)
        # nobody answering counts as fallback pressure, never as health
        share, denom = mc.fallback_share(rows)
        self.assertEqual((share, denom), (1.0, 1))

    def test_tool_violation_aborts_instead_of_falling_back(self):
        codex = FakeCodex([(4, codex_events('{"verdict": "ok"}'), "")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, mc.UNSAFE)
        self.assertEqual(orouter.requests, [])   # a refusal is never laundered onto another model

    def test_daily_cap_skips_the_metered_tier(self):
        self.ledger_path.parent.mkdir(parents=True, exist_ok=True)
        self.ledger_path.write_text(json.dumps({
            "ts": mc.utcnow(), "epoch": 9999999999, "surface": "test-surface", "tier": mc.TIER_FALLBACK,
            "outcome": "ok", "cost_usd": 25.0}) + "\n", encoding="utf-8")
        codex = FakeCodex([(3, "", "reason=quota")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=codex, opener=orouter, daily_usd_cap=10.0).call(
            "judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [])
        self.assertIn("daily cap", self.rows()[-2]["reason"] if len(self.rows()) > 1 else "")

    def test_missing_openrouter_key_is_a_skip_not_a_crash(self):
        real = mc.load_key
        mc.load_key = lambda *a, **k: None
        try:
            att = mc.call_deepseek([{"role": "user", "content": "x"}], opener=FakeOpenRouter([{}]))
        finally:
            mc.load_key = real
        self.assertEqual(att.outcome, "skipped")
        self.assertEqual(att.kind, mc.UNAVAILABLE)
        self.assertEqual(att.reason, "no OpenRouter key")


class TestExhaustionIsTerminal(ChainBase):
    """QA 2026-11-03: `chain_exhausted` means "this user request got NO model
    answer". A one-tier call in the MIDDLE of a caller's own ladder must not write
    it (doc-verify's free tier declining while the paid tier then answers paged the
    fleet as a dead chain), and the LAST rung failing must write it (credit-trust's
    paid rung dying was invisible to the immediate alarm)."""

    def exhausted_rows(self):
        return [r for r in self.rows() if r.get("outcome") == mc.CHAIN_EXHAUSTED]

    def test_a_mid_ladder_decline_records_nothing(self):
        res = self.chain(tiers=(mc.TIER_SUBSCRIPTION,), subscription_runner=FakeCodex(
            [(3, "", "reason=quota")])).call("read this", schema=SCHEMA, record_exhausted=False)
        self.assertFalse(res.ok)
        self.assertEqual(res.error_kind, mc.CHAIN_EXHAUSTED)
        self.assertEqual(self.exhausted_rows(), [], "the paid rung may still serve this request")

    def test_the_last_rung_failing_records_exhaustion(self):
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]),
                         opener=FakeOpenRouter([(429, "rate limited"), (429, "rate limited")])).call_fallback(
            "read this", schema=SCHEMA, step="extract")
        self.assertFalse(res.ok)
        self.assertEqual(len(self.exhausted_rows()), 1, "a dead end must be visible to the alarm")
        self.assertEqual(self.exhausted_rows()[0]["surface"], "test-surface")

    def test_an_unsafe_abort_is_not_exhaustion(self):
        res = self.chain(subscription_runner=FakeCodex([(9, "", "safety_violation")]),
                         opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])).call(
            "judge this", schema=SCHEMA)
        self.assertEqual(res.error_kind, mc.UNSAFE)
        self.assertEqual(self.exhausted_rows(), [], "a refusal is a decision, not a dead chain")


class TestCapIsACeiling(ChainBase):
    """QA 2026-11-03: `spent >= cap` plus a separate reservation let a $9.99 day
    admit the call that tips it over, and two workers could both read the same
    below-cap total. Check-and-reserve is one locked step."""

    def spent(self, usd, rows=None):
        self.ledger_path.write_text("".join(
            json.dumps({"ts": mc.utcnow(), "epoch": 9999999999, "tier": mc.TIER_FALLBACK,
                        "outcome": "ok", "cost_usd": usd / (rows or 1)}) + "\n" for _ in range(rows or 1)))

    def test_a_reservation_that_would_cross_the_cap_is_refused(self):
        self.spent(9.99)
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter,
                         daily_usd_cap=10.0).call("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [], "no spend that would cross the ceiling")
        self.assertIn("daily cap $10.00 reached", res.attempts[-1]["reason"])

    def test_concurrent_callers_cannot_all_pass_the_same_check(self):
        """Two reservations fit under a $0.10 cap; twenty concurrent attempts must
        still admit exactly two."""
        import threading
        ledger = mc.UsageLedger(self.ledger_path)
        admitted, refused = [], []
        gate = threading.Barrier(20)

        def worker():
            gate.wait()
            why = ledger.admit(0.10, 0.05, surface="s", step="concurrent")
            (refused if why else admitted).append(why)

        threads = [threading.Thread(target=worker) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(admitted), 2, f"admitted={len(admitted)} refused={len(refused)}")
        self.assertAlmostEqual(ledger.spent_today_usd(), 0.10, places=9)

    def test_zero_cap_means_unlimited_and_is_not_locked_out(self):
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter,
                         daily_usd_cap=0).call("judge this", schema=SCHEMA)
        self.assertTrue(res.ok)


class TestReservation(ChainBase):
    """QA 2026-11-03 (carried forward): a READABLE but UNWRITABLE ledger let every
    new process read the old total, spend, and fail to record - so the $10/day cap
    never bound across processes. The reservation is written first."""

    def test_a_reservation_is_durable_before_any_spend(self):
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter).call(
            "judge this", schema=SCHEMA)
        rows = self.rows()
        reserved = [r for r in rows if r["outcome"] == "reserve"]
        self.assertEqual(len(reserved), 1)
        self.assertEqual(reserved[0]["cost_usd"], mc.RESERVATION_USD)
        self.assertLess(rows.index(reserved[0]),
                        rows.index([r for r in rows if r["outcome"] == "ok"][0]),
                        "the reservation must be written BEFORE the paid call")
        # reserve (+), the real charge (+), the release (-): the SUM is the truth.
        self.assertAlmostEqual(sum(r["cost_usd"] or 0 for r in rows),
                               [r for r in rows if r["outcome"] == "ok"][0]["cost_usd"], places=9)

    @unittest.skipIf(os.geteuid() == 0, "root ignores permission bits; the seam test above covers this")
    def test_an_unwritable_ledger_refuses_before_spending_across_processes(self):
        """The cap must hold for a FRESH process too: the ledger here is readable
        and unwritable (a full disk / read-only mount looks exactly like this)."""
        ledger = self.ledger_path
        ledger.write_text("")                                   # readable, empty
        ledger.chmod(0o444)
        self.addCleanup(ledger.chmod, 0o644)
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter).call(
            "judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [], "no reservation, no spend")
        self.assertTrue(any("reservation not durable" in (a.get("reason") or "")
                            or "accounting unavailable" in (a.get("reason") or "")
                            for a in res.attempts), res.attempts)

    def test_a_failed_metered_call_still_releases_its_reservation(self):
        orouter = FakeOpenRouter([(429, "rate limited"), (429, "rate limited")])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter).call(
            "judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        rows = self.rows()
        reserved = [r for r in rows if r["outcome"] == "reserve"]
        released = [r for r in rows if r["outcome"] == "settle"]
        self.assertGreaterEqual(len(reserved), 1)          # one per attempt (429 retries)
        self.assertEqual(len(reserved), len(released), "every reservation is released")
        self.assertAlmostEqual(sum(r.get("cost_usd") or 0 for r in rows), 0.0, places=9,
                               msg="nothing was charged, so nothing stays reserved")


class TestStrictSchema(unittest.TestCase):
    """Measured on node-8 (2026-11-03, first live tier-1 call): codex's strict
    structured output rejects a schema without additionalProperties:false and
    requires every property in `required`. A 400 there would push the whole user
    path onto the metered tier forever, so it is normalized before the call."""

    def test_objects_are_made_strict(self):
        got = mc.strict_schema({"type": "object", "properties": {
            "verdict": {"type": "string"}, "why": {"type": "string"}}})
        self.assertIs(got["additionalProperties"], False)
        self.assertEqual(got["required"], ["verdict", "why"])

    def test_a_caller_cannot_keep_additional_properties_true(self):
        got = mc.strict_schema({"type": "object", "additionalProperties": True,
                                "required": [], "properties": {"a": {"type": "string"}}})
        self.assertIs(got["additionalProperties"], False)

    def test_nested_objects_and_arrays_are_walked(self):
        got = mc.strict_schema({"type": "object", "properties": {"items": {
            "type": "array", "items": {"type": "object", "properties": {"n": {"type": "integer"}}}}}})
        inner = got["properties"]["items"]["items"]
        self.assertIs(inner["additionalProperties"], False)
        self.assertEqual(inner["required"], ["n"])

    def test_the_helper_receives_the_strict_schema(self):
        """The shim must write the NORMALIZED schema, not the caller's."""
        seen = {}

        def runner(argv, input=None, **kw):
            seen["schema"] = json.loads(Path(argv[argv.index("--schema") + 1]).read_text())
            meta_f = Path(argv[argv.index("--meta-out") + 1])
            meta_f.write_text(json.dumps({"latency_ms": 3}))
            return subprocess.CompletedProcess(argv, 0, codex_events('{"verdict": "ok"}'), "")

        mc.call_subscription("q", schema={"type": "object", "properties": {"verdict": {"type": "string"}}},
                             runner=runner, helper=Path(__file__))
        self.assertIs(seen["schema"]["additionalProperties"], False)
        self.assertEqual(seen["schema"]["required"], ["verdict"])

    def test_scalars_and_free_form_nodes_are_untouched(self):
        self.assertEqual(mc.strict_schema({"type": "string"}), {"type": "string"})
        self.assertEqual(mc.strict_schema({}), {})
        self.assertEqual(mc.strict_schema({"$ref": "#/definitions/x"}), {"$ref": "#/definitions/x"})


class TestClassification(unittest.TestCase):
    def test_quota_beats_rate_limit(self):
        self.assertEqual(mc.classify_text("You've reached your Codex subscription usage limit"), mc.QUOTA)
        self.assertEqual(mc.classify_text("429 Too Many Requests"), mc.RATE_LIMITED)
        self.assertEqual(mc.classify_text("Your access token could not be refreshed"), mc.AUTH_EXPIRED)
        self.assertEqual(mc.classify_text("502 bad gateway"), mc.SERVER_ERROR)
        self.assertIsNone(mc.classify_text("everything is fine"))

    def test_http_status_classes(self):
        self.assertEqual(mc.classify_http(429), mc.RATE_LIMITED)
        self.assertEqual(mc.classify_http(401), mc.AUTH_EXPIRED)
        self.assertEqual(mc.classify_http(402), mc.QUOTA)
        self.assertEqual(mc.classify_http(503), mc.SERVER_ERROR)
        self.assertEqual(mc.classify_http(422), mc.UNAVAILABLE)


def load_watchdog():
    spec = importlib.util.spec_from_file_location(
        "model_chain_watchdog", SCRIPTS / "model-chain-watchdog.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestWatchdog(unittest.TestCase):
    def test_the_default_journal_units_are_the_installed_services(self):
        """QA 2026-11-03: the template spelling `openclaw-gateway@main` matches no
        unit on node-8, so every agent-turn fallback would have read as silence -
        the silent-health failure this watchdog exists to prevent. Verified on the
        host: `systemctl list-units "openclaw*"` shows -main and -edge."""
        wd = load_watchdog()
        self.assertEqual(tuple(wd.GATEWAYS), ("openclaw-gateway-main", "openclaw-gateway-edge"))

    def setUp(self):
        self.wd = load_watchdog()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Path(self.tmp.name) / "calls.jsonl"

    def write(self, rows):
        self.ledger.write_text("".join(json.dumps({**r, "ts": mc.utcnow(), "epoch": 9999999999}) + "\n"
                                       for r in rows), encoding="utf-8")

    def assess(self):
        return self.wd.assess(0, ledger=str(self.ledger), include_agents=False)

    def test_all_primary_is_healthy(self):
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"} for _ in range(10)])
        a = self.assess()
        self.assertEqual(a["fallback_share"], 0.0)
        self.assertFalse(a["fallback_breach"])
        self.assertFalse(a["chain_dead"])

    def test_over_twenty_percent_fallback_breaches(self):
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"} for _ in range(7)]
                   + [{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"} for _ in range(3)])
        a = self.assess()
        self.assertEqual(a["denominator"], 10)
        self.assertEqual(a["fallback_share"], 0.3)
        self.assertTrue(a["fallback_breach"])

    def test_at_twenty_percent_does_not_breach(self):
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"} for _ in range(8)]
                   + [{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"} for _ in range(2)])
        a = self.assess()
        self.assertFalse(a["fallback_breach"])   # strictly MORE than 20%

    def test_below_min_calls_is_not_judged(self):
        self.write([{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"}])
        a = self.assess()
        self.assertFalse(a["judged"])
        self.assertFalse(a["fallback_breach"])

    def test_a_dead_chain_pages_even_below_min_calls(self):
        self.write([{"surface": "s", "tier": "none", "outcome": mc.CHAIN_EXHAUSTED}])
        a = self.assess()
        self.assertTrue(a["chain_dead"])
        self.assertFalse(a["judged"])

    def test_only_served_calls_and_exhaustions_are_counted(self):
        # skips and retried failures are noise, not calls that were answered
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"},
                    {"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "skipped"},
                    {"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "error"}])
        a = self.assess()
        self.assertEqual(a["total"][mc.TIER_SUBSCRIPTION], 1)
        self.assertEqual(a["total"][mc.TIER_FALLBACK], 0)
        self.assertEqual(a["denominator"], 1)

    def test_agent_journal_records_map_to_tiers(self):
        rows = [
            {"decision": "candidate_succeeded", "requested": "openai/gpt-6-sol", "candidate": "openai/gpt-6-sol"},
            {"decision": "candidate_succeeded", "requested": "openai/gpt-6-sol",
             "candidate": "openrouter/deepseek/deepseek-v4.1-flash-1017"},
            {"decision": "candidate_failed", "requested": "openai/gpt-6-sol", "next": "none"},
            {"decision": "candidate_failed", "requested": "openai/gpt-6-sol", "next": "openrouter/x"},
        ]
        counts = self.wd.agent_counts(rows)
        self.assertEqual(counts[mc.TIER_SUBSCRIPTION], 1)
        self.assertEqual(counts[mc.TIER_FALLBACK], 1)
        self.assertEqual(counts[mc.CHAIN_EXHAUSTED], 1)   # only next=none
        self.assertEqual(counts["served"], 2)

    def test_agent_rows_are_parsed_from_journal_text(self):
        line = ("Jan 01 00:00:00 ovh-node-8 openclaw[1]: [model-fallback/decision] model fallback decision: "
                "decision=candidate_succeeded requested=openai/gpt-6-sol "
                "candidate=openrouter/deepseek/deepseek-v4.1-flash-1017 reason=unknown next=none")
        row = dict(self.wd._FIELD_RE.findall(line))
        self.assertEqual(row["decision"], "candidate_succeeded")
        self.assertEqual(row["candidate"], "openrouter/deepseek/deepseek-v4.1-flash-1017")

    def test_the_alert_cli_pages_through_main(self):
        """QA 2026-11-03 (CRITICAL): a duplicate render block landed inside main(),
        so every --check/--alert run died with NameError before checking or paging -
        the timer could not alert at all. This exercises the real entrypoint."""
        self.write([{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"} for _ in range(5)])
        posted = []
        self.wd.slack_post_critical = lambda msg: posted.append(msg) or True
        self.wd.STATE_PATH = Path(self.tmp.name) / "state.json"
        argv = ["--alert", "--no-agents", "--window-hours", "1", "--ledger", str(self.ledger)]
        self.assertEqual(self.wd.main(argv), 0)
        self.assertEqual(len(posted), 1, "a 100% fallback window must page exactly once")
        self.assertIn("FALLBACK tier", posted[0])
        # ... and the second run inside the repeat window is suppressed, not resent.
        self.wd.main(argv)
        self.assertEqual(len(posted), 1)

    def test_the_check_cli_does_not_crash_and_pages_nothing(self):
        self.write([{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"} for _ in range(5)])
        posted = []
        self.wd.slack_post_critical = lambda msg: posted.append(msg) or True
        proc = subprocess.run([sys.executable, str(SCRIPTS / "model-chain-watchdog.py"), "--check",
                               "--no-agents", "--ledger", str(self.ledger)],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("BREACH (would alert", proc.stderr)
        self.assertEqual(posted, [], "--check never posts")

    def test_an_unreadable_ledger_is_unknown_not_healthy(self):
        """QA 2026-11-03: read_calls() answers [] for an unreadable ledger, so the
        scripted side read as zero calls (healthy) while every fallback was invisible."""
        ledger = Path(self.tmp.name) / "ledger-is-a-directory"
        ledger.mkdir()
        a = self.wd.assess(0.0, ledger=str(ledger), include_agents=False)
        self.assertFalse(a["ledger_source_ok"])
        self.assertFalse(a["judged"])
        self.assertIn("USAGE LEDGER UNREADABLE", self.wd.render(a, 1.0))

    def test_an_unreadable_journal_is_unknown_not_healthy(self):
        """QA 2026-11-03: `journalctl` failing (or matching no unit) used to return
        zero rows, which merged into "10 scripted subscription calls, 0 fallbacks"
        and read as healthy while every agent turn could have been on DeepSeek."""
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"}] * 10)
        saved = self.wd.subprocess.run

        def blind(argv, **kw):
            return subprocess.CompletedProcess(argv, 1, "", "Failed to open journal: Permission denied")

        self.wd.subprocess.run = blind
        self.addCleanup(lambda: setattr(self.wd.subprocess, "run", saved))
        a = self.wd.assess(0.0, ledger=str(self.ledger), units=("openclaw-gateway-main",))
        self.assertFalse(a["agents_source_ok"])
        self.assertFalse(a["judged"], "an unknowable share is not a judged-healthy share")
        self.assertFalse(a["fallback_breach"])
        self.assertIn("AGENT SOURCE UNKNOWN (journal unreadable)", self.wd.render(a, 1.0))
        self.assertEqual(a["agents_source_note"], "journal unreadable")

    def test_a_renamed_unit_is_unknown_even_though_journalctl_exits_zero(self):
        """`journalctl -u <nonexistent>` exits 0 and prints nothing, so a rename is
        silent health unless the units are checked against systemd (the 11-03 bug)."""
        saved = self.wd.subprocess.run

        def fake(argv, **kw):
            if argv[0] == "systemctl":
                return subprocess.CompletedProcess(argv, 0, "openclaw-gateway-main.service enabled\n", "")
            return subprocess.CompletedProcess(argv, 0, "-- No entries --\n", "")

        self.wd.subprocess.run = fake
        self.addCleanup(lambda: setattr(self.wd.subprocess, "run", saved))
        a = self.wd.assess(0.0, ledger=str(self.ledger),
                           units=("openclaw-gateway-main", "openclaw-gateway@main"))
        self.assertFalse(a["agents_source_ok"])
        self.assertIn("no such unit: openclaw-gateway@main", a["agents_source_note"])

    def test_capability_only_fallbacks_are_not_outage_pressure(self):
        """QA 2026-11-03: credit_review's web reviews SKIP codex on purpose (no
        headless search on codex-cli 0.156.1) and are answered by DeepSeek. Five
        routine web reviews used to read as 5/5 = 100% fallback, i.e. a false
        outage page on a healthy subscription."""
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"}] * 5
                   + [{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok", "capability": True}] * 5)
        a = self.assess()
        self.assertEqual(a["scripted"]["capability"], 5)
        self.assertEqual(a["denominator"], 5, "capability rows are in neither side of the share")
        self.assertEqual(a["fallback_share"], 0.0)
        self.assertFalse(a["fallback_breach"])
        self.assertIn("capability-only fallbacks: 5", self.wd.render(a, 1.0))

    def test_a_capability_skip_marks_the_fallback_row(self):
        """The marking has to start in the chain, or no reader can tell the two
        kinds of fallback apart."""
        ledger = self.ledger
        chain = mc.ModelChain("credit-review", ledger=mc.UsageLedger(ledger),
                              subscription_runner=FakeCodex([(3, "", "reason=web_search_unavailable")]),
                              opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')]),
                              codex_helper=Path("scripts/lib/codex-judge-exec.sh"), sleep=lambda s: None)
        res = chain.call("judge this", schema=SCHEMA, web=True)
        self.assertTrue(res.ok)
        rows = [json.loads(x) for x in ledger.read_text().splitlines() if x.strip()]
        served = [r for r in rows if r.get("outcome") == "ok"]
        self.assertTrue(served and served[0].get("capability"), rows)
        self.assertEqual(mc.tier_counts(rows)["capability"], 1)
        self.assertEqual(mc.fallback_share(rows), (0.0, 0))

    def test_agent_fallbacks_are_an_absolute_count_not_a_share(self):
        """QA 2026-11-03: the installed runner logs `[model-fallback/decision]` only
        when a fallback happened, so a quiet window of 1,000 first-choice turns plus
        5 DeepSeek fallbacks has 5 agent rows and no primary ones. Folding that into
        the denominator reported 100% and paged on a ~0.5% reality."""
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"}] * 10)
        self.wd.agent_rows = lambda *a, **k: (
            [{"decision": "candidate_succeeded", "requested": "openai/gpt-6-sol",
              "candidate": "openrouter/deepseek/deepseek-v4.1-flash-1017"}] * 5, True)
        self.wd.unit_inventory = lambda: {"openclaw-gateway-main"}
        a = self.wd.assess(0.0, ledger=str(self.ledger), units=("openclaw-gateway-main",))
        self.assertEqual(a["agents"][mc.TIER_FALLBACK], 5)
        self.assertEqual(a["denominator"], 10, "the share's denominator is scripted calls only")
        self.assertEqual(a["fallback_share"], 0.0)
        self.assertFalse(a["fallback_breach"])
        self.assertFalse(a["agents_counts_complete"])
        self.assertTrue(a["agent_fallback_breach"], "5 agent fallback events is worth a page")
        self.assertIn("decision-only rows", self.wd.render(a, 1.0))

    def test_a_maintenance_window_suppresses_the_page_and_says_so(self):
        """A planned fleet window stops the codex subscription tier, so the breach
        shape is identical to a real outage; paging through it trains everyone to
        ignore the channel. Silence is only allowed because the run says it proved
        nothing (scripts/tests/maintenance-guard-drift.bats requires the guard)."""
        self.write([{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"}] * 10)
        posted = []
        self.wd.slack_post_critical = lambda msg: posted.append(msg) or True
        self.wd.maintenance_active = lambda: True
        self.wd.STATE_PATH = Path(self.tmp.name) / "state-maint.json"
        self.assertEqual(self.wd.main(["--alert", "--ledger", str(self.ledger)]), 0)
        self.assertEqual(posted, [], "a maintenance window pages nothing")

    def test_an_unverifiable_unit_inventory_is_not_a_quiet_fleet(self):
        """QA 2026-11-03: when `systemctl list-unit-files` failed or came back empty
        during a gateway rename, missing_units() returned [] and `journalctl -u
        <old name>` exited 0 with no rows - so an invisible agent fallback stream
        read as healthy. An unverifiable inventory is a blind source now."""
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"}] * 10)
        self.wd.unit_inventory = lambda: set()
        self.wd.agent_rows = lambda *a, **k: ([], True)
        a = self.wd.assess(0.0, ledger=str(self.ledger), units=("openclaw-gateway-main",))
        self.assertFalse(a["agents_source_ok"])
        self.assertFalse(a["judged"])
        self.assertIn("inventory unverifiable", a["agents_source_note"])
        self.assertIn("AGENT SOURCE UNKNOWN", self.wd.render(a, 1.0))
        # and the CLI path actually pages on it (breaches are built in main())
        posted = []
        self.wd.slack_post_critical = lambda msg: posted.append(msg) or True
        self.wd.STATE_PATH = Path(self.tmp.name) / "state-inventory.json"
        self.assertEqual(self.wd.main(["--alert", "--ledger", str(self.ledger)]), 0)
        self.assertTrue(posted, "an unverifiable inventory must page")
        self.assertIn("cannot read the agent journals", posted[0])
        self.assertIn("inventory unverifiable", posted[0])

    def test_a_single_agent_fallback_does_not_page(self):
        self.write([{"surface": "s", "tier": mc.TIER_SUBSCRIPTION, "outcome": "ok"}] * 10)
        self.wd.agent_rows = lambda *a, **k: (
            [{"decision": "candidate_succeeded", "requested": "openai/gpt-6-sol",
              "candidate": "openrouter/deepseek/deepseek-v4.1-flash-1017"}], True)
        self.wd.unit_inventory = lambda: {"openclaw-gateway-main"}
        a = self.wd.assess(0.0, ledger=str(self.ledger), units=("openclaw-gateway-main",))
        self.assertFalse(a["agent_fallback_breach"])

    def test_canary_mode_writes_nothing(self):
        self.write([{"surface": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok"}])
        before = self.ledger.read_text()
        proc = subprocess.run([sys.executable, str(SCRIPTS / "model-chain-watchdog.py"), "--canary",
                               "--ledger", str(self.ledger), "--no-agents", "--at", "9999999999"],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        report = json.loads(proc.stdout)
        self.assertIn("last_15m", report)
        self.assertIn("last_60m", report)
        self.assertEqual(report["last_60m"]["total"][mc.TIER_FALLBACK], 1)
        self.assertEqual(self.ledger.read_text(), before)



class TestDocVerifyTransport(unittest.TestCase):
    """doc-verify (scripts/credit_verify/docverify/extract.py) rides the same
    chain: free subscription first, DeepSeek when it declines, and the answer
    comes back in OpenRouter's shape so nothing downstream changes."""

    def setUp(self):
        from credit_verify.docverify import extract as ex
        self.ex = ex
        self.ledger_path = Path(os.environ["MODEL_CHAIN_LEDGER_PATH"])
        self.lines: list[str] = []
        self.saved = (ex.model_chain.call_subscription, ex.model_chain.call_deepseek)
        self.addCleanup(lambda: setattr(ex.model_chain, "call_subscription", self.saved[0]) or
                        setattr(ex.model_chain, "call_deepseek", self.saved[1]))

    def sub(self, outcome="ok", text='{"claims": []}', **kw):
        ex = self.ex
        ex.model_chain.call_subscription = lambda *a, **k: mc.TierAttempt(
            mc.TIER_SUBSCRIPTION, outcome, kind=kw.get("kind"), reason=kw.get("reason"),
            model=mc.SUBSCRIPTION_MODEL, text=text if outcome == "ok" else None, cost_usd=0.0,
            input_tokens=10, output_tokens=2, latency_ms=5)

    def ds(self, outcome="ok", text='{"claims": []}', reported=mc.FALLBACK_MODEL):
        ex = self.ex
        ex.model_chain.call_deepseek = lambda *a, **k: mc.TierAttempt(
            mc.TIER_FALLBACK, outcome, model=mc.FALLBACK_MODEL, text=text if outcome == "ok" else None,
            cost_usd=0.0004, input_tokens=11, output_tokens=3, latency_ms=7,
            # the real call_deepseek records what the PROVIDER reported, or None
            meta={"model_reported": reported})

    def post(self):
        return self.ex.chain_post({"messages": [{"role": "user", "content": "read this"}],
                                   "max_tokens": 100}, "key", 30)

    def test_the_free_tier_is_the_subscription_alone_and_is_recorded(self):
        """The free tier runs as its own single-tier chain call, so a $0 answer
        writes a ledger row and a tier=subscription line like everything else.
        Calling call_subscription directly (as this used to) left hundreds of
        successes invisible while the few metered rows showed up - a false 100%
        fallback share (QA 2026-11-03)."""
        self.sub()
        ledger = Path(self.ex.model_chain.UsageLedger().path)
        before = ledger.read_text() if ledger.exists() else ""
        r = self.ex._free_chain().call("read this", timeout_s=5, sensitive=True, step="free")
        self.assertTrue(r.ok)
        self.assertEqual(r.tier, mc.TIER_SUBSCRIPTION)
        self.assertEqual(r.cost_usd, 0.0)
        after = ledger.read_text() if ledger.exists() else ""
        self.assertGreater(len(after), len(before), "the free tier writes a ledger row")

    def test_chain_post_is_the_metered_tier_only(self):
        """The subscription was already asked by _free_tier, so chain_post must
        not ask it again (QA 2026-11-03: 'make one chain call and consume its
        result once')."""
        asked = []

        def sub(*a, **k):
            asked.append(1)
            raise AssertionError("chain_post must not re-ask the subscription")

        self.ex.model_chain.call_subscription = sub
        self.ds()
        data = self.post()
        self.assertEqual(data["model"], mc.FALLBACK_MODEL)
        self.assertEqual(asked, [])
        self.assertGreater(data["usage"]["cost"], 0)

    def test_an_unsafe_verdict_aborts_the_extraction_instead_of_laundering_it(self):
        """QA 2026-11-03: a tool/safety violation is not a decline. `chain_post`
        would re-ask the subscription, and the metered tier would then answer a
        question the subscription was found unsafe on. Fail the whole extraction
        closed and never touch tier 2."""
        self.sub(outcome="error", kind=mc.UNSAFE, reason="safety_violation")

        def boom(*a, **k):
            raise AssertionError("tier 2 must never be asked after an unsafe verdict")

        self.ex.model_chain.call_deepseek = boom

        class Store:
            rows: list = []

            def llm_call(self, row):
                self.rows.append(row)

            def spent_today_usd(self):
                return 0.0

        store = Store()
        out = self.ex.Extractor(store=store).extract("claims here", {}, "p-unsafe")
        self.assertFalse(out.ok)
        self.assertIn("unsafe", str(out.error))
        self.assertEqual(store.rows[-1]["cost_usd"], 0)
        self.assertIn("unsafe", store.rows[-1]["reason"])

    def test_a_quota_decline_on_the_free_tier_hands_the_document_to_the_metered_tier(self):
        self.sub(outcome="skipped", kind=mc.QUOTA, reason="quota")
        free = self.ex._free_chain().call("read this", timeout_s=5, sensitive=True, step="free")
        self.assertFalse(free.ok)
        self.assertEqual(free.attempts[-1]["kind"], mc.QUOTA)
        self.ds()
        data = self.post()
        self.assertEqual(data["model"], mc.FALLBACK_MODEL)
        self.assertGreater(data["usage"]["cost"], 0)

    class _Store:
        def __init__(self):
            self.rows = []

        def llm_call(self, row):
            self.rows.append(row)
            return len(self.rows)

        def spent_today_usd(self):
            return 0.0

    def _ledger_rows_since(self, before: int):
        ledger = Path(self.ex.model_chain.UsageLedger().path)
        rows = [json.loads(x) for x in ledger.read_text().splitlines() if x.strip()] if ledger.exists() else []
        return rows[before:]

    def _ledger_len(self):
        ledger = Path(self.ex.model_chain.UsageLedger().path)
        return len([x for x in ledger.read_text().splitlines() if x.strip()]) if ledger.exists() else 0

    def test_the_legacy_transport_never_claims_a_chain_outage(self):
        """QA 2026-11-04: with CREDIT_DOC_VERIFY_LEGACY_TRANSPORT=1 (or an injected
        post=) neither ModelChain tier runs, so a terminal `chain_exhausted` row
        makes the watchdog page "both tiers failed" about a path that never used
        them. The marker is written only by the chain transport."""
        bodies = []

        def legacy_post(body, key, timeout):
            bodies.append(body)
            return {"model": "legacy/whatever", "usage": {"cost": 0.001},
                    "choices": [{"finish_reason": "stop", "message": {"content": "not json at all"}}]}

        store = self._Store()
        before = self._ledger_len()
        out = self.ex.Extractor(store=store, key="k", post=legacy_post).extract(
            "a short document", {}, "p-legacy")
        self.assertFalse(out.ok)
        self.assertEqual(len(bodies), 1 + self.ex.UNUSABLE_RETRIES, "both legacy attempts ran")
        rows = self._ledger_rows_since(before)
        self.assertEqual([r for r in rows if r.get("outcome") == mc.CHAIN_EXHAUSTED], [],
                         "the legacy path must not claim a chain outage")
        self.assertEqual([r.get("outcome") for r in store.rows], ["error"] * (1 + self.ex.UNUSABLE_RETRIES),
                         "each legacy attempt is still its own doc-verify ledger row")

    def test_a_charge_that_fills_the_cap_on_the_retry_still_pages(self):
        """QA 2026-11-04: the first paid answer was charged and unusable, its cost
        reached doc-verify's daily cap, and the retry took the cap exit - so no
        extraction was served and no terminal marker written."""
        self.sub(outcome="skipped", kind=mc.QUOTA, reason="quota")
        self.ex.model_chain.call_deepseek = lambda messages, **k: mc.TierAttempt(
            mc.TIER_FALLBACK, "ok", model=mc.FALLBACK_MODEL, text="not json at all",
            cost_usd=0.0002, latency_ms=1,
            meta={"finish_reason": "stop", "model_reported": mc.FALLBACK_MODEL})

        class FilledStore(self._Store):
            """The cap is reached BY the first paid attempt's charge."""
            calls = 0

            def spent_today_usd(self):
                # Only the CHARGED attempt (its row carries a cost) fills the cap;
                # the free tier's own skip row must not.
                return 1e9 if any(r.get("cost_usd") for r in self.rows) else 0.0

        store = FilledStore()
        before = self._ledger_len()
        out = self.ex.Extractor(store=store, key="k", post=self.ex.chain_post).extract(
            "a short document", {}, "p-retry-cap")
        self.assertFalse(out.ok)
        rows = self._ledger_rows_since(before)
        markers = [r for r in rows if r.get("outcome") == mc.CHAIN_EXHAUSTED]
        self.assertEqual(len(markers), 1, "a cap that stops the retry must page")
        self.assertIn("reached the daily cap", markers[0].get("reason") or "")

    def test_a_declined_free_tier_plus_the_cap_or_no_key_still_pages(self):
        """QA 2026-11-03: with the free tier declined, the cap-reached and no-key
        early exits returned fallback() before chain_post, so the request got no
        answer and wrote no chain_exhausted row - the watchdog stayed blind."""
        self.sub(outcome="skipped", kind=mc.QUOTA, reason="quota")

        class CappedStore(self._Store):
            def spent_today_usd(self):
                return 1e9

        # `_extract` gated on `credit_review.judge.load_key` (imported into extract),
        # NOT model_chain.KEY_FILE, so patching the latter still reached the live
        # provider on a configured host (QA 2026-11-03). Stub the gate the code
        # actually calls, and make any network attempt fail loudly.
        saved_gate = self.ex.load_key
        saved_open = urllib.request.urlopen

        def no_network(*a, **k):
            raise AssertionError("this test must never reach the provider")

        self.addCleanup(lambda: (setattr(self.ex, "load_key", saved_gate),
                                 setattr(urllib.request, "urlopen", saved_open)))
        self.ex.load_key = lambda: None
        urllib.request.urlopen = no_network

        for store, why in ((CappedStore(), "daily cap reached"), (self._Store(), "no OpenRouter key")):
            before = self._ledger_len()
            out = self.ex.Extractor(store=store, post=self.ex.chain_post).extract(
                "a short document", {}, "p-dead")
            self.assertFalse(out.ok)
            rows = self._ledger_rows_since(before)
            markers = [r for r in rows if r.get("outcome") == mc.CHAIN_EXHAUSTED]
            self.assertEqual(len(markers), 1, why)
            self.assertEqual(markers[0]["tier"], "none", why)

    def test_two_malformed_paid_answers_are_a_dead_user_path(self):
        """QA 2026-11-03: chain_post calls the paid tier with schema=None, so
        nonempty non-JSON text with finish_reason=stop is recorded as ok; when both
        attempts then fail validate(), the path produced nothing and wrote no
        `chain_exhausted` row, leaving the watchdog blind."""
        self.sub(outcome="skipped", kind=mc.QUOTA, reason="quota")
        self.ex.model_chain.call_deepseek = lambda messages, **k: mc.TierAttempt(
            mc.TIER_FALLBACK, "ok", model=mc.FALLBACK_MODEL, text="I could not read this document.",
            cost_usd=0.0002, latency_ms=1,
            meta={"finish_reason": "stop", "model_reported": mc.FALLBACK_MODEL})
        store = self._Store()
        before = self._ledger_len()
        out = self.ex.Extractor(store=store, key="k", post=self.ex.chain_post).extract(
            "a short document", {}, "p-malformed")
        self.assertFalse(out.ok)
        rows = self._ledger_rows_since(before)
        self.assertEqual([r for r in rows if r.get("outcome") == mc.CHAIN_EXHAUSTED], rows[-1:],
                         "a path that produced no extraction must page")

    def test_a_recovered_truncation_leaves_no_terminal_marker(self):
        """QA 2026-11-03: call_fallback() recorded `chain_exhausted` for the
        truncation BEFORE doc-verify's recovery ran, so a document that was then
        chunked successfully still paged 'both tiers failed, the user got no
        answer'. The marker now belongs to the ladder owner, and only when its
        recovery gave nothing."""
        self.sub(outcome="skipped", kind=mc.QUOTA, reason="quota")
        self.ex.model_chain.call_deepseek = lambda *a, **k: mc.TierAttempt(
            mc.TIER_FALLBACK, "error", model=mc.FALLBACK_MODEL, kind=mc.BAD_ANSWER,
            reason="answer truncated (finish_reason: length)", text='{"claims": [',
            cost_usd=0.0004, meta={"finish_reason": "length", "model_reported": mc.FALLBACK_MODEL})
        ledger = Path(self.ex.model_chain.UsageLedger().path)
        before = len([x for x in ledger.read_text().splitlines() if x.strip()]) if ledger.exists() else 0
        self.post()
        rows = [json.loads(x) for x in ledger.read_text().splitlines() if x.strip()][before:]
        self.assertTrue(rows, "the paid attempt is recorded")
        self.assertEqual([r for r in rows if r.get("outcome") == mc.CHAIN_EXHAUSTED], [],
                         "a recoverable truncation is not a dead user path")

    def test_the_retry_actually_changes_the_request(self):
        """QA 2026-11-03: _extract adds frequency_penalty to the retry body, but
        chain_post forwarded only messages/max_tokens/temperature, so a short
        document that looped to the cap was retried byte-identically. The penalty
        now reaches the provider."""
        self.sub(outcome="skipped", kind=mc.QUOTA, reason="quota")
        seen = []

        def deepseek(messages, **k):
            seen.append(k.get("frequency_penalty"))
            if len(seen) == 1:      # first paid answer loops to the cap
                return mc.TierAttempt(mc.TIER_FALLBACK, "error", model=mc.FALLBACK_MODEL,
                                      kind=mc.BAD_ANSWER, reason="answer truncated (finish_reason: length)",
                                      text='{"claims": [', cost_usd=0.0004,
                                      meta={"finish_reason": "length", "model_reported": mc.FALLBACK_MODEL})
            return mc.TierAttempt(mc.TIER_FALLBACK, "ok", model=mc.FALLBACK_MODEL, text='{"claims": []}',
                                  cost_usd=0.001, latency_ms=1,
                                  meta={"finish_reason": "stop", "model_reported": mc.FALLBACK_MODEL})

        self.ex.model_chain.call_deepseek = deepseek
        out = self.ex.Extractor(store=self._Store(), key="k", post=self.ex.chain_post).extract(
            "a short document", {}, "p-retry")
        self.assertTrue(out.ok, out.error)
        self.assertEqual(seen[0], None)
        self.assertEqual(seen[1], self.ex.RETRY_FREQUENCY_PENALTY,
                         "the retry must reach the provider with the anti-repetition penalty")

    def test_a_truncated_paid_answer_keeps_the_callers_recovery_path(self):
        """QA 2026-11-03: a paid `finish_reason=length` became bad_answer, chain_post
        raised ChainTransport, and _extract returned fallback immediately - so a long
        document lost the chunk/retry recovery the old transport had. The truncation
        is now passed on as `finish_reason: length` (never accepted, never cached)."""
        self.ex.model_chain.call_deepseek = lambda *a, **k: mc.TierAttempt(
            mc.TIER_FALLBACK, "error", model=mc.FALLBACK_MODEL, kind=mc.BAD_ANSWER,
            reason="answer truncated (finish_reason: length)", text='{"claims": [',
            cost_usd=0.0004, meta={"finish_reason": "length", "model_reported": mc.FALLBACK_MODEL})
        data = self.post()
        self.assertEqual(data["choices"][0]["finish_reason"], "length")
        self.assertNotIn("model", [k for k, v in data.items() if v is None])

    def test_an_unreported_model_is_not_invented_for_the_cache(self):
        """QA 2026-11-03: chain_post reported `r.model`, which falls back to the
        REQUESTED id when the provider omits `model`, so an unknown-origin answer
        passed the `reported_model == self.model` cache guard and was replayed for
        24 h as if the configured model had produced it (undoing QA #1469)."""
        self.ds(reported=None)
        data = self.post()
        self.assertIsNone(data["model"], "no provider report, no model field")
        self.ds(reported=mc.FALLBACK_MODEL)
        self.assertEqual(self.post()["model"], mc.FALLBACK_MODEL)

    def test_an_empty_no_schema_answer_falls_through(self):
        """QA 2026-11-03: `{"text": ""}` unwrapped to an empty string and was marked
        ok, so the chain stopped on tier 1 and the caller got an unusable answer
        instead of the documented fallback. Exercised through the REAL
        call_subscription, because the empty check lives where the text is
        unwrapped."""
        from lib import model_chain as chainmod
        fake = FakeCodex([(0, json.dumps({"text": ""}), "")])
        att = chainmod.call_subscription("hi", schema=None, web=False, images=(),
                                        runner=fake, helper=Path(__file__))
        self.assertEqual(att.kind, mc.BAD_ANSWER)
        self.assertEqual(att.reason, "empty completion")
        # and the chain moves on to the metered tier instead of serving it
        chain = mc.ModelChain("test-surface", ledger=mc.UsageLedger(self.ledger_path),
                              sleep=lambda s: None, log=self.lines.append,
                              codex_helper=Path(__file__),
                              opener=FakeOpenRouter([openrouter_ok("hello")]),
                              subscription_runner=FakeCodex([(0, json.dumps({"text": "  "}), "")]))
        res = chain.call("hi", schema=None, max_tokens=100)
        self.assertTrue(res.ok)
        self.assertEqual(res.tier, mc.TIER_FALLBACK)
        self.assertEqual(res.text, "hello")

    def test_the_paid_tier_runs_the_model_the_caller_pinned(self):
        """QA 2026-11-03: `_paid_chain(key)` ignored body["model"], so a pinned
        CREDIT_DOC_VERIFY_MODEL still ran DeepSeek while the cache and the audit
        trail were keyed by the pin."""
        built = []
        real = self.ex.model_chain.ModelChain

        def spy(*a, **k):
            built.append(k.get("fallback_model"))
            return real(*a, **k)

        self.ex.model_chain.ModelChain = spy
        self.addCleanup(lambda: setattr(self.ex.model_chain, "ModelChain", real))
        self.ds()
        self.ex.chain_post({"model": "x-ai/grok-4.3",
                            "messages": [{"role": "user", "content": "read this"}],
                            "max_tokens": 100}, "key", 30)
        self.assertIn("x-ai/grok-4.3", built)

    def test_an_unusable_free_answer_does_not_count_as_a_served_subscription_call(self):
        """QA 2026-11-03: the free tier's success row was written before validate()
        ran, so 25 unusable-free/paid requests against 75 good ones reported 20%
        (25/125) instead of 25% (25/100) - and the strict >20% alarm stayed silent."""
        self.sub(text="not json at all")          # serves, but is unusable
        lock = Path(self.ex.model_chain.UsageLedger().path)
        before = lock.read_text() if lock.exists() else ""
        r = self.ex._free_chain().call("read this", timeout_s=5, sensitive=True, step="free",
                                       defer_served_row=True)
        self.assertTrue(r.ok)
        after = lock.read_text() if lock.exists() else ""
        self.assertEqual(before, after, "an unvalidated answer writes no served row")
        # and once the caller validates it, the row lands
        self.ex.model_chain.record_served("doc-verify", tier=mc.TIER_SUBSCRIPTION, step="free")
        rows = [json.loads(x) for x in lock.read_text().splitlines() if x.strip()]
        self.assertEqual((rows[-1]["tier"], rows[-1]["outcome"]), (mc.TIER_SUBSCRIPTION, "ok"))

    def test_a_dead_chain_raises_so_the_caller_fails_closed(self):
        self.sub(outcome="error", kind=mc.SERVER_ERROR, reason="502")
        self.ds(outcome="error")
        with self.assertRaises(self.ex.ChainTransport):
            self.post()

class TestLedgerFailClosed(ChainBase):
    """QA 2026-11-03: the daily cap is a promise, so "I could not read the ledger"
    must not be read as "we spent $0". Only the METERED tier is refused; the ($0)
    subscription keeps working, so an accounting failure can never take the user
    path down."""

    class Unwritable(mc.UsageLedger):
        """Reads work, writes fail - a read-only mount, a full disk, a bad owner.
        Permission bits cannot reproduce this on a root runner (QA 2026-11-03)."""

        def _append(self, line):
            raise PermissionError(13, "Permission denied (simulated read-only ledger)")

    def unreadable(self):
        """A ledger path whose directory cannot be opened (permission denied, which
        is what a broken mount or a wrong owner looks like to us)."""
        d = Path(self.tmp.name) / "locked"
        d.mkdir()
        d.chmod(0o000)
        self.addCleanup(d.chmod, 0o700)
        return d / "calls.jsonl"

    @unittest.skipIf(os.geteuid() == 0, "root ignores permission bits; the seam test above covers this")
    def test_unreadable_ledger_refuses_the_metered_tier(self):
        codex = FakeCodex([(3, "", "codex-judge-exec: refusing to call (reason=quota quota exhausted)")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        chain = mc.ModelChain("test-surface", ledger=mc.UsageLedger(self.unreadable()),
                              sleep=lambda s: None, log=self.lines.append,
                              codex_helper=Path(__file__), subscription_runner=codex, opener=orouter)
        res = chain.call("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [])                    # no spend past an unknown cap
        last = res.attempts[-1]
        self.assertEqual((last["tier"], last["outcome"]), (mc.TIER_FALLBACK, "skipped"))
        self.assertIn("accounting unavailable", last["reason"])

    def test_a_failed_write_marks_the_ledger_broken_and_stops_further_spend(self):
        ledger = self.Unwritable(self.ledger_path)
        ledger.record({"tier": "deepseek", "cost_usd": 1.0})
        self.assertIn("PermissionError", ledger.broken or "")
        with self.assertRaises(mc.AccountingUnavailable):
            ledger.spent_today_usd()

    def test_readable_but_unwritable_ledger_refuses_before_spending(self):
        """The cross-process case QA raised twice: the history reads fine, so the
        old cap check passed, and the spend that could not be recorded happened."""
        self.ledger_path.write_text("")                      # readable, empty
        ledger = self.Unwritable(self.ledger_path)
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = mc.ModelChain("test-surface", ledger=ledger, log=self.lines.append,
                            codex_helper=Path(__file__),
                            subscription_runner=FakeCodex([(0, "", "")]),
                            opener=orouter).call("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [], "an unrecordable spend must not happen")
        self.assertIn("accounting unavailable", res.attempts[-1]["reason"])

    def test_an_unpriceable_success_keeps_its_reservation_instead_of_reading_as_free(self):
        """A provider that omits `usage.cost` must not look free: the reservation
        stays counted, so the cap errs expensive rather than optimistic."""
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}', cost=None)])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter).call(
            "judge this", schema=SCHEMA)
        self.assertTrue(res.ok)
        self.assertEqual(res.cost_usd, mc.RESERVATION_USD)
        estimated = [r for r in self.rows() if (r.get("meta") or {}).get("cost_estimated")]
        self.assertEqual(len(estimated), 1, self.rows())
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(),
                               mc.RESERVATION_USD, places=9)

    def test_an_unpriced_billable_failure_still_costs_the_reservation(self):
        """QA 2026-11-03: a truncated/unusable completion consumed tokens, so a
        response with no `usage.cost` must not read as free just because the answer
        was unusable - otherwise repeated length-cuts keep the day at $0 forever."""
        # A served, billed, UNUSABLE completion: finish_reason=length and no
        # `usage.cost`, exactly what a cut-off DeepSeek answer looks like.
        truncated = {"model": "deepseek/deepseek-v4.1-flash-1017",
                     "usage": {"prompt_tokens": 900, "completion_tokens": 4000},
                     "choices": [{"finish_reason": "length", "message": {"content": '{"verdict": "o'}}]}
        orouter = FakeOpenRouter([truncated] * 4)
        for _ in range(4):
            res = self.chain(opener=orouter).call_fallback("judge this", schema=SCHEMA)
            self.assertFalse(res.ok)
            self.assertIn("bad_answer", res.error or "")
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(),
                               mc.RESERVATION_USD * 4, places=9)

    def test_a_transport_failure_costs_nothing(self):
        """The mirror case: a 429 (or a reset) consumed no tokens, so it must not
        drain the cap - otherwise an outage alone would lock the tier out."""
        orouter = FakeOpenRouter([(429, "rate limited")] * 4)
        res = self.chain(opener=orouter).call_fallback("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), 0.0, places=9)

    def test_the_reservation_is_the_requests_ceiling_not_a_flat_guess(self):
        """QA 2026-11-03: reserving a flat $0.05 let a call admitted at $9.95 settle
        at $10.05, so the hard daily cap was only a hint. The reservation is now the
        request's own upper bound (chars >= tokens, max_tokens for the answer, a fee
        per web result), so an admitted call cannot settle past the cap."""
        big = "x" * 400_000
        est = mc.estimate_upper_usd(mc.FALLBACK_MODEL, big, max_tokens=4000)
        small = mc.estimate_upper_usd(mc.FALLBACK_MODEL, "hi", max_tokens=4000)
        self.assertGreater(est, mc.RESERVATION_USD, "a large request reserves more than the floor")
        self.assertLess(small, mc.RESERVATION_USD + 1e-12, "a small one never reserves less than the floor")

        ledger = mc.UsageLedger(self.ledger_path)
        ledger.record({"surface": "s", "step": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok",
                       "cost_usd": 9.95})
        chain = self.chain(opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')]),
                           subscription_runner=FakeCodex([(3, "", "reason=quota")]),
                           daily_usd_cap=10.0)
        res = chain.call(big, schema=SCHEMA, max_tokens=4000)
        self.assertFalse(res.ok)
        self.assertIn("daily cap $10.00 reached", res.error or "")
        # the same chain still admits a small request under that cap
        res2 = chain.call("hi", schema=SCHEMA, max_tokens=4000)
        self.assertTrue(res2.ok)
        self.assertLessEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), 10.0)

    def test_unlimited_mode_does_not_go_negative(self):
        """QA 2026-11-03: with MODEL_CHAIN_DAILY_USD=0 the reserve row was skipped
        but _record() still settled -reserve, so a $0.01 call left the day at
        -$0.04 - and a later re-enabled cap read that as free headroom."""
        chain = self.chain(opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')]),
                           subscription_runner=FakeCodex([(3, "", "reason=quota")]),
                           daily_usd_cap=0)
        res = chain.call("hi", schema=SCHEMA, max_tokens=4000)
        self.assertTrue(res.ok)
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), res.cost_usd, places=9)
        self.assertGreater(mc.UsageLedger(self.ledger_path).spent_today_usd(), 0)

    def test_the_reservation_is_held_until_the_charge_is_recorded(self):
        """QA 2026-11-03: _attempt() released the reservation BEFORE the caller
        recorded the charge. At $9.95 spent, call A reserved $0.05 (total $10),
        settled -$0.05 while its $0.05 charge was not yet written, and call B's
        admit() then saw $9.95 and reserved another $0.05 - both settle at $10.05.
        The release now happens in _record(), after the charge row is durable."""
        ledger = mc.UsageLedger(self.ledger_path)
        ledger.record({"surface": "s", "step": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok",
                       "cost_usd": 9.95})
        chain = self.chain(opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')]),
                           subscription_runner=FakeCodex([(3, "", "reason=quota")]),
                           daily_usd_cap=10.0)
        seen = {}
        real_record = chain._record

        def record_between_charge_and_release(att, *a, **k):
            # exactly the window QA found: the attempt has been charged, the
            # caller's row is about to be written, and the reservation is still up
            seen["spent_before_record"] = mc.UsageLedger(self.ledger_path).spent_today_usd()
            return real_record(att, *a, **k)

        chain._record = record_between_charge_and_release
        res = chain.call("hi", schema=SCHEMA, max_tokens=4000)
        self.assertTrue(res.ok)
        self.assertAlmostEqual(seen["spent_before_record"], 10.0, places=6,
                               msg="the reservation must still be held before the charge lands")
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), 9.95 + res.cost_usd,
                               places=6)

    def test_a_pinned_model_is_priced_its_own_way_not_at_deepseek_rates(self):
        """QA 2026-11-03: `estimate_upper_usd` fell back to deepseek's price for any
        model it did not know, so `CREDIT_REVIEW_MODEL=x-ai/grok-4.3` (4x the tokens'
        price) reserved $0.05 and could settle past the cap."""
        grok = mc.estimate_upper_usd("x-ai/grok-4.3", "x" * 2000, max_tokens=4000)
        deep = mc.estimate_upper_usd(mc.FALLBACK_MODEL, "x" * 2000, max_tokens=4000)
        self.assertGreater(grok / deep, 3.0, "grok's tokens cost several times deepseek's")
        # at $9.95 spent, grok's own ceiling is refused only when it cannot fit; a
        # request whose real cost is above the $0.05 floor is admitted only if the
        # reservation covers it, so the day can never pass $10.
        ledger = mc.UsageLedger(self.ledger_path)
        ledger.record({"surface": "s", "step": "s", "tier": mc.TIER_FALLBACK, "outcome": "ok",
                       "cost_usd": 9.95})
        chain = self.chain(opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')]),
                           subscription_runner=FakeCodex([(3, "", "reason=quota")]),
                           fallback_model="x-ai/grok-4.3", daily_usd_cap=10.0)
        big = "x" * 40_000                       # 40000 chars * 2.5e-6 = $0.10
        self.assertGreater(mc.estimate_upper_usd("x-ai/grok-4.3", big, max_tokens=4000), 0.05)
        self.assertFalse(chain.call(big, schema=SCHEMA, max_tokens=4000).ok)
        self.assertLessEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), 10.0)

    def test_an_unpriced_model_is_refused_instead_of_priced_at_a_guess(self):
        chain = self.chain(opener=FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')]),
                           subscription_runner=FakeCodex([(3, "", "reason=quota")]),
                           fallback_model="someone/frontier-9")
        res = chain.call("hi", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertIn("unpriced model someone/frontier-9", res.error or "")
        self.assertIsNone(mc.estimate_upper_usd("someone/frontier-9", "hi", max_tokens=10))

    def test_uncharged_attempts_do_not_consume_the_cap(self):
        """QA 2026-11-03: skipped/terminal rows carry no cost, so counting them as a
        reservation billed $0.10 of phantom spend per request - and after 100 of
        them the tier stayed locked out for the UTC day even once the key returned."""
        orouter = FakeOpenRouter([(429, "rate limited"), (429, "rate limited")])
        saved = mc.load_key
        mc.load_key = lambda *a, **k: None
        self.addCleanup(lambda: setattr(mc, "load_key", saved))
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter).call_fallback(
            "judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), 0.0, places=9,
                               msg="nothing was charged, so nothing may be counted")

    def test_a_no_key_skip_plus_exhaustion_costs_nothing(self):
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        saved = mc.load_key
        mc.load_key = lambda *a, **k: None
        self.addCleanup(lambda: setattr(mc, "load_key", saved))
        res = self.chain(subscription_runner=FakeCodex([(3, "", "reason=quota")]), opener=orouter).call(
            "judge this", schema=SCHEMA)        # tier 1 quota, and no OpenRouter key at all
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [])
        self.assertAlmostEqual(mc.UsageLedger(self.ledger_path).spent_today_usd(), 0.0, places=9)

    def test_a_malformed_ledger_line_fails_closed_instead_of_shrinking_the_total(self):
        self.ledger_path.write_text('{"cost_usd": 3.0, "epoch": 9999999999}\n{"cost_usd": 4.\n')
        with self.assertRaises(mc.AccountingUnavailable):
            mc.UsageLedger(self.ledger_path).spent_today_usd()
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter,
                         daily_usd_cap=100.0).call("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [])

    def test_a_missing_ledger_is_a_real_zero_not_an_error(self):
        ledger = mc.UsageLedger(Path(self.tmp.name) / "calls.jsonl")
        self.assertEqual(ledger.spent_today_usd(), 0.0)
        self.assertIsNone(ledger.broken)

    def test_call_fallback_meters_and_records_without_touching_the_subscription(self):
        """credit_trust runs its own tier-1 ladder (codex -> jev) and then calls
        this, so it must NOT re-ask the subscription - but it must still be under
        the shared cap and visible in the ledger (QA 2026-11-03)."""
        codex = FakeCodex([(0, codex_events('{"verdict": "subscription"}'), "")])
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "deepseek"}')])
        res = self.chain(subscription_runner=codex, opener=orouter).call_fallback(
            messages=[{"role": "user", "content": "judge this"}], schema=SCHEMA, step="trust")
        self.assertTrue(res.ok)
        self.assertEqual(res.tier, mc.TIER_FALLBACK)
        self.assertEqual(codex.calls, [])                          # tier 1 untouched
        rows = self.rows()
        # reserve -> call -> settle: the reservation is written BEFORE the spend so
        # a process that cannot write the ledger cannot spend invisibly (QA 11-03),
        # and the settle row carries the difference, so the day's sum is exact.
        # reserve -> call -> SETTLE: the release is written only after the charge
        # row is durable, so the running total never dips below real spend
        # (QA 2026-11-03).
        self.assertEqual([r["outcome"] for r in rows], ["reserve", "ok", "settle"])
        self.assertTrue(all(r["step"] == "trust" for r in rows))
        self.assertEqual(rows[0]["cost_usd"], mc.RESERVATION_USD)
        actual = [r["cost_usd"] for r in rows if r["outcome"] == "ok"][0]
        self.assertAlmostEqual(sum(r["cost_usd"] or 0 for r in rows), actual, places=9)

    def test_call_fallback_obeys_the_daily_cap(self):
        self.ledger_path.write_text(json.dumps({"ts": mc.utcnow(), "epoch": 9999999999,
                                                "tier": "deepseek", "cost_usd": 10.0}) + "\n")
        orouter = FakeOpenRouter([openrouter_ok('{"verdict": "ok"}')])
        res = self.chain(subscription_runner=FakeCodex([(0, "", "")]), opener=orouter,
                         daily_usd_cap=10.0).call_fallback("judge this", schema=SCHEMA)
        self.assertFalse(res.ok)
        self.assertEqual(orouter.requests, [])
        self.assertIn("daily cap", res.attempts[-1]["reason"])


if __name__ == "__main__":
    unittest.main(verbosity=2)


