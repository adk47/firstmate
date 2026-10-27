"""The account gate every credit approval calls first (captain 2026-10-26 23:30-23:40Z, plan step 1).

Captain: "before any new credit approval, sum that account's user-submitted credits with no independent
Spotify or Tidal anchor. Over the line Fable sets, hold new approvals and ask for proof." Fable set the
level ([key=account-anchor-level], /opt/firstmate/fraud-lens/rules-account.json); fraud-lens-monitor-f1
publishes the ONE shared check on node-8:

    python3 /opt/firstmate/fraud-lens/account_gate.py check <user_id>
    -> one JSON {decision allow|hold|unknown, band, reasons[], unanchored{...}, level{...}, ask_proof, watch}
    exit 0 allow / 3 hold / 2 unknown

This module only calls it. Fail closed: anything but exit 0 with decision "allow" (hold, unknown, a
timeout, unparseable output, a missing user id) is NOT an allow, and the caller never approves.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
from dataclasses import dataclass, field
from typing import Any, Callable

GATE_CMD = os.environ.get("CREDIT_ACCOUNT_GATE_CMD", "python3 /opt/firstmate/fraud-lens/account_gate.py")
TIMEOUT_S = int(os.environ.get("CREDIT_ACCOUNT_GATE_TIMEOUT_S", "60"))
ALLOW, HOLD, UNKNOWN = "allow", "hold", "unknown"


@dataclass(frozen=True)
class GateResult:
    decision: str                      # allow | hold | unknown
    reasons: tuple[str, ...] = ()
    payload: dict[str, Any] = field(default_factory=dict, compare=False)

    @property
    def allowed(self) -> bool:
        return self.decision == ALLOW

    def why(self) -> str:
        return f"account gate {self.decision}" + (f" ({'; '.join(self.reasons)[:200]})" if self.reasons else "")


Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]


def _run(argv: list[str]) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT_S, check=False)


def check(user_id: Any, runner: Runner | None = None) -> GateResult:
    """One account's gate answer. Never raises; every failure is UNKNOWN (= no approval)."""
    if not isinstance(user_id, int) or isinstance(user_id, bool):
        return GateResult(UNKNOWN, ("no account user id on the request",))
    try:
        p = (runner or _run)(shlex.split(GATE_CMD) + ["check", str(user_id)])
    except Exception as exc:  # noqa: BLE001 - timeout / missing binary: fail closed
        return GateResult(UNKNOWN, (f"gate did not run: {type(exc).__name__}",))
    try:
        body = json.loads((p.stdout or "").strip().splitlines()[-1])
    except (ValueError, IndexError):
        return GateResult(UNKNOWN, (f"gate output unreadable (exit {p.returncode})",))
    if not isinstance(body, dict):
        return GateResult(UNKNOWN, (f"gate output unreadable (exit {p.returncode})",))
    reasons = tuple(str(r) for r in body.get("reasons") or [])
    if p.returncode == 0 and body.get("decision") == ALLOW:
        return GateResult(ALLOW, reasons, body)
    if p.returncode == 3 or body.get("decision") == HOLD:
        return GateResult(HOLD, reasons, body)
    return GateResult(UNKNOWN, reasons or (f"gate exit {p.returncode}",), body)


class Cached:
    """Per-run cache: one gate call per account."""

    def __init__(self, fn: Callable[[Any], GateResult] | None = None):
        self.fn = fn or check
        self.seen: dict[Any, GateResult] = {}

    def __call__(self, user_id: Any) -> GateResult:
        if user_id not in self.seen:
            self.seen[user_id] = self.fn(user_id)
        return self.seen[user_id]
