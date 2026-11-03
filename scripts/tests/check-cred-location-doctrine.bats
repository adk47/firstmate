#!/usr/bin/env bats
# Tests for check-cred-location-doctrine.sh: the gate that keeps live agent
# instruction surfaces from telling an agent to `source ~/.zshrc` for
# credentials. Born from the 2026-10-19 CMO incident (a fresh session followed
# muso-outreach-ghl-sync's `source ~/.zshrc && curl … $GHL_API_KEY`, found
# nothing, filed a bogus secrets request and blocked a draft batch).
#
# Hermetic: every test builds its own synthetic mini-repo under
# $BATS_TEST_TMPDIR (never a shared TMPDIR) via the REPO_ROOT /
# CRED_LOCATION_ALLOWLIST overrides; one test runs against the real tree.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-cred-location-doctrine.sh"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/skills-all/dummy" \
           "$BATS_TEST_TMPDIR/workspaces/x/skills/y" \
           "$BATS_TEST_TMPDIR/docs" "$BATS_TEST_TMPDIR/scripts"
  echo 'Credentials come from the gateway env.' > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'Use $GHL_API_KEY from the environment.' > "$BATS_TEST_TMPDIR/workspaces/x/skills/y/SKILL.md"
  echo '# Agent X' > "$BATS_TEST_TMPDIR/workspaces/x/SOUL.md"
  : > "$BATS_TEST_TMPDIR/allowlist.txt"
  export REPO_ROOT="$BATS_TEST_TMPDIR"
  export CRED_LOCATION_ALLOWLIST="$BATS_TEST_TMPDIR/allowlist.txt"
}

@test "passes on the real repo tree with the real allowlist" {
  unset REPO_ROOT CRED_LOCATION_ALLOWLIST
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "passes on a clean synthetic tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "fails on source ~/.zshrc in a workspace skill and names file, line and fix" {
  printf 'line one\nsource ~/.zshrc && curl -H "Authorization: $GHL_API_KEY" x\n' \
    >> "$BATS_TEST_TMPDIR/workspaces/x/skills/y/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/x/skills/y/SKILL.md:3"* ]]
  [[ "$output" == *"/etc/openclaw/main.env"* ]]
  [[ "$output" == *"edge.env"* ]]
  [[ "$output" == *"does not source an interactive shell"* ]]
}

@test "fails on source ~/.zshrc in skills-all (including skill scripts)" {
  mkdir -p "$BATS_TEST_TMPDIR/skills-all/dummy/scripts"
  echo 'source "$HOME/.zshrc" >/dev/null 2>&1 || true' > "$BATS_TEST_TMPDIR/skills-all/dummy/scripts/run.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/dummy/scripts/run.sh:1"* ]]
}

@test "fails on source ~/.zshrc in a workspace root doctrine file" {
  local f
  for f in SOUL AGENTS TOOLS STARTUP HEARTBEAT IDENTITY USER; do
    echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/workspaces/x/$f.md"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"workspaces/x/$f.md:1"* ]]
    rm "$BATS_TEST_TMPDIR/workspaces/x/$f.md"
  done
}

@test "catches the \$HOME, \${HOME}, quoted and ~/.bashrc spellings" {
  local spelling
  for spelling in 'source "$HOME/.zshrc"' 'source $HOME/.zshrc' 'source ${HOME}/.zshrc' \
                  "source '~/.zshrc'" 'source ~/.bashrc' 'source "$HOME/.bashrc"' \
                  '  source   ~/.zshrc'; do
    printf '%s\n' "$spelling" > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
    run "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "not caught: $spelling"; false; }
  done
}

@test "does not trip on prose that mentions ~/.zshrc without sourcing it" {
  echo 'DEEL_API_TOKEN is in ~/.zshrc (census pending).' > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "does not scan docs/ or scripts/ (not agent-facing surfaces)" {
  echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/docs/whatever.md"
  echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/scripts/helper.sh"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "allowlist entry on a scanned file is rejected and cannot exempt the hit" {
  echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'skills-all/dummy/SKILL.md -- sourcerc -- sneaky exemption' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"allowlist entry 'skills-all/dummy/SKILL.md' covers a scanned live-agent surface"* ]]
  [[ "$output" == *"skills-all/dummy/SKILL.md:1"* ]]
}

