#!/usr/bin/env bats
# Regression tests for the narrow OpenClaw 2026.7.1 non-interrupting delete backport.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PATCHER="$HYDRA_REPO/scripts/patch-openclaw-inactive-session-delete.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export OPENCLAW_DIST_DIR="$TEST_TMPDIR/dist"
  mkdir -p "$OPENCLAW_DIST_DIR"
  write_vulnerable_fixtures
}

teardown() { rm -rf "$TEST_TMPDIR"; }

write_vulnerable_fixtures() {
  cat > "$OPENCLAW_DIST_DIR/schema-fixture.js" <<'EOF'
const SessionsDeleteParamsSchema = Type.Object({
	key: NonEmptyString,
	agentId: Type.Optional(NonEmptyString),
	deleteTranscript: Type.Optional(Type.Boolean()),
	expectedSessionId: Type.Optional(NonEmptyString),
	expectedLifecycleRevision: Type.Optional(NonEmptyString),
	expectedSessionUpdatedAt: Type.Optional(Type.Number({ minimum: 0 })),
	emitLifecycleHooks: Type.Optional(Type.Boolean()),
	archivedOnly: Type.Optional(Type.Boolean())
}, { additionalProperties: false });
EOF

  cat > "$OPENCLAW_DIST_DIR/sessions-fixture.js" <<'EOF'
const mode = process.argv[2] ?? "idle";
const p = { requireInactive: true };
const key = "agent:scout:slack:channel:c1:thread:1.1";
const requestedAgentId = "scout";
const storePath = "/tmp/sessions.json";
const deleteLifecycleIdentities = [key, "session-1"];
const target = { canonicalKey: key };
const context = {};
const cfg = {};
const loadSessionEntry = () => ({ entry: { sessionId: "session-1" } });
const rejectExpectedSessionMismatch = () => false;
const resolveDefaultAgentId = () => "scout";
const isSessionWorkAdmissionActive = () => mode === "admission";
const replyRunRegistry = { isActive: (candidate) =>
  (mode === "reply-canonical" && candidate === target.canonicalKey) ||
  (mode === "reply-requested" && candidate === key)
};
const hasVisibleActiveSessionRun = () => mode === "visible";
let interrupts = 0;
let deletes = 0;
const interruptSessionWorkAdmissions = async () => { interrupts += 1; return true; };
const runExclusiveSessionLifecycleMutation = async ({ prepare, run }) => { await prepare(); await run(); };
const SESSION_WORK_ADMISSION_DRAIN_TIMEOUT_MS = 100;

const handlers = {
	"sessions.delete": async () => {
		let expectedSessionStillCurrent = true;
		let admittedWorkReleased = true;
		const deletion = await runExclusiveSessionLifecycleMutation({
			prepare: async () => {
				expectedSessionStillCurrent = !rejectExpectedSessionMismatch(loadSessionEntry(key, { agentId: requestedAgentId }).entry);
				if (!expectedSessionStillCurrent) return;
				admittedWorkReleased = await interruptSessionWorkAdmissions({
					scope: storePath,
					identities: deleteLifecycleIdentities,
					timeoutMs: SESSION_WORK_ADMISSION_DRAIN_TIMEOUT_MS
				});
			},
			run: async () => {
				if (!admittedWorkReleased) return;
				deletes += 1;
			}
		});
	}
};

await handlers["sessions.delete"]();
process.stdout.write(JSON.stringify({ interrupts, deletes }));
EOF
}

@test "patcher adds requireInactive schema and refuses to interrupt active work" {
  run "$PATCHER"

  [ "$status" -eq 0 ]
  grep -Fq 'requireInactive: Type.Optional(Type.Boolean())' "$OPENCLAW_DIST_DIR/schema-fixture.js"
  grep -Fq 'p.requireInactive === true && (isSessionWorkAdmissionActive(storePath, deleteLifecycleIdentities)' \
    "$OPENCLAW_DIST_DIR/sessions-fixture.js"
  run node --check "$OPENCLAW_DIST_DIR/schema-fixture.js"
  [ "$status" -eq 0 ]
  run node --check "$OPENCLAW_DIST_DIR/sessions-fixture.js"
  [ "$status" -eq 0 ]
}

@test "requireInactive refuses every active-run registry without interrupting it" {
  "$PATCHER"

  for mode in admission reply-canonical reply-requested visible; do
    run node "$OPENCLAW_DIST_DIR/sessions-fixture.js" "$mode"
    [ "$status" -eq 0 ]
    [ "$output" = '{"interrupts":0,"deletes":0}' ]
  done

  run node "$OPENCLAW_DIST_DIR/sessions-fixture.js" idle
  [ "$status" -eq 0 ]
  [ "$output" = '{"interrupts":1,"deletes":1}' ]
}

@test "patcher is idempotent" {
  "$PATCHER"

  run "$PATCHER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already patched"* ]]
}

@test "patcher recovers an interrupted install after enforcement landed first" {
  "$PATCHER"
  sed -i '/requireInactive: Type.Optional(Type.Boolean()),/d' \
    "$OPENCLAW_DIST_DIR/schema-fixture.js"

  run "$PATCHER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"added non-interrupting requireInactive session deletion"* ]]
  grep -Fq 'requireInactive: Type.Optional(Type.Boolean())' \
    "$OPENCLAW_DIST_DIR/schema-fixture.js"
  grep -Fq 'p.requireInactive === true && (isSessionWorkAdmissionActive(storePath, deleteLifecycleIdentities)' \
    "$OPENCLAW_DIST_DIR/sessions-fixture.js"
}

@test "patcher fails closed when either pinned-runtime anchor drifts" {
  printf '%s\n' 'const unrelated = true;' > "$OPENCLAW_DIST_DIR/sessions-fixture.js"

  run "$PATCHER"

  [ "$status" -ne 0 ]
  [[ "$output" == *"anchor"* ]]
}

@test "deploy reapplies the inactive-delete backport after every runtime install" {
  install_line="$(grep -n '^if ! install_openclaw; then$' "$HYDRA_REPO/scripts/deploy.sh" | cut -d: -f1)"
  patch_line="$(grep -n -F 'bash "$HYDRA_ROOT/scripts/patch-openclaw-inactive-session-delete.sh"; then' "$HYDRA_REPO/scripts/deploy.sh" | cut -d: -f1)"

  [ -n "$install_line" ]
  [ -n "$patch_line" ]
  [ "$patch_line" -gt "$install_line" ]
  grep -Fq 'fail "OpenClaw inactive-session delete backport failed"' "$HYDRA_REPO/scripts/deploy.sh"
}

@test "post-update hook reapplies the inactive-delete backport" {
  grep -Fq 'bash "$HYDRA_ROOT/scripts/patch-openclaw-inactive-session-delete.sh"' \
    "$HYDRA_REPO/scripts/post-openclaw-update.sh"
  grep -Fq 'ERROR: patch-openclaw-inactive-session-delete.sh not found' \
    "$HYDRA_REPO/scripts/post-openclaw-update.sh"
}
