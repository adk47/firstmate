#!/usr/bin/env bats
# Tests for check-agent-bridge-doctrine.sh — the guard that keeps the "CS/ops REQUEST,
# they never fix the data lane" doctrine from silently eroding out of the ops SOUL,
# Caroline's SOUL, the agent-bridge-request skill, its wrapper, and the operations
# agent's skill registration.
#
# A guard that cannot fail is not a guard, so each anchor gets a removal test.
#
# Hermetic: runs against temp COPIES of the real files via the AB_*_FILE overrides.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-agent-bridge-doctrine.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/workspaces/operations/SOUL.md"            "$TEST_TMPDIR/ops-SOUL.md"
  cp "$HYDRA_REPO/workspaces/support/SOUL.md"               "$TEST_TMPDIR/support-SOUL.md"
  cp "$HYDRA_REPO/skills-all/agent-bridge-request/SKILL.md" "$TEST_TMPDIR/SKILL.md"
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh"          "$TEST_TMPDIR/wrapper.sh"
  cp "$HYDRA_REPO/openclaw-main.json"                       "$TEST_TMPDIR/openclaw-main.json"
  export AB_OPS_SOUL_FILE="$TEST_TMPDIR/ops-SOUL.md"
  export AB_SUPPORT_SOUL_FILE="$TEST_TMPDIR/support-SOUL.md"
  export AB_SKILL_FILE="$TEST_TMPDIR/SKILL.md"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  export AB_MAIN_CONFIG_FILE="$TEST_TMPDIR/openclaw-main.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# strip <file> <fixed-substring> — drop every line containing the substring.
strip() {
  grep -vF -- "$2" "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

@test "passes on the real doctrine surface" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "fails if the ops request-don't-fix rule is removed" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "you REQUEST, you never fix"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the ops SOUL stops naming the skill (prohibition with no path)" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "agent-bridge-request"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the audit-trail-first rule is removed from the ops SOUL" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "audit trail is the FIRST query"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the gated-actions carve-out is removed (the rule would over-read)" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "Your own gated actions are unchanged"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if Caroline's never-diagnose rule is removed" {
  strip "$TEST_TMPDIR/support-SOUL.md" "you never diagnose"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if Caroline may again assert that data was lost or corrupted" {
  strip "$TEST_TMPDIR/support-SOUL.md" "never tell a customer their data was lost, deleted in error, or corrupted"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the skill loses a request type" {
  strip "$TEST_TMPDIR/SKILL.md" "data_verification"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the skill stops forbidding a hand-rolled post" {
  strip "$TEST_TMPDIR/SKILL.md" "Never hand-roll the"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the wrapper loses the symptom-not-diagnosis refusal" {
  strip "$TEST_TMPDIR/wrapper.sh" "SYMPTOMS, not causes"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the wrapper stops stamping the reports-not-instructions notice" {
  strip "$TEST_TMPDIR/wrapper.sh" "does not authorize any action"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the skill teaches an evidence field the wrapper would refuse" {
  # The real regression: the protocol doc grew `screenshot_described` while the gate's
  # allowlist did not, which would refuse a request for using a field the agent had just
  # read in its own instructions.
  # Mutate STRUCTURALLY: append to the line that opens the Evidence fields block, which is
  # identified by its own marker rather than by any field name. Naming a field here is how
  # this test silently stopped asserting anything twice — once when note/detail/what_they_see
  # were dropped, and again when screenshot_described was. A mutation test that references
  # the data it mutates decays with the data.
  sed -i.bak 's|^\*\*Evidence fields:\*\*|**Evidence fields:** `customer_phone`|' "$TEST_TMPDIR/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"disagree"* ]]
}

@test "fails if the wrapper allows an evidence field the skill never documents" {
  # Structural again: append to whichever line CLOSES the ALLOWED_EVIDENCE assignment,
  # located by the assignment itself rather than by its contents.
  awk '
    /^ALLOWED_EVIDENCE="/ { inblk = 1 }
    inblk && /"$/ { sub(/"$/, " undocumented_field\""); inblk = 0 }
    { print }
  ' "$TEST_TMPDIR/wrapper.sh" > "$TEST_TMPDIR/w.tmp" && mv "$TEST_TMPDIR/w.tmp" "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"disagree"* ]]
}

