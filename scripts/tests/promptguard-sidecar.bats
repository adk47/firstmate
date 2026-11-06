#!/usr/bin/env bats
# caroline-promptguard-canary-p1: the PromptGuard 2 22M sidecar's unit wiring and its builder.
#  - the unit renders with the three CPU/memory caps that keep it off the gateway's cores, the
#    loopback-only publish, the lazy build in ExecStartPre, and no failure loop on a docker-less host;
#  - install-aux-units.sh enables it but starts it with --no-block, so a first-time image build can
#    never hold a deploy open;
#  - promptguard-sidecar.sh never builds when the source is absent, and rebuilds when the source
#    fingerprint moves (the freshness rule that makes a server.py change actually land).
# The container itself is NOT started here: these are wiring/freshness tests, not a docker build.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
HELPER="$HYDRA_REPO/scripts/promptguard-sidecar.sh"
UNIT_DIR="/etc/systemd/system/"

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

_render() {
  local dir="$1" name="$2" dest="$3/"
  local snippet="$BATS_TEST_TMPDIR/render-$RANDOM.sh"
  awk -v dir="$dir" -v name="$name" -v dest="$dest" '
    !on && index($0, "cat > " dir name) == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1
      print "cat > " dest substr($0, length("cat > " dir) + 1); next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="$HYDRA_REPO" bash "$snippet"
}

@test "the sidecar unit exists and publishes ONLY on loopback" {
  _render "$UNIT_DIR" "hydra-promptguard.service" "$WORK"
  run cat "$WORK/hydra-promptguard.service"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--publish 127.0.0.1:18793:18793"* ]]
  # Never 0.0.0.0: the classifier sees raw customer text and must not be reachable off-box.
  [[ "$output" != *"0.0.0.0:18793"* ]]
}

@test "the sidecar unit carries all three caps that keep it off the gateway" {
  _render "$UNIT_DIR" "hydra-promptguard.service" "$WORK"
  run cat "$WORK/hydra-promptguard.service"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CPUQuota=1"* ]]
  [[ "$output" == *"MemoryMax=1G"* ]]
  [[ "$output" == *"Nice=10"* ]]
  # And the container-level caps, which are the ones that bind inside the cgroup.
  [[ "$output" == *"--cpus 1"* ]]
  [[ "$output" == *"--memory 1g"* ]]
}

@test "the sidecar unit builds lazily in ExecStartPre, with a build-sized timeout" {
  _render "$UNIT_DIR" "hydra-promptguard.service" "$WORK"
  run cat "$WORK/hydra-promptguard.service"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ExecStartPre=/bin/bash $HYDRA_REPO/scripts/promptguard-sidecar.sh ensure-image"* ]]
  # The first build downloads torch + the model: a 90s default would SIGTERM it mid-way and leave a
  # half-built image that the next start would trust.
  [[ "$output" == *"TimeoutStartSec=3600"* ]]
}

@test "a docker-less host skips the unit instead of restart-looping" {
  _render "$UNIT_DIR" "hydra-promptguard.service" "$WORK"
  run cat "$WORK/hydra-promptguard.service"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ConditionPathExists=/usr/bin/docker"* ]]
}

@test "install-aux-units enables the sidecar and starts it WITHOUT blocking on the build" {
  run grep -F "systemctl start --no-block hydra-promptguard.service" "$INSTALLER"
  [ "$status" -eq 0 ]
  # A blocking start on a first-time build would hang the deploy for minutes.
  run bash -c "grep -cE '^systemctl start hydra-promptguard.service' '$INSTALLER' || true"
  [ "$output" = "0" ]
}

@test "the builder refuses to build when the source is missing (fail-soft, no docker call)" {
  PROMPTGUARD_ROOT="$WORK/empty" PROMPTGUARD_STATE="$WORK/state" \
    run bash "$HELPER" ensure-image
  [ "$status" -ne 0 ]
  [[ "$output" == *"is missing"* ]]
}

@test "the builder rebuilds only when the source fingerprint moves" {
  mkdir -p "$WORK/root/promptguard"
  cp "$HYDRA_REPO/promptguard/"{Dockerfile,server.py,requirements.txt,requirements-torch.txt,model.sha256,fetch-model.sh} "$WORK/root/promptguard/"
  export PROMPTGUARD_ROOT="$WORK/root" PROMPTGUARD_STATE="$WORK/state" PROMPTGUARD_IMAGE="test/pg:latest"

  first="$(bash "$HELPER" fingerprint)"
  [ -n "$first" ]
  echo "# a comment changes no behaviour but does change bytes" >> "$WORK/root/promptguard/server.py"
  second="$(bash "$HELPER" fingerprint)"
  [ "$first" != "$second" ]

  # model.sha256 is IN the fingerprint, so a pinned-model swap forces a rebuild too.
  echo "# bump" >> "$WORK/root/promptguard/model.sha256"
  third="$(bash "$HELPER" fingerprint)"
  [ "$second" != "$third" ]
}

@test "check reports not-built and not-installed rather than claiming healthy" {
  PROMPTGUARD_ROOT="$WORK/empty" PROMPTGUARD_STATE="$WORK/state" PROMPTGUARD_IMAGE="test/absent:latest" \
    run bash "$HELPER" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not built"* ]] || [[ "$output" == *"did not answer"* ]]
}

# --- QA finding on #1719: `systemctl start` on an ACTIVE unit is a no-op, so ExecStartPre never
# --- re-ran and a changed server.py / Dockerfile / model pin never reached the container.
@test "install-aux-units restarts an ACTIVE sidecar, and only when a rebuild is due" {
  # The gate exists at all: active unit -> fingerprint test -> restart.
  run grep -F "systemctl is-active --quiet hydra-promptguard.service" "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -F "systemctl restart --no-block hydra-promptguard.service" "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -F '"$HYDRA_ROOT/scripts/promptguard-sidecar.sh" needs-build' "$INSTALLER"
  [ "$status" -eq 0 ]
  # ... and the discard paths still exist for the never-started case.
  run grep -F "systemctl start --no-block hydra-promptguard.service" "$INSTALLER"
  [ "$status" -eq 0 ]
}

@test "needs-build is 1 when the built image matches the deployed source, 0 when it does not" {
  mkdir -p "$WORK/root/promptguard" "$WORK/bin"
  cp "$HYDRA_REPO/promptguard/"{Dockerfile,server.py,requirements.txt,requirements-torch.txt,model.sha256,fetch-model.sh} "$WORK/root/promptguard/"
  # Stub docker: the image exists, so freshness is decided purely by the fingerprint stamp.
  cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "image inspect") exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$WORK/bin/docker"
  export PATH="$WORK/bin:$PATH"
  export PROMPTGUARD_ROOT="$WORK/root" PROMPTGUARD_STATE="$WORK/state" PROMPTGUARD_IMAGE="test/pg:latest"
  mkdir -p "$WORK/state"

  # No stamp yet -> a build would happen.
  run bash "$HELPER" needs-build
  [ "$status" -eq 0 ]

  # Stamp the CURRENT fingerprint -> nothing to do, and this is the case that must NOT restart.
  bash "$HELPER" fingerprint > "$WORK/state/image.fingerprint"
  run bash "$HELPER" needs-build
  [ "$status" -eq 1 ]

  # A one-byte source change -> a rebuild is due again.
  echo "# touch" >> "$WORK/root/promptguard/server.py"
  run bash "$HELPER" needs-build
  [ "$status" -eq 0 ]
}
