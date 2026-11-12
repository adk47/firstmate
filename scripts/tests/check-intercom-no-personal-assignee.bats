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
export const c = { async assignConversation(p) {} };
export async function w(inner, p) { return inner.assignConversation(p); }
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
  [[ "$output" == *"escalation-action.ts calls .assignConversation("* ]]
}

@test "channel.ts assigning to anything but the bot fails" {
  cat >> "$T/plugins/intercom/src/channel.ts" <<'TS'
await client.assignConversation({ conversationId: id, adminId: account.botAdminId, assigneeId: target });
TS
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other than account.botAdminId"* ]]
}
