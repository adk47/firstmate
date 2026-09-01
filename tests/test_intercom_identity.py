"""Tests for scripts/lib/intercom_identity.py — the single resolution point for
the Intercom admin id every unattended writer posts under.

WHY this exists (2026-08-31, PR #900 fallout): customers saw support replies
signed "Nicholas Sollazzo" because an agent composed an Intercom call with a
human's admin id. That was fixed for the agent path by doctrine + a CI gate, but
eight scripts still resolved the id as `os.environ.get("INTERCOM_ADMIN_ID", ...)`
with NO validation. `/etc/openclaw/main.env` carries
`INTERCOM_ADMIN_ID=5201828` (Aaron), and the main gateway's process env carries
it too — so any of those scripts invoked by an agent from that gateway posted
under a human's identity. The systemd timers were unaffected (their units load
shared.env/edge.env, which do not set it), which is exactly why this stayed
invisible: the scheduled path was correct and only the agent path was wrong.

The invariant these tests lock: **the posting identity is a constant of the
system, not a configurable.** An env var may never move it off Caroline. A wrong
value is IGNORED (not obeyed, not fatal) and reported loudly — refusing outright
would strand customer notifications behind a config typo, while obeying is the
customer-visible bug. Ignoring is the only option that is both correct and
non-disruptive.

Stdlib unittest + stubs only — no pytest, no network — so it runs under the same
bare `python3 -m unittest` the py-tests CI job already uses.
"""
from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr

from scripts.lib.intercom_identity import CAROLINE_ADMIN_ID, resolve_admin_id


class TestCarolineConstant(unittest.TestCase):
    def test_caroline_id_is_the_documented_value(self):
        # Pinned deliberately: docs/lessons/muso-domain.md and the
        # muso-intercom skill both name this id, and the CI doctrine gate
        # asserts it. If this ever changes, those must change together.
        self.assertEqual(CAROLINE_ADMIN_ID, "5763097")


class TestResolveAdminId(unittest.TestCase):
    def _resolve(self, env):
        """Resolve with a captured stderr; returns (admin_id, stderr_text)."""
        buf = io.StringIO()
        with redirect_stderr(buf):
            got = resolve_admin_id(env)
        return got, buf.getvalue()

    # --- the happy paths: nothing to warn about ---------------------------

    def test_unset_env_returns_caroline_silently(self):
        got, err = self._resolve({})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertEqual(err, "")

    def test_env_set_to_caroline_returns_caroline_silently(self):
        got, err = self._resolve({"INTERCOM_ADMIN_ID": "5763097"})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertEqual(err, "")

    def test_empty_env_is_treated_as_unset_and_is_not_a_misconfiguration(self):
        # `os.environ.get(..., default)` returns "" for an exported-but-empty
        # var — one of the three resolution variants in the tree had exactly
        # this bug. Empty means "not configured", not "configured wrongly", so
        # it must not cry wolf.
        for value in ("", "   ", "\t"):
            with self.subTest(value=repr(value)):
                got, err = self._resolve({"INTERCOM_ADMIN_ID": value})
                self.assertEqual(got, CAROLINE_ADMIN_ID)
                self.assertEqual(err, "")

    def test_surrounding_whitespace_on_a_valid_id_is_tolerated(self):
        got, err = self._resolve({"INTERCOM_ADMIN_ID": "  5763097\n"})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertEqual(err, "")

    # --- the whole point: a non-Caroline id is ignored, loudly ------------

    def test_a_human_admin_id_is_ignored_and_reported(self):
        # 5201828 is Aaron, and is the value live in /etc/openclaw/main.env.
        got, err = self._resolve({"INTERCOM_ADMIN_ID": "5201828"})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertIn("[intercom:identity]", err)
        self.assertIn("5201828", err)
        self.assertIn(CAROLINE_ADMIN_ID, err)

    def test_every_known_human_admin_id_is_ignored(self):
        # Allowlist semantics: these are not enumerated anywhere in the
        # implementation. They are refused because they are not Caroline,
        # which is why an id nobody has listed is refused too (below).
        for human in ("10206197", "5201828", "5465657"):
            with self.subTest(admin_id=human):
                got, err = self._resolve({"INTERCOM_ADMIN_ID": human})
                self.assertEqual(got, CAROLINE_ADMIN_ID)
                self.assertIn("[intercom:identity]", err)

    def test_an_unknown_id_on_no_blocklist_is_still_ignored(self):
        got, err = self._resolve({"INTERCOM_ADMIN_ID": "99999"})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertIn("[intercom:identity]", err)
        self.assertIn("99999", err)

    def test_a_non_numeric_value_is_ignored(self):
        got, err = self._resolve({"INTERCOM_ADMIN_ID": "caroline"})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertIn("[intercom:identity]", err)

    def test_a_lookalike_longer_id_is_ignored(self):
        # Substring/prefix confusion must not resolve to "close enough".
        got, err = self._resolve({"INTERCOM_ADMIN_ID": "57630970000"})
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertIn("[intercom:identity]", err)

    def test_the_warning_names_the_env_var_so_it_is_actionable(self):
        _, err = self._resolve({"INTERCOM_ADMIN_ID": "5201828"})
        self.assertIn("INTERCOM_ADMIN_ID", err)

    def test_the_return_value_is_never_the_supplied_override(self):
        # The identity guarantee, stated as a property rather than a case list.
        for value in ("5201828", "10206197", "5465657", "99999", "abc", "0"):
            with self.subTest(value=value):
                got, _ = self._resolve({"INTERCOM_ADMIN_ID": value})
                self.assertNotEqual(got, value)
                self.assertEqual(got, CAROLINE_ADMIN_ID)

    # --- defaults ---------------------------------------------------------

    def test_defaults_to_the_process_environment(self):
        import os
        from unittest import mock
        with mock.patch.dict(os.environ, {"INTERCOM_ADMIN_ID": "5201828"},
                             clear=False):
            buf = io.StringIO()
            with redirect_stderr(buf):
                got = resolve_admin_id()
        self.assertEqual(got, CAROLINE_ADMIN_ID)
        self.assertIn("[intercom:identity]", buf.getvalue())


