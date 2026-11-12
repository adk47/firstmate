#!/usr/bin/env python3
"""The one way a Python sender asks "may this exact message go out?".

Every customer message about a verification (a credit request, a profile claim, a merge, a
status line on any of them) needs a reviewer verdict bound to the sha256 of the bytes that are
about to be posted. The verdict store, the reviewer and the signature check live in
`gate.py`, next to this file; this module is the CALLER side, so that each send family does
not grow its own copy of "run the gate and read the answer".

    permit = sendgate.require_verdict(body, family="resolve-notify", campaign="resolve-notify")
    ... POST exactly `body` ...
    sendgate.record_sent(permit, ref=conv_id, message_id=part_id)

`require_verdict` returns a Permit only when the gate exits 0, says `approved`, names a
verdict id, and echoes the same body and subject hashes this module computed itself. Anything
else raises `NotApproved`, and the caller must not send:

    pending   no verdict for these bytes yet; the gate queued the body for review
    refused   the reviewer or the code lint said no (the reason never reaches the customer)
    error     the gate could not answer: missing, timed out, crashed, or answered something
              this module cannot read. "Could not ask" is never "nobody objected".

Every answer is appended to LOG_PATH as one JSON line carrying hashes and ids only, never the
message text. A log that cannot be written does not turn a refusal into a send, and does not
turn an approval into a refusal: the row also goes to stderr, which the unit's journal keeps.

The gate's path is this file's own directory. There is no environment variable and no
argument that points at another gate: a caller that could choose the gate could choose the
answer. Call this from the SAME function that performs the POST, immediately before it;
`scripts/check-outbound-copy-gate.py` fails CI when a send function does not.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

GATE_PATH = Path(__file__).resolve().parent / "gate.py"
LOG_PATH = Path("/var/lib/hydra/outbound-copy/sendgate.jsonl")
GATE_TIMEOUT_S = 60

# The gate's exit codes (gate.py `check`). Only 0 is a send.
RC_APPROVED, RC_REFUSED, RC_ERROR, RC_PENDING, RC_OBSERVED = 0, 1, 2, 3, 4
_RESULT_BY_RC = {RC_REFUSED: "refused", RC_ERROR: "error", RC_PENDING: "pending"}


class NotApproved(RuntimeError):
    """The message must not be sent. `result` is pending | refused | error."""

    def __init__(self, result: str, reason: str) -> None:
        super().__init__(f"copy gate: {result} ({reason})")
        self.result = result
        self.reason = reason


@dataclass(frozen=True)
class Permit:
    family: str
    campaign: str
    copy: str
    body_sha256: str
    subject_sha256: str
    verdict_id: str
    verdict_sha256: str


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log(row: dict) -> None:
    line = json.dumps({"at": _now(), **row}, sort_keys=True)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(LOG_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (line + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    except OSError as exc:
        print(f"sendgate: log unwritable ({exc}); row follows", file=sys.stderr)
        print(f"sendgate: {line}", file=sys.stderr)


def _run_gate(argv: list[str], stdin: str) -> tuple[int, str]:
    """The one subprocess seam: (exit code, stdout). Raises OSError / TimeoutExpired."""
    done = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=GATE_TIMEOUT_S)
    return done.returncode, done.stdout


def _ask(body: str, subject: str, campaign: str, copy: str, kind: str, message_type: str) -> tuple[str, str, dict]:
    """(result, reason, the gate's answer). result is approved | observed | pending | refused | error.

    `observed` is the gate's observe mode (exit 4): the review of these bytes is recorded and the send goes ahead.
    The gate's own table picks the mode per campaign; nothing here can ask for it."""
    if not GATE_PATH.is_file():
        return "error", "copy_gate_unavailable:gate_missing", {}
    argv = [sys.executable, "-I", str(GATE_PATH), "check", "--campaign", campaign, "--copy", copy,
            "--kind", kind, "--message-type", message_type]
    try:
        rc, out = _run_gate(argv, json.dumps({"subject": subject, "body": body}))
    except subprocess.TimeoutExpired:
        return "error", "copy_gate_unavailable:timeout", {}
    except OSError as exc:
        return "error", f"copy_gate_unavailable:{type(exc).__name__}", {}
    try:
        ans = json.loads((out or "").strip().splitlines()[-1])
        if not isinstance(ans, dict):
            raise ValueError("not an object")
    except (ValueError, IndexError):
        return "error", f"copy_gate_unavailable:unreadable_answer_rc{rc}", {}
    reason = str(ans.get("reason") or "")
    if rc == RC_OBSERVED:
        # A send only when the answer says so about THESE bytes; anything less is an error, never a send.
        if ans.get("result") != "observed" or ans.get("mode") != "observe":
            return "error", "copy_gate_unavailable:rc4_without_observe", ans
        if ans.get("body_sha256") != sha256_hex(body) or ans.get("subject_sha256") != sha256_hex(subject):
            return "error", "copy_gate_unavailable:answer_for_other_bytes", ans
        return "observed", f"observed:{ans.get('review') or 'unknown'}", ans
    if rc != RC_APPROVED:
        # An exit code this module does not know is an error, never a softer answer.
        return _RESULT_BY_RC.get(rc, "error"), reason or f"copy_gate_rc{rc}", ans
    # Exit 0 is a send only when the answer says so about THESE bytes.
    if ans.get("result") != "approved":
        return "error", "copy_gate_unavailable:rc0_without_approval", ans
    if ans.get("body_sha256") != sha256_hex(body) or ans.get("subject_sha256") != sha256_hex(subject):
        return "error", "copy_gate_unavailable:answer_for_other_bytes", ans
    if not ans.get("verdict_id") or not ans.get("verdict_sha256"):
        return "error", "copy_gate_unavailable:approval_without_verdict", ans
    return "approved", "", ans


def require_verdict(body: str, *, family: str, campaign: str, copy: str = "", kind: str = "",
                    message_type: str = "", subject: str = "", ref: str = "") -> Permit:
    """Return a Permit for exactly `body` (+ `subject`), or raise NotApproved. Never sends.

    A Permit with an empty `verdict_id` is an OBSERVED send: the campaign is in the gate's observe mode, and the
    log row's `result` says `observed` with what the review said."""
    if not isinstance(body, str) or not body:
        result, reason, ans = "error", "copy_gate_unavailable:empty_body", {}
        body = body if isinstance(body, str) else ""
    else:
        result, reason, ans = _ask(body, subject, campaign, copy, kind, message_type)
    row = {"family": family, "campaign": campaign, "copy": copy, "kind": kind, "ref": str(ref),
           "body_sha256": sha256_hex(body), "subject_sha256": sha256_hex(subject), "result": result,
           "reason": reason, "verdict_id": str(ans.get("verdict_id") or ""),
           "verdict_sha256": str(ans.get("verdict_sha256") or "")}
    _log(row)
    if result not in ("approved", "observed"):
        raise NotApproved(result, reason)
    return Permit(family=family, campaign=campaign, copy=copy, body_sha256=row["body_sha256"],
                  subject_sha256=row["subject_sha256"], verdict_id=row["verdict_id"],
                  verdict_sha256=row["verdict_sha256"])


def record_sent(permit: Permit, *, ref: str = "", message_id: str = "", status: str = "sent") -> None:
    """One row tying the delivered message to the verdict that allowed it."""
    _log({**asdict(permit), "ref": str(ref), "message_id": str(message_id), "result": status, "reason": ""})
