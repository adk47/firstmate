#!/usr/bin/env bats
# Step 0 / Step 4b delta transfer (MUS-5069): deploy applies the git delta since
# .deployed-sha and never --deletes server-only files.
#
# Library cases drive scripts/lib/delta-sync.sh against a scratch git repo (the
# "source") and a scratch dir (the "server"); the --report-only cases EXECUTE
# deploy.sh itself (hostname stub => HYDRA_LOCAL=true) so Step 0 runs for real.

LIB="${BATS_TEST_DIRNAME}/../lib/delta-sync.sh"
DEPLOY="${BATS_TEST_DIRNAME}/../deploy.sh"
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
  WORK="$(mktemp -d)"
  SRC="$WORK/src"; SERVER="$WORK/server"; mkdir -p "$SRC" "$SERVER" "$WORK/tmp" "$WORK/bin"
  export TMPDIR="$WORK/tmp"
  git -C "$SRC" init -q
  git -C "$SRC" config gc.auto 0; git -C "$SRC" config maintenance.auto false
  git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
  mkdir -p "$SRC/scripts" "$SRC/skills-all/risky" "$SRC/workspaces/ops"
  # deploy.sh runs from the scratch repo, so it needs this checkout's tracked files
  (cd "$REPO_ROOT" && git ls-files -z | rsync -a --from0 --files-from=- ./ "$SRC/")
  echo base > "$SRC/scripts/a.sh"
  echo base > "$SRC/skills-all/risky/SKILL.md"
  echo base > "$SRC/workspaces/ops/SOUL.md"
  echo base > "$SRC/workspaces/ops/TOOLS.md"
  echo keep > "$SRC/scripts/unchanged.sh"
  git -C "$SRC" add -A; git -C "$SRC" commit -qm base
  BASE=$(git -C "$SRC" rev-parse HEAD)
  git -C "$SRC" archive HEAD | tar -x -C "$SERVER"
  # What the real RSYNC_EXCLUDES contains for these two, as in deploy.sh.
  RSYNC_EXCLUDES=(--exclude='workspaces/*/TOOLS.md' --exclude='audit/')
}

teardown() { rm -rf "$WORK"; }

commit_src() { git -C "$SRC" add -A; git -C "$SRC" commit -qm "$1"; }

# Run a snippet with the lib sourced and the harness env deploy.sh provides.
lib() {
  run bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=true; SCRIPT_DIR="$4"
    RSYNC_EXCLUDES=(--exclude="workspaces/*/TOOLS.md" --exclude="audit/")
    log() { echo "[t] $*"; }
    source "$3"
    BASE=$5
    eval "$6"
  ' _ "$SRC" "$SERVER" "$LIB" "${BATS_TEST_DIRNAME}/.." "$BASE" "$1"
}

@test "equal server, changed repo: the file is transferred, an untouched server-only file survives" {
  echo new > "$SRC/scripts/a.sh"; commit_src change
  echo "agent note" > "$SERVER/workspaces/ops/agent-note.md"
  echo "agent tool" > "$SERVER/scripts/agent-tool.sh"
  echo "server edit to a path outside the delta" > "$SERVER/scripts/unchanged.sh"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$SERVER/scripts/a.sh")" = new ]
  [ -f "$SERVER/workspaces/ops/agent-note.md" ]
  [ "$(cat "$SERVER/scripts/agent-tool.sh")" = "agent tool" ]   # same directory as the transferred file
  [ "$(cat "$SERVER/scripts/unchanged.sh")" = "server edit to a path outside the delta" ]
}

@test "both sides changed: hard stop names the path and carries a diffstat, nothing transferred" {
  echo repo > "$SRC/scripts/a.sh"; commit_src change
  echo server > "$SERVER/scripts/a.sh"
  lib 'delta_compute $BASE; delta_gate $BASE'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/a.sh"*"+1/-1"* ]]
  [ "$(cat "$SERVER/scripts/a.sh")" = server ]
}

