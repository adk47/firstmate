#!/usr/bin/env python3
"""bats-scope.py: which Bats suites one pull request runs.

Reads the suites the Bats job discovered (one path per line, stdin) and prints
the ones this run executes (stdout, same order). Why it chose them goes to
stderr, one line.

WHY (2026-11-15). Measured on ovh-hydra over 6.3 hours that day: Bats was 69 of
the fleet's 98 runner-hours, every pull-request head ran all ~430 suites, and
77 heads arrived: 23 runners of work for 17. Runs waited a median of 30 minutes
for a runner.

THE RULE. A pull request runs:

  (a) every suite it adds or changes;
  (b) every suite that NAMES a file it changes, and every suite that names a
      file that names one (one step removed: the suite tests A, A sources B,
      the pull request changes B). The step is followed through code only,
      not through prose or recorded data (*.md, docs/, data/);
  (c) every whole-tree guard, always. A whole-tree guard reads the repo, so
      any file can turn it red: scripts/tests/check-*.bats and audit-*.bats (36 on
      2026-11-15), and any suite carrying the Bats file tag `every-pr`.

Everything else waits for the full run on main (.github/workflows/bats-main.yml:
every push to main, and nightly).

WHAT THIS COSTS, measured before it shipped, on this repo's own history.

  - Work: over every fourth merge to main since 2026-11-08 (39 of 157) a pull
    request would have run a median of 110 of ~430 suites and 35% of the cases
    (mean), and one of the 39 would have run everything.
  - What it lets through: on the 31 pull-request heads of 2026-11-12..15 where a
    Bats suite failed, leaving out two suites that failed the same two cases on
    a dozen unrelated branches in one night, there were 31 failing suites. This
    rule selects 30 of them. The one it leaves for main, credit-verify-zero-read
    on one head, failed on four unrelated branches in the same window, so it
    was probably not that pull request's doing; that is not proven.
  - The literal rule "only suites that name a changed file" selected 23 of 62
    and was not shipped. The misses were whole-tree guards, hence (c), and
    suites one step removed, hence the second half of (b).

A suite two or more steps from the change is NOT selected, and its failure shows
on main after the merge. That is the accepted cost. Nothing waits on the run on
main, so somebody has to read it.

"Names" is text: the file's base name as a whole word, or its name without the
extension together with its directory (`helpers/foo`, `pkg.foo`,
`from pkg import foo`). It over-selects, and that is the safe direction.

FAILS TOWARD EVERYTHING. Not a pull request, HEAD is not a pull-request merge
commit, git cannot say what changed, the change touches how Bats itself runs
(INFRA below, or the Bats job's own section of the workflow), a changed file is
named by too many files to follow, an unknown helper under a tests/ directory
changed, or anything raises: every discovered suite runs. A selector that
selects nothing by mistake is a pull request that merges with no Bats at all,
so nothing here returns an empty answer except "no suite is concerned AND there
are no whole-tree guards", which cannot happen while (c) is non-empty.
scripts/tests/bats-scope.bats executes this file against throwaway repos and
mutates it.

Reads:  BATS_SCOPE_EVENT  the GitHub event name. Anything but `pull_request`
                          (push, schedule, a laptop) runs everything.
        BATS_SCOPE_REPO   the checkout (default: the working directory)
"""
import os
import re
import subprocess
import sys

WORKFLOW = ".github/workflows/pr-validate.yml"
BATS_JOB = "bats-tests"

# Files that decide HOW Bats runs. A change to any of them is proven by every suite.
INFRA = (
    "scripts/ci/bats-scope.py",
    "scripts/ci/bats-job-step.py",
    "scripts/ci/arc-toolchain.sh",
    "scripts/bats-slot.sh",
    "scripts/assert-host-devnull.sh",
    ".github/workflows/bats-main.yml",
)

# A changed file named by more files than this is too connected to follow one
# step: the answer would be most of the suite anyway, so say so and run it all.
HUB_LIMIT = 400

