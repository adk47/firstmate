#!/usr/bin/env python3
"""The ZDR + precision floor on every production DeepSeek/GLM route.

Captain 2026-11-04: "we need [ZDR] ... only use the fastest cheapest ZDR
deepseek models ... make sure we aren't wasting money and protect our code".
Ruling: every production DeepSeek/GLM caller uses the ONE OpenRouter ZDR routing
block, and Fireworks is retired from production paths.

Two layers, both pinned here:

  * runtime — ``model_chain.validate_routing`` refuses a block that is not ZDR
    or that allows int4/int8, and ``call_deepseek`` sends the validated block on
    every metered call;
  * config — ``scripts/check-zdr-routing.py`` asserts the same for every
    OpenClaw config, and that no ``fireworks/`` ref survives.

Hermetic: no network, no key, no ledger. The OpenRouter opener is faked.
"""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from lib import model_chain as mc  # noqa: E402

GUARD = ROOT / "scripts" / "check-zdr-routing.py"
CONFIGS = ("openclaw-main.json", "openclaw-edge.json", "cron-jobs.json",
           "pods/qa-review-gateway/openclaw-qa.json")


def run_guard(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(GUARD), *args],
                          capture_output=True, text=True, cwd=str(ROOT), check=False)


class TestValidateRouting(unittest.TestCase):
    """The runtime guard: a weaker block is refused, never defaulted."""

    def test_the_one_block_passes(self):
        self.assertIs(mc.validate_routing(mc.ZDR_ROUTING), mc.ZDR_ROUTING)
        self.assertIs(mc.ZDR_ROUTING["zdr"], True)
        self.assertEqual(mc.ZDR_ROUTING["data_collection"], "deny")
        self.assertEqual(mc.ZDR_ROUTING["sort"], "price")
        self.assertEqual(mc.ZDR_ROUTING["quantizations"], ["fp8", "bf16", "fp16"])
        self.assertEqual(mc.ZDR_ROUTING["max_price"], {"prompt": 0.30, "completion": 1.20})

    def _mutant(self, **changes):
        block = copy.deepcopy(mc.ZDR_ROUTING)
        for key, value in changes.items():
            if value is _DELETE:
                block.pop(key, None)
            else:
                block[key] = value
        return block

    def test_a_missing_zdr_flag_is_refused(self):
        # "no zdr flag" is an UNVERIFIED route, not a permissive one.
        with self.assertRaises(mc.UnsafeRouting):
            mc.validate_routing(self._mutant(zdr=_DELETE))
        with self.assertRaises(mc.UnsafeRouting):
            mc.validate_routing(self._mutant(zdr=False))

    def test_data_collection_must_be_deny(self):
        with self.assertRaises(mc.UnsafeRouting):
            mc.validate_routing(self._mutant(data_collection="allow"))
        with self.assertRaises(mc.UnsafeRouting):
            mc.validate_routing(self._mutant(data_collection=_DELETE))

    def test_int4_and_int8_are_refused(self):
        for quant in ("int4", "int8", "fp4", "mxfp4", "nf4", "awq", "gptq", "unknown"):
            with self.subTest(quant=quant):
                with self.assertRaises(mc.UnsafeRouting):
                    mc.validate_routing(self._mutant(quantizations=["fp8", quant]))

    def test_an_unpinned_quantization_list_is_refused(self):
        # An empty/absent list lets OpenRouter pick any host, including int4.
        for value in (_DELETE, [], None, "fp8"):
            with self.subTest(value=value):
                with self.assertRaises(mc.UnsafeRouting):
                    mc.validate_routing(self._mutant(quantizations=value))

    def test_max_price_must_be_capped(self):
        for value in (_DELETE, {}, {"prompt": 0.3}, {"prompt": 0, "completion": 1.2}):
            with self.subTest(value=value):
                with self.assertRaises(mc.UnsafeRouting):
                    mc.validate_routing(self._mutant(max_price=value))

    def test_an_over_cap_max_price_is_refused(self):
        # QA 2026-11-04: a "positive" check accepted {prompt: 1000,
        # completion: 1000}, which selects the same hosts as no cap at all while
        # every guard reported clean.
        for value in ({"prompt": 1000, "completion": 1000},
                      {"prompt": 0.31, "completion": 1.20},
                      {"prompt": 0.30, "completion": 1.21},
                      {"prompt": -1, "completion": 1.20}):
            with self.subTest(value=value):
                with self.assertRaises(mc.UnsafeRouting):
                    mc.validate_routing(self._mutant(max_price=value))

    def test_the_ceiling_is_at_the_stated_numbers(self):
        # Exactly at the cap passes; one cent over does not. The cap is a spend
        # decision, so this boundary is the point of the rule.
        mc.validate_routing(self._mutant(max_price={"prompt": mc.MAX_PROMPT_PRICE,
                                                   "completion": mc.MAX_COMPLETION_PRICE}))
        with self.assertRaises(mc.UnsafeRouting):
            mc.validate_routing(self._mutant(max_price={"prompt": mc.MAX_PROMPT_PRICE + 0.0001,
                                                       "completion": mc.MAX_COMPLETION_PRICE}))

    def test_price_sort_is_required(self):
        with self.assertRaises(mc.UnsafeRouting):
            mc.validate_routing(self._mutant(sort="throughput"))

    def test_a_non_object_is_refused(self):
        for value in (None, [], "zdr", 1):
            with self.subTest(value=value):
                with self.assertRaises(mc.UnsafeRouting):
                    mc.validate_routing(value)


