#!/usr/bin/env bash
# check-ops-intake-policy.sh — CI guard: the ops-intake router's policy files must
# describe a surface that cannot perform an irreversible write, and must cover
# every ask class the code can produce.
#
# WHY (2026-11-04). Between 10-21 and 11-04 the `operations` Slack bot performed
# ~39 profile merges, 15 profile hides via `DELETE /admin/profile`, 134 ClickUp
# writes and 420 credit rejections on Jan's word, self-approved through the
# tier-2 god-mode allowlist, with no row anywhere carrying an inverse (hydra
# #1702). The router that replaces it is only safer if its policy file stays
# safe: a single line moved from W2 into W1, or a class pointed at a W2 action,
# turns the guardrail into decoration while every test still passes.
#
# Fails when:
#   1. a policy file is missing, unparseable, or lacks a required section;
#   2. any of the TEN classes is missing, or a class is mapped to tier W2;
#   3. a class names an action that is not declared in the tier it claims, or a
#      W1 write_action with no inverse recipe;
#   4. a W2 action is reachable from R/W1 (another tier, a class, or a writer);
#   5. tiers.W2.requesters is non-empty (NOBODY may trigger W2 from Slack), or a
#      requester is granted a tier other than R/W1, or a non-staff id gets W1;
#   6. every W2 action lacks a human_path, a why, or triggers;
#   7. caps are missing or non-positive (a zero cap is a violation, not
#      "unlimited"), or the fraud-lens / quarantine / canary / reply sections are
#      absent;
#   8. the channel allowlist is not a subset of the channels the `operations`
#      Slack account is bound to in openclaw-main.json, or the plugin entry is
#      missing/disabled there.
#
# Usage: check-ops-intake-policy.sh
# Env:   OPS_INTAKE_REQUESTERS, OPS_INTAKE_ACTIONS, OPENCLAW_MAIN_CONFIG
# Exit:  0 clean, 1 violation, 2 missing or unreadable input.
set -euo pipefail

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REQUESTERS="${OPS_INTAKE_REQUESTERS:-$ROOT/policies/ops-requesters.json}"
ACTIONS="${OPS_INTAKE_ACTIONS:-$ROOT/policies/ops-intake-actions.json}"
MAIN_CONFIG="${OPENCLAW_MAIN_CONFIG:-$ROOT/openclaw-main.json}"

die() { echo "check-ops-intake-policy: $*" >&2; exit 2; }
for f in "$REQUESTERS" "$ACTIONS" "$MAIN_CONFIG"; do
  [ -r "$f" ] || die "missing $f"
  jq -e . "$f" >/dev/null 2>&1 || die "$f is not JSON"
done

fail=0
violation() { echo "VIOLATION: $*" >&2; fail=1; }

# 1. required sections
required_exprs=(
  '.tiers.R != null'
  '.tiers.W1.actions != null'
  '.tiers.W2.actions != null'
  '.classes != null'
  '.caps != null'
  '.fraud_lens != null'
  '.quarantine != null'
  '.canary != null'
  '.reply != null'
  '.channels != null'
)
for expr in "${required_exprs[@]}"; do
  jq -e "$expr" "$ACTIONS" >/dev/null 2>&1 \
    || violation "policies/ops-intake-actions.json fails required check: $expr"
done
[ "$fail" = 0 ] || exit $fail

# 2. all ten classes, none of them W2
classes=$(jq -r '.classes | keys[]' "$ACTIONS" | sort | tr '\n' ' ')
expected="billing clickup-categorize fraud-scan gdpr-hide other profile-edit proof-review relay status-report summarize-resolve "
[ "$classes" = "$expected" ] || violation "class set is [$classes]; expected [$expected]"
while IFS= read -r cls; do
  tier=$(jq -r --arg c "$cls" '.classes[$c].tier // ""' "$ACTIONS")
  case "$tier" in
    R|W1) ;;
    *) violation "class '$cls' has tier '$tier' (only R and W1 may be class tiers)" ;;
  esac
done < <(jq -r '.classes | keys[]' "$ACTIONS")

# 3. class write actions must be declared W1 actions with an inverse
while IFS= read -r action; do
  [ -n "$action" ] || continue
  inv=$(jq -r --arg a "$action" '.tiers.W1.actions[$a].inverse // ""' "$ACTIONS")
  [ -n "$inv" ] || violation "class write_action '$action' is not a declared W1 action with an inverse"
done < <(jq -r '.classes[] | .write_action // empty' "$ACTIONS" | sort -u)

while IFS= read -r action; do
  [ -n "$action" ] || continue
  inv=$(jq -r --arg a "$action" '.tiers.W1.actions[$a].inverse // ""' "$ACTIONS")
  [ -n "$inv" ] || violation "W1 action '$action' declares no inverse"
done < <(jq -r '.tiers.W1.actions | keys[]' "$ACTIONS")

