#!/usr/bin/env bats
# Tests for check-intercom-reply-identity.sh: the mechanical backstop that keeps the
# Intercom reply-identity doctrine (agent-authored customer-facing replies post as
# Caroline 5763097, never under a human's admin id) from silently regressing out of
# skills-all/muso-intercom/SKILL.md, workspaces/operations/TOOLS.md and
# docs/lessons/muso-domain.md -- and that refuses any agent-callable surface binding a
# human admin id to an Intercom identity field.
#
# Hermetic: the anchor checks run against temp COPIES of the real files via the
# INTERCOM_SKILL_FILE / OPS_TOOLS_FILE / MUSO_LESSONS_FILE overrides, and the scan runs
# against a synthetic tree via INTERCOM_SCAN_ROOT, so a test never edits tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-intercom-reply-identity.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/skills-all/muso-intercom/SKILL.md" "$TEST_TMPDIR/SKILL.md"
  cp "$HYDRA_REPO/workspaces/operations/TOOLS.md" "$TEST_TMPDIR/TOOLS.md"
  cp "$HYDRA_REPO/docs/lessons/muso-domain.md" "$TEST_TMPDIR/muso-domain.md"
  export INTERCOM_SKILL_FILE="$TEST_TMPDIR/SKILL.md"
  export OPS_TOOLS_FILE="$TEST_TMPDIR/TOOLS.md"
  export MUSO_LESSONS_FILE="$TEST_TMPDIR/muso-domain.md"

  # Empty synthetic scan tree by default, so anchor tests are not affected by the
  # real repo's contents and scan tests control exactly one file.
  mkdir -p "$TEST_TMPDIR/scan/scripts"
  export INTERCOM_SCAN_ROOT="$TEST_TMPDIR/scan"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# strip <file> <fixed-substring> -- drop every line containing the substring.
strip() {
  grep -vF -- "$2" "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

# write_scanned <name> <content> -- drop a file into the synthetic scan tree.
write_scanned() {
  printf '%s\n' "$2" > "$TEST_TMPDIR/scan/scripts/$1"
}

# --- baseline ---------------------------------------------------------------

@test "passes on the real doctrine files with an empty scan tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "passes on the real repo as committed (no override)" {
  unset INTERCOM_SKILL_FILE OPS_TOOLS_FILE MUSO_LESSONS_FILE INTERCOM_SCAN_ROOT
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- anchors ----------------------------------------------------------------

@test "fails when the Reply Identity heading is removed from the skill" {
  strip "$TEST_TMPDIR/SKILL.md" "Reply Identity"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Reply Identity section heading"* ]]
}

@test "fails when Caroline's admin id is removed from the skill" {
  strip "$TEST_TMPDIR/SKILL.md" "5763097"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"posting identity"* ]]
}

@test "fails when the authorization-is-not-identity distinction is removed" {
  strip "$TEST_TMPDIR/SKILL.md" "under a human admin id"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"authorization-is-not-identity"* ]]
}

@test "fails when the rule is removed from the always-injected ops surface" {
  strip "$TEST_TMPDIR/TOOLS.md" "5763097"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"always-injected ops surface"* ]]
}

@test "fails when the lessons admin table loses its not-a-menu qualifier" {
  strip "$TEST_TMPDIR/muso-domain.md" "not a menu of posting identities"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a menu of posting identities"* ]]
}

@test "exits 2 when a doctrine file is missing entirely" {
  rm -f "$TEST_TMPDIR/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# --- scan: refusals ---------------------------------------------------------

@test "refuses a same-line human admin id in a JSON payload" {
  write_scanned bad.py 'r = post("https://api.intercom.io/conversations/1/reply", json={"admin_id": "10206197"})'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not Caroline"* ]]
}

# The 2026-08-31 QA finding on PR #900: a same-line matcher passed this, and it is
# valid code that posts as Nick.
@test "refuses a human admin id split across lines in a JSON payload" {
  write_scanned split.py 'r = post(
    "https://api.intercom.io/conversations/1/reply",
    json={"message_type": "comment",
          "admin_id":
              "10206197",
          "body": b})'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not Caroline"* ]]
}

