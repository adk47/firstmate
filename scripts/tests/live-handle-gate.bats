#!/usr/bin/env bats
# MUS-10455: the clone sweep's live-handle gate (has_live_handles) must judge
# its /proc enumeration by RESULT, not by exit code. On node-8 GNU find exits 1
# on every walk (a pid vanishing, plus `/proc/<pid>/net: Invalid argument`), so
# the old rc test held every candidate forever (12 Oct: swept=0 against 138 GB).
#
# Hermetic: SWEEP_PROC_DIR is a fixture, never the real /proc, and `find` is
# PATH-shadowed ONLY for the proc scan (and the GNU capability probe) so the
# production GNU branch runs on any host. Every root is a mktemp sandbox.
# Assertions are on the DECISION (clone deleted vs. still present), not on a
# log line, so a presence check cannot pass vacuously.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SWEEP="$HYDRA_REPO/scripts/sweep-workspace-clones.sh"

setup() {
  TEST_TMPDIR="$(cd "$(mktemp -d)" && pwd -P)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/repos" "$TEST_TMPDIR/ws/cto/tmp" \
    "$TEST_TMPDIR/origins" "$TEST_TMPDIR/proc/1"
  ln -s / "$TEST_TMPDIR/proc/1/cwd"
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"; : > "$STUB_CALLS"
  printf '#!/bin/bash\necho "test stub: ssh refused" >&2; exit 99\n' > "$TEST_TMPDIR/bin/ssh"
  printf '#!/usr/bin/env bash\necho "{\\"channel\\":\\"C0TEST\\",\\"ts\\":\\"1.1\\"}"\n' > "$TEST_TMPDIR/bin/muso"
  printf '#!/bin/bash\n[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"\nexit 0\n' > "$TEST_TMPDIR/bin/flock"

  export REAL_FIND; REAL_FIND="$(command -v find)"
  export FIND_COUNT="$TEST_TMPDIR/find-proc-count"; : > "$FIND_COUNT"
  cat > "$TEST_TMPDIR/bin/find" <<'STUB'
#!/usr/bin/env bash
# The GNU capability probe: pretend GNU so the production branch is exercised.
if [[ "$*" == *"-maxdepth 0 -ignore_readdir_race"* ]]; then exit 0; fi
if [[ "$*" == *"$SWEEP_PROC_DIR"* ]]; then
  echo x >> "$FIND_COUNT"
  case "$PROC_MODE" in
    gone)  echo /elsewhere/a; echo "find: '$SWEEP_PROC_DIR/999': No such file or directory" >&2; exit 1 ;;
    net)   echo /elsewhere/a; echo "find: '$SWEEP_PROC_DIR/999/net': Invalid argument" >&2; exit 1 ;;
    perm)  echo /elsewhere/a; echo "find: '$SWEEP_PROC_DIR/999/fd': Permission denied" >&2; exit 1 ;;
    wrongpath) echo /elsewhere/a; echo "find: '/etc/999': No such file or directory" >&2; exit 1 ;;
    empty) exit 0 ;;
    emptygone) echo "find: '$SWEEP_PROC_DIR/999': No such file or directory" >&2; exit 1 ;;
    holds) "$REAL_FIND" "$TEST_TMPDIR/repos" -maxdepth 3 -name f.txt -path '*/.sweep-quarantine.*' -print
           echo "find: '$SWEEP_PROC_DIR/999': No such file or directory" >&2; exit 1 ;;
  esac
