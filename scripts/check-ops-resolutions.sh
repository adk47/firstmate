#!/usr/bin/env bash
# check-ops-resolutions.sh — CI guard: the Ops resolution LOOKUP must stay closed and safe.
#
# WHY (2026-11-05). `policies/ops-resolutions.json` replaces an LLM-chosen production write with a
# lookup: a closed intent vocabulary intersected with a closed fact pattern maps to exactly one
# action key, and an unmapped pair is `unknown` (a hand-off). That is only safer than the judgement
# it replaced while the file stays CLOSED. One edited line — a rule pointed at a W2 action, an
# `executes_here` flipped on for a merge or a refund, a `when` predicate renamed so it silently
# never matches, an answer-bank line id typo'd — turns the guardrail into decoration while every
# unit test still passes, because the tests exercise the rules that exist, not the ones that should.
#
# Fails when:
#   1. the file is missing, unparseable, or lacks a required section;
#   2. `default_action` is not `unknown`, or `unknown` is not a hand-off;
#   3. a rule names an action, an intent label or a `when` predicate that does not exist (the
#      loader fails closed on these too — this catches it before a deploy, not at 3am);
#   4. any action with `executes_here: true` is not tier W1, or has no recorded inverse;
#   5. a merge, an erasure/hide, or a refund is marked `executes_here` — those are never executed
#      from this surface, by captain decision;
#   6. a rule's `line` is not an answer-bank entry (checked only when node is available, because
#      the bank lives in the plugin's TypeScript; the bats suite is the hard gate for that);
#   7. the last rule is not the `*` fallthrough to `unknown`, so an unmapped ask cannot escape.
#
# Usage: check-ops-resolutions.sh
# Env:   OPS_RESOLUTIONS (path), OPS_INTAKE_NODE (node binary)
# Exit:  0 clean, 1 violation, 2 missing or unreadable input.
set -euo pipefail

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
POLICY="${OPS_RESOLUTIONS:-$ROOT/policies/ops-resolutions.json}"

die() { echo "check-ops-resolutions: $*" >&2; exit 2; }

[[ -r "$POLICY" ]] || die "cannot read $POLICY"
command -v python3 >/dev/null || die "python3 is required"

BANK_IDS=""
if command -v "${OPS_INTAKE_NODE:-node}" >/dev/null 2>&1; then
  # The real bank is the authority. A failure here is NOT fatal: the bats suite
  # (scripts/tests/ops-intake-guard.bats) is the hard gate for line ids, and this
  # script must still be able to run on a host without node.
  BANK_IDS="$(cd "$ROOT" && python3 scripts/ops_intake/output_guard.py --bank 2>/dev/null \
    | awk '{print $1}' | paste -sd, - || true)"
fi

POLICY="$POLICY" BANK_IDS="$BANK_IDS" python3 - <<'PY'
import json
import os
import sys

path = os.environ["POLICY"]
bank_ids = {i for i in os.environ.get("BANK_IDS", "").split(",") if i}

problems: list[str] = []


def bad(msg: str) -> None:
    problems.append(msg)


try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as exc:  # noqa: BLE001
    print(f"check-ops-resolutions: unparseable policy: {exc}", file=sys.stderr)
    raise SystemExit(2)

# 1. required sections.
for key in ("version", "intent_labels", "actions", "rules", "default_action"):
    if key not in doc:
        bad(f"missing required section {key!r}")
if problems:
    print("\n".join(f"  - {p}" for p in problems), file=sys.stderr)
    raise SystemExit(1)

labels = set(doc["intent_labels"])
actions = doc["actions"]
rules = doc["rules"]

# 2. the fallthrough must be a hand-off.
if doc["default_action"] != "unknown":
    bad(f"default_action is {doc['default_action']!r}, must be 'unknown' (a hand-off)")
if "unknown" not in actions:
    bad("no 'unknown' action declared")
elif actions["unknown"].get("tier") != "handoff":
    bad(f"'unknown' is tier {actions['unknown'].get('tier')!r}, must be 'handoff'")

