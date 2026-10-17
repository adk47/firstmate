#!/usr/bin/env bats
# scripts/install-aux-units.sh -> gateway drop-ins (openclaw-gateway-<profile>)
#
# MUS-2652 instrument: MAIN ONLY, openclaw's own startup trace + diagnostics
# timeline, to name the 20-28 min post-start freeze (MUS-1295). These tests pin
# that the flags reach main and NEVER the customer-facing edge gateway, and that
# OPENCLAW_DIAGNOSTICS is the single flag `timeline` (=1/all/* enables all nine,
# including provider-HTTP logging). They run the REAL loop extracted from the
# installer, redirected at a temp dir.
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
    grep '^DIAG_DIR=' "$INSTALLER"
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

@test "main's drop-in has each of the five trace lines exactly once, in [Service]" {
  local key
  for key in OPENCLAW_GATEWAY_STARTUP_TRACE OPENCLAW_GATEWAY_RESTART_TRACE \
             OPENCLAW_DIAGNOSTICS OPENCLAW_DIAGNOSTICS_EVENT_LOOP \
             OPENCLAW_DIAGNOSTICS_TIMELINE_PATH; do
    [ "$(grep -c "^Environment=\"${key}=" "$(_dropin main)")" -eq 1 ]
    awk -v k="Environment=\"${key}=" 'index($0, k) == 1 {print sec}
         /^\[/ {sec=$0}' "$(_dropin main)" | grep -qx '\[Service\]'
  done
}

@test "edge's drop-in has ZERO OPENCLAW_ lines: the flags never reach the customer-facing gateway" {
  run grep -c 'OPENCLAW_' "$(_dropin edge)"
  [ "$output" = "0" ]
}

@test "OPENCLAW_DIAGNOSTICS is the literal 'timeline', never 1/true/all/*" {
  # =1 maps to the wildcard and turns on all nine flags, incl. brave.http and
  # telegram.http (provider HTTP traffic in the journal).
  grep -qx 'Environment="OPENCLAW_DIAGNOSTICS=timeline"' "$(_dropin main)"
  run grep -E '^Environment="OPENCLAW_DIAGNOSTICS=(1|true|all|\*)"' "$(_dropin main)"
  [ "$status" -ne 0 ]
}

@test "the timeline path is profile-specific and under the dir tmpfiles ages out" {
  local want path
  want="$(sed -n 's/^DIAG_DIR=//p' "$INSTALLER")"
  [[ "$want" == /* ]]
  grep -Eq '^d [$][{]DIAG_DIR[}] 0700 root root 3d$' "$INSTALLER"
  path="$(sed -n 's/^Environment="OPENCLAW_DIAGNOSTICS_TIMELINE_PATH=\(.*\)"$/\1/p' "$(_dropin main)")"
  [ "$path" = "$want/main-timeline.jsonl" ]
}

@test "main's NODE_OPTIONS is still present (12 GiB managed cap, MUS-6143), exactly once" {
  [ "$(grep -c '^Environment="NODE_OPTIONS=' "$(_dropin main)")" -eq 1 ]
  grep -qx 'Environment="NODE_OPTIONS=--max-old-space-size=12288 --diagnostic-dir=/var/lib/hydra/heap-snapshots"' "$(_dropin main)"
}

# Bot finding on #1065: openclaw appends to ONE fixed file, so every append
# refreshes mtime and the tmpfiles age never fires while main is active. The
# file needs real rotation, kept 3 days.
_diag_logrotate() {
  awk "/^cat > \/etc\/logrotate.d\/hydra-gateway-diag << 'DIAGLOGROTATE'\$/ {on=1; next}
       /^DIAGLOGROTATE\$/ {on=0} on" "$INSTALLER"
}

@test "the active timeline file is rotated by size and time, kept 3 days" {
  local conf; conf="$(_diag_logrotate)"
  [ -n "$conf" ]
  want="$(sed -n 's/^DIAG_DIR=//p' "$INSTALLER")"
  echo "$conf" | grep -Fq "${want}/main-timeline.jsonl"
  echo "$conf" | grep -qx '[[:space:]]*daily'
  echo "$conf" | grep -qx '[[:space:]]*rotate 3'
  echo "$conf" | grep -Eq '^[[:space:]]*maxsize [0-9]+[MG]$'
  # the writer holds the fd open and has no reopen signal
  echo "$conf" | grep -qx '[[:space:]]*copytruncate'
  echo "$conf" | grep -qx '[[:space:]]*missingok'
}

@test "logrotate lifecycle: a live-appended oversized timeline is rotated and the live file is truncated" {
  command -v logrotate >/dev/null || skip "logrotate not installed on this host"
  local conf dir; dir="$TEST_TMPDIR/diag"; mkdir -p "$dir"
  conf="$TEST_TMPDIR/lr.conf"
  _diag_logrotate | sed -e "s|/var/lib/hydra/diag|$dir|g" -e 's/maxsize [0-9]*[MG]/maxsize 1k/' > "$conf"
  head -c 5000 /dev/zero | tr '\0' x > "$dir/main-timeline.jsonl"
  run logrotate -s "$TEST_TMPDIR/state" "$conf"
  [ "$status" -eq 0 ]
  [ ! -s "$dir/main-timeline.jsonl" ]
  ls "$dir" | grep -q '^main-timeline.jsonl.1'
}