fi
exec "$REAL_FIND" "$@"
STUB
  chmod +x "$TEST_TMPDIR"/bin/*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  export SWEEP_REPOS_ROOT="$TEST_TMPDIR/repos" SWEEP_WS_ROOT="$TEST_TMPDIR/ws"
  export SWEEP_REPOS_TTL_DAYS=14 SWEEP_TMP_TTL_DAYS=7 SWEEP_KEEP_LIST="core-backend"
  export SWEEP_LOCKFILE="$TEST_TMPDIR/sweep.lock" SWEEP_SKIP_HOST_GUARD=1
  : > "$TEST_TMPDIR/mounts-empty"
  export SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts-empty"
  export SWEEP_PROC_DIR="$TEST_TMPDIR/proc"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

teardown() { /bin/rm -rf "$TEST_TMPDIR"; hash -r; }

# mkold <name> : clean, fully-pushed clone aged 20 days under repos/.
mkold() {
  local d="$TEST_TMPDIR/repos/$1" origin="$TEST_TMPDIR/origins/$1.git" stamp
  git init -q --bare "$origin"; git -C "$origin" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$d"
  ( cd "$d" && echo hello > f.txt && git add f.txt && git commit -qm init \
      && git remote add origin "$origin" && git push -q -u origin main )
  stamp="$(date -d '20 days ago' +%Y%m%d%H%M 2>/dev/null || date -v -20d +%Y%m%d%H%M)"
  "$REAL_FIND" "$d" -path "$d/.git" -prune -o -print0 | xargs -0 touch -h -t "$stamp" --
  touch -h -t "$stamp" -- "$d"
}

@test "1: a vanished pid (find rc=1, 'No such file or directory') does not hold the clone" {
  mkold c1; PROC_MODE=gone run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/c1" ]
}

@test "2: '/proc/<pid>/net: Invalid argument' (find rc=1) does not hold the clone" {
  mkold c2; PROC_MODE=net run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/c2" ]
}

@test "3: a Permission denied on the enumeration still holds (fail closed)" {
  mkold c3; PROC_MODE=perm run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/c3/.git" ]
}

@test "3b: a benign-looking message about a path OUTSIDE the proc tree still holds" {
  mkold c3b; PROC_MODE=wrongpath run "$SWEEP" --apply
  [ -d "$TEST_TMPDIR/repos/c3b/.git" ]
}

@test "4: an enumeration returning ZERO lines holds, with or without stderr noise" {
  mkold c4a; mkold c4b
  PROC_MODE=empty run "$SWEEP" --apply
  [ -d "$TEST_TMPDIR/repos/c4a/.git" ]
  PROC_MODE=emptygone run "$SWEEP" --apply
  [ -d "$TEST_TMPDIR/repos/c4b/.git" ]
}

@test "5: a missing PROC_DIR holds" {
  mkold c5; PROC_MODE=gone SWEEP_PROC_DIR="$TEST_TMPDIR/no-such-proc" run "$SWEEP" --apply
  [ -d "$TEST_TMPDIR/repos/c5/.git" ]
}

@test "6: a candidate named in the enumeration output is held (the predicate under test)" {
  mkold c6; PROC_MODE=holds run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/repos/c6/f.txt" ]
  [[ "$output" == *"live process holds the tree open"* ]]
}

@test "7: the enumeration runs once per sweep, not once per candidate" {
  mkold c7a; mkold c7b; mkold c7c
  PROC_MODE=gone run "$SWEEP" --apply
  [ ! -d "$TEST_TMPDIR/repos/c7a" ]
  [ ! -d "$TEST_TMPDIR/repos/c7b" ]
  [ ! -d "$TEST_TMPDIR/repos/c7c" ]
  [ "$(wc -l < "$FIND_COUNT" | tr -d ' ')" -eq 1 ]
}

@test "8: held summary reports bytes per class, and '?' when sizing fails" {
  mkold c8; echo dirty > "$TEST_TMPDIR/repos/c8/dirty.txt"
  touch -h -t "$(date -d "20 days ago" +%Y%m%d%H%M 2>/dev/null || date -v -20d +%Y%m%d%H%M)" "$TEST_TMPDIR/repos/c8/dirty.txt" "$TEST_TMPDIR/repos/c8"
  PROC_MODE=gone run "$SWEEP" --apply
  [[ "$output" =~ held:\ dirty/unpushed/stash=1\ \([0-9.]+\ (KB|MB|GB)\) ]]
  printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/bin/du"; chmod +x "$TEST_TMPDIR/bin/du"
  PROC_MODE=gone run "$SWEEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dirty/unpushed/stash=1 (?)"* ]]
}
