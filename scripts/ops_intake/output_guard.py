"""Every Ops customer reply passes the Caroline OUTPUT GUARD before it is posted.

Why this module exists (dispatch spec §3): the Ops bot's 34 Intercom customer replies in the 14-day
census never touched `guardOutbound`. Caroline's replies do, and the difference is the whole safety
layer — promises, secret sauce, contradicted process lines, off-topic. Two bots answering the same
customer from the same process is precisely how the two answers drift.

Design rules:

1. **One implementation.** This module does not re-implement the guard. It shells out to
   `guard_bridge.mjs`, which imports the plugin's own `caroline-output-guard.ts` (see
   `ts_resolve_hooks.mjs` for why that needs a loader hook). A Python copy would be a second source
   of truth for the exact strings that may reach a customer.
2. **Fail CLOSED.** If node is missing, the bridge exits non-zero, or the payload is unreadable,
   `check()` raises `GuardUnavailable`. The caller then sends NOTHING and hands off. A guard that
   silently degrades to "pass" is worse than no guard, because the ledger still claims a
   `guard_version`.
3. **Answer-bank only.** `line()` returns an entry VERBATIM; the answerer never composes customer
   copy of its own, so what goes out is exactly what `policies`-level review approved. A bank line
   whose `requiresFact` is not TRUE at send is refused here (Fable r5 [key=status-chase-fact]:
   only a known-true fact lets a fact-conditioned line through; false OR unknown hands off).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
BRIDGE = HERE / "guard_bridge.mjs"
HOOKS = HERE / "ts_resolve_hooks.mjs"
NODE = os.environ.get("OPS_INTAKE_NODE", "node")
TIMEOUT_S = int(os.environ.get("OPS_INTAKE_GUARD_TIMEOUT_S", "60"))


class GuardUnavailable(RuntimeError):
    """The guard could not be run. The caller must send nothing (fail closed)."""


class LineRefused(RuntimeError):
    """The requested answer-bank line may not be sent for this ask."""


@dataclass(frozen=True)
class GuardOutcome:
    verdict: str            # pass | block
    body: str
    guard_version: str
    bank_version: str
    mode: str
    flags: list[dict[str, str]] = field(default_factory=list)

    @property
    def blocked(self) -> bool:
        return self.verdict != "pass"


@dataclass(frozen=True)
class BankLine:
    id: str
    intents: tuple[str, ...]
    text: str
    requires_fact: str | None = None
    lead: str | None = None


def _node_cmd(*args: str) -> list[str]:
    return [NODE, "--experimental-strip-types", "--no-warnings",
            "--import", str(HOOKS), str(BRIDGE), *args]


def _run(payload: dict[str, Any] | None, *args: str) -> dict[str, Any]:
    if shutil.which(NODE) is None:
        raise GuardUnavailable(f"node not found on PATH ({NODE}); cannot run the output guard")
    if not BRIDGE.exists() or not HOOKS.exists():
        raise GuardUnavailable(f"guard bridge missing ({BRIDGE} / {HOOKS})")
    try:
        p = subprocess.run(_node_cmd(*args), input=json.dumps(payload or {}),
                           capture_output=True, text=True, timeout=TIMEOUT_S, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GuardUnavailable(f"guard bridge did not run: {exc}") from exc
    body = (p.stdout or "").strip()
    if p.returncode != 0:
        detail = body or (p.stderr or "").strip() or f"exit {p.returncode}"
        raise GuardUnavailable(f"guard bridge failed: {detail}")
    try:
        got = json.loads(body.splitlines()[-1]) if body else {}
    except ValueError as exc:
        raise GuardUnavailable(f"guard bridge printed no JSON: {body[:200]}") from exc
    if not got.get("ok"):
        raise GuardUnavailable(f"guard bridge refused: {got.get('error') or 'no reason'}")
    return got


def check(reply: str, *, customer_text: str = "", customer_names: list[str] | None = None,
          customer_emails: list[str] | None = None, open_request: bool | None = None) -> GuardOutcome:
    """Run the real guard on one reply. Raises GuardUnavailable rather than returning a pass."""
    payload: dict[str, Any] = {"reply": reply, "customerText": customer_text,
                               "customerNames": customer_names or [],
                               "customerEmails": customer_emails or []}
    if open_request is not None:
        payload["openRequest"] = bool(open_request)
    got = _run(payload)
    return GuardOutcome(
        verdict=str(got.get("verdict") or ""),
        body=str(got.get("body") or ""),
        guard_version=str(got.get("guardVersion") or ""),
        bank_version=str(got.get("bankVersion") or ""),
        mode=str(got.get("mode") or ""),
        flags=[{k: str(v) for k, v in (f or {}).items()} for f in (got.get("flags") or [])],
    )


def bank() -> dict[str, BankLine]:
    """The approved lines, read from the plugin's own answer bank (never a copy)."""
    got = _run(None, "--bank")
    out: dict[str, BankLine] = {}
    for e in got.get("entries") or []:
        out[str(e["id"])] = BankLine(
            id=str(e["id"]),
            intents=tuple(str(i) for i in (e.get("intents") or [])),
            text=str(e["text"]),
            requires_fact=e.get("requiresFact"),
            lead=e.get("lead"),
        )
    return out


