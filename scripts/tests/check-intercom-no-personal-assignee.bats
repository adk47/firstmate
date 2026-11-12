#!/usr/bin/env bats
# Tests for check-intercom-no-personal-assignee.sh: no Intercom conversation defaults to a person.
# Hermetic: every case runs against a synthetic tree via REPO_ROOT, never the tracked sources
# (except the first, which pins that the real repo passes).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-intercom-no-personal-assignee.sh"

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/plugins/intercom/src"
  cfg '{"botAdminId":"5763097","escalationTeamId":"7111842","humanHoldHours":72}'
  cat > "$T/plugins/intercom/src/assignment-policy.ts" <<'TS'
export async function applyHandOff(p) { await p.client.assignConversation({ assigneeId: "0" }); }
TS
  cat > "$T/plugins/intercom/src/outbound.ts" <<'TS'
export class C {
  async assignConversation(params: { assigneeId: string }): Promise<void> {
    // refused before the request
    assertAssignmentTarget(params);
    await fetch("/parts", { body: JSON.stringify({ message_type: "assignment", assignee_id: params.assigneeId }) });
  }
}
export class W {
  async assignConversation(params: { assigneeId: string }): Promise<void> {
    assertAssignmentTarget(params);
    return this.inner.assignConversation(params);
  }
}
TS
  cat > "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({
  conversationId: id,
  adminId: account.botAdminId,
  assigneeId: account.botAdminId,
});
TS
  export REPO_ROOT="$T"
}

teardown() { rm -rf "$T"; }

cfg() {  # cfg <account json>
  printf '{"channels":{"intercom":{"accounts":{"default":%s}}}}\n' "$1" > "$T/openclaw-edge.json"
}

@test "the real repo passes" {
  REPO_ROOT="$HYDRA_REPO" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: no Intercom conversation defaults to a person"* ]]
}

@test "a clean synthetic tree passes" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "defaultInboxId set in a config fails (the 2026-11 rule that put every hand-off on one person)" {
  cfg '{"botAdminId":"5763097","defaultInboxId":"5465657"}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"defaultInboxId"*"retired"* ]]
}

@test "an empty defaultInboxId is not a violation" {
  cfg '{"botAdminId":"5763097","defaultInboxId":""}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "escalationTeamId that is a person's admin id fails" {
  cfg '{"botAdminId":"5763097","escalationTeamId":"5465657"}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADMIN id"* ]]
}

@test "escalationTeamId equal to the bot fails" {
  cfg '{"botAdminId":"5763097","escalationTeamId":"5763097"}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"equals \`botAdminId\`"* ]]
}

@test "a non-numeric escalationTeamId fails" {
  cfg '{"botAdminId":"5763097","escalationTeamId":"jan"}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"numeric Intercom TEAM id"* ]]
}

@test "no escalationTeamId at all passes (escalations go to Unassigned)" {
  cfg '{"botAdminId":"5763097"}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "an unparseable config fails, it is not skipped" {
  echo '{not json' > "$T/openclaw-edge.json"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot parse"* ]]
}

@test "no config at all fails (nothing to check is not a pass)" {
  rm "$T/openclaw-edge.json"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "plugin source reading defaultInboxId outside the retiring files fails" {
  echo 'const t = account.defaultInboxId || "0";' > "$T/plugins/intercom/src/caroline-safety.ts"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"caroline-safety.ts references"* ]]
}