# 3/4/5. every action is safe to be reachable.
NEVER_EXECUTES = {
    "merge-candidate": "a profile merge is never executed from this surface",
    "erasure": "an erasure/hide is never executed from this surface (register row only)",
    "billing": "a refund is never executed from this surface",
    "requester-linked-refusal": "a requester-linked account is refused, never written to",
}
for key, action in actions.items():
    tier = action.get("tier")
    executes = bool(action.get("executes_here"))
    for flag in ("page", "refuse"):
        if flag in action and not isinstance(action[flag], bool):
            bad(f"action {key!r} has a non-boolean {flag!r}")
    if tier not in ("W1", "W2", "handoff", "human"):
        bad(f"action {key!r} has unknown tier {tier!r}")
    if executes and tier != "W1":
        bad(f"action {key!r} executes_here but is tier {tier!r}; only W1 may execute")
    if executes and not action.get("inverse"):
        bad(f"action {key!r} executes_here with no recorded inverse")
    if executes and key in NEVER_EXECUTES:
        bad(f"action {key!r} executes_here: {NEVER_EXECUTES[key]}")
    if tier == "W2" and executes:
        bad(f"action {key!r} is W2 and executes_here; W2 is a human path, never a write")

# 3. every rule is resolvable.
PREDICATES = {
    "account", "open_requests", "request_status", "open_status", "claims", "merges",
    "erasure", "proof_on_file", "dv_outcome", "subscription", "tickets", "target_popular",
}
seen_keys: set[str] = set()
for i, rule in enumerate(rules):
    key = rule.get("key") or f"<rule {i}>"
    if key in seen_keys:
        bad(f"duplicate rule key {key!r}")
    seen_keys.add(key)
    if rule.get("action") not in actions:
        bad(f"rule {key!r} names undeclared action {rule.get('action')!r}")
    intents = rule.get("intents") or []
    if not intents:
        bad(f"rule {key!r} has no intents")
    for intent in intents:
        if intent != "*" and intent not in labels:
            bad(f"rule {key!r} names unknown intent label {intent!r}")
    for pred in (rule.get("when") or {}):
        if pred not in PREDICATES:
            bad(f"rule {key!r} names unknown predicate {pred!r}")
    line = rule.get("line") or ""
    if line and bank_ids and line not in bank_ids:
        bad(f"rule {key!r} names answer-bank line {line!r}, which the bank does not have")

# 6b. a hand-off that reaches nobody is not a hand-off. Nothing on this surface can reassign an
# Intercom conversation (the router's writers are empty by captain decision), so an action that
# does not execute here and neither pages nor refuses leaves the case with the bot while the
# customer has been told someone will follow up. Scope is `executes_here: false`, NOT
# `tier == "handoff"`: `gap-ask` and `uvn-status` are W1 actions that do not execute here, and
# keying on the tier let `page: false` on either of them pass clean.
for key, action in actions.items():
    if action.get("executes_here"):
        continue
    if not (action.get("page") or action.get("refuse")):
        bad(f"action {key!r} does not execute here and neither pages nor refuses, "
            f"so it reaches no human")

# 6c. a refusal must never carry customer copy: that is the requester-linked self-approval case.
for key, action in actions.items():
    if action.get("refuse") and action.get("line"):
        bad(f"action {key!r} refuses but names answer-bank line {action['line']!r}; "
            "a refusal sends no customer copy")

# 7. the last rule is the catch-all.
if not rules:
    bad("no rules")
else:
    last = rules[-1]
    if last.get("intents") != ["*"] or last.get("action") != "unknown":
        bad("the last rule must be the '*' -> 'unknown' fallthrough, so an unmapped ask "
            "cannot escape the lookup")

if problems:
    print("check-ops-resolutions: the resolution policy is not safe to ship:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    raise SystemExit(1)

print(f"check-ops-resolutions: clean ({len(rules)} rules, {len(actions)} actions, "
      f"{len(labels)} intent labels, {len(bank_ids)} bank lines checked)")
PY