def line(line_id: str, *, open_request: bool | None = None,
         bank_lines: dict[str, BankLine] | None = None) -> str:
    """One approved line, verbatim, or `LineRefused`.

    A fact-conditioned line (`requiresFact: open_request`) is refused unless `open_request is True`.
    `None` (unknown) and `False` are both refusals: the send-time fact must be MEASURED true, which
    is the same fail-closed rule the plugin's guard applies.
    """
    lines = bank_lines if bank_lines is not None else bank()
    entry = lines.get(line_id)
    if entry is None:
        raise LineRefused(f"no answer-bank line {line_id!r} (known: {sorted(lines)})")
    if entry.requires_fact == "open_request" and open_request is not True:
        state = "unknown" if open_request is None else "false"
        raise LineRefused(f"{line_id}: requires open_request == true at send, measured {state}")
    if entry.requires_fact and entry.requires_fact != "open_request":
        raise LineRefused(f"{line_id}: unhandled requiresFact {entry.requires_fact!r}")
    return entry.text


def check_line(line_id: str, *, customer_text: str = "", open_request: bool | None = None,
               customer_names: list[str] | None = None,
               customer_emails: list[str] | None = None) -> tuple[str, GuardOutcome, dict[str, BankLine]]:
    """Resolve a bank line AND run the guard on it. Returns (text, outcome, bank).

    An approved line is masked by the guard, so this is not a rubber stamp: it still blocks a line
    that would promise or reveal something the bank text does not (a guard rule added after the
    line was written, which is exactly when a second layer earns its keep).
    """
    lines = bank()
    text = line(line_id, open_request=open_request, bank_lines=lines)
    outcome = check(text, customer_text=customer_text, open_request=open_request,
                    customer_names=customer_names, customer_emails=customer_emails)
    return text, outcome, lines


def _cli(argv: list[str]) -> int:
    """`python3 guard.py --bank` / `--check <reply>` — a reviewer's quick look, no hidden behaviour."""
    if "--bank" in argv:
        for lid, entry in sorted(bank().items()):
            flags = f" requiresFact={entry.requires_fact}" if entry.requires_fact else ""
            print(f"{lid}{flags}")
        return 0
    if "--check" in argv:
        i = argv.index("--check")
        reply = argv[i + 1] if len(argv) > i + 1 else ""
        try:
            out = check(reply)
        except GuardUnavailable as exc:
            print(f"GUARD UNAVAILABLE (fail closed): {exc}", file=sys.stderr)
            return 2
        print(json.dumps(out.__dict__, indent=2))
        return 0
    print("usage: guard.py [--bank | --check <reply>]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
