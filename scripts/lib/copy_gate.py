"""The Python senders' one way to ask the outbound copy gate (scripts/outbound_copy/gate.py).

Every script that POSTs customer-visible text calls `require()` on the exact body immediately before the POST. It
returns only when the gate answers "approved" for those exact bytes with a signed verdict id; anything else raises
`CopyHeld` and the caller sends nothing. There is no flag, no environment variable and no argument that skips it.

    from lib import copy_gate
    copy_gate.require("resolve-notify", message)        # raises CopyHeld -> do not POST, do not mark as sent

`CopyHeld.pending` is True when the body is simply waiting for its first review (the normal first-run state: the
body is now queued and the next run sends it once the reviewer has approved it). False means the reviewer refused
the copy, proposed a rewrite, or the gate could not run - a state somebody has to look at.

The gate is found from this file's own location and run as a file under `python3 -I`, the same way the bash sender
runs it. `GATE` and `STORE` are module attributes so a test can point them at a scratch tree; they are deliberately
not read from the environment (a caller-selectable gate is a caller-selectable approval).
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

GATE = Path(__file__).resolve().parents[1] / "outbound_copy" / "gate.py"
STORE = ""                       # "" = the gate's own default store
TIMEOUT_S = 60
RC_OBSERVED = 4                  # the gate's "observe mode: send, and here is what the review says"
VERDICT_ID_RE = re.compile(r"^ocv-[0-9a-f]{16}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


class CopyHeld(RuntimeError):
    """The gate did not approve this exact body. Nothing may be sent."""

    def __init__(self, reason: str, body_sha256: str = "", pending: bool = False):
        super().__init__(f"copy_review_hold: {reason}")
        self.reason, self.body_sha256, self.pending = reason, body_sha256, pending


def require(campaign: str, body: str, *, subject: str = "", copy: str = "", kind: str = "",
            message_type: str = "", data: tuple[str, ...] | list[str] = ()) -> dict:
    """The gate's answer when `body` may be sent; else CopyHeld.

    Two answers are a send: `approved` (exit 0: a signed approval on these bytes) and `observed` (exit 4: the
    campaign is in observe mode, so the review is recorded and the send goes ahead; `answer["review"]` says what the
    review said). Which mode applies is the gate's table, never this caller's choice. One documented exception may
    only TIGHTEN observe to a hold, never loosen: bulk_asks.EnforcedCopyGate, see docs/credit-verification/bulk-asks.md."""
    sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
    argv = [sys.executable, "-I", str(GATE), "check", "--campaign", campaign, "--copy", copy, "--kind", kind,
            "--message-type", message_type]
    if STORE:
        argv += ["--store", str(STORE)]
    try:
        proc = subprocess.run(argv, input=json.dumps({"subject": subject, "body": body, "data": list(data)}), capture_output=True,
                              text=True, timeout=TIMEOUT_S, check=False)
        ans = json.loads(proc.stdout.strip().splitlines()[-1])
        if not isinstance(ans, dict):
            raise ValueError("not an object")
    except (OSError, subprocess.SubprocessError, ValueError, IndexError) as exc:
        raise CopyHeld(f"copy_gate_error:{type(exc).__name__}", sha) from exc
    ok = (proc.returncode == 0 and ans.get("result") == "approved" and ans.get("body_sha256") == sha
          and VERDICT_ID_RE.match(str(ans.get("verdict_id", ""))) and SHA_RE.match(str(ans.get("verdict_sha256", ""))))
    observed = (proc.returncode == RC_OBSERVED and ans.get("result") == "observed" and ans.get("mode") == "observe"
                and ans.get("body_sha256") == sha)
    if not (ok or observed):
        reason = str(ans.get("reason") or f"copy_gate_error:rc={proc.returncode}")[:300]
        raise CopyHeld(reason, sha, pending=(proc.returncode == 3 and ans.get("result") == "pending"))
    return ans
