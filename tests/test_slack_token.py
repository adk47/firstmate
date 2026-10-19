"""Slack botToken SecretRef contract for the scripts that read openclaw config.

openclaw-main.json holds `channels.slack.accounts.*.botToken` as a
`{source: env, provider: hydra-env, id: MUSO_SLACK_BOT_TOKEN_*}` ref, not a
string. The gateway resolves it; these scripts read the raw file, so every one
must go through lib.slack_token.resolve_secret or it ends up sending
`Bearer {'source': ...}` to Slack (or silently skipping, in best-effort readers).
"""

import importlib.util
import json
import pathlib
import re
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
import sys  # noqa: E402

sys.path.insert(0, str(SCRIPTS))

from lib.slack_token import resolve_secret  # noqa: E402

REF = {"source": "env", "provider": "hydra-env", "id": "MUSO_SLACK_BOT_TOKEN_DEVOPS"}


def env_file(text):
    d = tempfile.mkdtemp()
    p = pathlib.Path(d) / "main.env"
    p.write_text(text)
    return str(p)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ResolveSecret(unittest.TestCase):
    def test_plain_string_passes_through(self):
        self.assertEqual(resolve_secret("xoxb-legacy"), "xoxb-legacy")

    def test_env_ref_reads_process_env_first(self):
        got = resolve_secret(REF, env={"MUSO_SLACK_BOT_TOKEN_DEVOPS": "from-env"},
                             env_file=env_file("MUSO_SLACK_BOT_TOKEN_DEVOPS=from-file\n"))
        self.assertEqual(got, "from-env")

    def test_env_ref_falls_back_to_the_gateway_env_file(self):
        # cron/systemd units that do not source main.env must still work
        got = resolve_secret(REF, env={}, env_file=env_file(
            "OTHER=1\nexport MUSO_SLACK_BOT_TOKEN_DEVOPS='from-file'\n"))
        self.assertEqual(got, "from-file")

    def test_unresolvable_ref_is_empty_never_a_dict(self):
        # an unresolved dict is truthy and would be sent as a Bearer token
        got = resolve_secret(REF, env={}, env_file="/nonexistent/main.env")
        self.assertEqual(got, "")
        self.assertIsInstance(got, str)

    def test_non_env_source_and_junk_are_empty(self):
        for v in ({"source": "file", "id": "x"}, None, 5, []):
            self.assertEqual(resolve_secret(v, env={}, env_file="/nonexistent"), "")


class HeadConfig(unittest.TestCase):
    def test_every_account_resolves_to_a_string(self):
        cfg = json.loads((ROOT / "openclaw-main.json").read_text())
        accts = cfg["channels"]["slack"]["accounts"]
        env = {a["botToken"]["id"]: "tok-" + n for n, a in accts.items()
               if isinstance(a["botToken"], dict)}
        self.assertTrue(env, "head config should carry SecretRef botTokens")
        for name, acct in accts.items():
            tok = resolve_secret(acct["botToken"], env=env, env_file="/nonexistent")
            self.assertEqual(tok, "tok-" + name)


class EveryReaderUsesTheResolver(unittest.TestCase):
    def test_no_script_reads_botToken_raw(self):
        # a reader that touches ["botToken"]/get("botToken") must mention the resolver
        offenders = []
        # whole repo, not just scripts/: skills under workspaces/ read the same file
        for p in sorted(ROOT.rglob("*")):
            if not p.is_file() or p.suffix not in (".py", ".sh"):
                continue
            parts = set(p.relative_to(ROOT).parts)
            if parts & {".git", "node_modules", "tests"} or p.name == "slack_token.py":
                continue
            text = p.read_text(errors="ignore")
            reads = re.search(r"""\[\s*["']botToken["']\s*\]|get\(\s*["']botToken["']""", text)
            if reads and "resolve_secret" not in text:
                offenders.append(str(p.relative_to(ROOT)))
        self.assertEqual(offenders, [])


class RealReaders(unittest.TestCase):
    def _config(self):
        d = tempfile.mkdtemp()
        p = pathlib.Path(d) / "openclaw.json"
        p.write_text(json.dumps({"channels": {"slack": {"accounts": {"devops": {"botToken": REF}}}}}))
        return str(p)

    def test_cs_needs_human_digest_reader_returns_str(self):
        mod = load(SCRIPTS / "cs-needs-human-digest.py", "csnhd")
        with mock.patch.dict("os.environ", {"MUSO_SLACK_BOT_TOKEN_DEVOPS": "T"}):
            self.assertEqual(mod._read_slack_token(self._config(), "devops"), "T")

    def test_outreach_slack_client_returns_str(self):
        from lib.muso_outreach import slack_client
        slack_client._TOKENS.clear()
        with mock.patch.dict("os.environ", {"MUSO_SLACK_BOT_TOKEN_DEVOPS": "T",
                                            "MUSO_OUTREACH_OPENCLAW_CONFIG": self._config()}):
            self.assertEqual(slack_client._load_token("devops"), "T")

    def test_intake_watchdog_resolves_str(self):
        mod = load(SCRIPTS / "intercom-intake-watchdog.py", "iiw")
        with mock.patch.dict("os.environ", {"MUSO_SLACK_BOT_TOKEN_DEVOPS": "T",
                                            "OPENCLAW_CONFIG": self._config()}, clear=False):
            with mock.patch.dict("os.environ", {}, clear=False):
                import os
                os.environ.pop("SLACK_BOT_TOKEN", None)
                self.assertEqual(mod.resolve_slack_token(), "T")


if __name__ == "__main__":
    unittest.main()
