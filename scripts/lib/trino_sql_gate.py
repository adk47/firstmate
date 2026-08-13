#!/usr/bin/env python3
"""trino_sql_gate.py — Layer B of scripts/check-trino-sql.sh: live EXPLAIN
(TYPE VALIDATE) compilation of every Trino SQL statement extracted by
scripts/lib/trino_sql_extract.py, ratcheted against a committed baseline.

Unlike trino_sql_extract.py (pure/offline), this module shells out: it
substitutes declared placeholders, rewrites legacy Athena names via
trino-query.sh's dry-run hook, and sends each statement to a live
trino-coordinator pod via `kubectl exec`.

THE SAFETY INVARIANT (non-negotiable — see scripts/check-trino-sql.sh header):
the Trino CLI splits `--execute` input on ';' and only the FIRST statement
keeps an EXPLAIN prefix — the rest EXECUTE for real. Every live call in this
module funnels through _send_explain_validate(), which:
  1. builds the payload as "EXPLAIN (TYPE VALIDATE) " + one statement,
  2. asserts the payload starts with that literal prefix before sending
     anything (violation -> SafetyViolation, caller must treat as exit 2),
  3. refuses a payload containing ';' outside the EXPLAIN prefix itself
     (a second, unprefixed statement riding along),
  4. wraps the subprocess call in a hard timeout (default 120s).
No other function in this file invokes kubectl.

Exit codes (see main()):
  0 — clean: no undeclared failures, no stale baseline/substitution entries
  1 — gate finding: new unbaselined failure, stale baseline entry, stale
      substitution entry, or an undeclared/unsubstitutable placeholder (a
      SKIP always costs — "skipping is never free")
  2 — cannot run: Trino unreachable, malformed baseline/substitutions file,
      zero blocks extracted on a full scan, or a safety-invariant violation
"""
from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
from scripts.lib import trino_sql_extract as tse  # noqa: E402

EXPLAIN_PREFIX = "EXPLAIN (TYPE VALIDATE) "

# The Trino CLI's compilation-failure signature, e.g.
#   Query 20260806_134403_59815_j792t failed: line 1:32: Column 'u.country' ...
# Captured from real node-8 runs. Anything else on a non-zero exit is a
# transport/launch error and must NOT be reported as a SQL verdict.
_TRINO_QUERY_FAILURE_RE = re.compile(r"^Query \S+ failed:", re.MULTILINE)

_QUOTED_RE = re.compile(r"'[^']*'")
_PLACEHOLDER_RE = re.compile(
    r"\$\{[^}]*\}"       # ${VAR}
    r"|<[^>]{1,60}>"     # <var>
    r"|%s"               # %s
    r"|(?<![A-Za-z0-9_])\?(?![A-Za-z0-9_])"  # bare ?
)


def _has_top_level_semicolon(sql: str) -> bool:
    """True if `sql` has a ';' OUTSIDE a string/quoted-identifier/comment.

    Delegates to tse.has_top_level_semicolon, which detects the DELIMITER
    itself. This used to ask `len(tse.split_statements(sql)) > 1`, but that
    splitter drops empty statements, so `; SELECT * FROM hive.x` yielded one
    statement and the check returned False — letting a payload with a real
    top-level ';' through to the Trino CLI, which would have executed the
    trailing statement without the EXPLAIN prefix. A naive substring check is
    still wrong in the other direction (a literal ';' inside a `-- ...`
    comment is a real case in skills-all/muso-query-writer/reference.md), so
    the state machine remains necessary.
    """
    return tse.has_top_level_semicolon(sql)


class SafetyViolation(Exception):
    """Raised when a payload fails the pre-send EXPLAIN-prefix / no-';' check.
    Callers must treat this as exit 2 and MUST NOT have sent anything."""


class GateUnreachable(Exception):
    """Trino/kubectl unreachable or a live call hard-errored/timed out."""


# --------------------------------------------------------- substitutions --

def load_substitutions(path: Path) -> dict:
    """Parses '<TOKEN> -- <replacement> -- <reason>' lines, same 3-field
    shape as .dead-infra-allowlist.txt. Blank lines and '#' comments ignored."""
    subs = {}
    if not path.exists():
        raise ValueError(f"missing substitutions file: {path}")
    for lineno, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(" -- ")
        if len(parts) < 3:
            raise ValueError(f"{path}:{lineno}: malformed line (need 'TOKEN -- replacement -- reason'): {raw}")
        token = parts[0].strip()
        replacement = parts[1].strip()
        reason = " -- ".join(parts[2:]).strip()
        if not token or not reason:
            raise ValueError(f"{path}:{lineno}: malformed line (empty token/reason): {raw}")
        subs[token] = replacement
    return subs