@test "refuses a human admin id assigned to the env knob" {
  write_scanned env.sh 'INTERCOM_ADMIN_ID=5201828
curl -s https://api.intercom.io/conversations/1/reply'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "refuses a human admin id as an env-knob default" {
  write_scanned default.sh 'ADMIN="${INTERCOM_ADMIN_ID:-5465657}"
curl -s https://api.intercom.io/me'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "refuses a human admin id in a markdown curl snippet an agent copies" {
  write_scanned doc.md 'Reply to a conversation:

```bash
curl -X POST https://api.intercom.io/conversations/$ID/reply \
  -d "{\"admin_id\": \"10206197\", \"body\": \"hi\"}"
```'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "refuses each human admin id, not just Nick's" {
  for id in 10206197 5201828 5465657; do
    write_scanned "each-$id.py" "payload = {\"admin_id\": \"$id\"}
url = \"https://api.intercom.io/conversations\""
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    rm -f "$TEST_TMPDIR/scan/scripts/each-$id.py"
  done
}

# --- scan: legitimate uses that must stay green -----------------------------

@test "accepts Caroline's own admin id bound to the identity field" {
  write_scanned good.py 'r = post("https://api.intercom.io/conversations/1/reply", json={"admin_id": "5763097"})'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# docs/lessons/muso-domain.md explicitly asks for staff ids to be EXCLUDED from
# customer-complaint analysis. That read-side use must not be mistaken for a write.
@test "accepts a read-side exclusion list naming staff admin ids" {
  write_scanned read.py 'EXCLUDE_ADMIN_IDS = ["5465657", "10206197", "5201828"]
URL = "https://api.intercom.io/conversations/search"'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- allowlist semantics ----------------------------------------------------
# Detection requires Caroline's id rather than enumerating forbidden ones, so an id
# that is on no blocklist anywhere is still refused. This is the property that ends
# the encoding arms race the 2026-08-31 QA reviews found twice.

@test "refuses an unknown id nobody has blocklisted" {
  write_scanned unknown.py 'payload = {"admin_id": "9812345"}
url = "https://api.intercom.io/conversations/1/reply"'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not Caroline"* ]]
}

# PR #900 QA finding 2: escapes that decode to a forbidden id at runtime. The checker
# cannot read them, so it refuses rather than guessing.
@test "refuses a unicode-escaped value it cannot resolve" {
  write_scanned esc.py 'payload = {"admin_id": "\u0031\u0030\u0032\u0030\u0036\u0031\u0039\u0037"}
url = "https://api.intercom.io/conversations/1/reply"'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escaped literal"* ]]
}

@test "refuses a hex-escaped value it cannot resolve" {
  write_scanned hex.js 'const body = { admin_id: "\x31\x30\x32\x30\x36\x31\x39\x37" };
fetch("https://api.intercom.io/conversations/1/reply");'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# PR #900 QA finding 1: scripts/intercom-webhook.js is a real tracked Intercom writer
# and .js was outside the scan.
@test "scans JavaScript Intercom writers" {
  write_scanned writer.js 'const res = await fetch(`https://api.intercom.io/conversations/${convId}/reply`, {
  body: JSON.stringify({ message_type: "comment", admin_id: "10206197" })
});'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "scans TypeScript Intercom writers" {
  write_scanned writer.ts 'const payload: Record<string,string> = { admin_id: "5201828" };
const url = "https://api.intercom.io/conversations/1/reply";'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "accepts Caroline's id in a JavaScript writer" {
  write_scanned ok.js 'const res = await fetch("https://api.intercom.io/conversations/1/reply", {
  body: JSON.stringify({ message_type: "comment", admin_id: "5763097" })
});'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# Variables are the common legitimate form (os.environ.get, $ADMIN, BOT_ADMIN_ID) and
# are out of a grep's reach by design -- documented in the script, not silently ignored.
@test "accepts an identity field bound to a variable" {
  write_scanned var.js 'const BOT_ADMIN_ID = process.env.INTERCOM_ADMIN_ID;
await fetch("https://api.intercom.io/conversations/1/reply", {
  body: JSON.stringify({ admin_id: BOT_ADMIN_ID })
});'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "accepts an identity field bound to an env lookup with Caroline as default" {
  write_scanned envdefault.py 'admin_id = os.environ.get("INTERCOM_ADMIN_ID", "5763097")
url = "https://api.intercom.io/conversations/1/reply"'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "does not read a short number in prose as an identity binding" {
  write_scanned prose.md 'Pass `admin_id` (see note 2) when calling https://api.intercom.io.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "accepts doctrine prose that names the forbidden ids in order to forbid them" {
  write_scanned doctrine.md 'Never post a reply under a human admin id (Nick `10206197`,
Aaron `5201828`, Jan `5465657`): agent replies post as Caroline, `admin_id` `5763097`.
See https://api.intercom.io docs.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "ignores a file that never mentions Intercom" {
  write_scanned unrelated.py 'SLACK_USER = "10206197"'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "refuses a longer literal that is not exactly Caroline's id" {
  write_scanned longer.py 'payload = {"admin_id": "102061970000"}
url = "https://api.intercom.io/conversations"'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "ignores a long number that is not bound to an identity field" {
  write_scanned other.py 'TRACE_ID = "102061970000"
url = "https://api.intercom.io/conversations"'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- gateway config: the id every Caroline reply is actually posted with -----
# PR #900 QA finding: the plugin posts with account.botAdminId, so this config value --
# not any string in a script -- authors every one of Caroline's replies. A one-character
# edit here misattributes the whole channel while every file scan stays green.

@test "accepts the committed gateway config" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "fails when a configured botAdminId is not Caroline" {
  jq '.channels.intercom.accounts.default.botAdminId="10206197"' \
    "$HYDRA_REPO/openclaw-edge.json" > "$TEST_TMPDIR/edge.json"
  INTERCOM_CONFIG_FILES="$TEST_TMPDIR/edge.json" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"botAdminId"* ]]
  [[ "$output" == *"EVERY Caroline reply"* ]]
}