@test "both sides changed + git-wins marker in the HEAD blob: logged overwrite, still in the transfer set" {
  printf 'x\n<!-- Reviewed baseline: deploy overwrites node-8 autonomous rewrites of this file (MUS-3099). -->\n' > "$SRC/skills-all/risky/SKILL.md"
  commit_src marker
  echo "autonomous rewrite" > "$SERVER/skills-all/risky/SKILL.md"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"git-wins: skills-all/risky/SKILL.md"*"Reviewed baseline: deploy overwrites"* ]]
  grep -q "^x$" "$SERVER/skills-all/risky/SKILL.md"
}

@test "the marker is read from the HEAD blob, never from the server's bytes" {
  echo repo > "$SRC/scripts/a.sh"; commit_src change
  printf 'agent wrote this\n<!-- Reviewed baseline: deploy overwrites -->\n' > "$SERVER/scripts/a.sh"
  lib 'delta_compute $BASE; delta_gate $BASE'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEPLOY BLOCKED"* ]]
  [[ "$output" != *"git-wins"* ]]
}

@test "server absent, repo changed: the file is written and logged" {
  echo new > "$SRC/scripts/b.sh"; commit_src add
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ]
  [[ "$output" == *"create: scripts/b.sh"* ]]
  [ "$(cat "$SERVER/scripts/b.sh")" = new ]
}

@test "server already equals the repo: no-op, logged" {
  echo new > "$SRC/scripts/a.sh"; commit_src change
  echo new > "$SERVER/scripts/a.sh"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op: scripts/a.sh"* ]]
}

@test "renames are D + A, never R" {
  git -C "$SRC" mv scripts/a.sh scripts/renamed.sh; commit_src rename
  lib 'delta_compute $BASE; echo "UP=$DELTA_UPSERT"; echo "DEL=$DELTA_DELETE"'
  [[ "$output" == *"UP=scripts/renamed.sh"* ]]
  [[ "$output" == *"DEL=scripts/a.sh"* ]]
}

@test "uncommitted work is not in the delta" {
  echo wip > "$SRC/scripts/a.sh"; echo wip > "$SRC/scripts/untracked.sh"
  lib 'delta_compute $BASE; echo "UP=[$DELTA_UPSERT] DEL=[$DELTA_DELETE]"'
  [[ "$output" == *"UP=[] DEL=[]"* ]]
}

@test "explicit deletion removes a tracked file and its emptied directory, via the three-way check" {
  git -C "$SRC" rm -rq skills-all/risky; commit_src remove
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ]
  [ ! -e "$SERVER/skills-all/risky" ]
}

@test "deleting a path the server modified is a hard stop, the file stays" {
  git -C "$SRC" rm -rq skills-all/risky; commit_src remove
  echo "agent improved it" > "$SERVER/skills-all/risky/SKILL.md"
  lib 'delta_compute $BASE; delta_gate $BASE'
  [ "$status" -eq 1 ]
  [ "$(cat "$SERVER/skills-all/risky/SKILL.md")" = "agent improved it" ]
}

@test "Step 4c chain: a removed skills-all skill leaves /opt/hydra, so 4c's own --delete clears every profile dir" {
  mkdir -p "$SRC/skills-all/other" "$SERVER/skills-all/other" "$WORK/profile-skills"
  echo o > "$SRC/skills-all/other/SKILL.md"; cp "$SRC/skills-all/other/SKILL.md" "$SERVER/skills-all/other/"
  commit_src other; BASE=$(git -C "$SRC" rev-parse HEAD)
  rsync -a "$SERVER/skills-all/" "$WORK/profile-skills/"
  [ -f "$WORK/profile-skills/risky/SKILL.md" ]
  git -C "$SRC" rm -rq skills-all/risky; commit_src remove
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ]
  # the 4c mirror, unchanged: rsync --delete from the server's skills-all into the profile dir
  rsync -a --delete "$SERVER/skills-all/" "$WORK/profile-skills/"
  [ ! -e "$WORK/profile-skills/risky" ]
}

