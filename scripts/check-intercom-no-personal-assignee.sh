#!/usr/bin/env bash
set -euo pipefail

# No Intercom conversation defaults to a PERSON (intercom-no-human-assignment-k1, captain 2026-11-11:
# "Jan is saying 50-100 assignments are happening to him a day can you cut this to zero").
#
# What happened: openclaw-edge.json carried `defaultInboxId` set to one person's admin id, and six
# call sites in plugins/intercom assigned to it. Measured from Intercom's own assignment parts,
# 478 of the 485 assignments that person received in 14 days were made by the plugin; 404 of those
# were Caroline's own reply failing the output guard. A config value nobody had read in months
# was the rule. Prose is not enforcement, so this gate fails when:
#
#   1. any openclaw-*.json intercom account sets a non-empty `defaultInboxId` (the key is retired);
#   2. an account's `escalationTeamId` is not a bare numeric id, equals its `botAdminId`, or is a
#      known ADMIN id (a person is not a queue; the plugin also sends it with type "team", so
#      Intercom refuses an admin id at runtime, and this catches it before deploy);
#   3. plugin source reads `defaultInboxId` anywhere but the three files that retire it;
#   4. plugin source calls `.assignConversation(` outside the policy module, the client, and the
#      bot's own self-assignment in channel.ts.
#
# Overrides for the bats tests: REPO_ROOT (tree to scan).

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$ROOT/plugins/intercom/src"
fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# Intercom ADMIN ids of people and of Intercom's own Operator (docs/lessons/muso-domain.md, and
# GET /admins read 2026-11-11). None of them is a queue. Caroline's own id is refused through the
# botAdminId comparison instead.
PERSON_OR_OPERATOR_IDS="5465657 10206197 5201828 4359478 5733748 7057669 9338415 9473520 10106343"

shopt -s nullglob
configs=("$ROOT"/openclaw-*.json)
[ "${#configs[@]}" -gt 0 ] || err "no openclaw-*.json found under $ROOT (nothing to check is not a pass)"

for cfg in "${configs[@]}"; do
  out="$(PERSON_IDS="$PERSON_OR_OPERATOR_IDS" python3 - "$cfg" <<'PY'
import json, os, re, sys
path = sys.argv[1]
people = set(os.environ["PERSON_IDS"].split())
try:
    cfg = json.load(open(path, encoding="utf8"))
except Exception as exc:  # unreadable is a failure, never a skip
    print(f"cannot parse {path}: {exc}")
    sys.exit(0)
accounts = (((cfg.get("channels") or {}).get("intercom") or {}).get("accounts") or {})
for name, acct in accounts.items():
    if not isinstance(acct, dict):
        continue
    where = f"{os.path.basename(path)} channels.intercom.accounts.{name}"
    if str(acct.get("defaultInboxId") or "").strip():
        print(f"{where}: `defaultInboxId` is set. That key is retired: it made one inbox the default "
              f"owner of every hand-off. Remove it; an escalation queue is `escalationTeamId` (a TEAM id).")
    team = acct.get("escalationTeamId")
    if team is None:
        continue
    team = str(team).strip()
    if not re.fullmatch(r"[1-9][0-9]*", team):
        print(f"{where}: `escalationTeamId` must be a numeric Intercom TEAM id, got {team!r}")
    elif team == str(acct.get("botAdminId") or "").strip():
        print(f"{where}: `escalationTeamId` equals `botAdminId`; the escalation queue is a team, not the bot")
    elif team in people:
        print(f"{where}: `escalationTeamId` {team} is an Intercom ADMIN id (a person or Operator), not a team. "
              f"No conversation is routed to an individual.")
    hold = acct.get("humanHoldHours")
    if hold is not None and (isinstance(hold, bool) or not isinstance(hold, (int, float))):
        print(f"{where}: `humanHoldHours` must be a number, got {hold!r}")
PY
)"
  if [ -n "$out" ]; then
    while IFS= read -r line; do err "$line"; done <<<"$out"
  fi
done

if [ -d "$SRC" ]; then
  # 3. the retired key is read nowhere.
  while IFS= read -r f; do
    case "$(basename "$f")" in
      config.ts|types.ts|assignment-policy.ts) ;;
      *) err "${f#"$ROOT"/} references \`defaultInboxId\`. The key is retired; who holds a conversation is decided only in plugins/intercom/src/assignment-policy.ts." ;;
    esac
  done < <(grep -rl --include='*.ts' 'defaultInboxId' "$SRC" || true)

  # 4. assignment calls live in the policy module, the client, and the bot's self-assign.
  while IFS= read -r f; do
    case "$(basename "$f")" in
      assignment-policy.ts|outbound.ts) ;;
      channel.ts)
        # every call in channel.ts must assign TO THE BOT (the AI queue)
        bad="$(python3 - "$f" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf8").read()
for m in re.finditer(r"\.assignConversation\(\s*\{(.*?)\}\s*\)", src, re.S):
    if not re.search(r"assigneeId:\s*account\.botAdminId\b", m.group(1)):
        print(src.count("\n", 0, m.start()) + 1)
PY
)"
        [ -z "$bad" ] || err "plugins/intercom/src/channel.ts line(s) $(echo $bad): assignConversation to something other than account.botAdminId. Use applyHandOff() from assignment-policy.ts (an escalation carries a reason and goes to the team queue)."
        ;;
      *) err "${f#"$ROOT"/} calls .assignConversation( directly. Use applyHandOff() from plugins/intercom/src/assignment-policy.ts." ;;
    esac
  done < <(grep -rl --include='*.ts' '\.assignConversation(' "$SRC" || true)
else
  err "missing $SRC (nothing to check is not a pass)"
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Intercom assignment doctrine violated. See scripts/check-intercom-no-personal-assignee.sh header." >&2
  exit 1
fi
echo "OK: no Intercom conversation defaults to a person (${#configs[@]} config(s); retired defaultInboxId unused; assignments go through assignment-policy.ts)."