@test "fails on a non-default account whose botAdminId is not Caroline" {
  jq '.channels.intercom.accounts.secondary = {"botAdminId":"5201828"}' \
    "$HYDRA_REPO/openclaw-edge.json" > "$TEST_TMPDIR/edge.json"
  INTERCOM_CONFIG_FILES="$TEST_TMPDIR/edge.json" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secondary"* ]]
}

@test "skips a config that has no intercom channel" {
  printf '%s\n' '{"channels":{}}' > "$TEST_TMPDIR/none.json"
  INTERCOM_CONFIG_FILES="$TEST_TMPDIR/none.json" run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "skips a config file that does not exist" {
  INTERCOM_CONFIG_FILES="$TEST_TMPDIR/absent.json" run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# PR #900 QA finding: JavaScript decodes an escaped KEY back to admin_id before sending,
# and a matcher anchored on the token `admin_id` cannot see a key that is spelled
# `admin_id`. Escapes are therefore refused file-wide in an Intercom-writing file.
@test "refuses an escaped admin_id KEY, not just an escaped value" {
  printf '%s\n' 'const b = {"\\u0061dmin_id": "10206197"};' \
                'fetch("https://api.intercom.io/conversations/1/reply", {body: JSON.stringify(b)});' \
    > "$TEST_TMPDIR/scan/scripts/esckey.js"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escaped literal"* ]]
}

@test "does not scan its own test fixtures" {
  mkdir -p "$TEST_TMPDIR/scan/scripts/tests"
  printf '%s\n' 'json={"admin_id": "10206197"}' > "$TEST_TMPDIR/scan/scripts/tests/fixture.py"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}