@test "a direct assignConversation call in another module fails" {
  echo 'await client.assignConversation({ conversationId, adminId, assigneeId: someone });' \
    > "$T/plugins/intercom/src/escalation-action.ts"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escalation-action.ts:1: names \`assignConversation\`"* ]]
}

# --- evasions (QA on #1889: the first version matched one call syntax) -----------------------

other() {  # other <ts source>: a module that is not the policy, the client or channel.ts
  printf '%s\n' "$1" > "$T/plugins/intercom/src/escalation-action.ts"
}

@test "evasion: a computed member access with the name as a string fails" {
  other 'await client["assignConversation"]({ conversationId, adminId, assigneeId: person });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escalation-action.ts:1: names"* ]]
}

@test "evasion: an alias of the method fails" {
  other 'const go = client.assignConversation.bind(client); await go({ assigneeId: person });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escalation-action.ts:1: names"* ]]
}

@test "evasion: a destructured method fails" {
  other 'const { assignConversation: go } = client; await go({ assigneeId: person });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escalation-action.ts:1: names"* ]]
}

@test "evasion: optional chaining and whitespace before the call fail" {
  other 'await client?.assignConversation  ({ assigneeId: person });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escalation-action.ts:1: names"* ]]
}

@test "evasion: the name assembled from string pieces fails" {
  other 'await client["assign" + "Conversation"]({ assigneeId: person });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"from string pieces"* ]]
}

@test "evasion: a raw assignment part posted without the client fails" {
  other 'await fetch(url, { body: JSON.stringify({ message_type: "assignment", admin_id: bot, assignee_id: person }) });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"writes \`assignee_id\` outside the client"* ]]
  [[ "$output" == *"builds an Intercom assignment part outside the client"* ]]
}

# QA on #1892: the exceptions were matched on the basename, so a nested file with an allowed
# name was exempt from everything.
nested() {  # nested <file name> <ts source>
  mkdir -p "$T/plugins/intercom/src/nested"
  printf '%s\n' "$2" > "$T/plugins/intercom/src/nested/$1"
}

@test "evasion: a raw assignment in a NESTED outbound.ts fails (the reviewed fixture)" {
  nested outbound.ts 'await fetch(url, { body: JSON.stringify({ message_type: "assignment", assignee_id: person }) });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/nested/outbound.ts:1: writes \`assignee_id\` outside the client"* ]]
  [[ "$output" == *"src/nested/outbound.ts:1: builds an Intercom assignment part outside the client"* ]]
}

@test "evasion: a NESTED outbound.ts, assignment-policy.ts or types.ts naming the method fails" {
  for name in outbound.ts assignment-policy.ts types.ts; do
    rm -rf "$T/plugins/intercom/src/nested"
    nested "$name" 'await client.assignConversation({ conversationId, adminId, assigneeId: person });'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"src/nested/$name:1: names"* ]]
  done
}

@test "evasion: a NESTED channel.ts does not get the bot self-assign exception" {
  nested channel.ts 'await client.assignConversation({ adminId: account.botAdminId, assigneeId: account.botAdminId });'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/nested/channel.ts:1: names"* ]]
}

@test "evasion: a NESTED config.ts reading defaultInboxId fails" {
  nested config.ts 'const t = account.defaultInboxId || "0";'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nested/config.ts references"* ]]
}

@test "reading admin_assignee_id (the live check) is not a write and passes" {
  other 'const who = conversation.admin_assignee_id ?? conversation.team_assignee_id;'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "evasion in channel.ts: a computed access fails even with the bot as assignee" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client["assignConversation"]({ conversationId: id, adminId: account.botAdminId, assigneeId: account.botAdminId });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"something other than a direct call"* ]]
}

@test "evasion in channel.ts: an argument that is not an object literal fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation(params);
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"its assignee cannot be read"* ]]
}

@test "evasion in channel.ts: a spread that can override the assignee fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({ assigneeId: account.botAdminId, ...override });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uses a spread"* ]]
}

@test "evasion in channel.ts: a second assigneeId key that wins fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({ assigneeId: account.botAdminId, conversationId: id, assigneeId: person });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other than account.botAdminId"* ]]
}

@test "evasion in channel.ts: a shorthand assigneeId fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({ conversationId: id, adminId: account.botAdminId, assigneeId });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other than account.botAdminId"* ]]
}

@test "evasion in channel.ts: a team assignment outside the policy module fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({ adminId: account.botAdminId, assigneeId: account.botAdminId, assigneeType: "team" });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the policy module assigns a team"* ]]
}

@test "a client that does not refuse a personal assignee first fails (the runtime half)" {
  cat > "$T/plugins/intercom/src/outbound.ts" <<'TS'
export class C {
  async assignConversation(params: { assigneeId: string }): Promise<void> {
    await fetch("/parts", { body: JSON.stringify({ message_type: "assignment", assignee_id: params.assigneeId }) });
  }
}
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not start with \`assertAssignmentTarget(params);\`"* ]]
}

@test "a client file with no assignConversation at all fails (nothing to check is not a pass)" {
  echo 'export const nothing = 1;' > "$T/plugins/intercom/src/outbound.ts"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no client"* ]]
}

@test "channel.ts assigning to anything but the bot fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({ conversationId: id, adminId: account.botAdminId, assigneeId: target });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other than account.botAdminId"* ]]
}
