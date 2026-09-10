#!/usr/bin/env bats
# Executes the REAL pasted Rollback block of docs/runbooks/UPGRADE-2026.8.1.md
# (QA finding, PR #899: an assignment outside the quoted here-doc made the
# pasted block die on `ARCHIVE: unbound variable` before touching the archive).
# The block text is extracted from the runbook at test time, so the test guards
# the shape an operator actually pastes; only paths and the side-effecting
# commands are substituted/stubbed.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
RUNBOOK="$HYDRA_REPO/docs/runbooks/UPGRADE-2026.8.1.md"

extract_rollback_block() {
  # the pasted shape = the `bash -euo pipefail <<'RUNBOOK_BLOCK' ... RUNBOOK_BLOCK` under "## Rollback"
  awk '/^## Rollback/{p=1} /^## Post-upgrade invariants/{p=0} p' "$RUNBOOK" \
    | awk '/^bash -euo pipefail <<.RUNBOOK_BLOCK.$/{p=1} p{print} /^RUNBOOK_BLOCK$/{if(p){exit}}'
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/root" "$TEST_TMPDIR/opt/scripts"
  CALLS="$TEST_TMPDIR/calls"; export CALLS
  rec() { printf '#!/bin/bash\necho "$(basename "$0") $*" >> "$CALLS"\n' > "$1"; chmod +x "$1"; }
  rec "$TEST_TMPDIR/bin/systemctl"
  # The downgrade helper stub is the load-bearing observer: it asserts, AT THE
  # MOMENT IT IS INVOKED, that the pre-8.1 archive has already been swapped in
  # (restore-before-downgrade). Moving the helper call above the swap in the
  # runbook makes this stub fail, which fails the block, which turns the suite red.
  cat > "$TEST_TMPDIR/opt/scripts/downgrade-openclaw-runtime.sh" <<STUB
#!/bin/bash
echo "\$(basename "\$0") \$*" >> "$CALLS"
grep -q '"pre":"8.1"' "$TEST_TMPDIR/root/.openclaw-main/openclaw.json" 2>/dev/null \
  || { echo "STUB-ASSERT: downgrade invoked BEFORE the pre-8.1 state was restored (main)" >&2; exit 97; }
grep -q '"pre":"8.1"' "$TEST_TMPDIR/root/.openclaw-edge/openclaw.json" 2>/dev/null \
  || { echo "STUB-ASSERT: downgrade invoked BEFORE the pre-8.1 state was restored (edge)" >&2; exit 97; }
[ ! -e "$TEST_TMPDIR/root/.openclaw-main/MIGRATED-8.2" ] \
  || { echo "STUB-ASSERT: downgrade invoked while the 8.2-migrated state was still live" >&2; exit 97; }
case " \$* " in *" --no-restart "*) ;; *) echo "STUB-ASSERT: downgrade invoked WITHOUT --no-restart (it would restart on whatever state is live)" >&2; exit 97;; esac
STUB
  chmod +x "$TEST_TMPDIR/opt/scripts/downgrade-openclaw-runtime.sh"
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/pgrep"; chmod +x "$TEST_TMPDIR/bin/pgrep"   # "no gateway process"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "openclaw $*" >> "$CALLS"
[ "$1" = "--version" ] && { echo "OpenClaw 2026.7.1 (test)"; exit 0; }
exit 0   # health --json => healthy
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  # live state dirs (8.2-migrated: marker file) that the rollback must REPLACE
  mkdir -p "$TEST_TMPDIR/root/.openclaw-main" "$TEST_TMPDIR/root/.openclaw-edge"
  echo migrated > "$TEST_TMPDIR/root/.openclaw-main/MIGRATED-8.2"
  # the pre-8.1 archive: both dirs with the trees the block validates
  mkdir -p "$TEST_TMPDIR/src/.openclaw-main/agents" "$TEST_TMPDIR/src/.openclaw-edge/agents"
  echo '{"pre":"8.1"}' > "$TEST_TMPDIR/src/.openclaw-main/openclaw.json"; echo '{"pre":"8.1"}' > "$TEST_TMPDIR/src/.openclaw-edge/openclaw.json"
  ( cd "$TEST_TMPDIR/src" && tar -czf "$TEST_TMPDIR/root/openclaw-state-pre81-TESTTS.tar.gz" .openclaw-main .openclaw-edge )
  ( cd "$TEST_TMPDIR/root" && sha256sum openclaw-state-pre81-TESTTS.tar.gz > openclaw-state-pre81-TESTTS.tar.gz.sha256 )
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# render_block — the real block with ONLY paths substituted (the operator fills <ts>)
render_block() {
  extract_rollback_block \
    | sed -e "s|<ts>|TESTTS|g" \
          -e "s|/root/|$TEST_TMPDIR/root/|g" \
          -e "s|/opt/hydra/scripts/|$TEST_TMPDIR/opt/scripts/|g"
}

