#!/usr/bin/env python3
"""Refuse to let the machine refund class arm itself without a named approval.

`scripts/muso-stripe-write.sh refunds create --machine-approval` spends real money
with no person's Slack id in the loop. Two switches must both move before it can:

  1. the record directory `/etc/hydra/refund-machine-approvals` exists on node-8, and
  2. `policies/refund-machine-approval-automation.json` says `enabled: true` with a
     non-empty `approved_by` and `approval_ref`.

The wrapper enforces both at run time. This guard is about the DIFF: switch 2 is a
file in the repo, so the change that flips it is reviewable, and this script fails
the review when it flips without naming who approved the class and where they said
it. That is the difference between "an operator created a directory" and "somebody
signed off in a diff a reviewer read".

Rules:
  R1  the file exists and parses, with `capability` == refund-machine-approval.
  R2  `enabled` is a boolean (never "true" as a string, never absent).
  R3  `enabled: true` requires a non-empty `approved_by` AND `approval_ref`.
  R4  `approved_by` / `approval_ref` are null-or-non-empty (an empty string is not
      an approval).
  R5  the caps in the file are positive integers and equal the wrapper's own
      compiled constants, so a cap change has to touch both and cannot float.
  R6  with --base <ref>: a diff that flips `enabled` from false to true must set
      both fields in the same change.

Exit 0 clean, 1 violation, 2 read error. Never writes outside a temp file.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "policies" / "refund-machine-approval-automation.json"
WRAPPER = ROOT / "scripts" / "muso-stripe-write.sh"
CAPABILITY = "refund-machine-approval"


def wrapper_caps() -> tuple[int, int] | None:
    """The caps the wrapper enforces, read from its own constants."""
    try:
        text = WRAPPER.read_text(encoding="utf-8")
    except OSError:
        return None
    found = {}
    for name in ("MACHINE_REFUND_CAP_CENTS", "MACHINE_CUSTOMER_CAP_CENTS"):
        m = re.search(rf"^readonly {name}=(\d+)$", text, re.MULTILINE)
        if not m:
            return None
        found[name] = int(m.group(1)) // 100
    return found["MACHINE_REFUND_CAP_CENTS"], found["MACHINE_CUSTOMER_CAP_CENTS"]


def check_row(row: dict) -> list[str]:
    problems: list[str] = []
    if row.get("capability") != CAPABILITY:
        problems.append(f"R1: capability must be {CAPABILITY!r}, got {row.get('capability')!r}")
    enabled = row.get("enabled")
    if not isinstance(enabled, bool):
        problems.append(f"R2: enabled must be true or false, got {enabled!r}")
    for field in ("approved_by", "approval_ref"):
        value = row.get(field, "<absent>")
        if value is not None and not (isinstance(value, str) and value.strip()):
            problems.append(f"R4: {field} must be null or a non-empty string, got {value!r}")
    if enabled is True:
        for field in ("approved_by", "approval_ref"):
            value = row.get(field)
            if not (isinstance(value, str) and value.strip()):
                problems.append(
                    f"R3: enabled is true but {field} is empty. Arming this class spends "
                    "money without a person's Slack id: name who approved it and where."
                )
    caps = wrapper_caps()
    for field, want in (("cap_usd_per_refund", 0), ("cap_usd_per_customer_per_year", 1)):
        value = row.get(field)
        if not isinstance(value, int) or value <= 0:
            problems.append(f"R5: {field} must be a positive integer, got {value!r}")
        elif caps is not None and value != caps[want]:
            problems.append(
                f"R5: {field} is {value} but the wrapper enforces {caps[want]}. "
                "A cap change has to change both, or the number in this file is a lie."
            )
    return problems


def flipped_without_approval(base: str) -> list[str]:
    """R6: did this change arm the class without naming an approval?"""
    rel = "policies/refund-machine-approval-automation.json"
    # "The file is new at this base" and "I could not read the base" are different
    # answers, and only the first one is allowed to pass. A one-line flip in a later
    # PR would otherwise walk through this rule whenever git could not resolve the
    # ref (qa-review 2026-11-15T15:04Z).
    try:
        ref = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}"],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [f"R6: could not resolve the base ref {base!r} ({exc}). Failing closed: an unreadable base is not a new file."]
    if ref.returncode != 0:
        return [f"R6: could not resolve the base ref {base!r}. Failing closed: an unreadable base is not a new file."]
    try:
        exists = subprocess.run(
            ["git", "cat-file", "-e", f"{base}:{rel}"],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [f"R6: could not test for the base copy of {rel} ({exc}). Failing closed."]
    if exists.returncode != 0:
        # The ref resolved and the path is genuinely absent there: a new file. Its own
        # row checks (R1-R5) govern it, so there is no earlier state to have bypassed.
        return []
    try:
        old = subprocess.run(
            ["git", "show", f"{base}:{rel}"],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [f"R6: could not read the base copy of {rel} ({exc}). Failing closed."]
    if old.returncode != 0:
        return [f"R6: {rel} exists at {base} but could not be read (git show exited {old.returncode}). Failing closed: an unreadable base is not a new file."]
    try:
        before = json.loads(old.stdout)
    except ValueError:
        return ["R6: the base copy of the registry does not parse; fix that before arming anything"]
    try:
        after = json.loads(REGISTRY.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [f"R1: the registry does not parse ({exc})"]
    if before.get("enabled") is True or after.get("enabled") is not True:
        return []
    problems = []
    # Both fields must be NEW on the flip, not merely present. A disabled base row
    # can already carry an old approval_ref, and a diff that sets enabled:true plus
    # a new approved_by would otherwise inherit that stale reference and pass
    # (qa-review 2026-11-15T15:5xZ).
    for field in ("approved_by", "approval_ref"):
        was = before.get(field)
        now = after.get(field)
        if not (isinstance(now, str) and now.strip()):
            continue  # R3 already fails this
        if was is not None and was == now:
            problems.append(
                f"R6: {field} is unchanged from the base row ({now!r}). A change that "
                "arms this class has to set a fresh approval in that same change, not "
                "inherit one from a row that was disabled."
            )
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--base", help="git ref to compare against (enables R6)")
    args = ap.parse_args(argv)

    try:
        row = json.loads(REGISTRY.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"FAIL: {REGISTRY} is missing", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"FAIL: cannot read {REGISTRY}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(row, dict):
        print(f"FAIL: {REGISTRY} is not an object", file=sys.stderr)
        return 2

    problems = check_row(row)
    if args.base:
        problems += flipped_without_approval(args.base)

    if problems:
        for p in problems:
            print(f"FAIL: {p}", file=sys.stderr)
        return 1
    state = "ARMED" if row.get("enabled") is True else "unarmed"
    print(
        f"OK: refund-machine-approval is {state} "
        f"(caps ${row['cap_usd_per_refund']}/${row['cap_usd_per_customer_per_year']}, "
        f"approved_by={row.get('approved_by') or '-'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
