#!/usr/bin/env python3
"""CI gate for `policies/sentinel-capabilities.json` (the sentinel capability registry).

The registry is the repo half of the "three independent stops" (report §2.6): a capability's
rollout state, its kill file, and the actor's own approval flag. `scripts/sentinel/demote.py`
reads this file on the host every night and can only ever NARROW what it says; a human PR is
the only thing that can widen it. That makes this file load-bearing in both directions, so it
gets the same treatment as `policies/agent-exec-policy.json`: shape is enforced in CI, not by
reviewer attention.

What this gate refuses:
  * a malformed row (missing id/class/action/rollout/demotion/kill_file, duplicate id);
  * a kill_file that is not exactly `/etc/hydra/<name>.disabled` — a demotion writes into that
    directory and nothing else, and a path that escapes it is a root write to somewhere nobody
    fenced;
  * a kill_file that NO code in this repo honours, on a row that is actually acting
    (`canary`/`live`). The dispatch's own DoD says it: "the kill files it drops are the ones
    cron_tick.sh / the actors already honour — verify by name against grep -r '.disabled'
    scripts/". A stop nobody implements is not a stop. A `shadow` row is exempt: it is not
    acting yet, and the file it names will be honoured by the actor that gets built for it.
  * a state IMPROVEMENT (shadow → canary → live) without `rollout.since` and
    `rollout.approval_ref`. Promotion is a PR carrying a Fable ruling id; the parity report
    from `scripts/sentinel/demote.py promote` is what the ruling is based on. Demotion needs no
    approval (it is the safe direction) — that asymmetry is the whole point.

A missing registry is NOT an error: sentinel-core-s0 owns the file and this gate must not block
unrelated PRs while it lands. It says so, loudly, and exits 0. The host behaves the same way:
`demote.py` exits 2 and pages once a day rather than pretending the loop is running.

Usage:
  scripts/check-sentinel-registry.py                  # check the working tree
  scripts/check-sentinel-registry.py --base origin/main   # also check promotions vs base
"""
from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

REGISTRY_REL = "policies/sentinel-capabilities.json"
KILL_FILE_RE = re.compile(r"^/etc/hydra/[A-Za-z0-9._-]+\.disabled$")
STATES = {"shadow": 0, "canary": 1, "live": 2}
# The `demotion` block is the ONLY thing that can stop a row, so a trigger the demoter does
# not implement is a stop that does not exist. Keys are validated against this table rather
# than accepted as free-form: `reverts_7d: "five"` and `audit_fail_any: "true"` both used to
# pass, and `_rule_hits()` ignores a non-numeric threshold and a non-`True` flag, so a row
# could ship with 99 reverts and a manipulated verdict and never demote.
NUMERIC_TRIGGERS = ("reverts_7d", "manipulated_7d", "contradicted_7d", "complaints_7d",
                    "audit_fails_7d", "overdue_pct")
FLAG_TRIGGERS = ("audit_fail_any",)
# Not a trigger: the state a trip moves to. Validated separately so a typo cannot ride in
# as an unknown key.
DEMOTION_META = ("on_trip",)
ACTION_TYPES = {"core_write", "hydra_executor", "message_line", "board_card", "handoff"}
# Where a kill-file name can be honoured from. Anything the actor reads, plus the cron store.
HONOUR_SEARCH = ("scripts", "cron-jobs.json", "plugins")


class BaseUnreadable(RuntimeError):
    """The base ref could not be read, so promotion cannot be verified. Never `{}`."""


def load(path: Path) -> List[Dict[str, Any]]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or not isinstance(doc.get("capabilities"), list):
        raise ValueError("registry must be an object with a `capabilities` list")
    return doc["capabilities"]


