#!/usr/bin/env python3
"""CI guard: every file that can send a message to a customer is on one list, and a file the
list calls `gated` cannot reach its POST without asking the copy gate first.

The list is policies/outbound-copy-senders.json. A row is one file:

    gated   every function in the file that holds a customer-send call is named in
            `send_functions`, and each asks the gate (`sendgate.require_verdict` or
            `copy_gate.require`: two callers of the same scripts/outbound_copy/gate.py, both
            raising when it has not approved the exact bytes) directly, or through a helper in
            the same file that does, in a statement of its OWN body ABOVE the send: not inside
            an `if`, a loop, a `try` or a `with`, where the send could be reached without the
            ask having run. Checked on the AST.
    gated_elsewhere
            behind the same gate in a shape this AST rule cannot read (a bash script; an ask
            whose answer is returned as a hold instead of raised). It must name the test file
            that proves a body with no verdict is not sent (`checked_by`, which must exist)
            and say why it is not `gated` (`why`).
    open    a customer sender that is not behind the gate yet. It must name the lane that owns
            wiring it (`owner`) and why it is open (`why`). Printed on every run, so an open
            sender is a line in CI output, not something somebody remembers.

`not_senders` are files that merely mention a send endpoint (a doc string, a doctrine check).

Fails (exit 1) when: a file matching a send pattern is on neither list; a listed file is gone;
a `gated` file has a send function that is unlisted or does not ask the gate; with
`--base REF`, a file that was `gated` or `gated_elsewhere` at REF is `open` or unlisted now.

What this does NOT prove: that the patterns below find every sender. They are the shapes this
tree uses today (an Intercom reply or message POST, `gog gmail send`, the send-gateway
`/v1/send`, `intercom-ops-write.sh reply`). A sender written in a new shape is caught by
review, not by this file. Senders that only call `scripts/intercom-verify-request.sh` are not
listed: that script holds the POST, so it is the row.
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "policies" / "outbound-copy-senders.json"
SEND_RE = re.compile(
    r"""conversations/[^"' \n]*/reply"""          # Intercom reply
    r"""|["']/messages["']"""                      # Intercom new message
    r"""|gog["', ]+gmail["', ]+send"""             # gog gmail send (shell or argv list)
    r"""|/v1/send\b"""                             # send-gateway
    r"""|send_draft\("""                           # outreach Gmail drafts
    r"""|OPS_WRITE,\s*["']reply["']"""             # intercom-ops-write.sh reply, argv list
)
SCAN_SUFFIXES = (".py", ".sh", ".js", ".ts")
SKIP_PARTS = ("/tests/", "/test/", "/dist/", "/node_modules/", "/redteam/", "/fixtures/")
GATE_CALLS = (("sendgate", "require_verdict"), ("copy_gate", "require"))
BEHIND = ("gated", "gated_elsewhere")


def tracked(root: Path) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "scripts", "plugins"],
                         capture_output=True, text=True, check=True).stdout
    return [p for p in out.splitlines()
            if p.endswith(SCAN_SUFFIXES) and not any(s in f"/{p}" for s in SKIP_PARTS)
            and not Path(p).name.startswith("test_") and ".test." not in p
            and p != "scripts/check-outbound-copy-gate.py"]


def discover(root: Path) -> set[str]:
    found = set()
    for rel in tracked(root):
        try:
            text = (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if SEND_RE.search(text):
            found.add(rel)
    return found


def _is_gate_call(node: ast.AST) -> bool:
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and (node.func.value.id, node.func.attr) in GATE_CALLS)


def _unconditional_ask(fn: ast.AST, helpers: set[str]) -> int:
    """Line of the first statement in `fn`'s OWN body whose whole value is the gate call (or a call
    to a helper that asks). 0 = none. Only a plain statement, an assignment or a return counts: a
    call inside `if`, a loop, `try`, `with`, or an expression such as `x or ask()` may never run,
    and one that never runs does not stand between the function's entry and its send."""
    for stmt in getattr(fn, "body", []):
        value = stmt.value if isinstance(stmt, (ast.Expr, ast.Assign, ast.AnnAssign, ast.Return)) else None
        if value is None:
            continue
        if _is_gate_call(value) or (isinstance(value, ast.Call) and isinstance(value.func, ast.Name)
                                    and value.func.id in helpers and value.func.id != getattr(fn, "name", "")):
            return stmt.lineno
    return 0


