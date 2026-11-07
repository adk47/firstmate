#!/usr/bin/env python3
"""The copy policy: the mechanical form of "we never say more than where the request is".

Run in PR Validation (`python3 scripts/check-request-status-lines.py`, and again as
`tests.test_request_comms`). It fails on:

  1. a structural hole in policies/request-status-lines.json (missing type/state, a line with no
     text, a channel block that is not explicit about being on or off);
  2. an enabled line with no `approval_ref`, or one whose review is still pending;
  3. banned wording in any line that is not a carried-verbatim approved block (a reason, a score,
     a band, a flag, a deadline or a promise);
  4. a placeholder that is not the one approved variable ({date});
  5. DRIFT between a carried-verbatim line and its own source file — the decline line vs
     plugins/intercom/src/answer-bank.ts, the erasure ack vs
     workspaces/support/reference/gdpr-erasure-requests.md. Two copies of one approved sentence
     is how a company says two different things.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from request_comms import lines  # noqa: E402


# ref -> the ONE line key it was approved for (the same binding `lines.validate` enforces). A ref is
# not a licence to waive the copy gate anywhere: following it as a movable label let the credit
# decline and the erasure ack be swapped, with a clean validator.
PINNED = {ref: (b[0], b[1], b[2]) for ref, b in lines.PINNED_BINDINGS.items()}


def main(argv: list[str] | None = None) -> int:
    path = (argv or sys.argv[1:])[0] if (argv or sys.argv[1:]) else str(ROOT / "policies/request-status-lines.json")
    policy = lines.load(path)
    problems = lines.validate(policy)

    pinned = lines.pinned_verbatim_texts(ROOT)
    for ref, (btyp, bstate, name) in PINNED.items():
        want = pinned.get(name, "")
        if not want:
            problems.append(f"cannot read the approved source for {ref} ({name})")
            continue
        found = [f"{t}/{s}" for t in lines.TYPES
                 for s in lines.STATES
                 if str(((policy.get("lines") or {}).get(t) or {}).get(s, {}).get("approval_ref") or "") == ref]
        if not found:
            problems.append(f"no line carries {ref}: an approved text is never dropped silently")
            continue
        for key in found:
            typ, state = key.split("/")
            if (typ, state) != (btyp, bstate):
                problems.append(f"lines.{key} carries {ref}, which was approved for {btyp}/{bstate}: "
                                "an approved ref cannot be moved to another line")
                continue
            got = policy["lines"][typ][state]
            if str(got.get("text") or "").strip() != want.strip():
                problems.append(f"lines.{key} drifted from its approved source ({ref}): "
                                "copy the sentence, never retype it")

    for p in problems:
        print(f"PROBLEM: {p}")
    if problems:
        print(f"\n{len(problems)} problem(s) in {Path(path).name}")
        return 1
    # The bell is the one rung that ships ON, and its words are not in this repo: say how many
    # kinds it can reach and which states are mapped, so a reader sees the surface, not a switch.
    from request_comms import routing  # noqa: PLC0415
    bell = (policy.get("channels") or {}).get("bell") or {}
    print(f"bell: enabled={bell.get('enabled')} kinds={len(routing.BELL_KEYS)} "
          f"mapped={len(routing.BELL_STATE_KEYS) + len(routing.BELL_RAW_KEYS)} "
          f"restrictions={len(bell.get('workflow_keys') or {})}")
    enabled = [f"{t}/{s}" for t in lines.TYPES for s in lines.STATES
               if (policy["lines"].get(t) or {}).get(s, {}).get("enabled")]
    print(f"{Path(path).name} OK — {len(lines.TYPES)} request types x {len(lines.STATES)} states, "
          f"driver {'ON' if policy.get('enabled') else 'off'}, "
          f"lines enabled: {', '.join(enabled) if enabled else 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