class TestMeteredCallCarriesTheBlock(unittest.TestCase):
    """The block rides on the request, not on a caller's good intentions."""

    def test_call_deepseek_sends_the_validated_block(self):
        sent = {}

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return json.dumps({"model": "deepseek/deepseek-v4.1-flash-1017",
                                   "choices": [{"message": {"content": "ok"},
                                                "finish_reason": "stop"}],
                                   "usage": {"cost": 0.0001}}).encode()

        def opener(req, timeout=None):
            sent["body"] = json.loads(req.data.decode())
            return Resp()

        att = mc.call_deepseek([{"role": "user", "content": "hi"}], key="k", opener=opener)
        self.assertEqual(att.outcome, "ok")
        self.assertEqual(sent["body"]["provider"], mc.ZDR_ROUTING)

    def test_sensitive_false_cannot_opt_out_of_zdr(self):
        # The parameter is kept for API compatibility only; ZDR is not optional.
        sent = {}

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return json.dumps({"model": "m", "choices": [{"message": {"content": "ok"},
                                                              "finish_reason": "stop"}],
                                   "usage": {}}).encode()

        def opener(req, timeout=None):
            sent["body"] = json.loads(req.data.decode())
            return Resp()

        mc.call_deepseek([{"role": "user", "content": "hi"}], key="k", opener=opener,
                         sensitive=False)
        self.assertEqual(sent["body"]["provider"], mc.ZDR_ROUTING)