# The trailing boundary is load-bearing (QA r8): without it the pattern matched the PREFIX
# of a longer name, so `KILL = Path("/etc/hydra/case.disabled.backup")` + `KILL.exists()`
# reported `/etc/hydra/case.disabled` as honoured — a `live` row could pass CI naming a
# switch the actor never reads, while demotion drops the file nobody checks. A kill path
# ends at a non-name character; `.`, `-`, `_`, `/` and alphanumerics all continue a name.
KILL_PATH_IN_TEXT = re.compile(r"/etc/hydra/[A-Za-z0-9._-]+\.disabled(?![A-Za-z0-9._/-])")
# "Is this file there?" idioms. A path that is only NAMED somewhere is not a stop; the
# actor has to actually look at the filesystem.
EXISTENCE_IDIOMS = re.compile(
    r"(\.exists\(\)|\.is_file\(\)|os\.path\.exists|os\.path\.isfile|isfile\(|access\("
    r"|test\s+-[ef]|\s-[ef]\s|Path\([^)]*\)\.exists)"
)
COMMENT_PREFIXES = ("#", "//", "*", "--", ";", "<!--")


def _code(line: str) -> str:
    """The line with any INLINE comment stripped, quote-aware.

    Without this, `KILL = "/etc/hydra/x.disabled"  # .exists()` counted as an existence
    check: the prose after `#` satisfied an idiom whose code does not exist. Only `#` and
    `//` are treated as comment starts, and only outside quotes. A kill path never
    contains either marker, so this can only ever REMOVE evidence, never invent it.
    """
    out: List[str] = []
    quote = ""
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = ""
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "#" or line.startswith("//", i):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def _imports(text: str) -> set:
    """Names this file imports, so a cross-file check can be resolved to a real module."""
    names: set = set()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("from ") and " import " in line:
            for part in line.split(" import ", 1)[1].split("#")[0].split(","):
                part = part.strip()
                if " as " in part:
                    names.add(part.split(" as ", 1)[1].strip())
                elif part and part != "*" and part.isidentifier():
                    names.add(part)
        elif line.startswith("import "):
            for part in line[7:].split("#")[0].split(","):
                part = part.strip()
                names.add(part.split(" as ", 1)[1].strip() if " as " in part else part.split(".")[0])
    return names


