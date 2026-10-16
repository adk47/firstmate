#!/usr/bin/env bats
# End-to-end check of the 403-triage example in skills-all/muso-github-code-review/SKILL.md
# (MUS-12312, bot finding on hydra#1213). Agents paste that fenced block and run it
# verbatim, so the test extracts the block from the doc and EXECUTES it. An unquoted
# `--repo <owner/repo>` parses as input/output redirection and the probe never reaches
# qa-gh.sh. qa-gh.sh and the classifier are stubbed; nothing touches GitHub.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SKILL="$HYDRA_REPO/skills-all/muso-github-code-review/SKILL.md"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/scripts/lib" "$TEST_TMPDIR/cwd"
  cat > "$TEST_TMPDIR/scripts/qa-gh.sh" <<'STUB'
#!/usr/bin/env bash
echo "QA_GH_ARGS=$*" >> "$TEST_TMPDIR/qa-gh.args"
echo "4321 1792157086"
STUB
  cat > "$TEST_TMPDIR/scripts/lib/qa-gh-error-class.sh" <<'STUB'
#!/usr/bin/env bash
echo "REM=$QA_GH_RATELIMIT_REMAINING RST=$QA_GH_RATELIMIT_RESET MSG=$1"
STUB
  # The first fenced bash block that calls qa-gh.sh with --repo, repointed at the stubs.
  awk '/^```bash/{b=1; buf=""; next} /^```/{if(b && buf ~ /qa-gh\.sh --repo/){printf "%s", buf; exit} b=0} b{buf=buf $0 "\n"}' "$SKILL" \
    | sed "s#/opt/hydra/scripts#$TEST_TMPDIR/scripts#g" > "$TEST_TMPDIR/block.sh"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the example block was extracted from the skill doc" {
  [ -s "$TEST_TMPDIR/block.sh" ]
}

@test "the example runs: rem/rst reach the classifier and --repo is a real slug" {
  cd "$TEST_TMPDIR/cwd"
  run --separate-stderr bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"REM=4321 RST=1792157086"* ]]
  grep -q -- '--repo Muso-AI/hydra api rate_limit' "$TEST_TMPDIR/qa-gh.args"
}
