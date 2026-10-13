#!/usr/bin/env bats
# scripts/install-aux-units.sh -> edge-only MemoryLow=6G in the gateway drop-in (MUS-6310)
#
# MemoryLow=6G protects the edge gateway (Caroline) from reclaim when main /
# Paperclip put node-8 under memory pressure. It is EDGE ONLY: main's drop-in
# must carry no MemoryLow line. The value was approved by Aaron 9 Oct (MUS-5057 W3).
# These tests run the REAL drop-in loop extracted from the installer against a
# temp dir.
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

@test "edge gets exactly one MemoryLow line, and its value is the approved 6G" {
  [ "$(grep -c '^MemoryLow=' "$(_dropin edge)")" -eq 1 ]
  [ "$(sed -n 's/^MemoryLow=//p' "$(_dropin edge)")" = "6G" ]
}

@test "MemoryLow is in [Service], where systemd honours it" {
  awk '/^\[/{sec=$0} /^MemoryLow=/{print sec}' "$(_dropin edge)" | grep -qx '\[Service\]'
}

@test "main gets no MemoryLow line (edge only)" {
  [ "$(grep -c 'MemoryLow' "$(_dropin main)")" -eq 0 ]
}