# 4. W2 must be unreachable from R/W1 and from any class
while IFS= read -r w2; do
  [ -n "$w2" ] || continue
  if jq -e --arg a "$w2" '([.tiers.R.actions[]?] + (.tiers.W1.actions | keys)) | index($a) != null' "$ACTIONS" >/dev/null; then
    violation "W2 action '$w2' is also listed in a read-only or W1 tier"
  fi
  if jq -e --arg a "$w2" '[.classes[] | .action?, .write_action?] | map(select(. != null)) | index($a) != null' "$ACTIONS" >/dev/null; then
    violation "class plan reaches the W2 action '$w2'"
  fi
  for field in human_path why; do
    val=$(jq -r --arg a "$w2" --arg f "$field" '.tiers.W2.actions[$a][$f] // ""' "$ACTIONS")
    [ -n "$val" ] || violation "W2 action '$w2' has no $field"
  done
  n=$(jq -r --arg a "$w2" '(.tiers.W2.actions[$a].triggers // []) | length' "$ACTIONS")
  [ "$n" -gt 0 ] || violation "W2 action '$w2' declares no triggers, so nothing refuses it"
done < <(jq -r '.tiers.W2.actions | keys[]' "$ACTIONS")

# 5. nobody may trigger W2 from Slack; only R/W1 may be granted
n=$(jq -r '.tiers.W2.requesters | length' "$ACTIONS")
[ "$n" = "0" ] || violation "tiers.W2.requesters is non-empty: no Slack ask may trigger an irreversible write"
while IFS=$'\t' read -r uid tier; do
  case "$tier" in
    R|W1) ;;
    *) violation "requester $uid has tier '$tier' (only R and W1 exist on this surface)" ;;
  esac
done < <(jq -r '.requesters | to_entries[] | "\(.key)\t\(.value.tier)"' "$REQUESTERS")

for uid in U038BM16T7W U0AL36NADEY U7RP6HKUZ; do
  tier=$(jq -r --arg u "$uid" '.requesters[$u].tier // ""' "$REQUESTERS")
  [ "$tier" = "W1" ] || violation "staff requester $uid must carry tier W1 (census: they are the askers)"
done
while IFS=$'\t' read -r uid staff tier; do
  if [ "$staff" = "false" ] && [ "$tier" = "W1" ]; then
    violation "non-staff id $uid carries tier W1 (a write tier is earned, not pasted)"
  fi
done < <(jq -r '.requesters | to_entries[] | "\(.key)\t\(.value.staff // false)\t\(.value.tier)"' "$REQUESTERS")

# 6. caps exist and are positive
for key in w1_per_requester_per_hour writes_per_target_per_day; do
  v=$(jq -r --arg k "$key" '.caps[$k] // 0' "$ACTIONS")
  if ! [ "$v" -gt 0 ] 2>/dev/null; then
    violation "caps.$key is '$v'; a missing or zero cap must be a violation, not 'unlimited'"
  fi
done

# 7. the reply contract's three promises are present
jq -e '.reply.forbid_unmeasured == true' "$ACTIONS" >/dev/null \
  || violation 'reply.forbid_unmeasured must be true'
jq -e '.reply.pending_requires_due_at == true' "$ACTIONS" >/dev/null \
  || violation 'reply.pending_requires_due_at must be true'
jq -e '.reply.forbid_firstmate_attribution_without_ruling == true' "$ACTIONS" >/dev/null \
  || violation 'reply.forbid_firstmate_attribution_without_ruling must be true'
jq -e '.quarantine.severity == "high"' "$ACTIONS" >/dev/null \
  || violation 'quarantine.severity must be "high"'
jq -e '.canary.on_leak == "fail_closed"' "$ACTIONS" >/dev/null \
  || violation 'canary.on_leak must be "fail_closed"'

# 8. the channel allowlist must be a subset of what the operations account is bound to
bound=$(jq -r '.channels.slack.accounts.operations.channels // {} | to_entries[]
                | select(.value.enabled == true) | .key' "$MAIN_CONFIG" | sort)
while IFS= read -r ch; do
  [ -n "$ch" ] || continue
  printf '%s\n' "$bound" | grep -Fxq "$ch" \
    || violation "policy routes channel $ch but openclaw-main.json does not bind it to the operations account (enabled)"
done < <(jq -r '.channels | to_entries[] | select(.key != "DMs" and .key != "_doc") | .key' "$ACTIONS")

# 8b. the plugin must be present and enabled, and the account must be the operations one
jq -e '.plugins.allow | index("ops-intake") != null' "$MAIN_CONFIG" >/dev/null \
  || violation 'openclaw-main.json plugins.allow does not include "ops-intake"'
jq -e '.plugins.entries["ops-intake"].enabled == true' "$MAIN_CONFIG" >/dev/null \
  || violation 'openclaw-main.json plugins.entries["ops-intake"].enabled is not true'
acct=$(jq -r '.plugins.entries["ops-intake"].config.account // ""' "$MAIN_CONFIG")
[ "$acct" = "operations" ] || violation "ops-intake plugin config.account is '$acct', expected 'operations'"
plugin_channels=$(jq -r '.plugins.entries["ops-intake"].config.channels[]? // empty' "$MAIN_CONFIG" | sort)
while IFS= read -r ch; do
  [ -n "$ch" ] || continue
  printf '%s\n' "$plugin_channels" | grep -Fxq "$ch" \
    || violation "policy routes $ch but the plugin's config.channels does not include it (the claim fast-path would skip it)"
done < <(jq -r '.channels | to_entries[] | select(.key != "DMs" and .key != "_doc") | .key' "$ACTIONS")

if [ "$fail" = 0 ]; then
  echo "check-ops-intake-policy: clean (10 classes, W2 unreachable from Slack, every W1 has an inverse, caps positive)"
fi
exit "$fail"