def _functions(tree: ast.AST) -> dict[str, ast.AST]:
    return {n.name: n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def _send_line(fn: ast.AST, lines: list[str]) -> int:
    """First line of `fn` that holds a send call, ignoring its docstring and comments. 0 = none."""
    doc_end = 0
    body = getattr(fn, "body", [])
    if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
            and isinstance(body[0].value.value, str):
        doc_end = body[0].end_lineno or 0
    for no in range(max(fn.lineno, doc_end + 1), (fn.end_lineno or fn.lineno) + 1):
        code = lines[no - 1].split("#", 1)[0]
        if SEND_RE.search(code):
            return no
    return 0


def check_gated(root: Path, row: dict) -> list[str]:
    rel = row["path"]
    if not rel.endswith(".py"):
        return [f"{rel}: `gated` is only checkable for Python; list it `open` until it has a checker"]
    src = (root / rel).read_text(encoding="utf-8")
    try:
        tree = ast.parse(src)
    except SyntaxError as exc:
        return [f"{rel}: cannot be parsed ({exc})"]
    lines, fns = src.splitlines(), _functions(tree)
    helpers = {name for name, fn in fns.items() if _unconditional_ask(fn, set())}
    listed = list(row.get("send_functions") or [])
    problems = []
    if not listed:
        problems.append(f"{rel}: `gated` with no send_functions")
    # Nested functions are walked too, so the innermost function holding the send is the one named.
    holders = {name for name, fn in fns.items() if _send_line(fn, lines)
               and not any(_send_line(inner, lines) for inner in ast.walk(fn)
                           if inner is not fn and isinstance(inner, (ast.FunctionDef, ast.AsyncFunctionDef)))}
    for name in sorted(holders - set(listed)):
        problems.append(f"{rel}: {name}() holds a customer send and is not in send_functions")
    module_level = [no for no, line in enumerate(lines, 1) if SEND_RE.search(line.split("#", 1)[0])
                    and not any(fn.lineno <= no <= (fn.end_lineno or fn.lineno) for fn in fns.values())]
    in_docstring = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Expr) and isinstance(getattr(node, "value", None), ast.Constant) \
                and isinstance(node.value.value, str):
            in_docstring.update(range(node.lineno, (node.end_lineno or node.lineno) + 1))
    for no in module_level:
        if no not in in_docstring:
            problems.append(f"{rel}:{no}: a customer send outside any function cannot be gated")
    for name in listed:
        fn = fns.get(name)
        if fn is None:
            problems.append(f"{rel}: send function {name}() does not exist")
            continue
        send_at = _send_line(fn, lines)
        if not send_at:
            problems.append(f"{rel}: {name}() is listed as a send function but holds no send")
            continue
        asked_at = _unconditional_ask(fn, helpers)
        if not asked_at or asked_at >= send_at:
            problems.append(f"{rel}: {name}() reaches its send at line {send_at} without asking "
                            f"the copy gate above it in a statement that always runs")
    return problems


def load(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("version") != 1 or not isinstance(data.get("senders"), list):
        raise ValueError("registry must be {version: 1, senders: [...], not_senders: [...]}")
    return data


def check(root: Path, registry: dict, base: dict | None = None) -> tuple[list[str], list[dict]]:
    problems: list[str] = []
    senders = {r.get("path"): r for r in registry["senders"]}
    not_senders = {r.get("path"): r for r in registry.get("not_senders") or []}
    if len(senders) != len(registry["senders"]):
        problems.append("a path is listed twice in senders")
    for path in sorted(set(senders) & set(not_senders)):
        problems.append(f"{path}: listed as both a sender and not a sender")
    for path, row in sorted(senders.items()):
        if not path or not (root / path).is_file():
            problems.append(f"{path}: listed, but there is no such file")
            continue
        if not row.get("family"):
            problems.append(f"{path}: no family")
        status = row.get("status")
        if status == "gated":
            problems.extend(check_gated(root, row))
        elif status == "gated_elsewhere":
            proof = str(row.get("checked_by") or "")
            if not proof or not row.get("why"):
                problems.append(f"{path}: `gated_elsewhere` must name the test that proves it (`checked_by`) and say why")
            elif not (root / proof).is_file():
                problems.append(f"{path}: `checked_by` names {proof}, and there is no such file")
        elif status == "open":
            if not row.get("owner") or not row.get("why"):
                problems.append(f"{path}: `open` must name an owner lane and say why")
        else:
            problems.append(f"{path}: status must be `gated`, `gated_elsewhere` or `open`, not {status!r}")
    for path, row in sorted(not_senders.items()):
        if not path or not (root / path).is_file():
            problems.append(f"{path}: listed in not_senders, but there is no such file")
        elif not row.get("why"):
            problems.append(f"{path}: a not_senders row must say why")
    for path in sorted(discover(root) - set(senders) - set(not_senders)):
        problems.append(f"{path}: holds a customer send and is on neither list in "
                        f"{REGISTRY.relative_to(ROOT)}")
    if base is not None:
        for row in base.get("senders") or []:
            now = senders.get(row.get("path"))
            if row.get("status") in BEHIND and (root / str(row.get("path"))).is_file() \
                    and (now is None or now.get("status") not in BEHIND):
                problems.append(f"{row.get('path')}: was `{row.get('status')}` at the base and is not behind the gate now")
    return problems, [r for r in registry["senders"] if r.get("status") == "open"]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--registry", default="")
    ap.add_argument("--base", default="", help="git ref: a sender gated there must still be gated")
    a = ap.parse_args(argv)
    root = Path(a.root).resolve()
    reg_path = Path(a.registry) if a.registry else root / REGISTRY.relative_to(ROOT)
    try:
        registry = load(reg_path)
    except (OSError, ValueError) as exc:
        print(f"FAIL: cannot read {reg_path}: {exc}", file=sys.stderr)
        return 1
    base = None
    if a.base:
        shown = subprocess.run(["git", "-C", str(root), "show", f"{a.base}:{REGISTRY.relative_to(ROOT)}"],
                               capture_output=True, text=True)
        if shown.returncode == 0:
            try:
                base = json.loads(shown.stdout)
            except ValueError:
                print(f"FAIL: the registry at {a.base} is not JSON", file=sys.stderr)
                return 1
        elif "exists on disk, but not in" not in shown.stderr and "does not exist in" not in shown.stderr:
            print(f"FAIL: cannot read the registry at {a.base}: {shown.stderr.strip()[:200]}", file=sys.stderr)
            return 1
    problems, still_open = check(root, registry, base)
    gated = [r for r in registry["senders"] if r.get("status") in BEHIND]
    print(f"outbound copy gate: {len(gated)} sender file(s) gated, {len(still_open)} open")
    for r in still_open:
        print(f"  OPEN {r['path']} [{r.get('family')}] owner={r.get('owner')}: {r.get('why')}")
    for p in problems:
        print(f"FAIL: {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
