#!/usr/bin/env bats
# scripts/install-aux-units.sh -> gateway drop-ins (openclaw-gateway-<profile>)
#
# Node's default heap cap (~4 GB) sits below main's normal working set: the
# heap swings 1-3.6 GB all day and every spike past the cap was a V8
# "heap out of memory" SIGABRT followed by a ~10 min post-restart freeze
# (8 crashes 2026-09-17..23; "ops is not responding" twice on 09-23). These
# tests pin the raised cap in the drop-in the installer really writes, so a
# refactor of the heredoc cannot silently drop it. They run the REAL loop
# extracted from the installer, redirected at a temp dir.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  SNIPPET="$TEST_TMPDIR/snippet.sh"
  # The installer has several `for profile in main edge` loops; the others
  # call systemctl enable/start/restart on the host. Take ONLY the drop-in
  # loop, and make any stray systemctl call fail the run instead of acting.
  {
    echo 'log() { :; }'
    echo 'systemctl() { echo "unexpected systemctl $*" >&2; exit 99; }'
    echo 'HYDRA_ROOT=/opt/hydra'
    grep '^HEAP_SNAPSHOT_DIR=' "$INSTALLER"
    awk '/^for profile in main edge; do$/ { buf = ""; inloop = 1 }
         inloop { buf = buf $0 "\n" }
         inloop && /^done$/ { if (buf ~ /GATEWAYDROP/) printf "%s", buf; inloop = 0 }' "$INSTALLER" \
      | sed "s|/etc/systemd/system|$TEST_TMPDIR|"
  } > "$SNIPPET"
  [ "$(grep -c '^for profile in main edge; do$' "$SNIPPET")" -eq 1 ]
  run bash "$SNIPPET"
  [ "$status" -eq 0 ]
}
teardown() { rm -rf "$TEST_TMPDIR"; }

_dropin() { echo "$TEST_TMPDIR/openclaw-gateway-$1.service.d/override.conf"; }

@test "the extraction found the drop-in loop (a moved loop must fail, not pass empty)" {
  [ -s "$(_dropin main)" ]
  [ -s "$(_dropin edge)" ]
}

_cap() { sed -n 's/^Environment="NODE_OPTIONS=.*--max-old-space-size=\([0-9]*\).*/\1/p' "$(_dropin "$1")"; }

@test "both gateways get exactly one heap cap, and it is above node's ~4 GB default" {
  local p mb
  for p in main edge; do
    [ "$(grep -c '^Environment="NODE_OPTIONS=' "$(_dropin "$p")")" -eq 1 ]
    mb="$(_cap "$p")"
    [ -n "$mb" ]
    [ "$mb" -ge 8192 ]
  done
}

# The hand-placed zz-heap-bridge.conf gave main 12 GiB after the 7-8 Oct OOMs
# at 8 GiB. Retiring it is only safe if the managed unit carries that cap.
# Literals on purpose: a test comparing the script to its own constant cannot fail.
@test "main's managed cap is 12288 (the bridge's value), edge stays 8192" {
  [ "$(_cap main)" = "12288" ]
  [ "$(_cap edge)" = "8192" ]
}

@test "main's managed NODE_OPTIONS is exactly the cap plus the diagnostic dir, no snapshot flag" {
  grep -qxF 'Environment="NODE_OPTIONS=--max-old-space-size=12288 --diagnostic-dir=/var/lib/hydra/heap-snapshots"' "$(_dropin main)"
}

@test "a stale zz-heap-bridge.conf in main's drop-in dir is removed, and the removal is logged" {
  local bridge="$TEST_TMPDIR/openclaw-gateway-main.service.d/zz-heap-bridge.conf"
  echo 'stale' > "$bridge"
  sed -i.bak 's/^log() { :; }$/log() { echo "LOG: $*"; }/' "$SNIPPET"
  run bash "$SNIPPET"
  [ "$status" -eq 0 ]
  [ ! -e "$bridge" ]
  [[ "$output" == *"zz-heap-bridge.conf"* ]]
  [ "$(_cap main)" = "12288" ]
}

@test "the bridge removal is exact: edge's copy and other drop-ins are untouched, rerun is a no-op" {
  local m="$TEST_TMPDIR/openclaw-gateway-main.service.d" e="$TEST_TMPDIR/openclaw-gateway-edge.service.d"
  echo keep > "$e/zz-heap-bridge.conf"
  echo keep > "$m/zz-other.conf"
  run bash "$SNIPPET"; [ "$status" -eq 0 ]
  run bash "$SNIPPET"; [ "$status" -eq 0 ]
  [ -e "$e/zz-heap-bridge.conf" ]
  [ -e "$m/zz-other.conf" ]
  [ -s "$m/override.conf" ]
}

@test "the heap cap is in [Service], where systemd honours Environment=" {
  local p
  for p in main edge; do
    awk '/^\[/{sec=$0} /^Environment="NODE_OPTIONS=/{print sec}' "$(_dropin "$p")" \
      | grep -qx '\[Service\]'
  done
}

@test "heap cap in place, snapshots aged by mtime, heapsnapshot flag disabled" {
  # A snapshot with no directory lands in the unit's cwd (/) and is never
  # cleaned; one in a dir with no tmpfiles age fills the disk a few GB per crash.
  local p dir want
  want="$(sed -n 's/^HEAP_SNAPSHOT_DIR=//p' "$INSTALLER")"
  [[ "$want" == /* ]]
  grep -Eq '^d [$][{]HEAP_SNAPSHOT_DIR[}] 0700 root root m:[0-9]+d$' "$INSTALLER"
  for p in main edge; do
    if grep -q -- '--heapsnapshot-near-heap-limit' "$(_dropin "$p")"; then false; fi
    dir="$(sed -n 's/^Environment="NODE_OPTIONS=.*--diagnostic-dir=\([^" ]*\).*/\1/p' "$(_dropin "$p")")"
    [ "$dir" = "$want" ]
  done
}
