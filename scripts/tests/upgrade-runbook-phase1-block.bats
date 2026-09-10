#!/usr/bin/env bats
# Executes the REAL pasted Phase 1 block of docs/runbooks/UPGRADE-2026.8.1.md
# (QA finding, PR #899: `gh workflow view | head -3` SIGPIPE'd under pipefail and
# aborted the block after disabling the deploy workflow but before stopping the
# refresher/gateways or archiving). The block text is extracted at test time;
# only paths are substituted and the side-effecting commands are stubbed. The
# stubs record argv so the ORDER of the window's first steps can be asserted.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
RUNBOOK="$HYDRA_REPO/docs/runbooks/UPGRADE-2026.8.1.md"

extract_phase1_block() {
  awk '/^## Phase 1/{p=1} /^## Phase 2/{p=0} p' "$RUNBOOK" \
    | awk '/^bash -euo pipefail <<.RUNBOOK_BLOCK.$/{p=1} p{print} /^RUNBOOK_BLOCK$/{if(p){exit}}'
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/root" "$TEST_TMPDIR/opt/scripts"
  CALLS="$TEST_TMPDIR/calls"; export CALLS
  rec() { printf '#!/bin/bash\necho "$(basename "$0") $*" >> "$CALLS"\n' > "$1"; chmod +x "$1"; }
  rec "$TEST_TMPDIR/opt/scripts/hydra-maintenance.sh"
  # systemctl: record; is-active reports inactive (units stopped), disable/stop succeed
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
[ "$1" = "is-active" ] && { echo inactive; exit 3; }
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
  # gh: record; `workflow list --json` reports the state the test wants
  cat > "$TEST_TMPDIR/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$CALLS"
case " $* " in
  *" workflow list "*) printf '%s\n' "${FAKE_WF_STATE:-disabled_manually}";;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/pgrep"; chmod +x "$TEST_TMPDIR/bin/pgrep"   # no gateway process
  # df/du: deterministic disk figures for the gate (live=2G -> need 13G); FAKE_AVAIL_GB sets free space
  printf '#!/bin/bash\necho "Avail"; echo "${FAKE_AVAIL_GB:-500}G"\n' > "$TEST_TMPDIR/bin/df"; chmod +x "$TEST_TMPDIR/bin/df"
  printf '#!/bin/bash\nfor a in "$@"; do case "$a" in -*) ;; *) echo "1G\t$a";; esac; done\n' > "$TEST_TMPDIR/bin/du"; chmod +x "$TEST_TMPDIR/bin/du"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  # two small "prod" state dirs to archive
  for d in .openclaw-main .openclaw-edge; do mkdir -p "$TEST_TMPDIR/root/$d/agents" "$TEST_TMPDIR/root/$d/locks/oauth-refresh"; echo '{}' > "$TEST_TMPDIR/root/$d/openclaw.json"; done
}
teardown() { rm -rf "$TEST_TMPDIR"; }

render_block() {
  # substitute only paths; the disk gate's `df / ` stays real (GNU df on the CI runner)
  extract_phase1_block \
    | sed -e "s|/root/|$TEST_TMPDIR/root/|g" \
          -e "s|/opt/hydra/scripts/|$TEST_TMPDIR/opt/scripts/|g" \
          -e "s|tar -C /root |tar -C $TEST_TMPDIR/root |"
}

@test "the runbook still contains a pasteable Phase 1 block, with no truncating pipe in it" {
  [ "$(extract_phase1_block | wc -l)" -gt 20 ]
  ! extract_phase1_block | grep -qE '\|[[:space:]]*head\b'
}

@test "the pasted Phase 1 block executes end-to-end: workflow disabled + asserted, refresher off, gateways stopped, archive + sha256 written" {
  render_block > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 0 ]
  grep -q '^gh workflow disable Deploy HYDRA' "$CALLS"
  grep -q '^gh workflow list --all' "$CALLS"
  [[ "$output" == *"Deploy HYDRA workflow: disabled_manually"* ]]
  grep -q '^systemctl disable --now codex-token-refresh.timer' "$CALLS"
  grep -q '^systemctl stop openclaw-gateway-main openclaw-gateway-edge' "$CALLS"
  ls "$TEST_TMPDIR"/root/openclaw-state-pre81-*.tar.gz >/dev/null
  ls "$TEST_TMPDIR"/root/openclaw-state-pre81-*.tar.gz.sha256 >/dev/null
  # order: disable workflow < refresher off < gateways stopped
  a=$(grep -n '^gh workflow disable' "$CALLS" | head -1 | cut -d: -f1); b=$(grep -n '^systemctl disable --now codex-token-refresh.timer' "$CALLS" | head -1 | cut -d: -f1); c=$(grep -n '^systemctl stop openclaw-gateway-main' "$CALLS" | head -1 | cut -d: -f1)
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
}

@test "a workflow that did NOT end up disabled refuses BEFORE the refresher or gateways are touched" {
  export FAKE_WF_STATE="active"
  render_block > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected disabled_manually"* ]]
  if grep -q '^systemctl' "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl' '$CALLS'" >&2; false; fi
  [ -z "$(ls "$TEST_TMPDIR"/root/openclaw-state-pre81-* 2>/dev/null)" ]
}

@test "a live oauth-refresh lock refuses before the gateways are stopped or anything is archived" {
  touch "$TEST_TMPDIR/root/.openclaw-main/locks/oauth-refresh/in-flight"
  render_block > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"live oauth-refresh lock"* ]]
  if grep -q '^systemctl stop openclaw-gateway' "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl stop openclaw-gateway' '$CALLS'" >&2; false; fi
  [ -z "$(ls "$TEST_TMPDIR"/root/openclaw-state-pre81-* 2>/dev/null)" ]
}

@test "LOW DISK refuses FIRST: nothing disabled, nothing stopped, no maintenance flag, no archive" {
  export FAKE_AVAIL_GB=5
  render_block > "$TEST_TMPDIR/block.sh"
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: 5G free"* ]]
  if grep -qE '^(gh|systemctl|hydra-maintenance.sh) ' "$CALLS" 2>/dev/null; then echo "mutation before the disk gate" >&2; false; fi
  [ -z "$(ls "$TEST_TMPDIR"/root/openclaw-state-pre81-* 2>/dev/null)" ]
}