def apply_substitutions(sql: str, subs: dict) -> tuple:
    """Returns (substituted_sql, tokens_used: set)."""
    used = set()
    out = sql
    for token, replacement in subs.items():
        if token in out:
            out = out.replace(token, replacement)
            used.add(token)
    return out, used


def find_unsubstitutable_placeholder(sql: str):
    """Returns the first unsubstitutable placeholder-shaped token found
    OUTSIDE single-quoted string literals and OUTSIDE comments, or None.
    Placeholders inside a string literal ('USER_EMAIL', '<PROFILE_ID>') are
    valid varchar literals and need no substitution (per spec)."""
    stripped = tse.normalize_sql(sql)  # strips comments, collapses whitespace
    no_strings = _QUOTED_RE.sub("", stripped)
    m = _PLACEHOLDER_RE.search(no_strings)
    return m.group(0) if m else None


# --------------------------------------------------------- runner rewrite --

def rewrite_legacy_names(sql: str, trino_query_sh: Path) -> str:
    """Runner-aware rewrite: pipes sql through trino-query.sh's own dry-run
    hook (TRINO_REWRITE_ONLY=1) so the legacy-Athena-name sed lives in exactly
    one place. Only called for runner == 'trino-query.sh' blocks."""
    proc = subprocess.run(
        ["bash", str(trino_query_sh), sql],
        env={"TRINO_REWRITE_ONLY": "1", "PATH": "/usr/bin:/bin:/usr/local/bin"},
        capture_output=True,
        text=True,
        timeout=30,
    )
    if proc.returncode != 0:
        raise GateUnreachable(f"trino-query.sh dry-run rewrite failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return proc.stdout.rstrip("\n")


# --------------------------------------------------------------- live call --

def _find_pod(namespace: str) -> str:
    try:
        proc = subprocess.run(
            ["kubectl", "get", "pods", "-n", namespace, "-l", "app=trino,component=coordinator",
             "-o", "jsonpath={.items[0].metadata.name}"],
            capture_output=True, text=True, timeout=30,
        )
        pod = proc.stdout.strip()
        if pod:
            return pod
    except (subprocess.SubprocessError, OSError) as exc:
        raise GateUnreachable(f"kubectl get pods failed: {exc}") from exc
    try:
        proc = subprocess.run(
            ["kubectl", "get", "pods", "-n", namespace,
             "-o", "jsonpath={.items[?(@.metadata.name)].metadata.name}"],
            capture_output=True, text=True, timeout=30,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        raise GateUnreachable(f"kubectl get pods (fallback) failed: {exc}") from exc
    for name in proc.stdout.split():
        if name.startswith("trino-coordinator-"):
            return name
    raise GateUnreachable(f"no trino-coordinator pod found in namespace={namespace}")


def _send_explain_validate(sql: str, namespace: str, session: str, source: str,
                            timeout_s: int = 120) -> tuple:
    """THE single choke point for every live call this module makes. Returns
    (ok: bool, detail: str). Raises SafetyViolation if the payload isn't a
    clean single EXPLAIN-VALIDATE statement — and sends NOTHING in that case.
    Raises GateUnreachable on pod-lookup failure, subprocess error, or
    timeout (timeout is NEVER treated as a pass)."""
    payload = EXPLAIN_PREFIX + sql
    if not payload.startswith(EXPLAIN_PREFIX):
        raise SafetyViolation("payload does not start with the EXPLAIN (TYPE VALIDATE) prefix")
    if _has_top_level_semicolon(sql):
        raise SafetyViolation("payload contains a top-level ';' after the EXPLAIN prefix — refusing to risk a second, unprefixed statement executing")

    pod = _find_pod(namespace)
    cmd = [
        "kubectl", "exec", "-n", namespace, pod, "--",
        "trino",
        "--session", session,
        "--source", source,
        "--execute", payload,
        "--output-format", "CSV",
    ]
    try:
        proc = subprocess.run(["timeout", str(timeout_s), *cmd], capture_output=True, text=True)
    except (subprocess.SubprocessError, OSError) as exc:
        raise GateUnreachable(f"kubectl exec failed to launch: {exc}") from exc
    if proc.returncode == 124:
        raise GateUnreachable(f"EXPLAIN VALIDATE timed out after {timeout_s}s")
    if proc.returncode == 0:
        return True, proc.stdout.strip()
    detail = (proc.stderr or proc.stdout).strip()
    # FAIL CLOSED on transport errors. Only a recognized Trino COMPILATION
    # failure is a SQL verdict; a kubectl/container/transport error (e.g.
    # `unable to upgrade connection`) also exits non-zero, and treating it as
    # ok=False let the baseline absorb it — a total Trino outage would then
    # report every baselined statement as "baselined-fail" and exit 0 having
    # validated nothing at all.
    if not _TRINO_QUERY_FAILURE_RE.search(detail):
        raise GateUnreachable(
            f"kubectl/trino transport error (rc={proc.returncode}), not a SQL "
            f"compilation failure: {detail[:300]}"
        )
    return False, detail


def send_raw(payload: str, namespace: str, session: str, source: str, timeout_s: int = 120):
    """Debug/test-only entrypoint (scripts/check-trino-sql.sh --send-raw):
    sends `payload` through the SAME safety-checked function real blocks use,
    with no EXPLAIN-prefix construction — exercises the invariant directly
    against a deliberately unsafe payload."""
    if not payload.startswith(EXPLAIN_PREFIX):
        raise SafetyViolation("payload does not start with the EXPLAIN (TYPE VALIDATE) prefix")
    if _has_top_level_semicolon(payload[len(EXPLAIN_PREFIX):]):
        raise SafetyViolation("payload contains a top-level ';' after the EXPLAIN prefix")
    pod = _find_pod(namespace)
    cmd = [
        "kubectl", "exec", "-n", namespace, pod, "--",
        "trino", "--session", session, "--source", source,
        "--execute", payload, "--output-format", "CSV",
    ]
    proc = subprocess.run(["timeout", str(timeout_s), *cmd], capture_output=True, text=True)
    return proc.returncode == 0, (proc.stdout if proc.returncode == 0 else proc.stderr).strip()


# ---------------------------------------------------------------- baseline --

def normalized_hash(sql: str) -> str:
    return hashlib.sha1(tse.normalize_sql(sql).encode("utf-8")).hexdigest()


def load_baseline(path: Path) -> dict:
    """Parses '<sha1> -- <file>:<line> -- <snippet>' lines. Returns
    {sha1: (hint_file, hint_line, snippet)}."""
    entries = {}
    if not path.exists():
        return entries
    for lineno, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(" -- ", 2)
        if len(parts) != 3:
            raise ValueError(f"{path}:{lineno}: malformed baseline line: {raw}")
        sha1, hint, snippet = parts
        sha1 = sha1.strip()
        if ":" in hint:
            hint_file, hint_line = hint.rsplit(":", 1)
        else:
            hint_file, hint_line = hint, ""
        entries[sha1] = (hint_file.strip(), hint_line.strip(), snippet.strip())
    return entries


def write_baseline(path: Path, entries: dict) -> None:
    lines = [
        "# .trino-sql-baseline.txt — ratchet for scripts/check-trino-sql.sh Layer B.",
        "#",
        "# Format: <sha1-of-normalized-sql> -- <file>:<line> -- <first ~80 chars of SQL>",
        "#",
        "# Keyed on the sha1 of the WHITESPACE-COLLAPSED, COMMENT-STRIPPED statement —",
        "# NOT file:line — so re-indenting a query doesn't churn this file, but editing",
        "# it does (a new hash). Semantics enforced by check-trino-sql.sh:",
        "#   failing + hash present here      -> BASELINED, exit 0 contribution",
        "#   failing + hash absent            -> FAIL (the actual gate)",
        "#   passing + hash present here      -> FAIL 'stale baseline entry — remove it'",
        "#   hash present here but not found  -> FAIL 'stale baseline entry — remove it'",
        "#     among this run's extracted statements (only checked for in-scope files)",
        "# Generated from the first full run (99-of-169 SQL-statement sweep behind PR",
        "# #794 / the Trino SQL staleness gate). The file can only shrink.",
    ]
    for sha1 in sorted(entries):
        hint_file, hint_line, snippet = entries[sha1]
        hint = f"{hint_file}:{hint_line}" if hint_line else hint_file
        lines.append(f"{sha1} -- {hint} -- {snippet}")
    path.write_text("\n".join(lines) + "\n")


# ------------------------------------------------------------------- main --

def _snippet(sql: str, n: int = 80) -> str:
    flat = tse.normalize_sql(sql)
    return flat[:n] + ("…" if len(flat) > n else "")


def run_gate(files, root: Path, baseline_path: Path, subs_path: Path,
             namespace: str, session: str, source: str, trino_query_sh: Path,
             generate_baseline: bool = False, full_scan: bool = False) -> int:
    subs = load_substitutions(subs_path)
    used_tokens = set()

    if full_scan:
        files = list(tse.discover_paths(root))
    result = tse.extract_paths(root, files)
    for skipped in result.skipped_declared:
        print(f"SKIPPED (declared): {skipped.file}:{skipped.line}: {skipped.reason}")

    if not result.blocks:
        if not files:
            print("No Trino-SQL-relevant files in scope — nothing to check.")
            return 0
        # Zero blocks from a non-empty scope has TWO causes needing OPPOSITE
        # answers, and collapsing them into one refusal reddened honest PRs:
        # the scope is every changed skills-all/*.{md,sh}, so editing one
        # SQL-free doc (e.g. a SKILL.md that is pure prose) landed here and
        # exited 2 with "refusing to pass vacuously" — a gate failure reported
        # against a PR that has no SQL to be stale.
        #
        #   (a) nothing in scope CARRIES SQL      -> zero blocks is the truth; pass.
        #   (b) something carries SQL markers but
        #       extraction still yielded nothing  -> the extractor is broken; REFUSE.
        #
        # Discriminated with the extractor's OWN markers, so this can never
        # drift into disagreeing with what extraction actually looks for.
        # A declared skip legitimately explains an empty result FOR THE FILE THAT
        # DECLARED IT — and only that file. Returning 0 as soon as any skip
        # existed (the first cut of this fix) let one file's valid declared-skip
        # mask a sibling file that carries SQL markers and yields no block, i.e.
        # exactly the extractor-broken case this branch exists to refuse. So the
        # scan runs over EVERY file first and passes only when every SQL-bearing
        # file is accounted for.
        skipped_files = {s.file for s in result.skipped_declared}
        sql_bearing = []
        for rel in files:
            try:
                text = (root / rel).read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                # Fail closed: an unreadable file is not evidence of "no SQL".
                print(f"Unreadable file in scope {rel}: {exc} — refusing to pass vacuously.",
                      file=sys.stderr)
                return 2
            for line in text.splitlines():
                # A ```sql fence is unconditionally SQL. A ```bash/shell/sh
                # fence is NOT — the extractor opens those only to look for a
                # trino-query.sh / `muso query` invocation inside, so a skill
                # full of ordinary bash examples carries no SQL. Matching every
                # fence here is what made the first cut of this fix still refuse
                # a pure-prose SKILL.md.
                fence = tse.FENCE_OPEN_RE.match(line)
                if fence and fence.group(1).lower() == "sql":
                    sql_bearing.append(rel)
                    break
                # Mirror extract_bash_blob: a `#`-commented mention of
                # trino-query.sh is documentation, not an invocation.
                if line.lstrip().startswith("#"):
                    continue
                if tse._INVOKE_RE.search(line):
                    sql_bearing.append(rel)
                    break
        # A SQL-bearing file is accounted for only if IT declared the skip.
        unaccounted = [f for f in sql_bearing if f not in skipped_files]
        if not unaccounted:
            if sql_bearing:
                print(f"All SQL in scope ({len(sql_bearing)} file(s)) is declared-skipped "
                      "— nothing left to compile.")
            else:
                print(f"No SQL in the {len(files)} changed file(s) in scope — nothing to compile.")
            return 0
        print("Extracted zero SQL blocks from files that DO carry SQL markers "
              f"({', '.join(unaccounted[:5])}) — extraction is broken, not the scope; "
              "refusing to pass vacuously.", file=sys.stderr)
        return 2

    exit_code = 0
    skip_count = 0
    # One record PER OCCURRENCE — deliberately NOT keyed by hash. Identical raw
    # SQL can validate differently depending on the runner: a `trino-query.sh`
    # block goes through rewrite_legacy_names, a bare ```sql fence does not, so
    # one occurrence can pass while the other fails. Keying by hash let whichever
    # block was visited last overwrite the other, meaning a later PASSING
    # occurrence could hide a real failure and turn the whole run green. The
    # hash is still computed, but it is used for baseline LOOKUP only.
    run_results = []  # list of (hash, ok, file, line, sql, detail)
    scanned_files = {f for f in files}

    for block in result.blocks:
        try:
            sql = block.sql
            if block.runner == "trino-query.sh":
                sql = rewrite_legacy_names(sql, trino_query_sh)
        except GateUnreachable as exc:
            print(f"ERROR: {block.file}:{block.line}: {exc}", file=sys.stderr)
            return 2

        placeholder = find_unsubstitutable_placeholder(sql)
        substituted, used = apply_substitutions(sql, subs)
        used_tokens |= used
        if placeholder is not None:
            still_placeholder = find_unsubstitutable_placeholder(substituted)
            if still_placeholder is not None:
                print(f"SKIP {block.file}:{block.line}: unsubstitutable placeholder {still_placeholder}")
                skip_count += 1
                continue
        sql = substituted

        try:
            ok, detail = _send_explain_validate(sql, namespace, session, source)
        except SafetyViolation as exc:
            print(f"SAFETY VIOLATION: {block.file}:{block.line}: {exc}", file=sys.stderr)
            return 2
        except GateUnreachable as exc:
            print(f"ERROR: {block.file}:{block.line}: {exc}", file=sys.stderr)
            return 2

        run_results.append(
            (normalized_hash(block.sql), ok, block.file, block.line, block.sql, detail)
        )

    if generate_baseline:
        entries = {
            h: (f, str(ln), _snippet(sql))
            for h, ok, f, ln, sql, _detail in run_results
            if not ok
        }
        write_baseline(baseline_path, entries)
        print(f"Generated baseline: {len(entries)} failing statement(s) -> {baseline_path}")
        return 0

    baseline = load_baseline(baseline_path)

    # A hash can now legitimately appear more than once, so a baseline entry is
    # stale only when EVERY occurrence of it passes — aggregate before judging,
    # or a hash that still fails somewhere gets reported as stale off the back
    # of a passing twin.
    all_passed = {}
    for h, ok, *_rest in run_results:
        all_passed[h] = all_passed.get(h, True) and ok

    pass_count = 0
    baselined_count = 0
    for h, ok, f, ln, sql, detail in sorted(run_results, key=lambda r: (r[2], r[3])):
        if ok:
            pass_count += 1
            continue
        if h in baseline:
            baselined_count += 1
            continue
        print(f"FAIL {f}:{ln}: {_snippet(sql)}")
        print(f"      {detail.splitlines()[0] if detail else '(no detail)'}")
        exit_code = 1

    for h in sorted(h for h, passed in all_passed.items() if passed and h in baseline):
        hint_file, hint_line, _snip = baseline[h]
        print(f"FAIL {hint_file}:{hint_line}: baseline entry {h} now PASSES — stale baseline entry, remove it")
        exit_code = 1

    for h, (hint_file, hint_line, snippet) in baseline.items():
        if h in all_passed:
            continue
        if hint_file in scanned_files:
            print(f"FAIL: baseline entry {h} ({hint_file}:{hint_line}: {snippet}) matches no statement extracted this run — stale, remove it")
            exit_code = 1

    if not generate_baseline and full_scan:
        for token in subs:
            if token not in used_tokens:
                print(f"FAIL: substitution entry '{token}' matches nothing — stale entry, remove it")
                exit_code = 1

    if skip_count:
        exit_code = max(exit_code, 1)

    print(f"Trino SQL gate (Layer B): {pass_count} pass, {baselined_count} baselined-fail, "
          f"{len(run_results) - pass_count - baselined_count} new-fail, {skip_count} skipped")
    return exit_code


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repo root")
    parser.add_argument("--baseline", default=".trino-sql-baseline.txt")
    parser.add_argument("--substitutions", default=".trino-sql-substitutions.txt")
    parser.add_argument("--namespace", default="data-processing")
    parser.add_argument("--session", default="query_max_execution_time=10s")
    parser.add_argument("--source", default="hydra-ci-trino-sql-gate")
    parser.add_argument("--generate-baseline", action="store_true")
    parser.add_argument("--full", action="store_true",
                         help="scan the whole skills-all/ tree instead of the given file list; "
                              "required for the stale-baseline/stale-substitution checks to run globally")
    parser.add_argument("--send-raw", default=None,
                         help="debug/test-only: send this exact payload through the safety-checked sender")
    parser.add_argument("files", nargs="*", help="repo-relative file paths to scan")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()

    if args.send_raw is not None:
        try:
            ok, detail = send_raw(args.send_raw, args.namespace, args.session, args.source)
        except SafetyViolation as exc:
            print(f"SAFETY VIOLATION: {exc}", file=sys.stderr)
            return 2
        except GateUnreachable as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2
        print(detail)
        return 0 if ok else 1

    trino_query_sh = root / "scripts" / "trino-query.sh"
    try:
        return run_gate(
            files=args.files,
            root=root,
            baseline_path=root / args.baseline if not Path(args.baseline).is_absolute() else Path(args.baseline),
            subs_path=root / args.substitutions if not Path(args.substitutions).is_absolute() else Path(args.substitutions),
            namespace=args.namespace,
            session=args.session,
            source=args.source,
            trino_query_sh=trino_query_sh,
            generate_baseline=args.generate_baseline,
            full_scan=args.full,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
