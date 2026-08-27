#!/usr/bin/env bats
# Tests for check-admin-api-doc-contract.sh: the mechanical backstop that keeps
# the analytics-source docs routed through muso-cli's typed `tracks sources`
# verbs (where the {"link": ...} body is golden-tested and cannot drift) and
# blocks the dead {"url": ...} and "fromTrackId" fields a hand-rolled payload
# would reach for.
#
# Hermetic: runs the guard against a temp COPY of the repo's skill tree via the
# REPO_ROOT env override, so a test never edits the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-admin-api-doc-contract.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/skills-all/muso-ops-tracks" "$TEST_TMPDIR/workspaces/operations/skills/other"
  cp "$HYDRA_REPO/skills-all/muso-ops-tracks/SKILL.md" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    || return 1
  export REPO_ROOT="$TEST_TMPDIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "passes on the real (patched) skill tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "fails if the dead url field resurfaces in the canonical tracks skill" {
  # Someone re-introduces a hand-rolled body next to the CLI example.
  printf '%s\n' 'call POST "/admin/track/<track_id>/analytics-sources" '"'"'{"url":"https://youtu.be/x"}'"'" \
    >> "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'{"url":'* ]]
  [[ "$output" == *"muso-ops-tracks/SKILL.md"* ]]
}

@test "fails if a payload carrying the phantom fromTrackId reappears" {
  # moveAnalyticsLink.js never reads fromTrackId — documenting it teaches a
  # silent no-op move.
  printf '%s\n' 'call PATCH "/admin/track/x/analytics-sources" '"'"'{"linkId":"L1","fromTrackId":"T2"}'"'" \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fromTrackId"* ]]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "a grep failure during the fromTrackId scan exits 2, never a vacuous pass" {
  # The scan must fail CLOSED. Not tested with chmod: CI bats runs as ROOT, and
  # root reads a 000-mode file happily, so a permission-based test would pass
  # vacuously — exactly the failure mode under test. Shim grep instead, failing
  # only the fromTrackId probe so the rest of the guard behaves normally.
  local shim="$TEST_TMPDIR/bin"
  mkdir -p "$shim"
  cat > "$shim/grep" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *fromTrackId*) exit 2 ;; esac
done
exec /usr/bin/grep "$@"
SH
  chmod +x "$shim/grep"
  PATH="$shim:$PATH" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to pass vacuously"* ]]
}

@test "removing the operational bulk-gate line fails even if the explanatory note survives" {
  # The note contrasts --approval-msg-id with --approval-ref, so a bare
  # '--approval-ref' anchor would still match it and the guard would pass while
  # operators had no usable override.
  #
  # The approver in this line used to be hardcoded `aaron`. Since 2026-08-26 it
  # is `<their handle>` — the requester's own, when they are allowlisted — so the
  # mutation targets that form instead. Deleting the line must still turn the
  # guard red; if this ever passes, the guard has stopped requiring an
  # operational override and operators who trip the threshold are stuck.
  grep -v -- '--confirmed-by <their handle> --approval-ref' \
    "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    > "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp"
  mv "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  # The note must still be present, or this test proves nothing.
  grep -q -- '--approval-ref' "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--approval-ref"* ]]
}

# --- the documented CLI-availability probe must reject an old CLI ------------
# Extracts the probe line from the skill and RUNS it, so the tested command is
# by construction the one operators copy. The trap it guards: cobra prints the
# parent `tracks` help and exits 0 for an unknown subcommand, so the obvious
# `muso tracks sources --help >/dev/null || ...` passes on v0.10.0 — the exact
# version it must reject (verified on node-8, exit=0).
probe_line() {
  grep -m1 -F 'muso tracks --help' "$HYDRA_REPO/skills-all/muso-ops-tracks/SKILL.md" \
    | sed 's/^> *//'
}

# fake_muso <with-sources|without-sources> — a cobra-shaped `muso` that always
# exits 0, mimicking the real unknown-subcommand behaviour.
fake_muso() {
  local mode="$1" bin="$TEST_TMPDIR/fakebin"
  mkdir -p "$bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'cat <<EOF'
    echo 'Available Commands:'
    echo '  capture     Re-capture (enrich) a track by its catalog ID'
    echo '  credits     Add or delete a profile'"'"'s credits on a track'
    [ "$mode" = with-sources ] && echo '  sources     List and edit a track'"'"'s analytics sources'
    echo '  unmerge     Extract previously merged tracks back out'
    echo 'EOF'
    echo 'exit 0'
  } > "$bin/muso"
  chmod +x "$bin/muso"
  echo "$bin"
}

