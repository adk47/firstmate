#!/usr/bin/env python3
"""credit_status_write_gate.py — the scanner behind scripts/check-credit-status-writes.sh.

WHY THIS IS NOT A LINE GREP (QA #1578, 2026-10-31). The guard's promise is "hydra can neither write a credit status
directly nor move one silently". A line-oriented scan cannot keep that promise: every one of these is a valid write
that a per-line match returns OK for, and each was reproduced by QA through the guard's own entrypoint:

    UPDATE
    credit_requests SET status = ...
    UPDATE "public"."credit_requests" SET status = ...
    coll = db["credit_requests"]
    coll
      .updateMany(query, update)
    payload = {"requestIds": ids,
               "notify": false}

So the text is NORMALISED first and matched as a whole:

  * quote characters that wrap an identifier / key (' " ` [ ]) are dropped, so any quoting of a table, schema or
    collection name reads the same way ("public"."credit_requests" == public.credit_requests);
  * the match runs over the WHOLE file, and every pattern joins its tokens with \\s+, which in Python matches a
    newline. A statement broken across lines is therefore one match, not two lines that each look innocent.

Line numbers are preserved (normalisation only removes quote characters, never newlines), so a hit is reported at the
line the statement starts on.

A bracket inside a STRING LITERAL is data, not structure (qa-review #1578 r21). The depth walks - the `collection(...)`
receiver and the alias binding - therefore consult a string mask (`_string_spans` / `_flat_string_mask`) instead of
counting every bracket they see. Without it `db.collection("credit_requests", {comment: ")"}).updateOne(...)` closed
the receiver at the quoted `)` and the write verb fell outside it: a real status write, reported OK.

Inside a TEMPLATE literal, an interpolation is CODE, not content (qa-review #1578 r22). Masking the whole backtick run
made `` `${db.collection("credit_requests").updateOne({}, {$set: {status: "approved"}})}` `` scan clean, because the
receiver sat in what the mask called a literal - yet the interpolation executes. `_string_spans` therefore leaves a
`${...}` body UNMARKED and resumes the literal after its closing brace. "Unmarked" is not enough on its own: the body
is walked by the same code/literal pair as the top level (`_mark_code`/`_mark_literal`), so its OWN quoted strings are
marked as content and its comments are blanked by `_blank_code`/`_blank_literal` - otherwise a quoted `)` in the body
closes the receiver at a data character, and a `/* ... */` in the body swallows the write verb (qa-review #1578 r23).
A body that CLOSES also spans newlines, because JavaScript allows them: stopping at the newline left a `/* hi */` on
the next line unblanked and the write scanned clean (qa-review #1578 r24). The newline rule survives only as the
fallback for a body that never closes, so a stray `${` cannot swallow the rest of the file.

A Mongo write is bound to its RECEIVER, not to a distance (QA #1578, ninth round): the verb must be called on an
expression that denotes the credit-requests collection - `db.credit_requests`, `db["credit_requests"]`,
`db.collection("credit_requests")`, the same built from a constant (`const C = "credit_requests"`), or a variable
bound to any of those at any distance. A `collection(...)` receiver's argument list is walked with a bracket depth
(tenth round): a newline before its closing paren, or an options object containing a call, is not an escape. The old rule matched any write verb within 400 characters of the name, so
a read of credit requests followed by a write to an unrelated collection failed the gate, and a collection named
through a constant was invisible.

Exit: 0 clean, 1 violation(s), 2 unreadable input. Usage: reads repo-relative paths on stdin, --root and --allow given
by the shell entrypoint (the shell owns file discovery, the allowlist and the exit contract).
"""
from __future__ import annotations

import argparse
import re
import sys

# Identifier quoting. Quotes are DROPPED, so `UPDATE "public"."credit_requests"` reads `UPDATE public.credit_requests`
# and `db["credit_requests"]` reads `db credit_requests`; brackets become a space rather than vanishing, so the name
# keeps a word boundary (`dbcredit_requests` would not match).
_QUOTES = str.maketrans({'"': "", "'": "", "`": " ", "[": " ", "]": " "})
# An ESCAPED quote (a JS template literal or a Python string that carries SQL) is the same quote: drop the backslash
# so `sql\`UPDATE \"credit_requests\"\`` normalises to `UPDATE credit_requests`.
_ESCAPED_QUOTE = re.compile(r"\\(?=[\"'`\[\]])")

# Comments are SEPARATORS in SQL and JS, so a comment between the verb and the table name must not hide the write:
# `UPDATE /* decision repair */ credit_requests SET status = ...` was a live false green (QA #1578, second round).
#
# Comments are blanked by a STRING-AWARE scanner, not a regex (QA #1578, fourth round): `const marker = "//";` followed
# by a real write on the same line was itself a false green, because a regex cannot tell a comment from a string
# literal that contains one. So the scanner walks the text, remembers whether it is inside a quote, and only blanks
# `/* */`, `--` and `//` in code. Quotes are untouched, so a URL inside a string stays a string.
# SQL line comments (`--`) are comments wherever they appear; only a JS DECREMENT (`i--;`, `i--)`) is not, and a
# decrement is recognizable by what follows the two dashes (an operator or a terminator), never by what precedes them.
# QA #1578 round 9: `UPDATE--repair` NEWLINE `credit_requests SET status='approved';` was a false green because the
# old rule required one of a fixed set of characters BEFORE the `--`, and `E` is not in it.
#: What can follow a postfix decrement. The old rule looked only at the character IMMEDIATELY after `--`, so
#: `i-- ;` (a space before the semicolon, perfectly valid JS) read as a SQL comment and the rest of the line was
#: blanked - QA #1578 r12 reproduced a same-line `db.credit_requests.updateOne(... {status:"approved"})` behind it
#: reporting `OK`. Bias: when the two readings are ambiguous the dashes are CODE, because treating code as a comment is
#: the direction that hides a write.
_DECREMENT_TAIL = set(";)]},.+-*/%=<>&|?:\"'`")
_OPERAND_BEFORE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$)]")


