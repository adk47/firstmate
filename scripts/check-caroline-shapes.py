#!/usr/bin/env python3
"""PR gate for the Caroline fix-loop register (policies/caroline-shapes.json).

Fails when the register breaks one of the loop's rules. The rules themselves live in
scripts/caroline_monitor/fixloop.py (`validate`); this file only runs them against the repo
copy, the recorded baseline and the recorded calibration:

  * every classifier shape has exactly one row, and no row names a conversation
  * `person` rows name why, and person shapes stay a small share of real threads
  * only rule and tool rows carry automation; a refusal names its reason and its way back
  * the four things Caroline never does are all registered as exemptions
  * a shipped fix carries the date and the ref that arm its re-measurement
  * the monitor's page ceilings never sit above the recorded baseline
  * the hand-label calibration on file is for the CURRENT rule set

Exit 0 clean, 1 on any violation, 2 when a file cannot be read.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from caroline_monitor import cli, fixloop, rules  # noqa: E402


def main():
    try:
        register = fixloop.load_register()
    except fixloop.RegisterError as e:
        print(f"check-caroline-shapes: {e}", file=sys.stderr)
        return 2
    baseline = cli.load_baseline()
    if baseline is None:
        print(f"check-caroline-shapes: cannot read {cli.BASELINE_PATH}", file=sys.stderr)
        return 2
    errors = fixloop.validate(register, baseline)
    if baseline.get("rules_version") != rules.RULES_VERSION:
        errors.append(f"baseline is for rules {baseline.get('rules_version')}, the classifier is "
                      f"{rules.RULES_VERSION}: re-run `caroline-monitor.py baseline`")
    try:
        with open(cli.CALIBRATION_PATH) as f:
            calibration = json.load(f)
    except (OSError, ValueError) as e:
        print(f"check-caroline-shapes: cannot read {cli.CALIBRATION_PATH}: {e}", file=sys.stderr)
        return 2
    if calibration.get("rules_version") != rules.RULES_VERSION:
        errors.append(f"calibration is for rules {calibration.get('rules_version')}, the classifier is "
                      f"{rules.RULES_VERSION}: the precision on file was not measured on these rules; re-label")
    for error in errors:
        print(f"check-caroline-shapes: {error}", file=sys.stderr)
    if errors:
        return 1
    shapes = register["shapes"]
    print(f"check-caroline-shapes: OK ({len(shapes)} shapes, "
          f"{sum(1 for r in shapes.values() if r['fix_type'] == 'person')} need a person, "
          f"{sum(1 for r in shapes.values() if r.get('shipped_at'))} shipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