@test "the documented availability probe REJECTS a CLI without the sources verb" {
  local bin; bin="$(fake_muso without-sources)"
  run env PATH="$bin:$PATH" bash -c "$(probe_line)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLI too old"* ]]
}

@test "the documented availability probe ACCEPTS a CLI that has the sources verb" {
  local bin; bin="$(fake_muso with-sources)"
  run env PATH="$bin:$PATH" bash -c "$(probe_line)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CLI too old"* ]]
}

@test "fails if remove-then-re-add returns as a recovery instruction" {
  # The shape this guards: the reassignment block says "move, do NOT
  # remove-then-add" while a later Common Issues entry still tells the operator
  # to remove and re-add. One authoritative line does not enforce anything while
  # a stale one survives elsewhere in the same file.
  printf '%s\n' '- **"Link is already assigned"** → Find the current track, remove, then re-add' \
    >> "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"remove-then-re-add is documented as a recovery"* ]]
  [[ "$output" == *"destroys the captured counters"* ]]
}

@test "naming remove-then-re-add in order to FORBID it stays legal" {
  # The discrimination test above is worthless without this one: a guard that
  # fires on the prohibition too would force the skill to stop warning against
  # the destructive path, which is the opposite of the intent. Both live
  # prohibitions in the canonical skill are exercised by the passing baseline;
  # these add the "never"/"instead of" phrasings.
  printf '%s\n' \
    'Never remove and re-add a source to reassign it.' \
    'Use `tracks sources move` instead of remove/re-add.' \
    >> "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "a grep failure during the remove-then-re-add scan exits 2, never a vacuous pass" {
  # Same fail-closed contract as the fromTrackId scan, and same reason for
  # shimming grep rather than chmod: CI bats runs as ROOT.
  local shim="$TEST_TMPDIR/bin"
  mkdir -p "$shim"
  cat > "$shim/grep" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *re-\?add*) exit 2 ;; esac
done
exec /usr/bin/grep "$@"
SH
  chmod +x "$shim/grep"
  PATH="$shim:$PATH" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to pass vacuously"* ]]
}

@test "naming fromTrackId in prose to warn against it stays legal" {
  # The canonical skill documents that the field is ignored; only a payload
  # carrying it as a JSON key may fail.
  printf '%s\n' 'Any `fromTrackId` you pass is silently ignored.' \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "fails if the dead url field appears in a workspace skill doc" {
  printf '%s\n' 'call POST "/admin/track/x/analytics-sources" '"'"'{"url":"https://youtu.be/x"}'"'" \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "fails on the spaced form of the dead url field (whitespace tolerance)" {
  printf '%s\n' 'call POST "/admin/track/x/analytics-sources" '"'"'{ "url": "https://youtu.be/x" }'"'" \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "an unrelated --link mention elsewhere cannot satisfy the add-link anchor" {
  # Strip the flag line under the `tracks sources add` invocation but leave
  # another --link elsewhere in the file: the bounded anchor must still fail.
  awk '/tracks sources add <track_id>/{print; getline; getline; next} {print} END{print "unrelated: muso something --link https://example.com"}' \
    "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    > "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp"
  mv "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracks sources add"* ]]
}

@test "fails on a multi-line pretty-printed dead url payload" {
  printf '%s\n' '```json' '{' '  "url": "https://youtu.be/x"' '}' '```' \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "fails on an early match in a large skill doc (no early-close pipe hazard)" {
  { printf '%s\n' 'call POST "/admin/track/x/analytics-sources" '"'"'{"url":"https://youtu.be/x"}'"'"
    yes 'padding line far past any pipe buffer' | head -50000
  } > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "fails if the bulk-gate override stops naming the CLI's --approval-ref flag" {
  # muso-admin-api.sh spells it --approval-msg-id; muso-cli spells it
  # --approval-ref. With CLI commands documented, an operator who trips the
  # bulk-destructive threshold needs the CLI spelling to get past it.
  sed 's/--approval-ref/--approval-msg-id/g' "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    > "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp"
  mv "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--approval-ref"* ]]
}

@test "fails if the tracks skill stops documenting the typed CLI add verb" {
  grep -vF -- 'tracks sources add <track_id>' "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    > "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp"
  mv "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracks sources add"* ]]
}

@test "exits 2 (script error) when the workspaces directory is missing — never a vacuous pass" {
  rm -rf "$TEST_TMPDIR/workspaces"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing directory"* ]]
}

@test "exits 2 (script error) when the tracks skill file is missing" {
  rm -f "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