#: Comment syntax is a property of the LANGUAGE, not of the character pair. qa-review #1578 (r13) reproduced two
#: false greens from treating it as universal: in Python `//` is FLOOR DIVISION (`x = 4 // 2; db.credit_requests
#: .update_one({"$set": {"status": "approved"}})`) and was blanked as a comment, and in SQL `--` is ALWAYS a comment
#: (`UPDATE-- ; repair` NEWLINE `credit_requests SET status='approved';`) while the decrement heuristic called it code
#: and the `-- ; repair` text then stopped `\bupdate\s+` from ever matching the table name.
_PYTHON_SUFFIXES = {".py", ".pyi", ".pyw"}
_SQL_SUFFIXES = {".sql", ".psql", ".pgsql", ".ddl", ".dml"}
#: Shell and YAML both comment with `#` to end of line, and NEITHER has `//` or `--` comments: in shell `//` is a path
#: or an arithmetic operator and `--` is an option prefix, so blanking them was over-blanking. qa-review #1578 (r14)
#: reproduced the other half: `.sh` was classified as JS, `#` was never recognized, and a documentation comment
#: (`# Example: UPDATE credit_requests SET status = 'approved'`) failed the required CI gate.
_HASH_SUFFIXES = {".sh", ".bash", ".zsh", ".ksh", ".dash", ".yml", ".yaml"}
_JS_SUFFIXES = {".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts", ".tsx", ".json", ".jsonc", ".lobster"}
#: What may precede a `#` for it to START a comment in shell/YAML. POSIX: `#` begins a comment only at the start of a
#: word, so `foo#bar` and `${var#prefix}` are not comments and must stay visible.
_HASH_COMMENT_BEFORE = set(" \t\r\n;|&()")


def _comment_language(path: str | None) -> str:
    """`python` | `sql` | `hash` | `js` | `unknown`, from the file's own suffix. Unknown keeps the pre-r13 behaviour."""
    suffix = ""
    if path:
        name = str(path).rsplit("/", 1)[-1]
        if "." in name.lstrip("."):
            suffix = "." + name.rsplit(".", 1)[-1].lower()
    if suffix in _PYTHON_SUFFIXES:
        return "python"
    if suffix in _SQL_SUFFIXES:
        return "sql"
    if suffix in _HASH_SUFFIXES:
        return "hash"
    if suffix in _JS_SUFFIXES:
        return "js"
    return "unknown"


def _dashes_are_a_sql_comment(text: str, i: int) -> bool:
    """Is the `--` at `i` a SQL line comment rather than a JS postfix decrement?

    A decrement needs an operand on its left and an operator/terminator on its right; a comment needs neither. Both
    `i-- ;` (decrement) and `UPDATE--repair` (comment, PostgreSQL accepts it - QA #1578 r9) have an identifier before
    the dashes, so the deciding evidence is what comes AFTER, skipping spaces and tabs.
    """
    before = text[i - 1] if i > 0 else ""
    if before not in _OPERAND_BEFORE:
        return True                                  # `-- prose` at line start, after a space, `(`, `=`, ...: a comment
    j = i + 2
    n = len(text)
    while j < n and text[j] in " \t\r":
        j += 1
    if j >= n or text[j] == "\n":
        return False                                 # `i--` at end of line: a decrement with nothing after it
    return text[j] not in _DECREMENT_TAIL
QUOTES_OF = {"'": "'", '"': '"', "`": "`"}

# 1. a direct SQL write on the core table, any quoting (normalised away above), any case, any line breaks
# PostgreSQL also accepts `UPDATE ONLY <table>` (QA #1578, round 6): `UPDATE ONLY credit_requests SET status = ...`
# is a plain update of the table, not of its inheritance children - the guard admitted it because it required the table
# name right after the verb. Comment separators are already blanked to spaces before this runs, so
# `UPDATE /* repair */ ONLY /* x */ credit_requests` matches through the same \s+.
SQL_WRITE = re.compile(r"\bupdate\s+(?:only\s+)?(?:public\s*\.\s*)?credit_requests\b", re.IGNORECASE)
# ... or the INSERT/upsert that sets the status instead of updating it (QA #1578, round 7):
# `INSERT INTO credit_requests (id, status) VALUES (42, 'approved') ON CONFLICT (id) DO UPDATE SET status = ...` creates
# or flips a credit-request status exactly like an UPDATE, and the rule above only looked for `UPDATE`. An INSERT into
# this table is a direct status write in every form (the row IS a status), so the whole family is caught: INSERT INTO,
# INSERT ... ON CONFLICT, and PostgreSQL 15's MERGE INTO.
SQL_INSERT_WRITE = re.compile(
    r"\b(?:insert\s+into|merge\s+into)\s+(?:only\s+)?(?:public\s*\.\s*)?credit_requests\b", re.IGNORECASE)
