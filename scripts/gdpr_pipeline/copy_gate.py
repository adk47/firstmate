"""The reviewer gate for the DSAR ladder's messages: no verdict bound to the exact body, no send.

This is a CLIENT of the outbound-copy gate (`scripts/outbound_copy/gate.py`, owned by the gate's own lane). That
gate queues a body for the reviewer model, and answers `approved` only when a signed verdict statement names this
body's sha256 under the rubric of this message family. This module asks it one question - "may these exact bytes be
sent?" - and turns every answer that is not a verified approval into a hold with a reason.

A hold is the safe failure and the only one: the gate file is missing, it cannot run, it times out, it prints
something unreadable, the verdict is pending, the verdict is a refusal or a rewrite, the body hash in the answer
is not the hash we computed, or the answer was given under another family's rubric. None of them sends.

The gate's location is derived from this file's own location. There is no environment variable and no argument
that selects it: a caller-selectable gate is a caller-selectable approval.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

GATE = Path(__file__).resolve().parents[1] / "outbound_copy" / "gate.py"
RUBRIC_FAMILY = "gdpr"
# The gate's campaign name per ladder kind. The gate maps each of these to the `gdpr` rubric family in its own
# table; until it does, its answer names another rubric and `check` holds.
CAMPAIGN = {"ack": "gdpr-ack", "status": "gdpr-status", "extension": "gdpr-extension", "denial": "gdpr-denial", "access": "gdpr-access",
            "final": "gdpr-final"}
TIMEOUT_S = 60
APPROVED, PENDING, REFUSED, ERROR = "approved", "pending", "refused", "error"


@dataclass
class Answer:
    ok: bool                    # True ONLY for a verified approval of these exact bytes
    result: str                 # approved | pending | refused | error
    reason: str = ""
    body_sha256: str = ""
    verdict_id: str = ""
    verdict_sha256: str = ""
    reviewer_model: str = ""
    reviewed_at: str = ""
    rubric: str = ""

    def as_cols(self) -> dict:
        """The `dsar_messages` columns this answer records."""
        return {"gate_result": self.result, "gate_reason": self.reason[:300], "verdict_id": self.verdict_id,
                "verdict_sha256": self.verdict_sha256, "reviewer_model": self.reviewer_model,
                "reviewed_at": self.reviewed_at, "rubric": self.rubric}


def body_sha(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _run(argv: list[str], stdin: str) -> tuple[int, str]:
    p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=TIMEOUT_S)
    return p.returncode, p.stdout


def check(kind: str, body: str, variant: str = "", slot: str = "", subject: str = "", runner=None) -> Answer:
    """May these exact bytes be sent as a `kind` message? Never raises: what cannot be answered is a hold.

    Calling it also QUEUES the body for review when no verdict exists yet (the gate writes the pending request), so
    the author step and the send step ask the same question the same way.
    """
    sha = body_sha(body)
    campaign = CAMPAIGN.get(kind)
    if not campaign:
        return Answer(False, ERROR, f"no gate campaign for message kind {kind!r}", sha)
    if not GATE.is_file():
        return Answer(False, ERROR, f"the copy gate is not installed ({GATE}): nothing is sent without it", sha)
    argv = [sys.executable, "-I", str(GATE), "check", "--campaign", campaign, "--copy", variant, "--kind", slot or kind]
    try:
        rc, out = (runner or _run)(argv, json.dumps({"subject": subject, "body": body}))
    except subprocess.TimeoutExpired:
        return Answer(False, ERROR, f"the copy gate did not answer in {TIMEOUT_S}s", sha)
    except (OSError, subprocess.SubprocessError) as exc:
        return Answer(False, ERROR, f"the copy gate could not run: {exc}", sha)
    try:
        ans = json.loads((out or "").strip().splitlines()[-1])
        if not isinstance(ans, dict):
            raise ValueError("not an object")
    except (ValueError, IndexError) as exc:
        return Answer(False, ERROR, f"the copy gate answered rc={rc} with unreadable output: {exc}", sha)
    result = str(ans.get("result") or "")
    got = Answer(False, result if result in (APPROVED, PENDING, REFUSED, ERROR) else ERROR,
                 str(ans.get("reason") or ""), sha, str(ans.get("verdict_id") or ""),
                 str(ans.get("verdict_sha256") or ""), str(ans.get("reviewer_model") or ""),
                 str(ans.get("reviewed_at") or ""), str(ans.get("rubric") or ""))
    if rc != 0 or result != APPROVED:
        if got.result == APPROVED:      # an "approved" that did not come with rc 0 is not one
            got.result, got.reason = ERROR, f"the copy gate printed approved with rc={rc}"
        if not got.reason:
            got.reason = f"the copy gate answered rc={rc} result={result or '(none)'}"
        return got
    # rc 0 and "approved": now hold it to what an approval of THESE bytes under THIS family must carry.
    if ans.get("body_sha256") != sha:
        got.result, got.reason = ERROR, "the approval names a different body hash than the body to be sent"
    elif ans.get("subject_sha256") != body_sha(subject):
        # Empty or not: an approval given for the same body under another subject line is not an approval of what
        # the recipient would read (QA review of #1908: a reworded subject rode an older verdict).
        got.result, got.reason = ERROR, "the approval names a different subject hash than the subject to be sent"
    elif got.rubric != RUBRIC_FAMILY:
        got.result, got.reason = ERROR, (f"the approval was given under the '{got.rubric or '(none)'}' rubric, not "
                                         f"'{RUBRIC_FAMILY}': the gate does not map {campaign} to it yet")
    elif ans.get("campaign") != campaign:
        got.result, got.reason = ERROR, "the approval is for another campaign"
    elif not got.verdict_id or not got.verdict_sha256:
        got.result, got.reason = ERROR, "the approval carries no verdict id / statement hash to record"
    else:
        got.ok = True
    return got
