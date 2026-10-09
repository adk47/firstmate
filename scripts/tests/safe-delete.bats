#!/usr/bin/env bats
# Tests for scripts/lib/safe-delete.sh — the guarded-removal primitives shared
# by every deleter on node-8. Hermetic: every path is under a mktemp sandbox,
# the mount table is a fixture file, and a guard in setup() refuses to run the
# suite if the sandbox is not where we think it is — hydra's bats runner IS
# node-8, so an escaped path would delete production.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/safe-delete.sh"

setup() {
  # pwd -P: lsof prints physical paths; mktemp lives under a /var symlink on macOS.
  SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
  export SANDBOX
  case "$SANDBOX" in /|""|/opt*|/root*|/home*|/var/lib*) echo "unsafe sandbox: $SANDBOX" >&2; exit 99 ;; esac
  mkdir -p "$SANDBOX/bin" "$SANDBOX/root"
  : > "$SANDBOX/mounts"
  export SAFE_DELETE_MOUNTS_FILE="$SANDBOX/mounts"
  export PATH="$SANDBOX/bin:$PATH"
  # shellcheck source=../lib/safe-delete.sh
  source "$LIB"
}

teardown() {
  exec 7>&- 2>/dev/null || true
  [ -n "${SANDBOX:-}" ] && case "$SANDBOX" in */tmp.*|/var/folders/*|/tmp/*) chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX" ;; esac
}

mkdir_with_data() {  # <dir>: a directory holding ~64 KB
  mkdir -p "$1/sub"
  head -c 65536 /dev/zero > "$1/sub/blob"
}

leftovers() {  # quarantine siblings under the sandbox root
  find "$SANDBOX/root" -name '.safe-delete-quarantine.*' | wc -l | tr -d ' '
}

@test "happy path: directory removed, freed KB > 0, quarantine sibling gone" {
  mkdir_with_data "$SANDBOX/root/victim"
  run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
  [ ! -e "$SANDBOX/root/victim" ]
  [ "$(leftovers)" -eq 0 ]
}

@test "open handle survives: a held fd makes safe_delete_path refuse" {
  f="$SANDBOX/root/held.log"
  exec 7>"$f"
  echo live >&7
  run safe_delete_path "$f"
  [ "$status" -ne 0 ]
  [ -f "$f" ]
  [ "$(leftovers)" -eq 0 ]
}

@test "open handle on a file INSIDE a directory protects the directory" {
  mkdir -p "$SANDBOX/root/d"
  exec 7>"$SANDBOX/root/d/inner.log"
  run safe_delete_path "$SANDBOX/root/d"
  [ "$status" -ne 0 ]
  [ -f "$SANDBOX/root/d/inner.log" ]
}

@test "cwd inside the path protects it" {
  mkdir -p "$SANDBOX/root/cwddir"
  (cd "$SANDBOX/root/cwddir" && exec sleep 30) &
  holder=$!
  sleep 0.3
  run safe_delete_path "$SANDBOX/root/cwddir"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [ -d "$SANDBOX/root/cwddir" ]
}

@test "lsof unavailable (exits 1) => refuse: probe failure is never 'free'" {
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/lsof"; chmod +x "$SANDBOX/bin/lsof"
  mkdir_with_data "$SANDBOX/root/victim"
  run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [ -d "$SANDBOX/root/victim" ]
  run safe_delete_has_open_handle "$SANDBOX/root/victim"
  [ "$status" -eq 0 ]
}

@test "lsof missing from PATH => refuse" {
  mkdir_with_data "$SANDBOX/root/victim"
  # Only coreutils-free essentials: build a PATH with symlinks to everything but lsof.
  mkdir -p "$SANDBOX/nolsof"
  for c in bash sh stat du awk mv rm rmdir mktemp dirname basename head find cat; do
    ln -s "$(command -v "$c")" "$SANDBOX/nolsof/$c"
  done
  PATH="$SANDBOX/nolsof" run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [ -d "$SANDBOX/root/victim" ]
}

@test "identity changed between classify and rm => refuse, replacement survives" {
  mkdir_with_data "$SANDBOX/root/victim"
  # du runs between the identity snapshot and the quarantine: swap the object there.
  real_du="$(command -v du)"
  cat > "$SANDBOX/bin/du" <<STUB
#!/bin/sh
rm -rf "$SANDBOX/root/victim"
mkdir "$SANDBOX/root/victim"
echo precious > "$SANDBOX/root/victim/replacement"
exec "$real_du" "\$@"
STUB
  chmod +x "$SANDBOX/bin/du"
  run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [ "$(cat "$SANDBOX/root/victim/replacement")" = "precious" ]
  [ "$(leftovers)" -eq 0 ]
}

@test "symlink candidate: link removed, target untouched" {
  mkdir_with_data "$SANDBOX/target"
  ln -s "$SANDBOX/target" "$SANDBOX/root/link"
  run safe_delete_path "$SANDBOX/root/link"
  [ "$status" -eq 0 ]
  [ ! -L "$SANDBOX/root/link" ]
  [ ! -e "$SANDBOX/root/link" ]
  [ -f "$SANDBOX/target/sub/blob" ]
}

@test "mountpoint under candidate => refuse" {
  mkdir_with_data "$SANDBOX/root/victim"
  mkdir -p "$SANDBOX/root/victim/mnt"
  printf 'tmpfs %s tmpfs rw 0 0\n' "$SANDBOX/root/victim/mnt" > "$SANDBOX/mounts"
  run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [ -f "$SANDBOX/root/victim/sub/blob" ]
}

@test "the candidate itself being a mountpoint => refuse" {
  mkdir_with_data "$SANDBOX/root/victim"
  printf 'tmpfs %s tmpfs rw 0 0\n' "$SANDBOX/root/victim" > "$SANDBOX/mounts"
  run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [ -d "$SANDBOX/root/victim" ]
}

@test "unreadable mount table => refuse (cannot prove absence of a mount)" {
  mkdir_with_data "$SANDBOX/root/victim"
  SAFE_DELETE_MOUNTS_FILE="$SANDBOX/nope" run safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [ -d "$SANDBOX/root/victim" ]
}

@test "refuses / and empty path" {
  run safe_delete_path ""
  [ "$status" -ne 0 ]
  run safe_delete_path "/"
  [ "$status" -ne 0 ]
  run safe_delete_path "//"
  [ "$status" -ne 0 ]
}

@test "missing path => refuse, nothing created" {
  run safe_delete_path "$SANDBOX/root/ghost"
  [ "$status" -ne 0 ]
  [ "$(leftovers)" -eq 0 ]
}

@test "restore blocked (name retaken) via the default handle check: stderr + SD_ERROR name the quarantined object, retaken file survives" {
  mkdir_with_data "$SANDBOX/root/victim"
  # 1st lsof call = pre-check (idle). 2nd = post-quarantine scan: reports a
  # holder AND a writer retakes the name, so the restore must be refused.
  cat > "$SANDBOX/bin/lsof" <<STUB
#!/bin/sh
n=\$(cat "$SANDBOX/lsof.n" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$SANDBOX/lsof.n"
if [ "\$n" -ge 1 ]; then
  mkdir "$SANDBOX/root/victim"
  echo retaken > "$SANDBOX/root/victim/new"
  for q in "$SANDBOX"/root/.safe-delete-quarantine.*/victim; do echo "n\$q"; done
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/lsof"
  run --separate-stderr safe_delete_path "$SANDBOX/root/victim"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"left quarantined at $SANDBOX/root/.safe-delete-quarantine."* ]]
  [ "$(cat "$SANDBOX/root/victim/new")" = "retaken" ]
  [ -f "$(echo "$SANDBOX"/root/.safe-delete-quarantine.*/victim/sub/blob)" ]
}

# A primitive moved into the lib must never be called bare by the sweep: after
# a merge with a branch that adds a caller, the bare name is command-not-found
# (127), which `if ! reaudit` swallows — a fail-open guard with no git conflict.
# Keep this list next to the lib's primitives: a future move updates both.
@test "sweep calls no bare primitive that moved into the lib" {
  run grep -nE '(^|[^_[:alnum:]])(mount_hazard|is_mountpoint|path_id|id_stable)[[:space:]]*"?\$?' "$HYDRA_REPO/scripts/sweep-workspace-clones.sh"
  [ "$status" -ne 0 ]
}