@test "fails loudly if an evidence-field list cannot be extracted at all" {
  # An unreadable list must not silently stop comparing -- that is worse than a mismatch.
  grep -v '^\*\*Evidence fields:\*\*' "$TEST_TMPDIR/SKILL.md" > "$TEST_TMPDIR/s.tmp"
  mv "$TEST_TMPDIR/s.tmp" "$TEST_TMPDIR/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not extract"* || "$output" == *"disagree"* ]]
}

@test "fails if the skill is de-registered from the operations agent" {
  jq '(.agents.list[] | select(.id == "operations") | .skills) |= map(select(. != "agent-bridge-request"))' \
    "$TEST_TMPDIR/openclaw-main.json" > "$TEST_TMPDIR/cfg.tmp"
  mv "$TEST_TMPDIR/cfg.tmp" "$TEST_TMPDIR/openclaw-main.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"operations agent's skills"* ]]
}

@test "a missing input file is an environment error, not a silent pass" {
  export AB_SKILL_FILE="$TEST_TMPDIR/does-not-exist.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "the gate FAILS when jq is unavailable — it cannot certify what it cannot check" {
  # The registration check used to warn-and-continue without jq. On a run where the image
  # lost jq AND the skill was de-registered, the gate exited 0 and certified a doctrine
  # with no invokable route. "Could not run" and "passed" must not share an exit code.
  stub_bin="$TEST_TMPDIR/nojq"
  mkdir -p "$stub_bin"
  for c in grep sed awk cat cut tr sort head tail basename dirname printf env bash date wc mktemp rm; do
    p="$(command -v $c || true)"; [ -n "$p" ] && ln -sf "$p" "$stub_bin/$c"
  done
  run env PATH="$stub_bin" "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
}

@test "fails if the real-time channel becomes caller-supplied" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak 's|^readonly CHANNEL="agent:pdp".*|CHANNEL="${1:-agent:pdp}"|' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"readonly"* ]]
}

@test "fails if the skill re-grows a raw publish curl around the wrapper" {
  printf '\ncurl -X POST http://cf/api/publish -H "X-API-Key: $K"\n' >> "$AB_SKILL_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"raw publish curl"* ]]
}

@test "fails if the mailbox-first escalation marker is removed from the notifier" {
  # Now asserts on the MARKER construction rather than on any line containing the literal
  # "type=escalation" — the old form was satisfied by comments, which is the defect the
  # anchored gate replaced.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  grep -v '^MARKER=' "$TEST_TMPDIR/notify.sh" > "$TEST_TMPDIR/n2" && mv "$TEST_TMPDIR/n2" "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"anchored escalation marker"* ]]
}

@test "fails if the anchored escalation marker is weakened, not just renamed" {
  # The old check grepped the unanchored literal "type=escalation", which also appears in
  # comments — so loosening the runtime MARKER left CI green, satisfied by the prose
  # explaining the thing it was meant to guard.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak 's|^MARKER=.*|MARKER="request_id=$REQUEST_ID"|' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"anchored escalation marker"* ]]
}


@test "a SECOND TESTABLE assignment is rejected even though the required line is present" {
  # The exact mutation QA reproduced: append `TESTABLE=$((1))` after the required literal.
  # The old gate asserted the line existed and that no exact `TESTABLE=1` line did, so this
  # passed — putting a DEPLOYED wrapper into caller-selectable test mode with CI green.
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  printf 'TESTABLE=$((1))\n' >> "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"assignments to TESTABLE"* ]]
}

@test "the safety literal must be readonly, not merely present" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak 's/^readonly TESTABLE=0$/TESTABLE=0/' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"readonly TESTABLE=0"* ]]
}