# Prose and recorded data. A suite that names one still runs when it changes, but
# neither is followed a step further: a report that mentions a script does not run
# it. Measured before this rule: data/*/report.md, changed by most pull requests,
# was "named" by 47-66 files and dragged a third of the suites in with it.
DOC = re.compile(r"(\.md$|^data/|^docs/)")
DOC_RULE = True
# A name without its extension counts only together with its directory (see needles).
STEMS = True

EVERY_PR_NAME = re.compile(r"(^|/)scripts/tests/(check|audit)-[^/]*\.bats$")
EVERY_PR_TAG = re.compile(r"(?m)^#\s*bats\s+file_tags=.*\bevery-pr\b")

# A name counts when it is not part of a longer one.
LEFT = r"(^|[^A-Za-z0-9_.-])"
RIGHT = r"($|[^A-Za-z0-9_-])"


class Everything(Exception):
    """Raised with the reason every suite runs."""


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise Everything(f"git {args[0]} failed: {p.stderr.strip()[:120]}")
    return p


def needles(path):
    """The names a file can be referred to by, as extended regular expressions."""
    base = os.path.basename(path)
    out = [LEFT + re.escape(base) + RIGHT]
    stem = base.rsplit(".", 1)[0] if "." in base else ""
    parent = os.path.basename(os.path.dirname(path))
    # Without its extension a name is only followed together with its directory:
    # `load helpers/foo`, `import pkg.foo`, `python3 -m pkg.foo`, `from pkg import foo`.
    # Alone, `store`, `config` and `report` name half the repo (measured: a change to
    # scripts/gdpr_pipeline/store.py was "named" by 439 files) and prove nothing.
    if STEMS and stem and parent:
        out.append(LEFT + re.escape(parent) + r"[/.]" + re.escape(stem) + RIGHT)
        out.append(r"from\s+[A-Za-z0-9_.]*" + re.escape(parent) + r"\s+import\s[^#]*\b" + re.escape(stem) + r"\b")
    return out



def followed(path):
    """Whether a file is followed one step. Prose and recorded data are not: a report
    that mentions a script does not run it."""
    return not (DOC_RULE and DOC.search(path))


def grep_files(repo, tree, patterns, paths=None):
    """Tracked files in `tree` naming any of `patterns`. No match is an empty set."""
    if not patterns:
        return set()
    args = ["grep", "-l", "-I", "-E", "-f", "-", tree]
    if paths is not None:
        if not paths:
            return set()
        args += ["--", *paths]
    p = subprocess.run(["git", "-C", repo, *args], input="\n".join(patterns) + "\n",
                       capture_output=True, text=True)
    if p.returncode not in (0, 1):
        raise Everything(f"git grep failed: {p.stderr.strip()[:120]}")
    prefix = tree + ":"
    return {l[len(prefix):] if l.startswith(prefix) else l for l in p.stdout.splitlines() if l}


def job_section(text):
    """The Bats job's lines of the workflow, or None when it cannot be found."""
    lines, out, on = text.splitlines(), [], False
    for l in lines:
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", l):
            if on:
                break
            on = l.strip() == BATS_JOB + ":"
        if on:
            out.append(l)
    return out or None


def is_suite_helper(path, suites):
    """A non-suite file inside a directory that holds discovered suites."""
    if path.endswith(".bats"):
        return False
    dirs = {os.path.dirname(s) for s in suites}
    d = os.path.dirname(path)
    while d:
        if d in dirs:
            return True
        d = os.path.dirname(d)
    return False


