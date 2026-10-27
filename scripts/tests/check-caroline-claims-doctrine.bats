#!/usr/bin/env bats
# Negative and positive cases for scripts/check-caroline-claims-doctrine.sh.
# Every case runs against a COPY of the files the gate reads (REPO_ROOT override), so a
# test can plant a violation without touching the real doctrine.

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GATE="$REAL_ROOT/scripts/check-caroline-claims-doctrine.sh"
  FAKE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FAKE/workspaces" "$FAKE/plugins/support-tools/src/tools" "$FAKE/plugins/intercom/src"
  cp -R "$REAL_ROOT/workspaces/support" "$FAKE/workspaces/support"
  cp "$REAL_ROOT/plugins/support-tools/src/tools/ticket-format.ts" "$FAKE/plugins/support-tools/src/tools/"
  cp "$REAL_ROOT/plugins/intercom/src/ticket-format.ts" "$FAKE/plugins/intercom/src/"
  CI_MD="$FAKE/workspaces/support/reference/common-issues.md"
}

run_gate() { run env REPO_ROOT="$FAKE" bash "$GATE"; }

# Pad a file well past the 64 KiB pipe buffer so a `producer | grep -q` matcher would see
# the producer die of SIGPIPE after an early match (the false-green QA found).
pad_large() { python3 -c "import sys; open(sys.argv[1],'a').write(('filler line about subscriptions\n')*8000)" "$1"; }

@test "clean copy of the real doctrine passes" {
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: Caroline claims/credits/merges doctrine"* ]]
}

@test "CAN FAIL: a forbidden merge date in a small file is caught" {
  printf '\nOur team will review and merge typically within 5 business days.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"merge typically within 5 business days"* ]]
}

@test "CAN FAIL: a forbidden phrase near the top of a LARGE file is caught (no SIGPIPE false-green)" {
  { printf 'They will follow up. You'"'"'ll hear back within 5 business days.\n'; cat "$CI_MD"; } > "$CI_MD.new"
  mv "$CI_MD.new" "$CI_MD"
  pad_large "$CI_MD"
  [ "$(wc -c < "$CI_MD")" -gt 200000 ]
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"hear back within 5 business days"* ]]
}

@test "CAN FAIL: forbid is case- and wrap-insensitive" {
  printf '\nThis needs a MANUAL REVIEW\nBY OUR TEAM, sorry.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"manual review by our team"* ]]
}

@test "CAN FAIL: a removed required anchor is caught" {
  python3 - "$CI_MD" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("Never tell them their claims need review or ask them to claim again", "Tell them it is pending")
open(p,'w').write(s)
EOF
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q6 all claimed by them"* ]]
}

@test "a large file with every anchor present still passes (require is not false-red on SIGPIPE)" {
  pad_large "$CI_MD"
  run_gate
  [ "$status" -eq 0 ]
}

@test "CAN FAIL: bulk-credit-change dropped from the null-SLA set is caught" {
  sed -i.bak 's/"credit-verify", "bulk-credit-change", "profile-claim",/"credit-verify", "profile-claim",/' \
    "$FAKE/plugins/support-tools/src/tools/ticket-format.ts"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENT_LANE_ACTIONS covers claims + credits"* ]]
}

@test "CAN FAIL: a conversation-reply promise for claims is caught" {
  python3 - "$CI_MD" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("Do not promise a reply here either: the claim decision reaches them as an app notification and email.",
            "The outcome is posted in this conversation.")
open(p,'w').write(s)
EOF
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no conversation-reply promise for claims"* ]]
}

@test "a missing input file exits 2, never passes" {
  rm "$FAKE/workspaces/support/reference/faq.md"
  run_gate
  [ "$status" -eq 2 ]
}
