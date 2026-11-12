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
#   4. plugin source NAMES `assignConversation` (a call, `client["assignConversation"]`, an alias,
#      a bind) outside the policy module, the client and the bot's own self-assignment in
#      channel.ts; assembles that name from string pieces; writes a raw `assignee_id` or an
#      assignment part outside the client; or a client implementation does not begin with
#      `assertAssignmentTarget(params)`.
#
# A text scan cannot see every computed call (QA on #1889: `client["assignConversation"](...)`
# passed the first version, which matched one call syntax). So rule 4 is a tripwire, and the rule
# itself is enforced at runtime: every client refuses an admin assignee other than "0" or the
# acting bot before any request is made (assertAssignmentTarget, tested in
# plugins/intercom/tests/outbound.test.ts through a computed access).
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
  # Exceptions are matched on the path under src/, never the basename: a nested file that
  # happens to share an allowed name is not allowed (QA on #1892).
  while IFS= read -r f; do
    case "${f#"$SRC"/}" in
      config.ts|types.ts|assignment-policy.ts) ;;
      *) err "${f#"$ROOT"/} references \`defaultInboxId\`. The key is retired; who holds a conversation is decided only in plugins/intercom/src/assignment-policy.ts." ;;
    esac
  done < <(grep -rl --include='*.ts' 'defaultInboxId' "$SRC" || true)

  # 4. assignment lives in the policy module, the client, and the bot's own self-assignment.
  #    The NAME is matched, not one call syntax: `client["assignConversation"](...)`, an alias, a
  #    destructure and a bind all carry it, and each is refused outside the allowed files.
  out="$(python3 - "$SRC" <<'PYSCAN'
import os, re, sys

src_dir = sys.argv[1]
NAME = "assignConversation"
ALLOWED = {"assignment-policy.ts", "outbound.ts", "types.ts"}
HINT = ("Use applyHandOff() from plugins/intercom/src/assignment-policy.ts "
        "(an escalation carries a reason and goes to the team queue).")
Q = "[\"'`]"


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def object_literal(text, start):
    """The balanced `{...}` starting at text[start], or None."""
    if start >= len(text) or text[start] != "{":
        return None
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


files = []
for root, _dirs, names in os.walk(src_dir):
    for n in sorted(names):
        if n.endswith(".ts"):
            files.append(os.path.join(root, n))

for path in sorted(files):
    # `base` is the path UNDER src/, not the basename: only the root client, policy module and
    # types file are exceptions. src/nested/outbound.ts is an ordinary module (QA on #1892).
    base = os.path.relpath(path, src_dir).replace(os.sep, "/")
    rel = "plugins/intercom/src/" + base
    text = open(path, encoding="utf8").read()

    if base != "outbound.ts":
        # a raw Intercom assignment write that never goes through the client
        for m in re.finditer(r"(?<![A-Za-z0-9_])assignee_id(?![A-Za-z0-9_])", text):
            print(f"{rel}:{line_of(text, m.start())}: writes `assignee_id` outside the client (outbound.ts). {HINT}")
        for m in re.finditer(r"message_type" + Q + r"?\s*:\s*" + Q + r"assignment", text):
            print(f"{rel}:{line_of(text, m.start())}: builds an Intercom assignment part outside the client (outbound.ts). {HINT}")

    if base not in ALLOWED:
        # the method name assembled from pieces, so the name itself never appears
        pieces = (Q + r"assign" + Q + "|" + Q + r"assignConv" + "|"
                  + Q + r"Conversation" + Q + r"\s*[\]),+]" + "|" + r"\+\s*" + Q + r"Conversation" + Q)
        for m in re.finditer(pieces, text):
            print(f"{rel}:{line_of(text, m.start())}: builds the name `{NAME}` from string pieces. {HINT}")

    hits = [m.start() for m in re.finditer(r"(?<![A-Za-z0-9_$])" + NAME + r"(?![A-Za-z0-9_$])", text)]
    if not hits or base in ALLOWED:
        continue
    if base != "channel.ts":
        for pos in hits:
            print(f"{rel}:{line_of(text, pos)}: names `{NAME}` (a call, an alias or a computed access). {HINT}")
        continue
    # channel.ts: every mention must be the direct call that assigns TO THE BOT (the AI queue).
    for pos in hits:
        where = f"{rel}:{line_of(text, pos)}"
        before = text[:pos].rstrip()
        after = text[pos + len(NAME):]
        call = re.match(r"\s*\(\s*", after)
        if not before.endswith(".") or not call:
            print(f"{where}: `{NAME}` used as something other than a direct call (alias, computed access, bind). {HINT}")
            continue
        obj = object_literal(after, call.end())
        if obj is None:
            print(f"{where}: `{NAME}` called with something other than an object literal, so its assignee cannot be read. {HINT}")
            continue
        if "..." in obj:
            print(f"{where}: `{NAME}` argument uses a spread, so its assignee cannot be read. {HINT}")
            continue
        targets = re.findall(r"(?<![A-Za-z0-9_])assigneeId\s*:\s*([^,}\n]+)", obj)
        shorthand = re.search(r"(?<![A-Za-z0-9_.:])assigneeId\s*[,}]", obj)
        if shorthand or len(targets) != 1 or targets[0].strip() != "account.botAdminId":
            print(f"{where}: assignConversation to something other than account.botAdminId. {HINT}")
        elif re.search(r"(?<![A-Za-z0-9_])assigneeType\b", obj):
            print(f"{where}: `{NAME}` sets assigneeType; only the policy module assigns a team. {HINT}")

# The runtime half: every client implementation refuses a personal assignee before the request.
out_path = os.path.join(src_dir, "outbound.ts")
if os.path.exists(out_path):
    text = open(out_path, encoding="utf8").read()
    defs = list(re.finditer(r"async\s+" + NAME + r"\s*\(", text))
    if not defs:
        print(f"plugins/intercom/src/outbound.ts: no client `{NAME}` found (nothing to check is not a pass)")
    for m in defs:
        brace = text.find("): Promise<void> {", m.end())
        body = text[brace:brace + 600] if brace != -1 else ""
        first = next((ln.strip() for ln in body.split("\n")[1:] if ln.strip() and not ln.strip().startswith("//")), "")
        if first != "assertAssignmentTarget(params);":
            print(f"plugins/intercom/src/outbound.ts:{line_of(text, m.start())}: a client `{NAME}` does not start with "
                  f"`assertAssignmentTarget(params);`. The client must refuse a personal assignee whatever the call site looks like.")
else:
    print("plugins/intercom/src/outbound.ts: missing (nothing to check is not a pass)")
PYSCAN
)"
  if [ -n "$out" ]; then
    while IFS= read -r line; do err "$line"; done <<<"$out"
  fi
else
  err "missing $SRC (nothing to check is not a pass)"
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Intercom assignment doctrine violated. See scripts/check-intercom-no-personal-assignee.sh header." >&2
  exit 1
fi
echo "OK: no Intercom conversation defaults to a person (${#configs[@]} config(s); retired defaultInboxId unused; assignments go through assignment-policy.ts)."
