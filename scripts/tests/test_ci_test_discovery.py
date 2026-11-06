"""Every test file CI runs with `python3 <file>` must actually RUN every test in it.

qa-review #1766 r7 finding 1: `scripts/tests/test_credit_decide_watchdog.py` called
`unittest.main()` at line 662, and `QaR3`, `QaR5` and `QaR6` were defined BELOW it. `unittest.main()`
discovers the classes that exist when it is called, so CI's `python3 scripts/tests/test_credit_decide_watchdog.py`
ran 38 of 52 tests and reported OK - the cap-admission, blind-input, tier-split and indeterminate-write
regressions were all invisible to the required step. `test_doc_approve.py` had the same shape and hid
`DocApproveQaR5` (122 of 125), and `test_doc_verify.py` hid `IntakeKeyingIsNotTheReadBudget`
(209 of 215) - the guard below found the third one, which is the point of writing it as a scan
rather than as three fixes.

pytest collects the whole module, so the gap only exists on the direct-invocation path - which is the
path CI uses. This test pins the invariant for every file CI invokes that way, so the next test class
appended after a `__main__` block fails here instead of silently not running.
"""

from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "pr-validate.yml"

# `python3 scripts/tests/foo.py` (optionally with a trailing redirect or args) - the direct-invocation
# form. `python3 -m pytest ...` is excluded on purpose: pytest collects the whole module.
_DIRECT = re.compile(r"^\s*python3\s+(scripts/tests/[\w./-]+\.py)\s*$", re.MULTILINE)


def _directly_invoked() -> list[Path]:
    found = []
    for rel in _DIRECT.findall(WORKFLOW.read_text()):
        p = ROOT / rel
        if p.exists():
            found.append(p)
    return sorted(set(found))


def _main_block_index(tree: ast.Module) -> int | None:
    """Index of the `if __name__ == "__main__":` statement, or None."""
    for i, node in enumerate(tree.body):
        if not isinstance(node, ast.If):
            continue
        test = node.test
        if (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name)
                and test.left.id == "__name__"
                and any(isinstance(c, ast.Constant) and c.value == "__main__"
                        for c in test.comparators)):
            return i
    return None


class CiTestDiscovery(unittest.TestCase):
    def test_the_workflow_actually_invokes_some_test_files(self):
        """A guard that finds nothing is not a guard: prove the scan sees the real list."""
        found = _directly_invoked()
        self.assertGreaterEqual(len(found), 3, f"the scan found only {found}")
        names = {p.name for p in found}
        self.assertIn("test_credit_decide_watchdog.py", names)
        self.assertIn("test_doc_approve.py", names)

    def test_no_test_class_is_defined_AFTER_the_main_block(self):
        """The finding, generalised: a class below `unittest.main()` never runs in CI."""
        offenders = []
        for path in _directly_invoked():
            tree = ast.parse(path.read_text(), filename=str(path))
            idx = _main_block_index(tree)
            if idx is None:
                continue
            after = [n.name for n in tree.body[idx + 1:]
                     if isinstance(n, ast.ClassDef) and n.name.startswith("Test")
                     or isinstance(n, ast.ClassDef) and any(
                         isinstance(b, ast.Name) and b.id == "unittest.TestCase"
                         for b in n.bases)]
            if after:
                offenders.append(f"{path.relative_to(ROOT)}: {', '.join(after)}")
        self.assertEqual(offenders, [], "these classes are defined after `unittest.main()` and never "
                                        "run under CI's direct invocation: " + "; ".join(offenders))

    def test_the_main_block_is_the_LAST_statement(self):
        """Stronger and simpler than the class scan: nothing at all may follow it."""
        offenders = []
        for path in _directly_invoked():
            tree = ast.parse(path.read_text(), filename=str(path))
            idx = _main_block_index(tree)
            if idx is None:
                continue
            if idx != len(tree.body) - 1:
                offenders.append(f"{path.relative_to(ROOT)}: {len(tree.body) - idx - 1} statement(s) "
                                 "follow the __main__ block")
        self.assertEqual(offenders, [], "; ".join(offenders))

    def test_the_two_files_that_had_the_bug_run_every_test_they_define(self):
        """The regression itself, pinned by count: direct invocation must match pytest's collection."""
        import subprocess
        import sys
        for name in ("test_credit_decide_watchdog.py", "test_doc_approve.py", "test_doc_verify.py"):
            path = ROOT / "scripts" / "tests" / name
            direct = subprocess.run([sys.executable, str(path)], capture_output=True, text=True,
                                    cwd=ROOT, timeout=600)
            self.assertEqual(direct.returncode, 0, direct.stderr[-2000:])
            ran = re.search(r"^Ran (\d+) tests?", direct.stderr, re.MULTILINE)
            self.assertIsNotNone(ran, direct.stderr[-2000:])
            collected = subprocess.run([sys.executable, "-m", "pytest", str(path), "-q",
                                        "--collect-only"], capture_output=True, text=True,
                                       cwd=ROOT, timeout=600)
            self.assertEqual(collected.returncode, 0, collected.stderr[-2000:])
            want = re.search(r"(\d+) tests? collected", collected.stdout)
            self.assertIsNotNone(want, collected.stdout[-2000:])
            self.assertEqual(int(ran.group(1)), int(want.group(1)),
                             f"{name}: CI's direct invocation runs {ran.group(1)} of "
                             f"{want.group(1)} tests")


if __name__ == "__main__":
    unittest.main()