def scope(repo, tree, base, changed, suites):
    """The suites a pull request runs, and why. Raises Everything to run them all."""
    if not changed:
        raise Everything("the list of what the pull request changes came back empty")
    suite_set = set(suites)

    for f in changed:
        if f in INFRA:
            raise Everything(f"the pull request changes {f}, which decides how Bats runs")
    if WORKFLOW in changed:
        old = git(repo, "show", f"{base}:{WORKFLOW}", check=False)
        new = git(repo, "show", f"{tree}:{WORKFLOW}", check=False)
        a = job_section(old.stdout) if old.returncode == 0 else None
        b = job_section(new.stdout) if new.returncode == 0 else None
        if a is None or b is None or a != b:
            raise Everything(f"the pull request changes the Bats job in {WORKFLOW}")

    always = set()
    for s in suites:
        if EVERY_PR_NAME.search(s):
            always.add(s)
            continue
        shown = git(repo, "show", f"{tree}:{s}", check=False)
        if shown.returncode == 0 and EVERY_PR_TAG.search(shown.stdout):
            always.add(s)

    own = {f for f in changed if f in suite_set}

    first = [n for f in changed for n in needles(f)]
    namers = grep_files(repo, tree, first)
    direct = namers & suite_set
    # One step removed, through code only: from a changed file that is not prose,
    # through a namer that is not prose.
    code = [n for f in changed if followed(f) for n in needles(f)]
    hops = {f for f in grep_files(repo, tree, code)
            if not f.endswith(".bats") and followed(f)} - set(changed)
    if len(hops) > HUB_LIMIT:
        raise Everything(f"what the pull request changes is named by {len(hops)} files, "
                         f"too many to follow (limit {HUB_LIMIT})")
    second = [n for f in sorted(hops) for n in needles(f)]
    removed = grep_files(repo, tree, second, sorted(suite_set))

    # A helper nobody names by a name we can see (a glob, a computed path) could be
    # loaded by any suite beside it.
    named_by_suite = direct | removed
    for f in changed:
        if is_suite_helper(f, suites) and re.search(r"\.(bash|sh)$|/[^./]+$", f):
            mine = grep_files(repo, tree, needles(f), sorted(suite_set))
            if not mine:
                raise Everything(f"the pull request changes {f}, a helper beside the suites "
                                 f"that no suite names, so any of them may load it")

    chosen = own | direct | removed | always
    why = (f"{len(chosen)} of {len(suites)} suites: {len(own)} changed by the pull request, "
           f"{len((direct | removed) - own)} that name what it changes "
           f"({len(direct - own)} directly, {len(removed - direct - own)} one step removed), "
           f"{len(always - own - named_by_suite)} whole-tree guards that always run. "
           f"The rest run on main (bats-main.yml)")
    return [s for s in suites if s in chosen], why


def decide(repo, event, suites):
    """(selected suites, one sentence). Never raises: any failure runs everything."""
    try:
        if event != "pull_request":
            raise Everything(f"this is {event or 'a run by hand'}, not a pull request")
        parents = git(repo, "rev-list", "--parents", "-n", "1", "HEAD").stdout.split()
        if len(parents) != 3:
            raise Everything(f"HEAD is not a pull-request merge commit (it has "
                             f"{max(len(parents) - 1, 0)} parent(s)), so what the pull "
                             f"request changes cannot be read")
        base = parents[1]
        # --no-renames: a moved file shows as its old name deleted and its new name added,
        # so suites naming either one still run.
        diff = git(repo, "diff", "--name-only", "--no-renames", "-z", base, "HEAD").stdout
        changed = [f for f in diff.split("\0") if f]
        chosen, why = scope(repo, "HEAD", base, changed, suites)
        return chosen, "scoped pull request: " + why
    except Everything as e:
        return list(suites), f"every suite ({len(suites)}): {e}"
    except Exception as e:  # noqa: BLE001 - any surprise must run everything, never nothing
        return list(suites), f"every suite ({len(suites)}): the scope could not be worked out ({type(e).__name__}: {e})"


def main():
    suites = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
    repo = os.environ.get("BATS_SCOPE_REPO") or "."
    chosen, why = decide(repo, os.environ.get("BATS_SCOPE_EVENT", ""), suites)
    print(f"Bats scope: {why}", file=sys.stderr)
    if chosen:
        print("\n".join(chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