@test "the runbook still contains a pasteable Rollback block" {
  [ "$(extract_rollback_block | wc -l)" -gt 10 ]
  extract_rollback_block | head -1 | grep -q "bash -euo pipefail <<'RUNBOOK_BLOCK'"
}

@test "the pasted block executes end-to-end: no unbound variable, archive restored BEFORE downgrade and start" {
  render_block > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  echo "$output" | grep -q "unbound variable" && { echo "$output"; false; }
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback complete"* ]]
  # state was swapped to the archive contents
  [ ! -e "$TEST_TMPDIR/root/.openclaw-main/MIGRATED-8.2" ]
  grep -q '"pre":"8.1"' "$TEST_TMPDIR/root/.openclaw-main/openclaw.json"
  grep -q '"pre":"8.1"' "$TEST_TMPDIR/root/.openclaw-edge/openclaw.json"
  # ordering: stop < downgrade(--yes --no-restart) < timer enable < start
  stop_ln=$(grep -n "^systemctl stop" "$CALLS" | head -1 | cut -d: -f1)
  dg_ln=$(grep -n "^downgrade-openclaw-runtime.sh --yes --no-restart" "$CALLS" | head -1 | cut -d: -f1)
  tmr_ln=$(grep -n "^systemctl enable --now codex-token-refresh.timer" "$CALLS" | head -1 | cut -d: -f1)
  start_ln=$(grep -n "^systemctl start" "$CALLS" | head -1 | cut -d: -f1)
  [ -n "$dg_ln" ] && [ "$stop_ln" -lt "$dg_ln" ] && [ "$dg_ln" -lt "$tmr_ln" ] && [ "$tmr_ln" -lt "$start_ln" ]
  # the helper stub itself asserted restore-before-downgrade at invocation time (exit 97 otherwise);
  # its recorded call proves it ran and passed that assertion
  grep -q "^downgrade-openclaw-runtime.sh --yes --no-restart" "$CALLS"
  [[ "$output" != *"STUB-ASSERT"* ]]
}

@test "MUTATION: moving the downgrade call above the archive swap turns the suite RED" {
  # rewrite the real block so the helper runs BEFORE the state swap (the unsafe ordering)
  render_block > "$TEST_TMPDIR/block.sh"
  python3 - "$TEST_TMPDIR/block.sh" "$TEST_TMPDIR/mutant.sh" <<'PY'
import sys,re
src=open(sys.argv[1]).read().split("\n")
# the helper invocation is a 2-line command: the call line (ends with \) and its || { ... } continuation
i=next(k for k,l in enumerate(src) if "downgrade-openclaw-runtime.sh --yes --no-restart" in l)
call=src[i:i+2]; del src[i:i+2]
j=next(k for k,l in enumerate(src) if l.startswith("rm -rf ") and ".openclaw-main" in l)
src[j:j]=call
open(sys.argv[2],"w").write("\n".join(src))
PY
  h=$(grep -n "downgrade-openclaw-runtime.sh --yes --no-restart" "$TEST_TMPDIR/mutant.sh" | head -1 | cut -d: -f1)
  r=$(grep -n "^rm -rf .*openclaw-main" "$TEST_TMPDIR/mutant.sh" | head -1 | cut -d: -f1)
  [ -n "$h" ] && [ -n "$r" ] && [ "$h" -lt "$r" ]
  run bash "$TEST_TMPDIR/mutant.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STUB-ASSERT: downgrade invoked BEFORE the pre-8.1 state was restored"* ]]
}

@test "a wrong <ts> refuses before deleting anything" {
  render_block | sed "s|pre81-TESTTS|pre81-WRONG|g" > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: archive or its .sha256 not found"* ]]
  [ -e "$TEST_TMPDIR/root/.openclaw-main/MIGRATED-8.2" ]     # live state untouched
  if grep -q "^systemctl stop" "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl stop' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "a checksum mismatch refuses before deleting anything" {
  echo "0000000000000000000000000000000000000000000000000000000000000000  openclaw-state-pre81-TESTTS.tar.gz" > "$TEST_TMPDIR/root/openclaw-state-pre81-TESTTS.tar.gz.sha256"
  render_block > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: archive checksum mismatch"* ]]
  [ -e "$TEST_TMPDIR/root/.openclaw-main/MIGRATED-8.2" ]
}
