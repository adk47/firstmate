#!/usr/bin/env bash
# PromptGuard sidecar lifecycle helper (caroline-promptguard-canary-p1).
#
# The sidecar itself is promptguard/{Dockerfile,server.py}: Meta Llama Prompt Guard 2 22M served on
# node-8 loopback at 127.0.0.1:18793/v1/classify, CPU-only, one thread, capped to 1 CPU / 1 GB by its
# unit. Two consumers share that slot:
#   - the intercom plugin (plugins/intercom/src/safety-classifier.ts), 800 ms budget, shadow or
#     enforce by CONFIG (account.safetyClassifier.mode);
#   - the legacy host-only intake (scripts/intercom-webhook.js), 300 ms budget, shadow by default.
#
# WHY A BUILDER WRAPPER AND NOT `docker build` IN THE UNIT
# The model is BAKED INTO THE IMAGE (promptguard/fetch-model.sh verifies model.sha256 at build time),
# so the request path never touches the network and a swapped model fails the build instead of
# serving silently. That makes a build minutes long, which is far too long for a unit start on a
# deploy host -- so this script rebuilds only when the SOURCE ACTUALLY CHANGED, and the unit starts
# the container asynchronously. `ensure-image` is the ExecStartPre.
#
# FAIL-SOFT IS THE CONTRACT
# The classifier is an EXTRA layer: caroline-safety.ts treats an unavailable sidecar as "the
# deterministic guard is the whole decision", and every unavailable call is counted in the ledger so a
# dead sidecar is visible rather than silent. So nothing here fails a deploy -- a failed build leaves
# the unit inactive and the fleet behaves exactly as it does today (the 1,582 `classifier_unavailable`
# rows that motivated this work are a MEASUREMENT gap, not an outage).
#
#   scripts/promptguard-sidecar.sh ensure-image     # build only if the source fingerprint changed
#   scripts/promptguard-sidecar.sh cleanup          # remove any leftover container (ExecStartPre/post)
#   scripts/promptguard-sidecar.sh health           # GET /health, for the watchdog and operators
#   scripts/promptguard-sidecar.sh check            # installed + built + healthy? (0 ok / 1 not / 2 err)
#   scripts/promptguard-sidecar.sh needs-build      # 0 = rebuild would happen, 1 = image is current
#   scripts/promptguard-sidecar.sh fingerprint      # print the source fingerprint (debug)
#
# Env: PROMPTGUARD_ROOT (default /opt/hydra), PROMPTGUARD_IMAGE (default hydra-promptguard:latest),
#      PROMPTGUARD_STATE (default /var/lib/hydra/promptguard)
set -euo pipefail

ROOT="${PROMPTGUARD_ROOT:-/opt/hydra}"
IMAGE="${PROMPTGUARD_IMAGE:-hydra-promptguard:latest}"
STATE="${PROMPTGUARD_STATE:-/var/lib/hydra/promptguard}"
SRC="$ROOT/promptguard"
URL="http://127.0.0.1:18793/health"

log() { echo "promptguard: $*" >&2; }
warn() { echo "promptguard: WARN: $*" >&2; }

# Everything that changes the image's behaviour. Deliberately EXCLUDES model bytes: those are pinned
# by model.sha256, which is in the list, so a model swap changes the fingerprint through the manifest.
fingerprint() {
  [ -d "$SRC" ] || { echo "missing"; return 0; }
  (
    cd "$SRC"
    for f in Dockerfile server.py requirements.txt requirements-torch.txt model.sha256 fetch-model.sh; do
      [ -f "$f" ] || { echo "$f:absent"; continue; }
      sha256sum "$f"
    done
  ) | sha256sum | cut -d' ' -f1
}

docker_bin() {
  command -v docker 2>/dev/null || echo /usr/bin/docker
}

image_present() {
  "$(docker_bin)" image inspect "$IMAGE" >/dev/null 2>&1
}

ensure_image() {
  [ -d "$SRC" ] || { warn "$SRC is missing — nothing to build"; return 1; }
  for f in Dockerfile server.py model.sha256 fetch-model.sh; do
    [ -f "$SRC/$f" ] || { warn "$SRC/$f is missing — refusing to build"; return 1; }
  done
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker is not installed; the sidecar cannot build on this host"
    return 1
  fi

  local want stamp
  want="$(fingerprint)"
  stamp="$(cat "$STAMP" 2>/dev/null || echo none)"
  if [ "$want" = "$stamp" ] && image_present; then
    log "image is current (fingerprint ${want:0:12})"
    return 0
  fi

  log "building $IMAGE from $SRC (fingerprint ${want:0:12}, was ${stamp:0:12}) — first build downloads torch and the model and takes several minutes"
  if ! "$(docker_bin)" build -t "$IMAGE" "$SRC" >&2; then
    # Leave the stamp unwritten: the next start retries rather than believing a half-built image.
    warn "build failed — the classifier stays unavailable and the deterministic guard remains the whole decision"
    return 1
  fi

  mkdir -p "$STATE"
  printf '%s\n' "$want" > "$STAMP"
  # Tag the deployed sha too, when we have one, so an image on disk can be traced to a commit.
  local sha
  sha="$(tr -d '[:space:]' <"$ROOT/.deployed-sha" 2>/dev/null || true)"
  if printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
    "$(docker_bin)" tag "$IMAGE" "hydra-promptguard:${sha:0:12}" >/dev/null 2>&1 || true
  fi
  log "built $IMAGE"
}

# Exit 0 when a rebuild is actually required (source moved, or no image), 1 when the built image
# already matches the deployed source. install-aux-units.sh uses this to decide whether an ACTIVE
# unit needs a restart: `systemctl start` is a no-op on an active unit, so without this check a
# changed server.py or model pin would never reach the running container.
needs_build() {
  local want stamp
  want="$(fingerprint)"
  stamp="$(cat "$STAMP" 2>/dev/null || echo none)"
  if [ "$want" = "$stamp" ] && image_present; then
    return 1
  fi
  return 0
}

cleanup() {
  if command -v docker >/dev/null 2>&1 && "$(docker_bin)" container inspect hydra-promptguard >/dev/null 2>&1; then
    "$(docker_bin)" rm -f hydra-promptguard >/dev/null 2>&1 || true
    log "removed the leftover container"
  fi
}

health() {
  curl -fsS --max-time 5 "$URL" 2>/dev/null
}

MODE="${1:-}"
STAMP="$STATE/image.fingerprint"

case "$MODE" in
  ensure-image) ensure_image ;;
  cleanup) cleanup ;;
  health) health; echo ;;
  fingerprint) fingerprint ;;
  needs-build) needs_build ;;
  check)
    rc=0
    if ! image_present; then
      log "FAIL: image $IMAGE not built (run: $0 ensure-image)"
      rc=1
    fi
    if ! systemctl cat hydra-promptguard.service >/dev/null 2>&1; then
      log "FAIL: hydra-promptguard.service is not installed (run: scripts/install-aux-units.sh)"
      rc=1
    fi
    if ! h="$(health)"; then
      log "FAIL: $URL did not answer"
      rc=1
    elif [ "$rc" -eq 0 ]; then
      log "OK: $h"
    fi
    exit "$rc"
    ;;
  *)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