@test "allowlist entry on a scanned directory prefix is rejected" {
  echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/workspaces/x/skills/y/SKILL.md"
  echo 'workspaces/x/skills/ -- sourcerc -- sneaky exemption' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"covers a scanned live-agent surface"* ]]
}

@test "allowlist entry on a scanned workspace root file is rejected even with no hit" {
  echo 'workspaces/x/SOUL.md -- sourcerc -- sneaky exemption' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"covers a scanned live-agent surface"* ]]
}

@test "an allowlist entry on a different path does not exempt the hit" {
  echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'source ~/.zshrc' > "$BATS_TEST_TMPDIR/docs/plan.md"
  echo 'docs/plan.md -- sourcerc -- historical plan' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/dummy/SKILL.md:1"* ]]
}

@test "an entry for an unscanned path stays live while its pattern still matches" {
  echo 'x "bash:source ~/.zshrc && gog gmail drafts send"' > "$BATS_TEST_TMPDIR/scripts/deny.sh"
  echo 'scripts/deny.sh -- sourcerc -- tool-deny pattern' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "stale entry: path no longer exists -> red" {
  echo 'docs/gone.md -- sourcerc -- historical plan' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/gone.md"* ]]
  [[ "$output" == *"nonexistent"* ]]
}

@test "stale entry: pattern no longer matches in the file -> red" {
  echo 'nothing to see' > "$BATS_TEST_TMPDIR/docs/plan.md"
  echo 'docs/plan.md -- sourcerc -- historical plan' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/plan.md"* ]]
  [[ "$output" == *"no longer matches"* ]]
}

@test "stale directory-prefix entry is detected too" {
  mkdir -p "$BATS_TEST_TMPDIR/docs/old"
  echo 'clean' > "$BATS_TEST_TMPDIR/docs/old/a.md"
  echo 'docs/old/ -- sourcerc -- old plans' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/old/"* ]]
}

@test "malformed allowlist line -> exit 2" {
  echo 'docs/plan.md sourcerc no separators' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "unknown pattern key in the allowlist -> exit 2" {
  echo 'docs/plan.md -- bogus -- reason' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "missing skills-all/ or workspaces/ refuses to pass vacuously (exit 2)" {
  rm -rf "$BATS_TEST_TMPDIR/skills-all"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# --- bot round 2 (MUS-27566): the gate must match a path class, not spellings ---

@test "catches quoted-HOME and absolute-path spellings of source <rc>" {
  local spelling
  for spelling in 'source "$HOME"/.zshrc' 'source "${HOME}"/.zshrc' \
                  'source /home/x/.bashrc' "source ~/'.zshrc'" 'builtin source ~/.zshrc'; do
    printf '%s\n' "$spelling" > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
    run "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "not caught: $spelling"; false; }
    [[ "$output" == *"skills-all/dummy/SKILL.md:1"* ]]
  done
}

@test "catches a backslash-continued source and reports the FIRST physical line" {
  printf 'intro\nsource \\\n  ~/.zshrc && curl x\n' > "$BATS_TEST_TMPDIR/workspaces/x/skills/y/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/x/skills/y/SKILL.md:2"* ]]
  [[ "$output" != *"SKILL.md:3"* ]]
}

@test "catches the dot form at command position" {
  local spelling
  for spelling in 'x && . ~/.zshrc && curl y' '. ~/.bashrc' '$ . "$HOME/.zshrc"'; do
    printf '%s\n' "$spelling" > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
    run "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "not caught: $spelling"; false; }
  done
}

@test "prose that merely mentions source and the rc file stays clean" {
  printf 'the source of truth is not ~/.zshrc\nend of sentence. ~/.zshrc holds completions\n' \
    > "$BATS_TEST_TMPDIR/skills-all/dummy/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "stale check uses the joined matcher: an entry whose only match is continued is live" {
  printf 'deny: source \\\n  ~/.zshrc\n' > "$BATS_TEST_TMPDIR/docs/plan.md"
  echo 'docs/plan.md -- sourcerc -- continued historical form' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}
@test "stale check survives a large allowlisted file with an early match (no SIGPIPE false red)" {
  { echo 'deny: source ~/.zshrc'; for _ in $(seq 1 4000); do echo 'padding line to push the file well past the pipe buffer'; done; } > "$BATS_TEST_TMPDIR/docs/big.md"
  echo 'docs/big.md -- sourcerc -- long historical doc' > "$BATS_TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}