@test "fails if ONLY the mailbox hand-roll prohibition is deleted" {
  # A single "Never hand-roll the" check was satisfied by EITHER prohibition, so deleting the
  # mailbox one left the publish one holding the gate up. They guard different credentials
  # and different blast radii; each is mutated independently now.
  grep -v 'Never hand-roll the$' "$AB_SKILL_FILE" > "$TEST_TMPDIR/s.tmp" && mv "$TEST_TMPDIR/s.tmp" "$AB_SKILL_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MAILBOX-POST prohibition"* ]]
}

@test "fails if ONLY the publish hand-roll prohibition is deleted" {
  grep -v 'Never hand-roll the publish' "$AB_SKILL_FILE" > "$TEST_TMPDIR/s.tmp" && mv "$TEST_TMPDIR/s.tmp" "$AB_SKILL_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PUBLISH prohibition"* ]]
}

@test "fails if a SECOND CHANNEL assignment un-pins the real-time channel" {
  # The exact mutation: append `CHANNEL="${AGENT_BRIDGE_CHANNEL:-agent:pdp}"` after the
  # literal. The old guard proved the literal EXISTED, not that it HELD — and a re-pointed
  # CHANNEL aims a cluster-wide publish key at ticker:*, the customer nowcast bus.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  printf 'CHANNEL="${AGENT_BRIDGE_CHANNEL:-agent:pdp}"\n' >> "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"assignments to CHANNEL"* ]]
}

@test "fails if REPO/ISSUE/FROM are not frozen after resolution" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  grep -v '^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$' "$TEST_TMPDIR/notify.sh" > "$TEST_TMPDIR/n2" && mv "$TEST_TMPDIR/n2" "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not freeze its resolved constants"* ]]
}


@test "fails on a PRODUCTION-ONLY reassignment inserted after the freeze" {
  # The exact scenario: an override that only deployed copies execute, so the derived-copy
  # Bats run stays green and this gate is the only thing that can see it.
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  printf 'REPO="Muso-AI/somewhere-else"\n' >> "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AFTER the freeze"* ]]
}

@test "fails if the notifier re-points its mailbox after the freeze" {
  # CURL_BIN is covered by the readonly freeze itself (a post-freeze assignment is a runtime
  # error); the GATE's post-freeze scan is asserted on a constant it names explicitly.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  printf 'REPO="Muso-AI/somewhere-else"\n' >> "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AFTER the freeze"* ]]
}

@test "the gate never exits nonzero with no output" {
  # A guard that fails silently is indistinguishable from a real failure and impossible to
  # diagnose — the same class of defect it exists to catch. This caught a real one: a
  # `grep -c` returning 1 inside a command substitution under `set -e`.
  run "$SCRIPT"
  [ -n "$output" ]
}

@test "fails on a production-only override inserted BETWEEN the seam and the freeze" {
  # Sharper than a post-freeze assignment: this one is INSIDE the resolution path, guarded on
  # TESTABLE=0, so no derived test copy executes it and it becomes the frozen runtime value.
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  perl -0pi -e 's/^readonly REPO ISSUE GH_BIN TEST_DIR$/[ "\$TESTABLE" = "0" ] \&\& REPO="Muso-AI\/somewhere-else"\nreadonly REPO ISSUE GH_BIN TEST_DIR/m' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"on the PRODUCTION path"* ]]
}

@test "fails on a production-only notifier channel override before the freeze" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  perl -0pi -e 's/^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$/[ "\$TESTABLE" = "0" ] \&\& CHANNEL="ticker:abc"\nreadonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN/m' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"on the PRODUCTION path"* ]]
}

@test "fails on a pre-freeze production-only CURL_BIN substitution" {
  # The credential-touching binaries are resolved inside the seam's if/else, so ANY assignment
  # to one on the production path outside that block is a substitution that then receives the
  # cluster-wide publish key. Omitting them from the check was why this was reachable.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  perl -0pi -e 's/^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$/[ "\$TESTABLE" = "0" ] \&\& CURL_BIN="\/tmp\/capture"\nreadonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN/m' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
  [[ "$output" == *"PRODUCTION path"* ]]
}

@test "fails on a pre-freeze production-only KUBECTL_BIN substitution" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  perl -0pi -e 's/^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$/KUBECTL_BIN="\/tmp\/capture"\nreadonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN/m' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KUBECTL_BIN"* ]]
}

