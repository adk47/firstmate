#!/usr/bin/env python3
"""Credit-approval change guard (PR-time CI check).

Why this exists (captain, 2026-10-11): a cron approved ~57,400 credits the
validator had declined, and a separate PR weakened the validator. Nobody is
blocked from changing the credit-approval system, but every change to it must be
visible and reviewed. A PR that touches a credit-approval path:

  1. gets the label `credit-approval-change`;
  2. fails unless its body has a `## Credit approval impact` section that says
     what changes and gives a before/after measurement on prod data;
  3. fails unless the captain (CAPTAIN_LOGIN, default adk47) has APPROVED the
     PR's current head commit (a push after the approval needs a new one).
     There is NO author exemption: GitHub forbids self-approval, so a PR
     authored by the captain account stays red here and is admin-merged on
     Fable GO + QA GO + green CI, with +15/+60 min monitoring (captain's rule,
     2026-10-16). The account is shared with firstmate and the QA bot. The QA
     bot's approve wrapper (hydra scripts/qa-pr-approve.sh, Guard 3d) refuses
     PRs labelled `credit-approval-change`, and as a second line this check
     ignores any APPROVED review whose body carries the bot's brand
     (BOT_REVIEW_MARKERS). An unbranded APPROVED from the shared login still
     counts (accepted under option b).

The section check is syntactic: the BEFORE and AFTER lines must carry a
figure that is not a date, year, SHA or PR ref. Whether the figures are a real
prod measurement is the captain's call at review.

The credit-approval paths are NOT listed here. They are the patterns inside the
`# >>> credit-approval` / `# <<< credit-approval` block of CODEOWNERS,
read from BOTH the base and the head commit, so a PR cannot dodge the guard by
deleting patterns from the block (the base copy still applies) and a PR that adds
a pattern is checked against it immediately. Shared files that cannot be gated
whole (a route table) use `#content-match <path> <regex>` lines in the block:
they trip the guard only when a changed line matches. `#content-sample <path>
<line>` fixtures pin what each rule must catch (checked on every run). Renames count as
delete + add, so moving a protected file out of a protected path still trips.
This script, its workflow and CODEOWNERS itself are listed in that block, so
changing the guard trips it.

CODEOWNERS on its own cannot require the captain: when a line lists several
owners, ANY one of them satisfies "require code owner review". This check is
what makes the captain's review mandatory; it must be a required status check
on the protected branches to block merges.

Stdlib only (runs on the bare python3 of the in-cluster runner). `--self-test`
runs the unit tests below; the workflow runs them before the real check.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

LABEL = "credit-approval-change"
BLOCK_BEGIN = "# >>> credit-approval"
BLOCK_END = "# <<< credit-approval"
# GitHub reads the first of these that exists.
CODEOWNERS_PATHS = (".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS")
SECTION_TITLE = "Credit approval impact"


# ── CODEOWNERS block parsing / matching ──────────────────────────────────────


def parse_block(codeowners_text: str | None) -> list[str]:
    """Return the path patterns inside the credit-approval block (may be empty)."""
    if not codeowners_text:
        return []
    patterns: list[str] = []
    inside = False
    for raw in codeowners_text.splitlines():
        line = raw.strip()
        if line.startswith(BLOCK_BEGIN):
            inside = True
            continue
        if line.startswith(BLOCK_END):
            inside = False
            continue
        if not inside or not line or line.startswith("#"):
            continue
        patterns.append(line.split()[0])
    return patterns


CONTENT_RULE = "#content-match"


def parse_content_rules(codeowners_text: str | None) -> list[tuple[str, str]]:
    """`#content-match <path-pattern> <regex>` lines inside the block.

    For shared files that cannot be gated whole (e.g. a route table): the PR
    trips the guard when an added or removed line of a matching file matches
    the regex. They are comments, so GitHub's CODEOWNERS parser ignores them.
    """
    if not codeowners_text:
        return []
    rules: list[tuple[str, str]] = []
    inside = False
    for raw in codeowners_text.splitlines():
        line = raw.strip()
        if line.startswith(BLOCK_BEGIN):
            inside = True
        elif line.startswith(BLOCK_END):
            inside = False
        elif inside and line.startswith(CONTENT_RULE + " "):
            parts = line.split(None, 2)
            if len(parts) == 3:
                rules.append((parts[1], parts[2]))
    return rules


CONTENT_SAMPLE = "#content-sample"


def parse_content_samples(codeowners_text: str | None) -> list[tuple[str, str]]:
    """`#content-sample <path> <changed line>` fixtures inside the block.

    Each sample is a changed line that MUST trip a `#content-match` rule. They
    are the repo-specific regression tests for those regexes, checked on every
    run (base + head) and by `--self-test` when run in a checkout.
    """
    if not codeowners_text:
        return []
    out: list[tuple[str, str]] = []
    inside = False
    for raw in codeowners_text.splitlines():
        line = raw.strip()
        if line.startswith(BLOCK_BEGIN):
            inside = True
        elif line.startswith(BLOCK_END):
            inside = False
        elif inside and line.startswith(CONTENT_SAMPLE + " "):
            parts = line.split(None, 2)
            if len(parts) == 3:
                out.append((parts[1].lstrip("/"), parts[2]))
    return out


def sample_problems(codeowners_text: str | None) -> list[str]:
    rules = parse_content_rules(codeowners_text)
    problems = []
    for path, sample in parse_content_samples(codeowners_text):
        if not content_hits([path], rules, lambda _p, line=sample: f"+{line}\n"):
            problems.append(f"#content-sample for {path} does not trip any #content-match rule: {sample}")
    return problems


def changed_lines(diff_text: str) -> list[str]:
    return [
        ln[1:]
        for ln in diff_text.splitlines()
        if ln[:1] in "+-" and not ln.startswith("+++") and not ln.startswith("---")
    ]


def content_hits(files: list[str], rules: list[tuple[str, str]], diff_for) -> list[str]:
    """Files whose changed lines match a content rule; diff_for(path) -> unified diff."""
    hits = []
    for path in files:
        for pattern, regex in rules:
            if pattern_to_regex(pattern).match(path) and any(
                re.search(regex, ln) for ln in changed_lines(diff_for(path))
            ):
                hits.append(f"{path} (changed lines match /{regex}/)")
                break
    return hits


def pattern_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a CODEOWNERS (gitignore-style) pattern to a regex over repo paths.

    Errs on the side of matching: for a guard, an over-match only asks for an
    impact section; an under-match lets a change through unreviewed.
    """
    pat = pattern
    dir_only = pat.endswith("/")
    pat = pat.rstrip("/")
    anchored = pat.startswith("/") or "/" in pat
    pat = pat.lstrip("/")

    out = []
    i = 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pat[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    body = "".join(out)
    prefix = "^" if anchored else "^(?:.*/)?"
    # `dir/*` matches only direct children in GitHub CODEOWNERS; everything
    # else also matches when it names a directory (its contents).
    if pattern.rstrip("/").endswith("/*") and not dir_only:
        suffix = "$"
    else:
        suffix = "(?:/.*)?$"
    return re.compile(prefix + body + suffix)


def matching_files(files: list[str], patterns: list[str]) -> list[str]:
    regexes = [pattern_to_regex(p) for p in patterns]
    return [f for f in files if any(r.match(f) for r in regexes)]


# ── PR body section ──────────────────────────────────────────────────────────

_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")


def impact_section(body: str | None) -> str | None:
    """Return the text of the `Credit approval impact` section, or None."""
    if not body:
        return None
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    lines = body.splitlines()
    for idx, line in enumerate(lines):
        m = _HEADING.match(line)
        if m and m.group(1).strip().lower().startswith(SECTION_TITLE.lower()):
            content = []
            for nxt in lines[idx + 1 :]:
                if _HEADING.match(nxt):
                    break
                content.append(nxt)
            # Drop unfilled template prompts ("- Before (...):" with nothing after
            # the colon) so an untouched PR template never passes.
            content = [c for c in content if not re.match(r"^\s*(?:[-*]\s*)?[^:]*:\s*$", c)]
            return "\n".join(content).strip()
    return None


def _strip_non_measurements(line: str) -> str:
    """Remove digits that are not measurements: PR refs, SHAs, dates, years."""
    line = re.sub(r"#\d+", "", line)
    line = re.sub(r"\b(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b", "", line)
    line = re.sub(r"\b\d{4}-\d{2}(-\d{2})?(T[\d:.]+Z?)?\b", "", line)
    line = re.sub(r"\b(19|20)\d{2}\b", "", line)
    return line


def _keyword_clauses(section: str) -> dict[str, list[str]]:
    """Split each line at every 'before'/'after' so each figure binds to ONE clause.

    "Before: 1 approved. After: unknown" yields before=["Before: 1 approved. "] and
    after=["After: unknown"], so the BEFORE figure cannot satisfy AFTER.
    """
    out: dict[str, list[str]] = {"before": [], "after": []}
    for line in section.splitlines():
        marks = list(re.finditer(r"\b(before|after)\b", line, re.I))
        for i, m in enumerate(marks):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(line)
            out[m.group(1).lower()].append(line[m.start() : end])
    return out


def section_problems(body: str | None) -> list[str]:
    section = impact_section(body)
    if section is None:
        return [f"PR body has no '## {SECTION_TITLE}' section."]
    problems = []
    text = section.lower()
    if len(re.sub(r"\s+", "", section)) < 80:
        problems.append(f"'{SECTION_TITLE}' section is too short to describe the change and its measurement.")
    # A measurement is a number: the line that says "before" and the line that
    # says "after" must each carry at least one figure (PR refs like #1093 do
    # not count). Keyword-only prose ("before prod we discussed...") fails.
    clauses = _keyword_clauses(section)
    for word in ("before", "after"):
        if not any(re.search(r"\d", _strip_non_measurements(c)) for c in clauses[word]):
            problems.append(
                f"'{SECTION_TITLE}' section must give a measured {word.upper()} value "
                f"(a line mentioning '{word}' with the figure, e.g. '{word.capitalize()}: 1,204 approved / 310 declined')."
            )
    if not re.search(r"\bprod(uction)?\b", text):
        problems.append(f"'{SECTION_TITLE}' section must say the measurement was taken on prod data.")
    return problems


# ── captain approval ─────────────────────────────────────────────────────────


# Bodies the QA bot always writes (hydra scripts/qa-pr-approve.sh brands every
# review "Muso QA Bot"). An APPROVED review carrying one is never the captain's.
BOT_REVIEW_MARKERS = ("muso qa bot", "hydra-qa", "<!-- qa-")


def is_bot_review(review: dict) -> bool:
    body = (review.get("body") or "").lower()
    return any(m in body for m in BOT_REVIEW_MARKERS)


def captain_approved(reviews: list[dict], captain: str, head_sha: str, author: str = "") -> tuple[bool, str]:
    """True when the captain's latest decisive review is APPROVED on head_sha.

    Deliberately no exemption for PRs authored by the captain account (Fable
    decision 2026-10-16, option b): those stay red and are admin-merged on
    Fable GO + QA GO + green CI with +15/+60 monitoring.
    """
    if author and author.lower() == captain.lower():
        return False, (
            f"PR authored by @{captain}: GitHub forbids self-approval, so this check stays red by design. "
            "Admin-merge only on Fable GO + QA GO + green CI, then monitor at +15/+60 min."
        )
    decisive = [
        r
        for r in reviews
        if (r.get("user") or {}).get("login", "").lower() == captain.lower()
        and r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED")
        and not (r.get("state") == "APPROVED" and is_bot_review(r))
    ]
    if not decisive:
        return False, f"@{captain} has not approved this PR."
    last = decisive[-1]
    if last["state"] != "APPROVED":
        return False, f"@{captain}'s latest review is {last['state']}, not APPROVED."
    if last.get("commit_id") != head_sha:
        return False, (
            f"@{captain} approved {str(last.get('commit_id'))[:12]}, but the PR head is now "
            f"{head_sha[:12]}; the new commits need a fresh approval."
        )
    return True, f"@{captain} approved head {head_sha[:12]}."


# ── git / GitHub I/O ─────────────────────────────────────────────────────────


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def git_show(sha: str, path: str) -> str | None:
    try:
        return git("show", f"{sha}:{path}")
    except subprocess.CalledProcessError:
        return None


def codeowners_at(sha: str) -> str | None:
    for path in CODEOWNERS_PATHS:
        text = git_show(sha, path)
        if text is not None:
            return text
    return None


class GitHub:
    def __init__(self, repo: str, token: str):
        self.repo = repo
        self.token = token

    def call(self, method: str, path: str, data: dict | None = None):
        url = path if path.startswith("https://") else f"https://api.github.com/repos/{self.repo}{path}"
        req = urllib.request.Request(url, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        payload = None
        if data is not None:
            payload = json.dumps(data).encode()
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, payload, timeout=30) as resp:
            raw = resp.read()
            link = resp.headers.get("Link", "")
        return (json.loads(raw) if raw else None), link

    def paginate(self, path: str) -> list:
        items: list = []
        sep = "&" if "?" in path else "?"
        url = f"{path}{sep}per_page=100"
        while url:
            page, link = self.call("GET", url)
            items.extend(page)
            m = re.search(r'<([^>]+)>;\s*rel="next"', link)
            url = m.group(1) if m else ""
        return items


def set_label(gh: GitHub, number: int, present: bool, current: list[str]) -> bool:
    """Returns False when a REQUIRED label could not be added.

    The label is what the QA bot's approve wrapper (hydra qa-pr-approve.sh,
    Guard 3d) reads, so a credit PR left unlabelled must not pass quietly.
    Failing to REMOVE a stale label is harmless (it only over-blocks): warn.
    """
    try:
        if present and LABEL not in current:
            gh.call("POST", f"/issues/{number}/labels", {"labels": [LABEL]})
            print(f"labelled PR with '{LABEL}'")
        elif not present and LABEL in current:
            gh.call("DELETE", f"/issues/{number}/labels/{urllib.parse.quote(LABEL)}")
            print(f"removed label '{LABEL}'")
    except urllib.error.HTTPError as exc:
        if present:
            print(f"::error::could not add label '{LABEL}' (HTTP {exc.code}); failing so the PR is not left unmarked")
            return False
        print(f"::warning::could not remove stale label '{LABEL}': HTTP {exc.code}")
    return True


def run(args: argparse.Namespace) -> int:
    gh = GitHub(args.repo, os.environ["GITHUB_TOKEN"])
    pr, _ = gh.call("GET", f"/pulls/{args.pr}")
    base_sha, head_sha = pr["base"]["sha"], pr["head"]["sha"]
    git("fetch", "--no-tags", "--quiet", "origin", base_sha, head_sha)
    merge_base = git("merge-base", base_sha, head_sha).strip()
    # --no-renames: a rename shows as delete(old) + add(new), so moving a
    # protected file to an unprotected name still trips the guard.
    files = [f for f in git("diff", "--no-renames", "--name-only", f"{merge_base}...{head_sha}").splitlines() if f]
    patterns = sorted(
        set(parse_block(codeowners_at(base_sha))) | set(parse_block(codeowners_at(head_sha)))
    )
    if args.codeowners_file:  # local testing: also apply a working-tree block
        patterns = sorted(set(patterns) | set(parse_block(open(args.codeowners_file).read())))
    if not patterns:
        print(f"::error::no '{BLOCK_BEGIN}' block found in CODEOWNERS at base or head")
        return 1
    texts = [codeowners_at(base_sha), codeowners_at(head_sha)]
    if args.codeowners_file:
        texts.append(open(args.codeowners_file).read())
    rules = sorted({r for t in texts for r in parse_content_rules(t)})
    sample_errs = sorted({p for t in texts for p in sample_problems(t)})
    if sample_errs:
        for p in sample_errs:
            print(f"::error::{p}")
        return 1
    hits = matching_files(files, patterns)
    hits += content_hits(
        [f for f in files if f not in hits],
        rules,
        lambda path: git("diff", "--no-renames", "-U0", f"{merge_base}...{head_sha}", "--", path),
    )
    labels = [lbl["name"] for lbl in pr.get("labels", [])]
    if args.dry_run:
        print(f"(dry run: label '{LABEL}' would be {'present' if hits else 'absent'})")
    elif not set_label(gh, args.pr, bool(hits), labels):
        return 1
    if not hits:
        print(f"PR touches no credit-approval path ({len(files)} files checked against {len(patterns)} patterns).")
        return 0

    print("PR touches credit-approval paths:")
    for f in hits:
        print(f"  - {f}")
    problems = section_problems(pr.get("body"))
    reviews = gh.paginate(f"/pulls/{args.pr}/reviews")
    ok, why = captain_approved(reviews, args.captain, head_sha, (pr.get("user") or {}).get("login", ""))
    print(why)
    if not ok:
        problems.append(why)
    for p in problems:
        print(f"::error::{p}")
    if problems:
        print(
            f"\nA credit-approval change needs (a) a '## {SECTION_TITLE}' section in the PR body: what "
            "changes, plus a before/after measurement on prod data (e.g. approved/declined counts over the "
            f"same window), and (b) @{args.captain}'s approval of the current head commit."
        )
        return 1
    return 0


# ── self-test ────────────────────────────────────────────────────────────────


def self_test() -> int:
    import unittest

    class T(unittest.TestCase):
        def m(self, pattern, path):
            return bool(pattern_to_regex(pattern).match(path))

        def test_patterns(self):
            self.assertTrue(self.m("/processors/raw/validation/", "processors/raw/validation/a.py"))
            self.assertFalse(self.m("/processors/raw/validation/", "x/processors/raw/validation/a.py"))
            self.assertTrue(self.m("*credit*valid*", "deep/dir/user_credit_validator.py"))
            self.assertTrue(self.m("*credit*valid*", "tests/x_credit_validation_test.py"))
            self.assertFalse(self.m("*credit*valid*", "processors/credit.py"))
            self.assertTrue(self.m("/src/apis/**/credit-request*/", "src/apis/_admin/credit-requests/update.js"))
            self.assertTrue(self.m("/src/apis/**/credit-request*/", "src/apis/credit-requests/x/y.js"))
            self.assertFalse(self.m("/src/apis/**/credit-request*/", "src/services/credit-requests/x.js"))
            self.assertTrue(self.m("**/muso-ops-fraud/", "skills-all/muso-ops-fraud/SKILL.md"))
            self.assertTrue(self.m("/cron-jobs.json", "cron-jobs.json"))
            self.assertFalse(self.m("/cron-jobs.json", "a/cron-jobs.json"))
            self.assertTrue(self.m("/src/apis/_admin/profile/deleteCredits*", "src/apis/_admin/profile/deleteCredits.test.js"))
            self.assertTrue(self.m("/docs/*", "docs/a.md"))
            self.assertFalse(self.m("/docs/*", "docs/sub/a.md"))
            self.assertTrue(self.m("/.github/CODEOWNERS", ".github/CODEOWNERS"))

        def test_block(self):
            text = "* @x\n# >>> credit-approval\n# c\n/a/ @x @adk47\n\nb.py @adk47\n# <<< credit-approval\n/z @y\n"
            self.assertEqual(parse_block(text), ["/a/", "b.py"])
            self.assertEqual(parse_block(None), [])
            self.assertEqual(matching_files(["a/q", "c/b.py", "z"], parse_block(text)), ["a/q", "c/b.py"])

        def test_section(self):
            good = (
                "## Changes\n- x\n\n## Credit approval impact\n<!-- placeholder before after prod -->\n"
                "Tightens the low-risk rule. Before: 1,204 approved / 310 declined on prod, 7d. "
                "After (replayed on the same prod window): 1,050 approved / 464 declined.\n## Tests\nok\n"
            )
            self.assertEqual(section_problems(good), [])
            self.assertTrue(section_problems("## Changes\n- x\n"))
            only_comment = "## Credit approval impact\n<!-- before after prod measurement goes here -->\n## X\n"
            self.assertTrue(section_problems(only_comment))
            template = (
                "### Credit approval impact\n\n- What changes in credit approval / validation / charts:\n"
                "- Before (measured on prod data, window + query):\n- After (same window, same query):\n"
            )
            self.assertTrue(section_problems(template))
            filled = template.replace("charts:", "charts: low-risk rule now also requires popularity >= 30") \
                .replace("query):\n-", "query): 7d prod, 1,204 approved / 310 declined\n-") \
                .replace("query):\n", "query): 1,050 approved / 464 declined\n")
            self.assertEqual(section_problems(filled), [])
            keyword_only = (
                "## Credit approval impact\nBefore prod, everyone should discuss the system with care. "
                "After prod, everyone should continue discussing the system with care; no data is supplied.\n"
            )
            self.assertTrue(section_problems(keyword_only))
            date_only = (
                "## Credit approval impact\nBefore production in 2026, we discussed the credit approval process "
                "extensively but collected no result. After production in 2027, we will continue discussing it; "
                "no measurements have been collected for this change (since 2026-10-11, sha 0acba869).\n"
            )
            self.assertTrue(section_problems(date_only))
            big = "## Credit approval impact\nRaises the validator threshold; replayed on prod data, same 7d window.\nBefore: 57400000 approved / 0 declined.\nAfter: 1204 approved / 56196000 declined.\n"
            self.assertEqual(section_problems(big), [])
            shared_figure = (
                "## Credit approval impact\nTightens the low-risk rule, measured on prod data over a 7d window.\n"
                "Before: 1 approved. After: unknown; no replay or measurement was performed.\n"
            )
            self.assertTrue(any("AFTER" in p for p in section_problems(shared_figure)))
            pr_ref_only = (
                "## Credit approval impact\nChanges the rule from #1093 in the validator on prod data. "
                "Before: see #1093. After: see #1093 again, nothing else measured here.\n"
            )
            self.assertTrue(section_problems(pr_ref_only))
            no_prod = "## Credit approval impact\n" + "Before: 10 approved. After: 8 approved. " * 3
            self.assertTrue(any("prod" in p for p in section_problems(no_prod)))

        def test_content_rules(self):
            text = (
                "# >>> credit-approval\n/a/ @x\n#content-match /src/apis/index.w.js /admin/credit-requests|claiming\n"
                "# <<< credit-approval\n#content-match /outside x\n"
            )
            rules = parse_content_rules(text)
            self.assertEqual(rules, [("/src/apis/index.w.js", "/admin/credit-requests|claiming")])
            self.assertEqual(parse_block(text), ["/a/"])
            diffs = {
                "src/apis/index.w.js": "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-router.route('/admin/credit-requests').put(A)\n+router.route('/admin/credit-requests').put(B)\n",
            }
            self.assertEqual(len(content_hits(["src/apis/index.w.js"], rules, diffs.get)), 1)
            other = {"src/apis/index.w.js": "@@ -1 +1 @@\n-router.route('/x').get(a)\n+router.route('/x').get(b)\n"}
            self.assertEqual(content_hits(["src/apis/index.w.js"], rules, other.get), [])

        def test_content_samples(self):
            text = (
                "# >>> credit-approval\n#content-match /src/r.js admin/credit|\\bCREDIT_[A-Z_]+\n"
                "#content-sample /src/r.js const CREDIT_AUTOMATION_ROUTE_ROLES = ['admin', 'user'];\n"
                "# <<< credit-approval\n"
            )
            self.assertEqual(sample_problems(text), [])
            bad = text.replace("CREDIT_AUTOMATION_ROUTE_ROLES", "ROUTE_ROLES")
            self.assertEqual(len(sample_problems(bad)), 1)
            # the repo's own block, when run from a checkout
            for path in CODEOWNERS_PATHS:
                if os.path.exists(path):
                    self.assertEqual(sample_problems(open(path).read()), [], path)
                    break

        def test_approval(self):
            def rv(login, state, sha):
                return {"user": {"login": login}, "state": state, "commit_id": sha}

            self.assertFalse(captain_approved([], "adk47", "h")[0])
            self.assertFalse(captain_approved([rv("nsollazzo", "APPROVED", "h")], "adk47", "h")[0])
            self.assertTrue(captain_approved([rv("adk47", "APPROVED", "h")], "adk47", "h")[0])
            self.assertTrue(captain_approved([rv("adk47", "APPROVED", "h"), rv("adk47", "COMMENTED", "h")], "adk47", "h")[0])
            self.assertFalse(captain_approved([rv("adk47", "APPROVED", "old")], "adk47", "h")[0])
            self.assertFalse(captain_approved([rv("adk47", "APPROVED", "h"), rv("adk47", "DISMISSED", "h")], "adk47", "h")[0])
            self.assertFalse(captain_approved([rv("adk47", "APPROVED", "h"), rv("adk47", "CHANGES_REQUESTED", "h")], "adk47", "h")[0])
            self.assertFalse(captain_approved([], "adk47", "h", author="ADK47")[0])
            bot = rv("adk47", "APPROVED", "h")
            bot["body"] = "🤖 Approved by Muso QA Bot (automated review): CI is green and there are no blocking findings."
            self.assertFalse(captain_approved([bot], "adk47", "h", author="nsollazzo")[0])
            self.assertTrue(captain_approved([rv("adk47", "APPROVED", "h"), bot], "adk47", "h", author="nsollazzo")[0])
            self.assertFalse(captain_approved([rv("adk47", "APPROVED", "h")], "adk47", "h", author="adk47")[0])
            self.assertTrue(captain_approved([rv("adk47", "APPROVED", "h")], "adk47", "h", author="nsollazzo")[0])
            self.assertFalse(captain_approved([], "adk47", "h", author="nsollazzo")[0])

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(T))
    return 0 if result.wasSuccessful() else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="read-only: never touch labels")
    ap.add_argument("--codeowners-file", help="testing: also read the block from this file")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    ap.add_argument("--pr", type=int)
    ap.add_argument("--captain", default=os.environ.get("CAPTAIN_LOGIN", "adk47"))
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.repo or not args.pr:
        ap.error("--repo and --pr are required")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