# ... or a Sequelize model write
SEQUELIZE_WRITE = re.compile(r"\bcreditrequests\s*\.\s*(?:update|upsert|create|bulkcreate)\s*\(", re.IGNORECASE)
# 2. a Mongo write verb bound to the credit-requests RECEIVER. There is no distance window any more (QA #1578
# round 9, finding 2): the old rule matched any write verb within 400 characters of the collection name, so
# `const rows = db.credit_requests.find({}); db.artists.updateOne(q, u);` - a read plus an unrelated write - failed the
# gate. A hit now requires the verb to be called ON the collection expression itself:
#   db.credit_requests.insertOne(      db["credit_requests"].insertMany(
#   db.collection("credit_requests").updateOne(      db.collection(CREDIT_COLLECTION).insertOne(
# See _credit_constants() / _mongo_receiver_pattern() for the constant-backed forms and _mongo_aliases() for the
# bound-variable forms.
# ... and the ALIASED form, which has no distance limit (QA #1578, fourth round): `coll = db["credit_requests"];`
# sixty lines later `coll.updateMany(q, u)` is the same write, and any fixed byte window is a guess. The alias is
# collected from the assignment and its write verb matched anywhere in the file.
# The binding is read with a bracket-aware scan, not a regex line: `const coll = db[\n  "credit_requests"\n];` is a
# multiline binding, and a `[^;\n]*` RHS stopped at the first newline (QA #1578, fifth round). A statement ends at a
# `;` or a newline OUTSIDE brackets, so the RHS span is the statement, never an arbitrary byte count.
MONGO_ALIAS_ASSIGN = re.compile(r"(?<![A-Za-z0-9_$.])([A-Za-z_$][\w$]*)\s*=\s*", re.IGNORECASE)
_BRACKETS = {"[": "]", "(": ")", "{": "}"}
# QA #1578 r8: an INSERT into this collection is the same write as an UPDATE - the row IS a status - so the verbs now
# cover the row-creating family too (`insertOne`/`insertMany`, and the driver's snake_case forms). Without them
# `db.credit_requests.insertOne({status: "approved"})` produced an approved request outside core's PUT while the
# equivalent SQL INSERT was refused: the same hole, one API down.
_MONGO_VERBS = r"(?:insert_?one|insert_?many|update_?one|update_?many|find_?one_?and_?update|replace_?one|bulk_?write|bulk_?insert)"
_MONGO_VERB = rf"\b{_MONGO_VERBS}\s*\("
#: How a write verb is REACHED on a receiver. qa-review #1578 (r15) reproduced two valid forms the literal `.verb(`
#: join missed: OPTIONAL CHAINING (`db.credit_requests?.updateOne(...)`, `db.collection("credit_requests")?.updateOne`)
#: and the BRACKET CALL (`db.credit_requests["updateOne"](...)`). Both execute a direct status write when the
#: collection exists, so both are the same violation. `?.` is matched explicitly; the bracket form is matched on the
#: NORMALISED stream, where `["updateOne"]` has already become ` updateOne ` (brackets to spaces, quotes dropped).
_MONGO_ACCESS = r"\s*\??\.\s*"
# 3. a silent move: the notify flag set false. This one runs on the RAW text (quotes intact) because a quote is what
# separates a code key from prose: `decision_told.py`'s docstring says "under a notify:false re-drive marker", which
# is a sentence, not a write, and the normalised stream cannot tell the two apart. Three forms, each \s so a value on
# the next line still matches, and each with lookarounds so `notify_all` / `no_notify` / `notifyFalse` stay out:
#   quoted key (JSON / JS / Python dict)  "notify": false   'notify': False
#   JS shorthand inside an object literal  { requestIds, notify: false }
#   Python keyword argument                notify=False
NOTIFY_FALSE = re.compile(
    r"(?<![A-Za-z0-9_])(?:[\"']notify[\"'](?![A-Za-z0-9_])\s*:\s*false"
    r"|(?<=[{,])\s*notify(?![A-Za-z0-9_])\s*:\s*false"
    r"|(?<![A-Za-z0-9_])notify(?![A-Za-z0-9_])\s*=\s*false)"
    r"(?![A-Za-z0-9_])",
    re.IGNORECASE,
)

RULES = (
    (SQL_WRITE, "direct credit-status write (use core's PUT /admin/credit-requests[/conditional-status])"),
    (SQL_INSERT_WRITE, "direct credit-status write (use core's PUT /admin/credit-requests[/conditional-status])"),
    (SEQUELIZE_WRITE, "direct credit-status write (use core's PUT /admin/credit-requests[/conditional-status])"),
)
MONGO_MSG = "Mongo credit-request write (use core's PUT)"
# the silent-move rule reads the raw text, not the normalised stream (see NOTIFY_FALSE)
NOTIFY_MSG = "silent credit move (notify:false); core's PUT notifies, a re-drive owes one notice"


def _blank_comments(text: str, path: str | None = None) -> str:
    """Code comments -> spaces, newlines kept (so line numbers stay true), STRING LITERALS left alone.

    What counts as a comment depends on the language `path` names (see `_comment_language`). Blanking a token that the
    language reads as CODE is the failure direction that hides a write, so where a form is not a comment in that
    language it is left alone: over a false positive any day.
    """
    lang = _comment_language(path)
    out: list[str] = []
    _blank_code(text, 0, out, lang, stop_at_brace=False)
    return "".join(out)