class TestEveryCallerConfig(unittest.TestCase):
    """The config layer: every shipped config passes, and a weakened one fails."""

    def test_every_shipped_config_is_clean(self):
        res = run_guard()
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("clean", res.stdout)

    def test_each_config_is_checked_on_its_own(self):
        for rel in CONFIGS:
            with self.subTest(config=rel):
                res = run_guard(rel)
                self.assertEqual(res.returncode, 0, res.stderr)

    def test_a_config_that_allows_int4_fails(self):
        cfg = json.loads((ROOT / "openclaw-main.json").read_text(encoding="utf-8"))
        for provider in cfg["models"]["providers"].values():
            for model in provider.get("models") or []:
                if str(model.get("id", "")).startswith("deepseek/"):
                    model["compat"]["openRouterRouting"]["quantizations"] = ["fp8", "int4"]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(cfg, fh)
            path = fh.name
        try:
            res = run_guard(path)
        finally:
            Path(path).unlink()
        self.assertEqual(res.returncode, 1)
        self.assertIn("lossy quantization", res.stderr)

    def test_a_config_without_the_zdr_flag_fails(self):
        cfg = json.loads((ROOT / "openclaw-main.json").read_text(encoding="utf-8"))
        for provider in cfg["models"]["providers"].values():
            for model in provider.get("models") or []:
                if str(model.get("id", "")).startswith("deepseek/"):
                    model["compat"]["openRouterRouting"].pop("zdr", None)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(cfg, fh)
            path = fh.name
        try:
            res = run_guard(path)
        finally:
            Path(path).unlink()
        self.assertEqual(res.returncode, 1)
        self.assertIn("no zdr", res.stderr)

    def test_a_second_provider_cannot_mask_a_missing_openrouter_block(self):
        # QA 2026-11-04 reproduced this on the previous head: with a flat
        # `model id -> routing` map, an OpenRouter DeepSeek entry that LOST its
        # routing was silently overwritten by any other provider declaring the
        # same id with a valid block, and the guard exited 0 reporting clean
        # while the live openrouter/deepseek/... route had no ZDR filter.
        cfg = json.loads((ROOT / "openclaw-main.json").read_text(encoding="utf-8"))
        good = None
        for provider in cfg["models"]["providers"].values():
            for model in provider.get("models") or []:
                if str(model.get("id", "")).startswith("deepseek/"):
                    good = model["compat"]["openRouterRouting"]
                    model.pop("compat", None)
        self.assertIsNotNone(good, "the fixture must declare the deepseek routing")
        cfg["models"]["providers"]["decoy"] = {
            "baseUrl": "https://decoy.invalid/v1",
            "models": [{"id": "deepseek/deepseek-v4.1-flash-1017",
                        "compat": {"openRouterRouting": good}}],
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(cfg, fh)
            path = fh.name
        try:
            res = run_guard(path)
        finally:
            Path(path).unlink()
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertIn("has no compat.openRouterRouting", res.stderr)

    def test_a_model_id_declared_twice_in_one_provider_fails(self):
        # The guard cannot say which entry the runtime resolves, so neither
        # answer is trustworthy.
        cfg = json.loads((ROOT / "openclaw-main.json").read_text(encoding="utf-8"))
        for provider in cfg["models"]["providers"].values():
            ids = [str(m.get("id", "")) for m in (provider.get("models") or [])]
            dupe = next((i for i in ids if i.startswith("deepseek/")), None)
            if dupe:
                provider["models"].append({"id": dupe, "compat": {"openRouterRouting":
                                                                 dict(mc.ZDR_ROUTING)}})
                break
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(cfg, fh)
            path = fh.name
        try:
            res = run_guard(path)
        finally:
            Path(path).unlink()
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertIn("declared twice", res.stderr)

    def test_a_fireworks_ref_fails(self):
        cfg = json.loads((ROOT / "openclaw-main.json").read_text(encoding="utf-8"))
        cfg["agents"]["defaults"]["model"]["fallbacks"] = ["fireworks/deepseek-v3p2"]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(cfg, fh)
            path = fh.name
        try:
            res = run_guard(path)
        finally:
            Path(path).unlink()
        self.assertEqual(res.returncode, 1)
        self.assertIn("retired provider", res.stderr)

    def test_no_fireworks_anywhere_in_production_configs(self):
        for rel in CONFIGS:
            with self.subTest(config=rel):
                text = (ROOT / rel).read_text(encoding="utf-8")
                self.assertNotIn("fireworks/", text)
                self.assertNotIn("api.fireworks.ai", text)

    def test_a_missing_explicit_config_fails(self):
        # QA 2026-11-04: a renamed production profile used to be SKIPPED, so the
        # guard went green having checked nothing.
        res = run_guard("openclaw-main.json", "openclaw-not-a-real-profile.json")
        self.assertEqual(res.returncode, 1)
        self.assertIn("required config is missing", res.stderr)

    def test_the_required_profile_set_is_pinned(self):
        # A glob-only default would shrink silently when a profile was renamed.
        sys.path.insert(0, str(ROOT / "scripts"))
        import importlib.util
        spec = importlib.util.spec_from_file_location("zdr_guard", GUARD)
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        defaults = guard.default_configs()
        for rel in ("openclaw-main.json", "openclaw-edge.json", "cron-jobs.json",
                    "pods/qa-review-gateway/openclaw-qa.json"):
            self.assertIn(rel, defaults)
        res = run_guard()
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_every_python_caller_probes_its_outgoing_block(self):
        # Behavioral, not a grep: QA 2026-11-04 showed that deleting the
        # provider assignment while keeping a comment that mentions ZDR_ROUTING
        # satisfied a source-token check, and the judge's legacy direct
        # transport would then have sent credit data with no filter at all.
        sys.path.insert(0, str(ROOT / "scripts"))
        import importlib.util
        spec = importlib.util.spec_from_file_location("zdr_guard2", GUARD)
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        for rel, probe in guard.PY_CALLERS:
            with self.subTest(caller=rel):
                self.assertEqual(probe(), mc.ZDR_ROUTING)

    def test_unprobeable_or_absent_caller_fails(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import importlib.util
        spec = importlib.util.spec_from_file_location("zdr_guard3", GUARD)
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        saved = guard.PY_CALLERS
        try:
            guard.PY_CALLERS = (("scripts/lib/model_chain.py", lambda: None),)
            self.assertTrue(any("unsafe provider block" in p
                                for p in guard.check_python_callers()))
            guard.PY_CALLERS = (("scripts/does-not-exist.py", lambda: mc.ZDR_ROUTING),)
            self.assertTrue(any("missing" in p for p in guard.check_python_callers()))
            def boom():
                raise RuntimeError("no")
            guard.PY_CALLERS = (("scripts/lib/model_chain.py", boom),)
            self.assertTrue(any("could not probe" in p
                                for p in guard.check_python_callers()))
        finally:
            guard.PY_CALLERS = saved


class _Delete:
    pass


_DELETE = _Delete()

if __name__ == "__main__":
    unittest.main(verbosity=2)