@test "a delta path matching an exclude is neither transferred nor silent" {
  echo new > "$SRC/workspaces/ops/TOOLS.md"; commit_src tools
  echo "server-owned tools" > "$SERVER/workspaces/ops/TOOLS.md"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspaces/ops/TOOLS.md — skipped, matches exclude workspaces/*/TOOLS.md"* ]]
  [ "$(cat "$SERVER/workspaces/ops/TOOLS.md")" = "server-owned tools" ]
}

@test "baseline guard: a SHA that is not an ancestor of HEAD fails closed" {
  git -C "$SRC" checkout -q -b other; echo o > "$SRC/o"; commit_src other
  other=$(git -C "$SRC" rev-parse HEAD)
  git -C "$SRC" checkout -q -; echo m > "$SRC/m"; commit_src main2
  run bash -c 'HYDRA_ROOT="$1"; source "$2"; delta_check_baseline "$3"' _ "$SRC" "$LIB" "$other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an ancestor"* ]]
}

# --- deploy.sh itself ---------------------------------------------------------

run_deploy_report() {
  printf '#!/bin/sh\necho node-8\n' > "$WORK/bin/hostname"; chmod +x "$WORK/bin/hostname"
  run env PATH="$WORK/bin:$PATH" DEPLOY_PATH="$SERVER" "$@" bash "$SRC/scripts/deploy.sh" --report-only
}

@test "deploy.sh --report-only: server-only files are no longer a halt; the per-file check runs; exit 0 before any transfer" {
  echo "agent scratch" > "$SERVER/workspaces/ops/cc-plan.md"
  echo "server-only skill" > "$SERVER/skills-all/risky/extra.md"
  echo "$BASE" > "$SERVER/.deployed-sha"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  run_deploy_report
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Delta: 1 changed, 0 removed"* ]]
  [[ "$output" == *"Skipped — the delta transfer never deletes server-only files"* ]]
  [[ "$output" != *"Step 4b"* ]]
  [ -f "$SERVER/workspaces/ops/cc-plan.md" ]
  [ "$(cat "$SERVER/scripts/a.sh")" = base ]
}

@test "deploy.sh --report-only: a both-sides-changed path stops the run, named" {
  echo "$BASE" > "$SERVER/.deployed-sha"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  echo "server edit" > "$SERVER/scripts/a.sh"
  run_deploy_report
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEPLOY BLOCKED"*"scripts/a.sh"* ]]
}

# Bot round on PR #1123 (b9ede90f): the dirty-worktree guard used a git option that
# does not exist (exit 129), and `|| true` turned that into "nothing is dirty".
@test "deploy.sh: an uncommitted edit to a path in the delta stops Step 0, named (bytes not in HEAD never ship)" {
  echo "$BASE" > "$SERVER/.deployed-sha"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  echo "uncommitted local edit" > "$SRC/scripts/a.sh"
  run_deploy_report
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes in paths this deploy ships"*"scripts/a.sh"* ]]
}

@test "deploy.sh: no .deployed-sha needs an explicit HYDRA_FULL_SYNC=1" {
  run_deploy_report
  [ "$status" -ne 0 ]
  [[ "$output" == *"HYDRA_FULL_SYNC=1"* ]]
}

@test "the delta transfer path carries no --delete (rsync ignores it under --files-from, so a mutation test cannot pin it)" {
  body=$(awk '/^delta_apply\(\) \{/,/^}/' "$LIB")
  [ -n "$body" ]
  [[ "$body" != *"--delete"* ]]
}

# QA round 1 (MUS-6189): a failed server-hash call on the upsert pass was masked
# by the delete pass returning 0 on empty input, so the gate passed with nothing
# to transfer and .deployed-sha advanced over changes that never shipped.
@test "remote hash call fails (ssh down), one upsert, zero deletes: the gate fails closed" {
  printf '#!/bin/sh\necho "ssh: connect refused" >&2\nexit 255\n' > "$WORK/bin/ssh"; chmod +x "$WORK/bin/ssh"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=false; SCRIPT_DIR="$4"
    SSH_KEY=k; SSH_OPTS=(); NODE8_USER=u; NODE8_IP=127.0.0.1
    RSYNC_EXCLUDES=()
    log() { echo "[t] $*"; }
    source "$3"
    delta_compute "$5"; delta_gate "$5"; rc=$?
    echo "gate rc=$rc transfer=[$DELTA_TRANSFER]"; exit "$rc"
  ' _ "$SRC" "$SERVER" "$LIB" "${BATS_TEST_DIRNAME}/.." "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" != *"gate rc=0"* ]]
}

# Bot round 1 on PR #1123 (c8cfd89c).
@test "rsync missing/failing inside the exclude filter: the gate fails closed, not 'everything excluded'" {
  printf '#!/bin/sh\necho "rsync: boom" >&2\nexit 23\n' > "$WORK/bin/rsync"; chmod +x "$WORK/bin/rsync"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=true; SCRIPT_DIR="$4"
    RSYNC_EXCLUDES=(--exclude="audit/")
    log() { echo "[t] $*"; }
    source "$3"
    delta_compute "$5"; delta_gate "$5" || rc=$?; echo "gate rc=${rc:-0}"; exit "${rc:-0}"
  ' _ "$SRC" "$SERVER" "$LIB" "${BATS_TEST_DIRNAME}/.." "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" != *"gate rc=0"* ]]
}

@test "a server-side rm that fails makes the delete helper fail (file stays, so the deploy must not advance)" {
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/rm"; chmod +x "$WORK/bin/rm"
  git -C "$SRC" rm -q scripts/a.sh; commit_src drop
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=true; SCRIPT_DIR="$4"
    RSYNC_EXCLUDES=()
    log() { echo "[t] $*"; }
    source "$3"
    DELTA_TRANSFER=""; DELTA_REMOVE="scripts/a.sh"
    delta_apply; echo "apply rc=$?"
  ' _ "$SRC" "$SERVER" "$LIB" "${BATS_TEST_DIRNAME}/.." "$BASE"
  [[ "$output" != *"apply rc=0"* ]]
  [ -f "$SERVER/scripts/a.sh" ]
}

@test "mode-only change (0644 -> 0755), server bytes already equal: the file is transferred, not NOOP" {
  chmod +x "$SRC/scripts/a.sh"; commit_src chmod
  chmod 644 "$SERVER/scripts/a.sh"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"no-op: scripts/a.sh"* ]]
  [ -x "$SERVER/scripts/a.sh" ]
}

@test "placeholder creation fails inside the exclude filter: the gate fails closed, not 'path excluded'" {
  printf '#!/bin/sh\ncase "$*" in *"/src/scripts"*) exit 1;; esac\nexec /bin/mkdir "$@"\n' > "$WORK/bin/mkdir"; chmod +x "$WORK/bin/mkdir"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=true; SCRIPT_DIR="$4"
    RSYNC_EXCLUDES=(--exclude="audit/")
    log() { echo "[t] $*"; }
    source "$3"
    delta_compute "$5"; delta_gate "$5" || rc=$?; echo "gate rc=${rc:-0}"; exit "${rc:-0}"
  ' _ "$SRC" "$SERVER" "$LIB" "${BATS_TEST_DIRNAME}/.." "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" != *"gate rc=0"* ]]
}

@test "placeholder creation fails on a NON-last delta path: the loop guard still fails the gate closed" {
  printf '#!/bin/sh\ncase "$*" in *"/src/scripts"*) exit 1;; esac\nexec /bin/mkdir "$@"\n' > "$WORK/bin/mkdir"; chmod +x "$WORK/bin/mkdir"
  mkdir -p "$SRC/zzz"; echo new > "$SRC/zzz/b.sh"
  echo changed > "$SRC/scripts/a.sh"; commit_src change
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=true; SCRIPT_DIR="$4"
    RSYNC_EXCLUDES=(--exclude="audit/")
    log() { echo "[t] $*"; }
    source "$3"
    delta_compute "$5"; delta_gate "$5" || rc=$?; echo "gate rc=${rc:-0}"; exit "${rc:-0}"
  ' _ "$SRC" "$SERVER" "$LIB" "${BATS_TEST_DIRNAME}/.." "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" != *"gate rc=0"* ]]
}

@test "server path is a symlink whose target holds the HEAD bytes: the gate stops, it is not a NOOP" {
  echo new > "$SRC/scripts/a.sh"; commit_src change
  echo new > "$WORK/outside.txt"
  rm "$SERVER/scripts/a.sh"; ln -s "$WORK/outside.txt" "$SERVER/scripts/a.sh"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply; echo "gate rc=$?"'
  [[ "$output" == *"gate rc=1"* ]]
  [[ "$output" == *"DEPLOY BLOCKED"* ]]
  [[ "$output" != *"no-op: scripts/a.sh"* ]]
  [ -L "$SERVER/scripts/a.sh" ]
}

@test "git mode unchanged (0755), server holds the HEAD bytes at 0644: the file is transferred, not NOOP" {
  chmod +x "$SRC/scripts/a.sh"; commit_src base-exec
  B2=$(git -C "$SRC" rev-parse HEAD)
  echo new > "$SRC/scripts/a.sh"; commit_src change
  cp "$SRC/scripts/a.sh" "$SERVER/scripts/a.sh"; chmod 644 "$SERVER/scripts/a.sh"
  lib 'delta_compute '"$B2"'; delta_gate '"$B2"' && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"no-op: scripts/a.sh"* ]]
  [ -x "$SERVER/scripts/a.sh" ]
}

@test "a deleted tracked file whose name holds a newline: delta_compute refuses, it is not a NOOP delete" {
  nl=$'scripts/we\nird.sh'
  echo x > "$SRC/$nl"; commit_src add-weird
  BASE=$(git -C "$SRC" rev-parse HEAD)
  cp "$SRC/$nl" "$SERVER/scripts/" 2>/dev/null || true
  git -C "$SRC" rm -q -- "$nl"; commit_src rm-weird
  lib 'delta_compute $BASE; echo "compute rc=$?"'
  [[ "$output" == *"compute rc=1"* ]]
  [[ "$output" == *"scripts/we"* ]]
}

@test "git diff fails inside delta_compute called as the left side of ||: it returns non-zero, not an empty delta" {
  echo new > "$SRC/scripts/a.sh"; commit_src change
  REAL_GIT=$(command -v git)
  printf '#!/bin/sh\ncase "$*" in *" diff "*) echo "fatal: simulated git failure" >&2; exit 128;; esac\nexec %s "$@"\n' "$REAL_GIT" > "$WORK/bin/git"; chmod +x "$WORK/bin/git"
  # errexit is ignored inside a function whose call is on the left of ||, as in deploy.sh
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -euo pipefail
    HYDRA_ROOT="$1"; log() { echo "[t] $*"; }
    source "$2"
    delta_compute "$3" || { echo "compute rc=$?"; exit 0; }
    echo "REACHED-AFTER-COMPUTE UP=[$DELTA_UPSERT] DEL=[$DELTA_DELETE]"
  ' _ "$SRC" "$LIB" "$BASE"
  [[ "$output" == *"compute rc=1"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"REACHED-AFTER-COMPUTE"* ]]
}

# Each git diff in delta_compute needs its own guard: failing BOTH diffs (test above) is
# satisfied by either guard alone, so these fail exactly one pass.
delta_compute_with_failing_diff() {  # <diff-filter value to fail: D (delete pass) | d (upsert pass)>
  echo new > "$SRC/scripts/a.sh"; git -C "$SRC" rm -q scripts/unchanged.sh; commit_src change
  REAL_GIT=$(command -v git)
  printf '#!/bin/sh\ncase "$*" in *"diff-filter=%s"*) echo "fatal: simulated git failure" >&2; exit 128;; esac\nexec %s "$@"\n' "$1" "$REAL_GIT" > "$WORK/bin/git"; chmod +x "$WORK/bin/git"
  run env PATH="$WORK/bin:$PATH" bash -c '
    set -euo pipefail
    HYDRA_ROOT="$1"; log() { echo "[t] $*"; }
    source "$2"
    delta_compute "$3" || { echo "compute rc=$?"; exit 0; }
    echo "REACHED-AFTER-COMPUTE UP=[$DELTA_UPSERT] DEL=[$DELTA_DELETE]"
  ' _ "$SRC" "$LIB" "$BASE"
}

@test "only the delete-pass git diff fails: delta_compute returns non-zero, a deletion is not dropped" {
  delta_compute_with_failing_diff D
  [[ "$output" == *"compute rc=1"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"REACHED-AFTER-COMPUTE"* ]]
}

@test "only the upsert-pass git diff fails: delta_compute returns non-zero, a change is not dropped" {
  delta_compute_with_failing_diff d
  [[ "$output" == *"compute rc=1"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"REACHED-AFTER-COMPUTE"* ]]
}

@test "deleting a path the server modified, halt suppressed (HYDRA_FORCE): the server copy is REMOVED, not sent to rsync" {
  git -C "$SRC" rm -rq skills-all/risky; commit_src remove
  echo "agent improved it" > "$SERVER/skills-all/risky/SKILL.md"
  lib 'DELTA_HALT_SUPPRESSED=1; delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$SERVER/skills-all/risky/SKILL.md" ]
  [[ "$output" != *"rsync error"* ]]
}

@test "deleting a path the server modified, edit announced as a hot-patch: the server copy is REMOVED (ack branch)" {
  git -C "$SRC" rm -rq skills-all/risky; commit_src remove
  echo "agent improved it" > "$SERVER/skills-all/risky/SKILL.md"
  export HYDRA_HOTPATCH_LOG="$WORK/hot-patches.log"
  abs=$(realpath "$SERVER/skills-all/risky/SKILL.md")
  sha=$(sha256sum "$abs" | awk '{print $1}')
  printf '%s 2026-01-01T00:00:00Z agent pid=1 ppid=1 sha256=%s %s\n' "$(date -u +%s)" "$sha" "$abs" > "$HYDRA_HOTPATCH_LOG"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$SERVER/skills-all/risky/SKILL.md" ]
  [[ "$output" == *"hot-patch acknowledged: skills-all/risky/SKILL.md — removing"* ]]
}

@test "deleting a tracked file whose server path is now a non-empty directory: the gate stops, it is not a NOOP" {
  git -C "$SRC" rm -q scripts/a.sh; commit_src remove
  rm -f "$SERVER/scripts/a.sh"; mkdir -p "$SERVER/scripts/a.sh"; echo x > "$SERVER/scripts/a.sh/keep"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply; echo "gate rc=$?"'
  [[ "$output" == *"gate rc=1"* ]]
  [[ "$output" != *"no-op: scripts/a.sh"* ]]
  [ -d "$SERVER/scripts/a.sh" ]
}

@test "deleting a tracked file the server only chmod-ed (same bytes, exec bit differs from baseline): the gate stops, it is not DELETE" {
  git -C "$SRC" rm -q scripts/a.sh; commit_src remove
  chmod +x "$SERVER/scripts/a.sh"
  lib 'delta_compute $BASE; delta_gate $BASE && delta_apply; echo "gate rc=$?"'
  [[ "$output" == *"gate rc=1"* ]]
  [ -e "$SERVER/scripts/a.sh" ]
}