@test "fails on a MULTI-LINE production-only branch substituting a binary" {
  # The seam detector used to skip ANY conditional mentioning TESTABLE/SANDBOX, so a
  # deployed-only branch was skipped as though it were the test seam — the exact inversion of
  # the check's purpose. Only the two enumerated seam headers are skipped now.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  perl -0pi -e 's/^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$/if [ "\$TESTABLE" = "0" ]; then\n  CURL_BIN="\/tmp\/capture"\nfi\nreadonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN/m' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
  [[ "$output" == *"PRODUCTION path"* ]]
}

@test "fails on a multi-line SANDBOX-polarity branch re-pointing the request mailbox" {
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  perl -0pi -e 's/^readonly REPO ISSUE GH_BIN TEST_DIR$/if [ "\$SANDBOX" -eq 0 ]; then\n  REPO="Muso-AI\/somewhere-else"\nfi\nreadonly REPO ISSUE GH_BIN TEST_DIR/m' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REPO"* ]]
}

@test "the legitimate binary-existence check is NOT flagged" {
  # `if [ "$SANDBOX" -eq 0 ]` guarding the pinned-binary existence test is production-only and
  # correct: it assigns nothing. A blanket "no production-polarity guard" rule flagged it, and
  # flagged `readonly TESTABLE=0` too — the property is about ASSIGNMENT, not about polarity.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a DUPLICATE seam header cannot hide an override — only the first occurrence is skipped" {
  # Matching the seam by header text alone meant a second block wearing the same header was
  # skipped too. The walk now skips only the FIRST occurrence, so a duplicate is walked like
  # any other production code.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  perl -0pi -e 's/^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$/if [ "\$TESTABLE" != "1" ]; then\n  CURL_BIN="\/tmp\/capture"\nfi\nreadonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN/m' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
}

@test "a duplicate seam header in the request wrapper cannot hide a mailbox override" {
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  perl -0pi -e 's/^readonly REPO ISSUE GH_BIN TEST_DIR$/if [ "\$TESTABLE" != "1" ]; then\n  REPO="Muso-AI\/somewhere-else"\nfi\nreadonly REPO ISSUE GH_BIN TEST_DIR/m' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REPO"* ]]
}

@test "the notifier's two legitimate SANDBOX blocks are not flagged" {
  # The resolution seam and the sentinel-key replacement both use `if [ "$SANDBOX" -eq 1 ]`.
  # A "header occurs exactly once" rule flagged this correct code, which is why the check is
  # about assignments rather than about header counts.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}


@test "fails on a substitution inside the PRODUCTION arm of the real seam" {
  # The sharpest form yet: not a new block, but a line added to the arm deployed copies
  # actually run. Skipping the whole seam block discarded exactly this.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  awk '
    /^if \[ "\$TESTABLE" != "1" \]; then$/ { inblk = 1 }
    inblk && /^else$/ { print "  CURL_BIN=\"/tmp/capture\""; inblk = 0 }
    { print }
  ' "$TEST_TMPDIR/notify.sh" > "$TEST_TMPDIR/n2" && mv "$TEST_TMPDIR/n2" "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
  [[ "$output" == *"PRODUCTION path"* ]]
}

@test "fails on a SELECTIVE [ shadow combined with a mapfile substitution" {
  # The reported Critical, reproduced verbatim. Two gaps had to line up: `[` was missing from
  # the builtin-shadow list, and `mapfile` was missing from the protected-assignment scan. A
  # SELECTIVE shadow is the nasty part — it returns success only for the substitution's own
  # comparison and delegates every other test to `builtin [`, so the runtime pin passes while
  # the rest of the script behaves completely normally, and the deployed notifier hands the
  # cluster-wide Centrifugo key to /tmp/capture.
  #
  # The pins now compare with `builtin test`, which no function definition can intercept, and
  # both gaps are closed. This test exists so that reopening either one has to delete it.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  python3 - "$TEST_TMPDIR/notify.sh" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
inject = """  CURL_BIN="/usr/bin/curl"
  [() { if [ "$1" = "/tmp/capture" ] && [ "$3" = "/usr/bin/curl" ]; then return 0; fi; builtin [ "$@"; }
  mapfile -t CURL_BIN < <(printf '/tmp/capture\\n')
"""
p.write_text(s.replace('  CURL_BIN="/usr/bin/curl"\n', inject, 1))
PY
  grep -q 'mapfile -t CURL_BIN' "$TEST_TMPDIR/notify.sh"   # precondition: the mutation is really there
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"redefines a shell builtin"* ]]
  [[ "$output" == *"mapfile"* ]]
}