def _interpolation_end(raw: str, i: int) -> int | None:
    """Index just past the `}` closing a `${` interpolation whose body starts at `i`, or None if it never closes.

    Only used to decide whether a body may span newlines, so it is deliberately cheap: it skips quoted strings (a `}`
    inside one is data) and counts braces, and it does NOT know about comments. A `}` inside a comment therefore makes
    it report a close that the real walk will not find - which only ever makes the body MORE permissive, the safe
    direction, because the real walk still stops at the brace it actually reaches.
    """
    n = len(raw)
    depth = 1
    while i < n:
        c = raw[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if QUOTES_OF.get(c):
            i = _literal_end(raw, i)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def _literal_end(raw: str, i: int) -> int:
    """Index just past the string literal starting at `i` (a newline or the end of the text ends an unterminated one)."""
    n = len(raw)
    quote = raw[i]
    i += 1
    while i < n:
        c = raw[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == quote or c == "\n":
            return i + 1
        if quote == "`" and c == "$" and i + 1 < n and raw[i + 1] == "{":
            end = _interpolation_end(raw, i + 2)
            i = end if end is not None else i + 2
            continue
        i += 1
    return n


def _blank_code(text: str, i: int, out: list[str], lang: str, *, stop_at_brace: bool,
                stop_at_newline: bool = True) -> int:
    """Blank comments in CODE from `i`, appending to `out`. Returns the index to resume at.

    With `stop_at_brace`, this is the body of a `${...}` interpolation: it stops just past the `}` that closes it
    (brace-depth aware, and literals are consumed whole so a `}` inside one cannot close it early).

    `stop_at_newline` is the UNTERMINATED fallback: a newline ends a body that has no closing brace, so a stray `${`
    cannot swallow the rest of the file. A body that DOES close keeps going across newlines, because JavaScript allows
    them - qa-review #1578 (r24): stopping at the newline left a `/* hi */` on the next line unblanked, so the receiver
    matcher could not join the collection call to `.updateOne` and a real write scanned clean.
    """
    n = len(text)
    depth = 1
    while i < n:
        ch = text[i]
        if QUOTES_OF.get(ch):                        # copy the literal verbatim (a `//` inside it is not a comment)
            i = _blank_literal(text, i, out, lang)
            continue
        if stop_at_brace:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    out.append(ch)
                    return i + 1
            elif ch == "\n" and stop_at_newline:
                out.append(ch)
                return i + 1
        if lang == "python":                     # `#` to end of line; `//` here is floor division, `--` is negation
            if ch == "#":
                end = text.find("\n", i)
                end = n if end < 0 else end
                out.append(re.sub(r"[^\n]", " ", text[i:end]))
                i = end
                continue
            out.append(ch)
            i += 1
            continue
        if lang == "hash":                       # shell / YAML: `#` to end of line, at a word boundary only
            if ch == "#" and (i == 0 or text[i - 1] in _HASH_COMMENT_BEFORE):
                end = text.find("\n", i)
                end = n if end < 0 else end
                out.append(re.sub(r"[^\n]", " ", text[i:end]))
                i = end
                continue
            out.append(ch)
            i += 1
            continue
        if lang == "sql":                        # SQL has no `--` operator: the dashes are ALWAYS a comment
            if text.startswith("--", i) or text.startswith("/*", i):
                if text.startswith("/*", i):
                    end = text.find("*/", i + 2)
                    end = n if end < 0 else end + 2
                else:
                    end = text.find("\n", i)
                    end = n if end < 0 else end
                out.append(re.sub(r"[^\n]", " ", text[i:end]))
                i = end
                continue
            out.append(ch)
            i += 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
            continue
        if text.startswith("//", i) or (text.startswith("--", i) and _dashes_are_a_sql_comment(text, i)):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
            continue
        out.append(ch)
        i += 1
    return n


def _blank_literal(text: str, i: int, out: list[str], lang: str) -> int:
    """Copy the string literal starting at `i` verbatim, but blank comments inside its `${...}` interpolations.

    qa-review #1578 (r23) Important: an interpolation is CODE, so a `/* ... */` between the collection call and the
    write verb inside one is a comment and must be blanked - otherwise the verb is swallowed as comment text and the
    write scans clean. The literal resumes after the interpolation's closing brace.
    """
    n = len(text)
    quote = text[i]
    out.append(text[i])
    i += 1
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:              # an escaped char, whatever it is
            out.append(c)
            out.append(text[i + 1])
            i += 2
            continue
        if c == quote or c == "\n":               # a newline ends the literal: never swallow the rest of the file
            out.append(c)
            return i + 1
        if quote == "`" and c == "$" and i + 1 < n and text[i + 1] == "{":
            out.append(c)
            out.append(text[i + 1])
            i = _blank_code(text, i + 2, out, lang, stop_at_brace=True,
                            stop_at_newline=_interpolation_end(text, i + 2) is None)
            continue
        out.append(c)
        i += 1
    return n


_CONST_ASSIGN = re.compile(
    r"(?<![A-Za-z0-9_$.])(?:const|let|var|final|val)?\s*([A-Za-z_$][\w$]*)\s*(?::[^=\n]+)?=\s*([\"'`])([^\"'`\n]*)\2")


def _credit_constants(binding_text: str) -> set[str]:
    """Names bound to a plain string literal that denotes the credit-requests collection.

    QA #1578 round 9, finding 1: `const CREDIT_COLLECTION = "credit_requests";` and a receiver built from it
    (`db.collection(CREDIT_COLLECTION)`) carried the collection name while no rule read it, so an insert through that
    receiver was a false green. Only single-line literals without interpolation count - a built-up name is a different
    problem, and guessing at it would trade a false green for a false red."""
    consts: set[str] = set()
    for m in _CONST_ASSIGN.finditer(binding_text):
        if re.search(r"credit_?requests", m.group(3), re.IGNORECASE):
            consts.add(m.group(1))
    return consts


def _const_alt(consts: set[str]) -> str:
    names = "|".join(re.escape(c) for c in sorted(consts))
    return f"(?:{names})" if names else r"(?!)"


def _receiver_source(consts: set[str]) -> str:
    """Regex source for an expression that DENOTES the credit-requests collection, matched on the normalised stream.

    The `collection(...)` / `getCollection(...)` call is deliberately NOT here: its argument list needs a bracket
    depth to be read honestly. A character class cannot do it - `[^()\n]*` ended the receiver at the newline QA #1578
    round 10 reproduced (`db.collection(` NEWLINE `"credit_requests"` NEWLINE `)` was a false green), and widening it
    to `[^()]*` is still defeated by an options object that contains a call
    (`db.collection("credit_requests", {validator: f()})`). _collection_calls() walks the argument list instead, so
    one form has one implementation."""
    lit = r"credit_?requests"
    name = _const_alt(consts)
    # ONE outer group: without it the alternation binds looser than the `\.\s*VERB(` appended by
    # _mongo_receiver_pattern, so the first branch matched a collection name and the write verb was never required
    # (QA #1578 round 10: `db.credit_requests.find(` was reported as a write).
    return (
        rf"(?:db\s*\.\s*(?:{lit}|{name})\b"                                           # db.credit_requests / db.CONST
        rf"|\bdb\s+(?:{lit}|{name})\b)"                                                # db["credit_requests"] (quotes/brackets normalised)
    )


def _mongo_receiver_pattern(consts: set[str]) -> re.Pattern[str]:
    return re.compile(rf"{_receiver_source(consts)}{_MONGO_ACCESS}{_MONGO_VERBS}\s*\(", re.IGNORECASE)


def _mongo_bracket_call_pattern(consts: set[str]) -> re.Pattern[str]:
    """`db.credit_requests["updateOne"](...)` - the bracket call, read on the NORMALISED stream.

    `["updateOne"]` normalises to ` updateOne ` (brackets become spaces, quotes are dropped), so the verb follows the
    receiver as a bare word. The receiver must still be the credit collection, so this is not a wildcard.
    """
    return re.compile(rf"{_receiver_source(consts)}\s+(?:{_MONGO_VERBS})\s*\(", re.IGNORECASE)


# QA #1578 round 10: the inline `collection(...)` receiver needs a bracket depth too. QA reproduced a false green
# through the real entrypoint with a newline before the closing paren (`db.collection(` NEWLINE `"credit_requests"`
# NEWLINE `).insertOne({status: "approved"})` -> OK, 542 tracked files scanned). The same character-class limit also
# let an options object containing a call through. The first TOP-LEVEL argument is the only one that names the
# collection; anything after the first comma is options. A receiver whose first argument cannot be resolved to the
# collection is not a guess - it is not a hit, exactly as the literal/constant forms already behaved.
# qa-review #1578 (r20) Important: PyMongo's `db.get_collection("credit_requests")` was not recognized - the same
# receiver one API spelling over.
_COLLECTION_OPEN = re.compile(r"(?<![A-Za-z0-9_$])(?:collection|getcollection|get_collection)\s*\(", re.IGNORECASE)


def _denotes_credit(arg: str, consts: set[str]) -> bool:
    """Does one argument expression name the credit-requests collection? `arg` comes from the normalised stream, so
    identifier quotes are already spaces; a constant bound to the literal counts."""
    a = arg.strip()
    if not a:
        return False
    return bool(re.fullmatch(rf"(?:credit_?requests|{_const_alt(consts)})", a, re.IGNORECASE))


def _string_spans(raw: str) -> list[bool]:
    """Per-RAW-offset flag: is this character part of a string literal (the delimiting quotes included)?

    qa-review #1578 (r21) Critical: `_collection_calls` walked the NORMALISED stream, where the quotes are already
    gone, so a `)` or `}` INSIDE a string argument decremented the bracket depth and closed the receiver early:
    `db.collection("credit_requests", {comment: ")"}).updateOne({}, {$set: {status: "approved"}})` scanned clean
    through the real entrypoint. A quoted `}` did the same. The depth walk therefore needs to know which characters
    are string CONTENT, and that information only exists before the quotes are dropped.

    The literal rules mirror `_blank_comments` exactly (a backslash escapes the next character; an unterminated
    literal ends at the newline), so the two scanners never disagree about where a string ends.

    qa-review #1578 (r22) Important: a template interpolation `${...}` is CODE, not string content. Masking it hid
    `` `${db.collection("credit_requests").updateOne({}, {$set: {status: "approved"}})}` `` completely, because the
    receiver sat inside what the mask called a literal. The interpolation body is left UNMARKED and the literal
    resumes after its closing brace, so the receiver inside it is scanned like any other code.

    qa-review #1578 (r23) Important: "scanned like any other code" has to include the interpolation's OWN literals.
    The r22 helper advanced past the body without marking a nested string's content, so
    `` `${db.collection("credit_requests", {comment: ")"}).updateOne(...)}` `` closed the receiver at that quoted `)`
    and the write scanned clean. The body is now walked by the same code/literal pair as the top level, so a nested
    literal's content is marked exactly as it would be outside the template.
    """
    inside = [False] * len(raw)
    _mark_code(raw, 0, inside, stop_at_brace=False)
    return inside


def _mark_code(raw: str, i: int, inside: list[bool], *, stop_at_brace: bool,
               stop_at_newline: bool = True) -> int:
    """Mark string CONTENT in CODE from `i`. Returns the index to resume at.

    With `stop_at_brace`, this is the body of a `${...}` interpolation: it stops just past the `}` that closes it
    (brace-depth aware, and literals are consumed whole so a `}` inside one cannot close it early).

    `stop_at_newline` is the UNTERMINATED fallback, exactly as in `_blank_code`: a body that closes keeps going across
    newlines (qa-review #1578 r24), a body that does not stops at the newline so a stray `${` cannot swallow the file.
    """
    n = len(raw)
    depth = 1
    while i < n:
        c = raw[i]
        if QUOTES_OF.get(c):
            i = _mark_literal(raw, i, inside)
            continue
        if stop_at_brace:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return i + 1
            elif c == "\n" and stop_at_newline:
                return i + 1
        i += 1
    return n


def _mark_literal(raw: str, i: int, inside: list[bool]) -> int:
    """Mark the string literal starting at `i` as content, descending into its `${...}` interpolations as CODE.

    The DELIMITING quotes are not marked: the normalisation drops them, so marking them would shift the mask by one.
    """
    n = len(raw)
    quote = raw[i]
    i += 1
    while i < n:
        c = raw[i]
        if c == "\\" and i + 1 < n:              # an escaped char, whatever it is
            inside[i] = True
            inside[i + 1] = True
            i += 2
            continue
        if c == quote or c == "\n":               # the closing quote / a newline ends the literal
            return i + 1
        if quote == "`" and c == "$" and i + 1 < n and raw[i + 1] == "{":
            i = _mark_code(raw, i + 2, inside, stop_at_brace=True,
                           stop_at_newline=_interpolation_end(raw, i + 2) is None)
            continue
        inside[i] = True
        i += 1
    return n


def _flat_string_mask(raw: str) -> set[int]:
    """The RAW string-literal positions, expressed in the `flat` stream's coordinates.

    `flat` is `raw` with the quote characters dropped, so the two streams drift apart by one offset per quote. The
    mask is replayed through `_flat_offsets` - the same transform the alias positions already use - so a caller can
    ask "is flat offset i inside a string?" without a second coordinate system (qa-review #1578 r19).
    """
    inside = _string_spans(raw)
    fmap = _flat_offsets(raw)
    return {fmap[i] for i, flag in enumerate(inside) if flag}


def _collection_calls(flat: str, consts: set[str], in_string: set[int] | frozenset[int] = frozenset()
                      ) -> list[tuple[int, int]]:
    """(start, end) for every `collection(...)` / `getCollection(...)` call whose FIRST argument names the
    credit-requests collection. `end` is the index just past the call's closing parenthesis, so a caller can look at
    what was called ON the receiver. Brackets are walked with a depth, never a character class.

    `in_string` holds the flat offsets that are string CONTENT (see `_flat_string_mask`). A bracket or comma there is
    data, not structure: counting it closed the receiver early and hid the write (qa-review #1578 r21)."""
    calls: list[tuple[int, int]] = []
    for m in _COLLECTION_OPEN.finditer(flat):
        if m.start() in in_string:                     # the call itself is inside a literal: not a receiver
            continue
        depth, i, n = 1, m.end(), len(flat)
        first_arg: str | None = None
        arg_start = m.end()
        closed = -1
        while i < n:
            ch = flat[i]
            if i in in_string:                         # string content: never a bracket, never an argument break
                i += 1
                continue
            if ch in _BRACKETS:
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    if first_arg is None:
                        first_arg = flat[arg_start:i]
                    closed = i + 1
                    break
            elif depth == 1 and ch == "," and first_arg is None:
                first_arg = flat[arg_start:i]
                arg_start = i + 1
            i += 1
        if closed < 0:                                 # unbalanced: a call we cannot read is not a hit
            continue
        if _denotes_credit(first_arg or "", consts):
            calls.append((m.start(), closed))
    return calls


def _collection_receiver_hits(flat: str, consts: set[str], in_string: set[int] | frozenset[int] = frozenset()
                              ) -> list[tuple[int, str]]:
    """A write verb called ON a `collection(...)`/`getCollection(...)` receiver, at any distance and across any line
    break. Positioned at the receiver's start, so a hit is reported at the line the statement starts on."""
    hits: list[tuple[int, str]] = []
    for start, end in _collection_calls(flat, consts, in_string):
        if re.match(rf"(?:{_MONGO_ACCESS}{_MONGO_VERBS}\s*\(|\s+(?:{_MONGO_VERBS})\s*\()", flat[end:],
                    re.IGNORECASE):
            hits.append((start, MONGO_MSG))
    return hits


def _is_credit_expr(expr: str, consts: set[str], receivers: set[str], alias_at=None) -> bool:
    """Does this binding's right-hand side DENOTE the credit-requests collection?

    qa-review #1578 (r14): the old rule searched the whole RHS for the substring `credit_requests`, so
    `const artists = db.collection("artists", {comment: "credit_requests"})` bound `artists` to the credit collection
    and a write to `artists` failed the required CI gate. A MENTION is not a RECEIVER: the RHS must BE the collection
    expression, or a call whose FIRST argument names it - the same rule the inline receivers already use. The RHS is
    normalised first (quotes dropped, brackets to spaces) so `db["credit_requests"]` reads like `db.credit_requests`.
    """
    flat = _ESCAPED_QUOTE.sub("", expr).translate(_QUOTES)
    in_string = _flat_string_mask(_ESCAPED_QUOTE.sub("", expr))
    if re.fullmatch(rf"\s*{_receiver_source(consts)}\s*", flat, re.IGNORECASE):
        return True
    if _collection_calls(flat, consts, in_string):     # a multiline or options-bearing collection call
        return True
    for name in receivers:                             # transitive: const a = db.credit_requests; const b = a;
        if re.fullmatch(rf"\s*{re.escape(name)}\s*", flat):
            return True
    if alias_at is not None:
        # qa-review #1578 (r17): a transitive binding must be resolved against its SOURCE AT THAT POSITION, not
        # against the source's last binding. `let a = db.collection("credit_requests"); let b = a;
        # a = db.collection("artists"); b.updateOne(...)` still holds the credit collection at runtime, and the
        # global last-binding set said `a` was `artists`, so `b` was never an alias and the write scanned clean.
        m = re.fullmatch(r"\s*([A-Za-z_$][\w$]*)\s*", flat)
        if m and alias_at(m.group(1)):
            return True
    return False


# `const { credit_requests: coll } = db;` binds the collection without a plain assignment: the receiver-anchored rules
# would otherwise lose a form the old distance window happened to catch.
_MONGO_DESTRUCTURE = re.compile(
    r"\{[^{}]*\bcredit_?requests\s*:\s*([A-Za-z_$][\w$]*)[^{}]*\}\s*=\s*db\b", re.IGNORECASE)


def _mongo_bindings(binding_text: str) -> list[tuple[str, str, int]]:
    """(name, right-hand side, position) for every assignment, read on the text WITH its brackets and quotes.

    The bracket depth is what tells a multiline RHS (`db[` NEWLINE `"credit_requests"` NEWLINE `]`) from the next
    statement - the normalised stream has already turned those brackets into spaces. A statement ends at a `;` or a
    newline OUTSIDE brackets, so the RHS span is the statement, never an arbitrary byte count."""
    out: list[tuple[str, str]] = []
    n = len(binding_text)
    # qa-review #1578 (r21): the depth walk runs on the text WITH its quotes, so a bracket inside a string literal is
    # data. Counting it ended the RHS early - `const c = db.collection("credit_requests", {comment: ")"});` bound `c`
    # to a truncated expression that no longer denoted the collection, and the later `c.updateOne(...)` scanned clean.
    in_string = _string_spans(binding_text)
    for m in MONGO_ALIAS_ASSIGN.finditer(binding_text):
        # qa-review #1578 r11: an assignment CONTINUES after `=` past newlines, comments and a backslash
        # continuation. Stopping at the first newline at depth 0 left `const c =` NEWLINE
        # `db.collection("credit_requests");` unbound, so a later `c.updateOne({status: "approved"})` looked like an
        # unrelated call and escaped the gate entirely.
        i = m.end()
        while i < n:
            if binding_text[i].isspace() or binding_text[i] == "\\":
                i += 1
            elif binding_text.startswith("//", i):
                nl = binding_text.find("\n", i)
                i = n if nl < 0 else nl + 1
            elif binding_text.startswith("/*", i):
                end = binding_text.find("*/", i + 2)
                i = n if end < 0 else end + 2
            else:
                break
        start, depth = i, 0
        while i < n:
            ch = binding_text[i]
            if in_string[i]:                      # string content: never a bracket, never a statement end
                i += 1
                continue
            if ch in _BRACKETS:
                depth += 1
            elif ch in ")]}":
                if depth == 0:                    # a closing bracket from an outer expression: the RHS is over
                    break
                depth -= 1
            elif depth == 0 and ch in ";\n":
                break
            i += 1
        out.append((m.group(1), binding_text[start:i], m.start()))
    for m in _MONGO_DESTRUCTURE.finditer(binding_text):
        out.append((m.group(1), "db.credit_requests", m.start()))
    # qa-review #1578 (r18) Important: destructuring matches were appended AFTER every ordinary assignment, so the
    # forward pass saw them out of order - `const {credit_requests: a} = db; const b = a; b.updateOne(...)` resolved
    # `b` before `a` existed and scanned clean. The bindings are sorted by SOURCE POSITION, which is the order the
    # forward pass requires.
    out.sort(key=lambda b: b[2])
    return out


def _flat_offsets(raw: str) -> list[int]:
    """For every RAW offset, the offset in the normalised (`flat`) stream the call sites are matched in.

    qa-review #1578 (r19) Important: the binding positions came from `raw_code` (quotes intact, brackets kept) and were
    compared with call positions from `flat` (quotes dropped, brackets spaced) - two coordinate systems. After enough
    quote characters the offsets drift and a real write stops matching its own alias:
    `const x = "";` x100 followed by `const a = db.collection("credit_requests"); a.updateOne(...)` scanned clean.
    This replays exactly the two transforms applied to `raw_code` so the comparison happens in ONE system.
    """
    keep = [True] * len(raw)
    for m in _ESCAPED_QUOTE.finditer(raw):
        keep[m.start()] = False                       # the backslash the escaped-quote rule drops
    prefix = [0] * (len(raw) + 1)
    for i, ch in enumerate(raw):
        if not keep[i]:
            prefix[i + 1] = prefix[i]
        elif ch in ('"', "'"):
            prefix[i + 1] = prefix[i]                 # dropped by the quote translate
        else:
            prefix[i + 1] = prefix[i] + 1
    return prefix


def _mongo_aliases(binding_text: str, consts: set[str]) -> dict[str, list[tuple[int, bool]]]:
    """name -> [(position, is_credit)] for every assignment, in file order.

    qa-review #1578 (r15) fixed the false positive (a name rebound to another collection stayed an alias for the rest
    of the file). qa-review #1578 (r16) found the mirror image: keeping only the LAST binding hid an EARLIER write -
    `let coll = db.collection("credit_requests"); coll.updateOne(...); coll = db.collection("artists");` is a real
    direct status write and scanned clean. So the binding is resolved AT EACH CALL SITE: a name is an alias at
    position p when the last assignment before p is a credit expression.
    """
    receivers: set[str] = set(consts)
    bindings = _mongo_bindings(binding_text)
    # ONE FORWARD PASS, in file order: each binding is resolved against the timeline built SO FAR, so a transitive
    # reference sees its source as it stood at that assignment (qa-review #1578 r17).
    timeline: dict[str, list[tuple[int, bool]]] = {}
    fmap = _flat_offsets(binding_text)                # ONE coordinate system: the flat stream the calls match in
    for name, rhs, pos in bindings:
        if name in {"db", "collection", "getCollection", "getcollection", "get_collection"}:
            continue
        is_credit = _is_credit_expr(rhs, consts, receivers,
                                    alias_at=lambda n, _p=pos: _alias_at(timeline, n, _p))
        timeline.setdefault(name, []).append((fmap[pos], is_credit))
    return timeline


def _alias_at(timeline: dict[str, list[tuple[int, bool]]], name: str, pos: int) -> bool:
    """Was `name` bound to the credit collection at `pos`? The last assignment BEFORE the call decides."""
    live = False
    for at, is_credit in timeline.get(name, ()):
        if at >= pos:
            break
        live = is_credit
    return live


def _mongo_alias_hits(timeline: dict[str, list[tuple[int, bool]]], body: str) -> list[tuple[int, str]]:
    """Every write verb on an alias that was bound to the credit collection AT THAT POINT.

    Both access forms are matched: `.verb(` / `?.verb(` and the BRACKET call, which normalises to ` alias verb ( `
    (qa-review #1578 r16: `const c = db.credit_requests; c["updateOne"](...)` scanned clean).
    """
    hits: list[tuple[int, str]] = []
    for alias in sorted(timeline):
        if alias in {"db", "collection", "getCollection", "getcollection", "get_collection"}:
            continue
        pattern = (rf"(?<![A-Za-z0-9_$]){re.escape(alias)}(?:{_MONGO_ACCESS}{_MONGO_VERBS}\s*\(|"
                   rf"\s+(?:{_MONGO_VERBS})\s*\()")
        for m in re.finditer(pattern, body, re.IGNORECASE):
            if _alias_at(timeline, alias, m.start()):
                hits.append((m.start(), MONGO_MSG))
    return hits


def scan(text: str, path: str | None = None) -> list[tuple[int, str]]:
    """[(line, message)] for one file, in file order, one hit per rule per line.

    `path` selects the comment syntax (qa-review #1578 r13): the same bytes are a comment in one language and code in
    another, and the caller always knows which file it read.
    """
    # ORDER MATTERS: comments are blanked FIRST, on the text as written (the scanner needs the quotes to know it is
    # inside a string literal), and only then are quotes dropped. Doing it the other way round turns `"//"` into a
    # comment and blanks the rest of the line - a false green QA reproduced (QA #1578, fourth round).
    uncommented = _blank_comments(text, path)
    flat = _ESCAPED_QUOTE.sub("", uncommented).translate(_QUOTES)
    raw_code = _ESCAPED_QUOTE.sub("", uncommented)      # quotes kept: a quote is what separates a code key from prose
    hits: list[tuple[int, str]] = []
    seen: set[tuple[int, str]] = set()
    consts = _credit_constants(raw_code)
    in_string = _flat_string_mask(raw_code)             # string CONTENT, in flat coordinates (qa-review #1578 r21)
    found = [(m.start(), msg) for rx, msg in RULES for m in rx.finditer(flat)]
    found += [(m.start(), MONGO_MSG) for m in _mongo_receiver_pattern(consts).finditer(flat)]
    found += _collection_receiver_hits(flat, consts, in_string)
    found += [(m.start(), MONGO_MSG) for m in _mongo_bracket_call_pattern(consts).finditer(flat)]
    found += [(m.start(), NOTIFY_MSG) for m in NOTIFY_FALSE.finditer(raw_code)]
    found += _mongo_alias_hits(_mongo_aliases(raw_code, consts), flat)
    for start, msg in found:
        line = flat.count("\n", 0, start) + 1
        if (line, msg) in seen:
            continue
        seen.add((line, msg))
        hits.append((line, msg))
    hits.sort()
    return hits


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", required=True)
    ap.add_argument("--allow", required=True)
    args = ap.parse_args(argv)

    root = args.root.rstrip("/") or "/"
    try:
        with open(args.allow, encoding="utf-8", errors="replace") as fh:
            allow = {ln.split("#", 1)[0].strip() for ln in fh}
    except OSError as exc:  # fail closed: an unreadable allowlist is not "nothing is allowed"
        print(f"ERROR: allowlist {args.allow} unreadable: {exc}", file=sys.stderr)
        return 2
    allow.discard("")

    bad = 0
    n = 0
    for rel in (ln.strip() for ln in sys.stdin):
        if not rel:
            continue
        n += 1
        if rel in allow:
            continue
        try:
            with open(f"{root}/{rel}", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as exc:
            print(f"ERROR: {rel} unreadable: {exc}", file=sys.stderr)
            return 2
        for line, msg in scan(text, rel):
            print(f"VIOLATION: {rel}:{line} — {msg}")
            bad = 1

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
