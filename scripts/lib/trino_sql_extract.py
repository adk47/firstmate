#!/usr/bin/env python3
"""trino_sql_extract.py — pure/offline extraction of Trino SQL statements from
agent-facing content, for scripts/check-trino-sql.sh (the CI gate that stops
stale Trino SQL from shipping in skills; see PR #794 / the 99-of-169-fail sweep).

Precedent: scripts/lib/detect-store-only-crons.py — a pure Python helper with
no network/subprocess side effects, driven by a bash wrapper.

Extraction sources:
  - ```sql fences in skills-all/**/*.md            (runner=None, "bare")
  - ```bash fences invoking trino-query.sh / `muso query` (runner="trino-query.sh"
    or "muso-query")
  - .sh files: the same two invocation shapes, scanned over the raw file text

Deliberately OUT of scope: skills-all/muso-query-writer/saved-queries/** (258
files of bare legacy-named queries — a known, separately-tracked debt pile,
not this gate's job). Callers must exclude it explicitly (see EXCLUDED_DIRS)
so the exclusion is visible, not silent.

Statement splitting uses a real state machine (normal / single-quoted /
double-quoted-identifier / `--` line comment / `/* */` block comment) and
splits on `;` ONLY in the `normal` state — never inside a string, quoted
identifier, or comment. This matters because ~19 fences in skills-all/ are
multi-statement (numbered walkthroughs, BAD/GOOD example pairs) and 14 contain
deliberate anti-example queries; the caller (check-trino-sql.sh) is
responsible for sending each returned statement as its OWN EXPLAIN VALIDATE
invocation, never re-joined with `;`.

No network, no subprocess, no filesystem writes — this module only reads
paths it's given and returns data. Fully unit-testable in isolation
(tests/test_trino_sql_extract.py).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Optional

# Path (as a POSIX-style relative-to-repo-root string) prefixes this module
# refuses to extract from. Callers should still print a visible "excluded"
# notice — this module just never emits blocks for them.
EXCLUDED_DIRS = (
    "skills-all/muso-query-writer/saved-queries/",
)

# HTML-comment marker that declares a fence as non-Trino SQL (e.g. Postgres
# DDL like `CREATE ROLE` / `GRANT`). Must appear on its own line immediately
# above the opening ``` fence. Example:
#   <!-- trino-sql-gate: skip (postgres DDL, not Trino) -->
#   ```sql
#   CREATE ROLE ...
#   ```
SKIP_MARKER_RE = re.compile(r"^\s*<!--\s*trino-sql-gate:\s*skip\s*(?:\((?P<reason>[^)]*)\))?\s*-->\s*$")

FENCE_OPEN_RE = re.compile(r"^```(sql|bash|shell|sh)\s*$", re.IGNORECASE)
FENCE_CLOSE_RE = re.compile(r"^```\s*$")


@dataclass
class SqlBlock:
    """One extracted SQL statement, ready to hand to EXPLAIN (TYPE VALIDATE)."""

    file: str          # path as given to extract_file (repo-relative)
    line: int           # 1-based line number of the statement's first line
    sql: str            # the statement text (no trailing ';')
    runner: Optional[str]  # "trino-query.sh" | "muso-query" | None (bare ```sql)


@dataclass
class SkippedDeclared:
    """A ```sql/```bash fence explicitly opted out via the skip marker."""

    file: str
    line: int
    reason: str


@dataclass
class ExtractResult:
    blocks: list = field(default_factory=list)         # list[SqlBlock]
    skipped_declared: list = field(default_factory=list)  # list[SkippedDeclared]


# ------------------------------------------------------------- statement split --

def split_statements(sql_text: str, start_line: int = 1) -> list:
    """Split sql_text on top-level ';' only. Returns list of (line, statement)
    with statement text stripped of leading/trailing whitespace and the
    trailing ';' removed. Empty statements (e.g. a trailing ';' with nothing
    after it) are dropped.

    States: normal, single ('...'), dquote ("..." — a quoted identifier in
    Trino/ANSI SQL, not a string literal, but the same escaping applies for
    our purposes: no ';' splitting inside it), line comment (-- ...), block
    comment (/* ... */). Splitting happens ONLY in `normal`.
    """
    statements = []
    buf = []
    line = start_line
    stmt_start_line = start_line
    state = "normal"
    i = 0
    n = len(sql_text)
    while i < n:
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < n else ""

        if ch == "\n":
            line += 1

        if state == "normal":
            if ch == "'":
                state = "single"
                buf.append(ch)
            elif ch == '"':
                state = "dquote"
                buf.append(ch)
            elif ch == "-" and nxt == "-":
                state = "linecomment"
                buf.append(ch)
                buf.append(nxt)
                i += 1
            elif ch == "/" and nxt == "*":
                state = "blockcomment"
                buf.append(ch)
                buf.append(nxt)
                i += 1
            elif ch == ";":
                stmt = "".join(buf).strip()
                if stmt:
                    statements.append((stmt_start_line, stmt))
                buf = []
                stmt_start_line = line
            else:
                buf.append(ch)
        elif state == "single":
            buf.append(ch)
            if ch == "'":
                if nxt == "'":  # escaped '' inside a string literal
                    buf.append(nxt)
                    i += 1
                else:
                    state = "normal"
        elif state == "dquote":
            buf.append(ch)
            if ch == '"':
                if nxt == '"':
                    buf.append(nxt)
                    i += 1
                else:
                    state = "normal"
        elif state == "linecomment":
            buf.append(ch)
            if ch == "\n":
                state = "normal"
        elif state == "blockcomment":
            buf.append(ch)
            if ch == "*" and nxt == "/":
                buf.append(nxt)
                i += 1
                state = "normal"
        i += 1

    tail = "".join(buf).strip()
    if tail:
        statements.append((stmt_start_line, tail))
    return statements


def has_top_level_semicolon(sql_text: str) -> bool:
    """True if sql_text contains a ';' in the `normal` state — a real statement
    delimiter, not one inside a string / quoted identifier / comment.

    Deliberately NOT `len(split_statements(...)) > 1`. That splitter DROPS
    empty statements, so a leading or doubled delimiter collapses to a single
    non-empty part and reads as delimiter-free: `; SELECT * FROM hive.x` splits
    to exactly one statement. The Trino CLI does NOT drop it — it splits on the
    ';' all the same, keeps the EXPLAIN prefix on the (empty) first statement,
    and EXECUTES the trailing SELECT unprefixed. That is precisely the
    production-query safety invariant this gate exists to enforce, so detection
    must key on the delimiter itself, never on the surviving statement count.
    """
    state = "normal"
    i = 0
    n = len(sql_text)
    while i < n:
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < n else ""
        if state == "normal":
            if ch == "'":
                state = "single"
            elif ch == '"':
                state = "dquote"
            elif ch == "-" and nxt == "-":
                state = "linecomment"
                i += 1
            elif ch == "/" and nxt == "*":
                state = "blockcomment"
                i += 1
            elif ch == ";":
                return True
        elif state == "single":
            if ch == "'":
                if nxt == "'":
                    i += 1
                else:
                    state = "normal"
        elif state == "dquote":
            if ch == '"':
                if nxt == '"':
                    i += 1
                else:
                    state = "normal"
        elif state == "linecomment":
            if ch == "\n":
                state = "normal"
        elif state == "blockcomment":
            if ch == "*" and nxt == "/":
                i += 1
                state = "normal"
        i += 1
    return False


# ---------------------------------------------------------------- normalize --

_WS_RE = re.compile(r"\s+")


def normalize_sql(sql_text: str) -> str:
    """Whitespace-collapse + strip comments, for baseline hashing. Comments are
    stripped using the same state machine as split_statements (so a `--` or
    `/* */` inside a string literal is correctly left alone), then all
    remaining whitespace runs collapse to a single space."""
    out = []
    state = "normal"
    i = 0
    n = len(sql_text)
    while i < n:
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < n else ""
        if state == "normal":
            if ch == "'":
                state = "single"
                out.append(ch)
            elif ch == '"':
                state = "dquote"
                out.append(ch)
            elif ch == "-" and nxt == "-":
                # A stripped comment leaves a SPACE, never nothing: dropping it
                # outright welds the tokens either side together, so
                # `SELECT bad/*note*/FROM t` normalized to `SELECT badFROM t`
                # and collided with the genuinely different `SELECT badFROM t`.
                # A shared hash lets an already-baselined commented form absorb
                # a newly-added failing statement as "pre-existing debt". The
                # trailing whitespace collapse below makes this a no-op for
                # comments that were already whitespace-separated.
                out.append(" ")
                state = "linecomment"
                i += 1
            elif ch == "/" and nxt == "*":
                out.append(" ")
                state = "blockcomment"
                i += 1
            else:
                out.append(ch)
        elif state == "single":
            out.append(ch)
            if ch == "'":
                if nxt == "'":
                    out.append(nxt)
                    i += 1
                else:
                    state = "normal"
        elif state == "dquote":
            out.append(ch)
            if ch == '"':
                if nxt == '"':
                    out.append(nxt)
                    i += 1
                else:
                    state = "normal"
        elif state == "linecomment":
            if ch == "\n":
                state = "normal"
        elif state == "blockcomment":
            if ch == "*" and nxt == "/":
                i += 1
                state = "normal"
        i += 1
    collapsed = _WS_RE.sub(" ", "".join(out)).strip()
    return collapsed


def _is_comment_only(stmt: str) -> bool:
    """True if a split_statements() fragment is nothing but comments/whitespace
    (e.g. a trailing `-- note` left over after the final ';' in a fence).
    Not real SQL — extract_file() drops these rather than emitting a
    zero-content SqlBlock that would hash to sha1('') and confuse the
    baseline."""
    return normalize_sql(stmt) == ""


# ------------------------------------------------------------- bash scanning --

# Matches the START of a trino-query.sh / muso query invocation anywhere in a
# bash blob. Captures the runner label and whatever follows on the same line
# (either a quote char to hunt for, or a heredoc marker).
_INVOKE_RE = re.compile(
    r"""(?P<runner>
            (?:bash\s+(?:/opt/hydra/)?scripts/)?trino-query\.sh
          | muso\s+query
        )
        \s+
        (?P<rest>.*)$
    """,
    re.VERBOSE,
)

_HEREDOC_RE = re.compile(r"^-?\s*<<\s*'?(?P<marker>[A-Za-z_][A-Za-z0-9_]*)'?\s*$")


def _runner_label(raw: str) -> str:
    return "trino-query.sh" if "trino-query.sh" in raw else "muso-query"


def _extract_quoted(lines: list, start_idx: int, start_col: int, quote: str):
    """Scan forward from lines[start_idx][start_col:] for the matching
    unescaped quote char, across as many physical lines as needed (a quoted
    string that itself spans lines, which bash permits literally). Returns
    (text, ending_line_index) or None if unterminated. Each physical line's
    captured slice is joined with '\\n', preserving the SQL's original line
    breaks (they were literal inside the shell string too)."""
    line_parts = []
    i = start_idx
    col = start_col
    while i < len(lines):
        line = lines[i]
        j = col
        while j < len(line):
            ch = line[j]
            if ch == "\\" and quote == '"' and j + 1 < len(line):
                # backslash-escape only meaningful inside double quotes
                j += 2
                continue
            if ch == quote:
                line_parts.append(line[col:j])
                return "\n".join(line_parts), i
            j += 1
        # no closing quote on this line: keep whole remainder, move to next line
        line_parts.append(line[col:])
        i += 1
        col = 0
    return None


def _extract_heredoc(lines: list, start_idx: int, marker: str):
    body = []
    i = start_idx
    while i < len(lines):
        if lines[i].strip() == marker:
            return "\n".join(body), i
        body.append(lines[i])
        i += 1
    return None


def extract_bash_blob(text: str, base_line: int = 1) -> list:
    """Scan raw bash text (fence body or a whole .sh file) for trino-query.sh /
    `muso query` invocations and return a list of (line, runner, sql)."""
    lines = text.split("\n")
    results = []
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if line.lstrip().startswith("#"):
            # A bash `#` comment mentioning trino-query.sh / `muso query` in
            # prose (e.g. "run bash trino-query.sh \"<SQL>\" — it still
            # rewrites") is documentation, not an invocation. Only match real
            # (uncommented) invocation lines.
            idx += 1
            continue
        m = _INVOKE_RE.search(line)
        if not m:
            idx += 1
            continue
        runner = _runner_label(m.group("runner"))
        rest = m.group("rest").strip()
        stmt_line = base_line + idx

        # heredoc form: `... <<'SQL'` or `... - <<'SQL'`
        hd = _HEREDOC_RE.match(rest)
        if hd:
            got = _extract_heredoc(lines, idx + 1, hd.group("marker"))
            if got is None:
                idx += 1
                continue
            sql, end_idx = got
            results.append((stmt_line + 1, runner, sql))
            idx = end_idx + 1
            continue

        # quoted-argument form: '...' or "..."
        if rest[:1] in ("'", '"'):
            quote = rest[0]
            col_in_line = len(line) - len(rest)
            got = _extract_quoted(lines, idx, col_in_line + 1, quote)
            if got is None:
                idx += 1
                continue
            sql, end_i = got
            results.append((stmt_line, runner, sql))
            idx = end_i + 1
            continue

        # Trailing backslash continuation before the quote starts on the next
        # line (`trino-query.sh \` then `"SELECT ..."` on the next line).
        if rest == "\\" or rest == "":
            j = idx + 1
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            if j < len(lines):
                cand = lines[j].strip()
                if cand[:1] in ("'", '"'):
                    quote = cand[0]
                    col = lines[j].index(cand) + 1
                    got = _extract_quoted(lines, j, col, quote)
                    if got is not None:
                        sql, end_i = got
                        results.append((base_line + j, runner, sql))
                        idx = end_i + 1
                        continue
        idx += 1
    return results


# --------------------------------------------------------------- file walk --

def _is_excluded(rel_path: str) -> bool:
    return any(rel_path.startswith(prefix) for prefix in EXCLUDED_DIRS)


def extract_file(rel_path: str, text: str) -> ExtractResult:
    """Extract all SqlBlocks + declared skips from one file's text. rel_path
    is used only for labeling (SqlBlock.file / SkippedDeclared.file) and to
    decide extraction strategy (.md fences vs raw .sh scanning)."""
    result = ExtractResult()
    if _is_excluded(rel_path):
        return result

    if rel_path.endswith(".md"):
        lines = text.split("\n")
        i = 0
        pending_skip_reason = None
        while i < len(lines):
            skip_m = SKIP_MARKER_RE.match(lines[i])
            if skip_m:
                pending_skip_reason = skip_m.group("reason") or "declared skip"
                i += 1
                continue
            fence_m = FENCE_OPEN_RE.match(lines[i])
            if not fence_m:
                if lines[i].strip():
                    pending_skip_reason = None
                i += 1
                continue
            fence_kind = fence_m.group(1).lower()
            fence_start = i
            j = i + 1
            body_lines = []
            while j < len(lines) and not FENCE_CLOSE_RE.match(lines[j]):
                body_lines.append(lines[j])
                j += 1
            body = "\n".join(body_lines)

            if pending_skip_reason is not None:
                result.skipped_declared.append(
                    SkippedDeclared(file=rel_path, line=fence_start + 1, reason=pending_skip_reason)
                )
                pending_skip_reason = None
            elif fence_kind == "sql":
                for stmt_line, stmt in split_statements(body, start_line=fence_start + 2):
                    if _is_comment_only(stmt):
                        continue
                    result.blocks.append(SqlBlock(file=rel_path, line=stmt_line, sql=stmt, runner=None))
            else:  # bash / shell / sh fence: only invocations of the two runners
                for ln, runner, sql in extract_bash_blob(body, base_line=fence_start + 2):
                    for stmt_line, stmt in split_statements(sql, start_line=ln):
                        if _is_comment_only(stmt):
                            continue
                        result.blocks.append(
                            SqlBlock(file=rel_path, line=stmt_line, sql=stmt, runner=runner)
                        )

            i = j + 1 if j < len(lines) else j
        return result

    if rel_path.endswith(".sh"):
        for ln, runner, sql in extract_bash_blob(text, base_line=1):
            for stmt_line, stmt in split_statements(sql, start_line=ln):
                if _is_comment_only(stmt):
                    continue
                result.blocks.append(SqlBlock(file=rel_path, line=stmt_line, sql=stmt, runner=runner))
        return result

    return result


def extract_paths(root: Path, rel_paths: list) -> ExtractResult:
    """Convenience: extract over a list of repo-relative paths under root."""
    combined = ExtractResult()
    for rel in rel_paths:
        full = root / rel
        try:
            text = full.read_text(encoding="utf-8", errors="strict")
        except (OSError, UnicodeDecodeError) as exc:
            # NEVER `continue` here. Skipping silently drops that file's SQL
            # from the scan while any other in-scope file keeps result.blocks
            # non-empty — so the "refusing to pass vacuously" guard stays quiet
            # and the gate exits 0 having validated only part of its scope.
            # Surfacing it as ValueError lands on main()'s handler => exit 2.
            raise ValueError(
                f"{rel}: cannot read/decode file in scope "
                f"({exc.__class__.__name__}: {exc}) — refusing to skip it "
                "silently, its SQL would ship unchecked."
            ) from exc
        r = extract_file(rel, text)
        combined.blocks.extend(r.blocks)
        combined.skipped_declared.extend(r.skipped_declared)
    return combined


def discover_paths(root: Path) -> Iterator[str]:
    """Default discovery: every skills-all/**/*.md and skills-all/**/*.sh,
    excluding EXCLUDED_DIRS. Callers doing changed-files-only scoping should
    build their own list instead of calling this."""
    skills = root / "skills-all"
    if not skills.is_dir():
        return
    for p in sorted(skills.rglob("*")):
        if not p.is_file():
            continue
        if p.suffix not in (".md", ".sh"):
            continue
        rel = p.relative_to(root).as_posix()
        if _is_excluded(rel):
            continue
        yield rel