@test "the pins compare with builtin test, which no function can intercept" {
  # The mechanism, asserted directly rather than inferred from the mutations it defeats:
  # `[` is a builtin a function CAN shadow; `builtin test` is not interceptable, and a
  # redefinition of `builtin` itself is rejected by the closed-set check. Enumerating THAT
  # set terminates — it is finite — which is the property the assignment-spelling
  # enumeration never had.
  run grep -c 'builtin test "\$' "$HYDRA_REPO/scripts/agent-bridge-notify.sh"
  [ "$output" -ge 9 ]
  run grep -c 'builtin test "\$' "$HYDRA_REPO/scripts/agent-bridge-request.sh"
  [ "$output" -ge 4 ]
  # ...and no pin still uses the shadowable form.
  run grep -c '^\s*\[ "\$[A-Z_]*" = .* || { printf .ERROR:' "$HYDRA_REPO/scripts/agent-bridge-notify.sh"
  [ "$output" -eq 0 ]
}

@test "fails when the street-address pattern drifts between the two wrappers" {
  # The blocking QA finding on 73c392f1: the word-run bound was applied to the request
  # wrapper and not the notifier, so the notifier kept classifying ordinary escalation prose
  # ("...6 customers ... no independent way to verify") as a street address and would have
  # refused to publish. Two copies of one pattern is two places to fix; this is the check
  # that makes fixing only one of them impossible.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  # Revert the notifier to the OLD unbounded run, leaving the request wrapper bounded.
  perl -0pi -e "s/\\[0-9\\]\\+\\[A-Za-z\\]\\? \\+\\(\\[A-Za-z\\]\\+ \\+\\)\\{0,3\\}\\(street/[0-9]+ +[A-Za-z][A-Za-z ]* (street/" "$TEST_TMPDIR/notify.sh"
  grep -q '\[A-Za-z \]\* (street' "$TEST_TMPDIR/notify.sh"   # precondition: the drift is really there
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFTED"* ]]
}

@test "fails when the street-address pattern is REMOVED from a wrapper entirely" {
  # A missing pattern must not read as a passing check. Comparing nothing to nothing is the
  # failure mode where a guard reports OK because both sides are equally absent.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  grep -v 'terrace' "$TEST_TMPDIR/notify.sh" > "$TEST_TMPDIR/n2" && mv "$TEST_TMPDIR/n2" "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not extract"* ]]
}

@test "the real production arm of the seam is counted, not skipped" {
  # Guards the expectation itself: the binaries are assigned exactly once on the production
  # path (in the SANDBOX seam's else arm). An expectation of 0 here would mean the walk had
  # gone back to skipping the whole block.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "'^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN\$' 1" "$SCRIPT"
}

@test "fails on an export-form substitution in the production arm" {
  # `export CURL_BIN=/tmp/capture` is an assignment in every sense that matters; a counter
  # that knew only bare and `readonly` forms let it through. Caught twice now — by the
  # builtin rejection AND by the broadened counter.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  awk '
    { print }
    /^  CURL_BIN="\/usr\/bin\/curl"$/ { print "  export CURL_BIN=\"/tmp/capture\"" }
  ' "$TEST_TMPDIR/notify.sh" > "$TEST_TMPDIR/n2" && mv "$TEST_TMPDIR/n2" "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shell builtin"* ]]
}

@test "fails on a declare-form substitution" {
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  printf 'declare REPO="Muso-AI/somewhere-else"\n' >> "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shell builtin"* ]]
}