class TestNoWriterResolvesTheEnvItself(unittest.TestCase):
    """Structural guard: the point of a single choke point is that nothing
    bypasses it. Every Intercom writer must go through resolve_admin_id()
    rather than reading the env var directly, or the validation is one
    copy-paste away from being reintroduced without it."""

    # Writers that can import the canonical module.
    WRITERS = (
        "scripts/close-resolved-conversations.py",
        "scripts/resolve-notify.py",
        "scripts/overdue-verification-notifier.py",
        "scripts/close-duplicate-conversations.py",
        "scripts/close-stale-conversations.py",
        "scripts/resolution-matcher.py",
        "scripts/dedup/sweeps/notify-merged-customers.py",
    )

    # abuse-block.py deploys standalone as a skill
    # (skills/muso-abuse-block/scripts/) with no lib/ alongside it, so it
    # CANNOT import the canonical module and carries a vendored copy instead.
    # It is held to the same behaviour below rather than exempted.
    VENDORED = "skills-all/muso-abuse-block/scripts/abuse-block.py"

    def _root(self):
        from pathlib import Path
        return Path(__file__).resolve().parent.parent

    # The canonical resolver is the ONE place allowed to read the env var. Its
    # module docstring also quotes the old `os.environ.get("INTERCOM_ADMIN_ID",
    # ...)` form in order to explain what was wrong with it.
    RESOLVER = "scripts/lib/intercom_identity.py"

    def _scanned_py_files(self):
        """Every deployed .py under scripts/ and skills-all/, minus test trees.

        DISCOVERED, not enumerated. A guard that walks a hardcoded list proves
        nothing about the writer somebody adds next month — which is the exact
        shape of the defect this whole module exists to prevent. Walking the
        tree means a new Intercom writer is covered the day it lands, without
        an edit here.
        """
        root = self._root()
        for sub in ("scripts", "skills-all"):
            for path in sorted((root / sub).rglob("*.py")):
                rel = path.relative_to(root).as_posix()
                if "/tests/" in f"/{rel}" or rel == self.RESOLVER:
                    continue
                yield rel, path

    @staticmethod
    def _env_var_references(path, allow_resolver_fn=False):
        """Yield (lineno, source_line) for every AST reference to the env var.

        STRUCTURAL, not textual. The first version of this guard matched lines
        containing both "environ" and the var name, which a QA review showed
        was false-green for `os.getenv("INTERCOM_ADMIN_ID")` -- the substring
        "environ" simply is not in "getenv" -- and for any form that split the
        access across lines. Reproduced before fixing: the guard stayed green
        at 16/16 while the writer resolved to a human id under the live env.

        Parsing the tree instead covers every spelling at once: os.getenv,
        os.environ.get, os.environ[...], a bare `environ` imported from os, and
        any of them wrapped across lines, because the AST does not care where
        the newlines are. Docstrings are excluded so a file may still DOCUMENT
        the variable; comments never reach the AST at all.

        Known limit, stated rather than papered over: a name assembled at
        runtime ("INTERCOM_" + "ADMIN_ID") is out of reach, as it is for any
        static check.
        """
        import ast
        tree = ast.parse(path.read_text())

        docstrings = set()
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.FunctionDef,
                                 ast.AsyncFunctionDef, ast.ClassDef)):
                body = getattr(node, "body", None)
                if (body and isinstance(body[0], ast.Expr)
                        and isinstance(body[0].value, ast.Constant)
                        and isinstance(body[0].value.value, str)):
                    docstrings.add(id(body[0].value))

        # The vendored copy carries the sanctioned resolver, which must read
        # the env var -- that IS its job.
        #
        # The exemption is keyed on the FILE, never on the function name. A QA
        # review on #902 showed the name-based version was bypassable: any new
        # writer could define its own `def resolve_admin_id()` that read the env
        # and validated nothing, and both this guard and the "must call the
        # resolver" test stayed green. Exempting a name lets anyone claim it;
        # exempting one known path cannot be claimed by a file that is not that
        # path, and that file's behaviour is separately asserted in
        # TestNoWriterResolvesTheEnvItself.test_the_vendored_copy_enforces_the_same_rule.
        sanctioned = set()
        if allow_resolver_fn:
            for node in ast.walk(tree):
                if (isinstance(node, ast.FunctionDef)
                        and node.name == "resolve_admin_id"):
                    for inner in ast.walk(node):
                        sanctioned.add(id(inner))

        lines = path.read_text().splitlines()
        for node in ast.walk(tree):
            if (isinstance(node, ast.Constant)
                    and node.value == "INTERCOM_ADMIN_ID"
                    and id(node) not in docstrings
                    and id(node) not in sanctioned):
                line = lines[node.lineno - 1].strip() if node.lineno <= len(lines) else ""
                yield node.lineno, line

    def test_no_file_reads_INTERCOM_ADMIN_ID_directly(self):
        scanned = []
        offenders = []
        for rel, path in self._scanned_py_files():
            scanned.append(rel)
            for lineno, line in self._env_var_references(
                    path, allow_resolver_fn=(rel == self.VENDORED)):
                offenders.append(f"{rel}:{lineno}: {line}")
        self.assertEqual(
            offenders, [],
            "these files name INTERCOM_ADMIN_ID in code instead of calling "
            "resolve_admin_id():\n  " + "\n  ".join(offenders))
        # A scan that silently covered nothing is a false green, so assert the
        # walk actually reached the writers we already know about.
        for rel in self.WRITERS + (self.VENDORED,):
            self.assertIn(rel, scanned, f"scan did not reach {rel}")

    def test_a_lookalike_resolver_cannot_claim_the_exemption(self):
        """Regression for the #902 QA finding: the sanctioned-function
        exemption used to key on the NAME, so any file could define its own
        `def resolve_admin_id()` that read the env, validated nothing, and
        passed both this guard and the must-call-the-resolver test. The
        exemption is keyed on the vendored PATH now; prove a lookalike
        elsewhere is still refused."""
        import tempfile
        from pathlib import Path
        src = (
            "import os\n"
            "def resolve_admin_id():\n"
            "    return os.environ.get('INTERCOM_ADMIN_ID', '5763097')\n"
        )
        with tempfile.TemporaryDirectory() as td:
            fake = Path(td) / "lookalike.py"
            fake.write_text(src)
            # Not the vendored path -> the exemption must not apply.
            hits = list(self._env_var_references(fake, allow_resolver_fn=False))
            self.assertTrue(
                hits, "a lookalike resolver outside the vendored path was "
                      "treated as sanctioned")
            # And the real vendored file still gets its exemption.
            vendored = self._root() / self.VENDORED
            self.assertEqual(
                list(self._env_var_references(vendored,
                                              allow_resolver_fn=True)), [],
                "the vendored resolver should be exempt on its own path")

    def test_every_writer_actually_calls_the_resolver(self):
        """Importing the resolver is not using it. A writer could keep the
        import and still read the env directly -- the exact residue the QA
        review flagged -- so assert a real call node exists."""
        import ast
        root = self._root()
        missing = []
        for rel in self.WRITERS + (self.VENDORED,):
            tree = ast.parse((root / rel).read_text())
            called = any(
                isinstance(n, ast.Call)
                and ((isinstance(n.func, ast.Name)
                      and n.func.id == "resolve_admin_id")
                     or (isinstance(n.func, ast.Attribute)
                         and n.func.attr == "resolve_admin_id"))
                for n in ast.walk(tree))
            if not called:
                missing.append(rel)
        self.assertEqual(missing, [],
                         f"writers that never CALL resolve_admin_id(): {missing}")

    def test_every_writer_imports_the_shared_resolver(self):
        root = self._root()
        missing = [rel for rel in self.WRITERS
                   if "from lib.intercom_identity import resolve_admin_id"
                   not in (root / rel).read_text()]
        self.assertEqual(missing, [],
                         f"writers not importing the shared resolver: {missing}")

    def test_the_vendored_copy_enforces_the_same_rule(self):
        """The duplicate in the skill is only acceptable while it behaves
        identically. Load it and assert the behaviour, not the text."""
        import importlib.util
        path = self._root() / self.VENDORED
        self.assertTrue(path.is_file(), f"not found: {self.VENDORED}")
        spec = importlib.util.spec_from_file_location("abuse_block_vendored",
                                                      path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        self.assertEqual(mod.resolve_admin_id({}), CAROLINE_ADMIN_ID)
        self.assertEqual(
            mod.resolve_admin_id({"INTERCOM_ADMIN_ID": "5763097"}),
            CAROLINE_ADMIN_ID)
        for bad in ("5201828", "10206197", "5465657", "99999", "abc"):
            with self.subTest(value=bad):
                buf = io.StringIO()
                with redirect_stderr(buf):
                    got = mod.resolve_admin_id({"INTERCOM_ADMIN_ID": bad})
                self.assertEqual(got, CAROLINE_ADMIN_ID)
                self.assertIn("[intercom:identity]", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