def _bound_names(line: str) -> set:
    """Names this line binds, e.g. `KILL = Path("...")` -> KILL; `def f(sw="...")` -> sw."""
    names: set = set()
    m = re.match(r"\s*(?:export\s+|readonly\s+|local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=", line)
    if m:
        names.add(m.group(1))
    for m in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=,)]+)?=\s*[^,)]*$", line.split("(", 1)[-1]):
        names.add(m.group(1))
    return names


def _self_checks(text: str) -> set:
    """Names this file existence-checks without a qualifier."""
    names: set = set()
    for line in text.splitlines():
        line = _code(line)
        if line.lstrip().startswith(COMMENT_PREFIXES) or not EXISTENCE_IDIOMS.search(line):
            continue
        for m in re.finditer(r"(?<![.\w])([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(?:exists|is_file)\s*\(\s*\)", line):
            names.add(m.group(1))
        for m in re.finditer(r"os\.path\.(?:exists|isfile)\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*[,)]", line):
            names.add(m.group(1))
        for m in re.finditer(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", line):
            names.add(m.group(1))
    return names


def _qualified_checks(text: str) -> set:
    """(module, name) pairs this file existence-checks as `module.NAME.exists()`."""
    pairs: set = set()
    for line in text.splitlines():
        line = _code(line)
        if line.lstrip().startswith(COMMENT_PREFIXES) or not EXISTENCE_IDIOMS.search(line):
            continue
        for m in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(?:exists|is_file)\s*\(\s*\)", line):
            pairs.add((m.group(1), m.group(2)))
        for m in re.finditer(r"os\.path\.(?:exists|isfile)\(\s*([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)", line):
            pairs.add((m.group(1), m.group(2)))
    return pairs


def honoured_names(repo: Path) -> str:
    """The kill-file paths this repo's PRODUCTION code actually checks, one per line.

    Three versions have been reviewed, each less generous than the last:

    1. A substring scan over `scripts/` counted a `.bats` comment — fixed by dropping
       test paths.
    2. It still counted a plain comment in a production file.
    3. Collecting "checked" names tree-wide and matching any binding was UNSOUND: an
       unrelated `UNUSED = Path("/etc/hydra/x.disabled")` in one file plus an unrelated
       `UNUSED.exists()` in another was accepted, so a `live` row could ship a switch
       nothing checks.

    A path is evidence now only when the line is not a comment AND either the line
    itself performs an existence check, or the path is bound to a name that is
    existence-checked in the SAME file, or in a file that IMPORTS the binding's module
    and checks it as `module.NAME.exists()` (the definition and the check genuinely live
    in different files: `credit_review/decide.py` binds KILL_SWITCH, `credit-review.py`
    imports `decide` and calls `decide.KILL_SWITCH.exists()`).

    This is the strongest claim static analysis can honestly make; it is not proof the
    path runs, which is why a human still reads the row.
    """
    files: List[Tuple[str, str]] = []
    for target in HONOUR_SEARCH:
        base = repo / target
        if base.is_file():
            if not _is_test_path(base):
                files.append((base.name, base.read_text(encoding="utf-8", errors="replace")))
        elif base.is_dir():
            for p in base.rglob("*"):
                if not p.is_file() or p.suffix not in (".sh", ".py", ".bats", ".ts", ".js", ".json", ".yaml", ".yml"):
                    continue
                if _is_test_path(p):
                    continue
                try:
                    files.append((p.stem if p.suffix == ".py" else p.name,
                                  p.read_text(encoding="utf-8", errors="replace")))
                except OSError:
                    continue

    # module stem -> names it binds to a kill path
    bindings: Dict[str, Dict[str, set]] = {}
    for module, text in files:
        for line in text.splitlines():
            line = _code(line)
            if line.lstrip().startswith(COMMENT_PREFIXES):
                continue
            paths = {m.group(0) for m in KILL_PATH_IN_TEXT.finditer(line)}
            if not paths:
                continue
            for name in _bound_names(line):
                bindings.setdefault(module, {}).setdefault(name, set()).update(paths)

    # module -> names that OTHER files existence-check as `module.NAME` after importing
    # module. Collected globally because the binding line (which carries the literal
    # path) and the check line (which carries the evidence) are in different files.
    vouched: Dict[str, set] = {}
    for _, text in files:
        imported = _imports(text)
        for qual, name in _qualified_checks(text):
            if qual in imported:
                vouched.setdefault(qual, set()).add(name)

    evidenced: set = set()
    for module, text in files:
        self_checked = _self_checks(text)
        mine = vouched.get(module, set())
        for line in text.splitlines():
            line = _code(line)
            if line.lstrip().startswith(COMMENT_PREFIXES):
                continue
            inline = bool(EXISTENCE_IDIOMS.search(line))
            for m in KILL_PATH_IN_TEXT.finditer(line):
                path = m.group(0)
                if inline:
                    evidenced.add(path)
                    continue
                for name in _bound_names(line):
                    if name in self_checked:
                        evidenced.add(path)
                        break
                    # Another file imports this module and checks `module.NAME.exists()`.
                    if name in mine and path in bindings.get(module, {}).get(name, set()):
                        evidenced.add(path)
                        break
    return "\n".join(sorted(evidenced))


def _is_test_path(p: Path) -> bool:
    """A test/fixture path. Never evidence that a switch is read."""
    parts = p.parts
    if any(part in ("tests", "test", "__tests__", "fixtures") for part in parts):
        return True
    name = p.name
    return (name.endswith(".bats") or name.startswith("test_") or name.startswith("test-")
            or ".test." in name or ".spec." in name or name.endswith("_test.py"))


def _git_runner(repo: Path):
    """A `git -C <repo>` runner whose failures are BaseUnreadable, never a silent `{}`."""
    def git(*args: str) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(["git", "-C", str(repo), *args],
                                  capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as exc:  # git missing, timeout
            raise BaseUnreadable(f"cannot run git ({exc})") from exc
    return git


def _registry_on_base(git, base: str) -> bool:
    """Whether the registry file exists on `base`. FAIL CLOSED on any git trouble.

    `ls-tree`, not `cat-file -e`: BOTH a missing path and a bad object exit 128 from
    cat-file, so its status cannot tell "this PR introduces the file" from "git failed".
    ls-tree exits 0 either way and prints the path only when it exists.
    """
    ref = git("rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if ref.returncode != 0:
        raise BaseUnreadable(f"base ref {base!r} does not resolve: {(ref.stderr or ref.stdout).strip()}"
                             " — fetch it (git fetch origin) or pass a ref that exists")
    listed = git("ls-tree", "--name-only", base, "--", REGISTRY_REL)
    if listed.returncode != 0:
        raise BaseUnreadable(f"cannot list {REGISTRY_REL} at {base!r}: "
                            f"{(listed.stderr or listed.stdout).strip()}")
    return bool((listed.stdout or "").strip())


def base_rollouts(repo: Path, base: str) -> Dict[str, Dict[str, Any]]:
    """Each row's `rollout` block on the base ref, for the promotion-metadata rule.

    A promotion must carry metadata for ITSELF. Without the base block, a `canary` row that
    already cites a ruling could be flipped to `live` by editing `rollout.state` alone, and
    the old ruling — which authorized the canary step — would silently authorize the new one.
    """
    return {str(r.get("id")): dict(r.get("rollout") or {})
            for r in _base_rows(repo, base) if isinstance(r, dict)}


def _base_rows(repo: Path, base: str) -> List[Dict[str, Any]]:
    """The registry rows on the base ref, for the promotion rules.

    FAIL CLOSED, with one honest exception. `[]` means "the registry does not exist on
    base yet" (this PR introduces it), which needs no promotion ruling. Everything else
    — an unfetched/garbled ref, a git failure, an unparseable document — raises
    BaseUnreadable, because silently returning `[]` would accept `shadow → live` with no
    `approval_ref`, i.e. the one gate the promotion rule exists for.
    """
    git = _git_runner(repo)
    if not _registry_on_base(git, base):
        return []  # genuinely not on base yet: no previous state to compare to
    shown = git("show", f"{base}:{REGISTRY_REL}")
    if shown.returncode != 0:
        raise BaseUnreadable(f"cannot read {REGISTRY_REL} at {base!r}: "
                            f"{(shown.stderr or shown.stdout).strip()}")
    try:
        doc = json.loads(shown.stdout)
    except ValueError as exc:
        raise BaseUnreadable(f"{REGISTRY_REL} at {base!r} is not valid JSON ({exc})") from exc
    # A document that EXISTS but has no `capabilities` list is a broken registry, not an
    # empty one: returning `{}` there would let `shadow → live` pass with no ruling.
    if not isinstance(doc, dict) or not isinstance(doc.get("capabilities"), list):
        raise BaseUnreadable(f"{REGISTRY_REL} at {base!r} has no `capabilities` list "
                            f"(got {type(doc).__name__}) — fix the base registry, do not skip the rule")
    return doc["capabilities"]


def base_states(repo: Path, base: str) -> Dict[str, str]:
    """Row states on the base ref, for the promotion rule."""
    return {str(r.get("id")): str((r.get("rollout") or {}).get("state"))
            for r in _base_rows(repo, base) if isinstance(r, dict)}


def _demotion_problems(where: str, demotion: Dict[str, Any]) -> List[str]:
    """Every trigger must be one the demoter implements, with a value it can act on."""
    bad: List[str] = []
    for key, value in demotion.items():
        if key in NUMERIC_TRIGGERS:
            # bool is an int in Python: `reverts_7d: true` would read as a threshold of 1.
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                bad.append(f"{where}: demotion.{key} must be a number, got {value!r} — "
                           "a non-numeric threshold is silently ignored, so this trigger "
                           "can never fire")
            elif not math.isfinite(value):
                # json.loads accepts the bare tokens NaN/Infinity, and every comparison
                # against NaN is False — so `reverts_7d: NaN` passed the `<= 0` check and
                # then `_rule_hits()` ignored even 99 reverts. A threshold that cannot be
                # compared is a stop that does not exist.
                bad.append(f"{where}: demotion.{key} must be a finite number, got {value!r} — "
                           "NaN/Infinity compare false against every count, so this trigger "
                           "can never fire")
            elif value <= 0:
                bad.append(f"{where}: demotion.{key} must be > 0, got {value!r} — a threshold "
                           "of 0 or less never fires")
        elif key in FLAG_TRIGGERS:
            if value is not True:
                bad.append(f"{where}: demotion.{key} must be the boolean true, got {value!r} — "
                           "the demoter tests `is True`, so a string \"true\" never fires")
        elif key in DEMOTION_META:
            if value not in STATES:
                bad.append(f"{where}: demotion.{key} must be one of {sorted(STATES)}, got {value!r}")
        else:
            bad.append(f"{where}: demotion.{key} is not a trigger the demoter implements "
                       f"(known: {sorted(NUMERIC_TRIGGERS + FLAG_TRIGGERS + DEMOTION_META)}) — "
                       "an unknown key is a stop that does not exist")
    return bad


def check(rows: List[Dict[str, Any]], honoured: str, prev: Dict[str, str],
          prev_rollout: Optional[Dict[str, Dict[str, Any]]] = None) -> Tuple[List[str], List[str]]:
    bad: List[str] = []
    warn: List[str] = []
    seen: set = set()
    # EXACT path entries, never substring membership: `/etc/hydra/foo.disabled` is a
    # substring of `/etc/hydra/foo.disabled.disabled`, so a live row could name a switch
    # that only exists as a longer, different path and pass.
    honoured_set = {line.strip() for line in honoured.splitlines() if line.strip()}
    for i, row in enumerate(rows):
        where = f"capabilities[{i}]"
        if not isinstance(row, dict):
            bad.append(f"{where}: not an object")
            continue
        cap = row.get("id")
        if not cap or not isinstance(cap, str):
            bad.append(f"{where}: missing `id`")
            continue
        where = f"`{cap}`"
        if cap in seen:
            bad.append(f"{where}: duplicate id")
        seen.add(cap)
        if not row.get("class"):
            bad.append(f"{where}: missing `class`")
        action = row.get("action") or {}
        if not isinstance(action, dict) or action.get("type") not in ACTION_TYPES:
            bad.append(f"{where}: action.type must be one of {sorted(ACTION_TYPES)}, got {action.get('type')!r}")
        rollout = row.get("rollout") or {}
        state = rollout.get("state")
        if state not in STATES:
            bad.append(f"{where}: rollout.state must be one of {sorted(STATES)}, got {state!r}")
        since = rollout.get("since")
        if not since:
            bad.append(f"{where}: rollout.since is required (when did this state start?)")
        demotion = row.get("demotion")
        if not isinstance(demotion, dict) or not demotion:
            bad.append(f"{where}: missing `demotion` block (a row with no triggers cannot be demoted)")
        else:
            bad.extend(_demotion_problems(where, demotion))
            if "audit_fail_any" not in demotion:
                warn.append(f"{where}: demotion has no `audit_fail_any` trigger — the strongest "
                            "manipulation signal cannot demote this row")
        kill_file = row.get("kill_file")
        if not isinstance(kill_file, str) or not KILL_FILE_RE.match(kill_file):
            bad.append(f"{where}: kill_file must look like /etc/hydra/<name>.disabled, got {kill_file!r}")
        elif state in ("canary", "live") and kill_file not in honoured_set:
            bad.append(f"{where}: kill_file {kill_file} is not honoured by any production code "
                       "in this repo — a stop nothing implements is not a stop, and a path that "
                       "only appears in prose or a test is not a check (a `shadow` row may name "
                       "one early)")
        if isinstance(rollout, dict) and rollout.get("demoted") and not rollout["demoted"].get("at"):
            bad.append(f"{where}: rollout.demoted needs `at`")
        # Promotion is the only direction that needs a ruling.
        before = prev.get(cap)
        if before in STATES and state in STATES and STATES[state] > STATES[before]:
            if not rollout.get("approval_ref"):
                bad.append(f"{where}: {before} → {state} is a PROMOTION and must cite "
                           "`rollout.approval_ref` (a Fable ruling id; see "
                           "`scripts/sentinel/demote.py promote`)")
            if not since:
                bad.append(f"{where}: {before} → {state} is a PROMOTION and must set `rollout.since`")
            # ...and the metadata must be for THIS promotion. Reusing the base row's
            # approval_ref/since means the ruling authorized the PREVIOUS state, so a
            # state-only edit would launder an old ruling into a new promotion.
            base_rollout = (prev_rollout or {}).get(cap) or {}
            reused = [k for k in ("approval_ref", "since")
                      if rollout.get(k) and rollout.get(k) == base_rollout.get(k)]
            if reused:
                bad.append(f"{where}: {before} → {state} reuses the base row's "
                           + " and ".join(f"`rollout.{k}`" for k in reused)
                           + " — a promotion needs its OWN Fable ruling id and `since`; the "
                           "old ones authorized the previous state")
    return bad, warn


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Validate policies/sentinel-capabilities.json")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--path", default=None, help=f"registry path (default <repo>/{REGISTRY_REL})")
    ap.add_argument("--base", default=None,
                    help="git ref to compare against for the promotion rule (e.g. origin/main)")
    a = ap.parse_args(argv)
    repo = Path(a.repo)
    path = Path(a.path) if a.path else repo / REGISTRY_REL

    if not path.exists():
        # Absence is only acceptable BEFORE the registry has ever landed. Once it is on
        # base, deleting it turns every sentinel unit into a clean exit-2 skip — automatic
        # demotion silently stops and this gate would otherwise report success. A file
        # that cannot be removed loudly cannot be removed quietly.
        if a.base:
            try:
                if _registry_on_base(_git_runner(repo), a.base):
                    print(f"FAIL: {REGISTRY_REL} exists on {a.base} but is missing here — "
                          "deleting the registry silently disables every sentinel unit "
                          "(they skip with exit 2). Restore it, or remove the units that "
                          "depend on it in the same PR.")
                    return 1
            except BaseUnreadable as e:
                print(f"FAIL: cannot verify whether the registry was deleted: {e}")
                return 1
        else:
            print(f"note: {path} does not exist and no --base was given, so this run cannot "
                  "tell 'not landed yet' from 'deleted' — pass --base in CI")
        print(f"note: {path} does not exist yet (sentinel-core-s0 owns it) — nothing to check")
        return 0
    try:
        rows = load(path)
    except (ValueError, OSError) as e:
        print(f"FAIL: {path} is not a valid registry: {e}")
        return 1
    prev: Dict[str, str] = {}
    prev_rollout: Dict[str, Dict[str, Any]] = {}
    if a.base:
        try:
            prev = base_states(repo, a.base)
            prev_rollout = base_rollouts(repo, a.base)
        except BaseUnreadable as e:
            print(f"FAIL: cannot verify promotion rulings against {a.base}: {e}")
            return 1
    bad, warn = check(rows, honoured_names(repo), prev, prev_rollout)
    for w in warn:
        print(f"WARN: {w}")
    if bad:
        for b in bad:
            print(f"FAIL: {b}")
        print(f"\n{len(bad)} problem(s) in {REGISTRY_REL}")
        return 1
    print(f"ok: {len(rows)} sentinel capabilit{'y' if len(rows) == 1 else 'ies'} valid"
          + (f" ({len(prev)} rows on {a.base})" if a.base else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