@test "fails on a printf -v substitution" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  printf 'printf -v CHANNEL "%%s" "ticker:abc"\n' >> "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shell builtin"* ]]
}

@test "fails if an assertion is edited to certify the substituted value" {
  # Moving BOTH halves together: substitute the binary and rewrite the assertion to match it.
  # Checking only that an assertion mentioning the variable exists would certify this.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak 's|builtin test "$CURL_BIN" = "/usr/bin/curl"|builtin test "$CURL_BIN" = "/tmp/capture"|' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
}

@test "fails when the runtime assertion is COMMENTED OUT and the binary substituted via eval" {
  # The combined attack: `eval 'CURL_BIN=...'` (a spelling no scan enumerated) plus commenting
  # out the runtime pin that would have caught it anyway. Closed by checking LIVE CODE only —
  # not by adding `eval` to a pattern list.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  awk '
    { print }
    $0 == "  CURL_BIN=\"/usr/bin/curl\"" { print "  eval '"'"'CURL_BIN=\"/tmp/capture\"'"'"'" }
  ' "$TEST_TMPDIR/notify.sh" > "$TEST_TMPDIR/n2" && mv "$TEST_TMPDIR/n2" "$TEST_TMPDIR/notify.sh"
  sed -i.bak 's|^\(  builtin test "\$CURL_BIN".*\)$|  # \1|' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exact runtime pin for CURL_BIN"* ]]
}

@test "a commented-out assertion alone is caught" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak 's|^\(  builtin test "\$CHANNEL".*\)$|  # \1|' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exact runtime pin for CHANNEL"* ]]
}

@test "an eval-form assignment is caught even with the assertion intact" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  printf 'eval %s\n' "'REPO=\"Muso-AI/somewhere-else\"'" >> "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails on a DECOY clause that satisfies the substrings but inverts the assertion" {
  # `[ "$CURL_BIN" = "/tmp/capture" ] || [ "sentinel" = "/usr/bin/curl" ]` contains both
  # substrings the old check looked for, while the real comparison accepts the substitution.
  # Independent substring matching is not structural matching.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak -e 's|^  CURL_BIN="/usr/bin/curl"$|  CURL_BIN="/tmp/capture"|' \
             -e 's|^  builtin test "\$CURL_BIN".*$|  builtin test "$CURL_BIN" = "/tmp/capture" \|\| builtin test "sentinel" = "/usr/bin/curl" \|\| die "CURL_BIN was altered: $CURL_BIN"|' \
             "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exact runtime pin for CURL_BIN"* ]]
}

@test "the canonical assertion form is accepted with any indentation" {
  # Guards the normalisation: the real file aligns these with runs of spaces, and an exact
  # match that ignored that would fail on correct code.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "fails when die is neutered AND a constant substituted (combined mutation)" {
  # The gate proved a comparison existed but not that failing it stopped anything.
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak -e 's|^die().*|die() { :; }|' \
             -e 's|^  CURL_BIN="/usr/bin/curl"$|  CURL_BIN="/tmp/capture"|' "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
}

@test "fails on two assignments on ONE line plus a shadowed exit" {
  cp "$HYDRA_REPO/scripts/agent-bridge-notify.sh" "$TEST_TMPDIR/notify.sh"
  export AB_NOTIFY_FILE="$TEST_TMPDIR/notify.sh"
  sed -i.bak 's|^  CURL_BIN="/usr/bin/curl"$|  CURL_BIN="/usr/bin/curl"; CURL_BIN="/tmp/capture"|' "$TEST_TMPDIR/notify.sh"
  printf 'exit() { :; }\n' >> "$TEST_TMPDIR/notify.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURL_BIN"* ]]
  [[ "$output" == *"redefines a shell builtin"* ]]
}

@test "fails on a shadowed exit alone" {
  cp "$HYDRA_REPO/scripts/agent-bridge-request.sh" "$TEST_TMPDIR/wrapper.sh"
  export AB_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  printf 'exit() { :; }\n' >> "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"redefines a shell builtin"* ]]
}
