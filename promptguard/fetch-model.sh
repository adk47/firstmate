#!/usr/bin/env bash
# Download the sha256-pinned Prompt Guard 2 22M weights into a local directory.
#
# Runs INSIDE the image build (promptguard/Dockerfile), so the model is baked into the image and the
# request path never touches the network. Every file is verified against promptguard/model.sha256;
# a mismatch deletes the file and exits non-zero so the BUILD fails rather than shipping a model
# whose verdicts we never measured.
#
# The source repo is the NON-GATED mirror recorded in model.sha256's header (Meta's canonical repo
# is gated: anonymous fetches answer 401, and there is no HF_TOKEN on node-8).
#
# Usage: fetch-model.sh [DEST_DIR]        default: /app/model
#   HF_BASE_URL override  — a mirror/proxy base; default the public HF resolve endpoint.
#   HF_TOKEN              — NOT needed for the pinned mirror; passed only if a fork starts gating.
#
# Exit codes: 0 ok; 2 bad usage; 3 download failed; 4 checksum mismatch.
set -euo pipefail

DEST="${1:-/app/model}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/model.sha256"

REPO="project-free-llama/Llama-Prompt-Guard-2-22M"
REVISION="98f241c60b7999ba67eb8603f548461b577b3bc9"
BASE="${HF_BASE_URL:-https://huggingface.co/${REPO}/resolve/${REVISION}}"

log() { printf '[fetch-model] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST" 2
command -v curl >/dev/null 2>&1 || fail "curl is required" 2
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required" 2

mkdir -p "$DEST"

# Only the files the manifest lists are downloaded. model.sha256's comment lines are ignored by
# sha256sum -c itself (verified against GNU coreutils), so the manifest doubles as the file list.
mapfile -t FILES < <(grep -Ev '^\s*(#|$)' "$MANIFEST" | awk '{print $2}')
[[ ${#FILES[@]} -gt 0 ]] || fail "no files listed in $MANIFEST" 2

cd "$DEST"
for f in "${FILES[@]}"; do
  # Idempotent: a rebuilt layer with the file already present and correct costs no network.
  if [[ -f "$f" ]] && sha256sum --status -c <(grep -E "[[:space:]]${f//./\\.}\$" "$MANIFEST"); then
    log "already present + verified: $f"
    continue
  fi
  log "downloading $f"
  # --retry handles HF's occasional 5xx/connection resets during a large single-file fetch; the
  # 283 MB safetensors is the one that matters. --fail turns an HTML error page into a non-zero
  # exit instead of a corrupt .safetensors that torch would later reject with a confusing error.
  if ! curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors \
      ${HF_TOKEN:+-H "Authorization: Bearer ${HF_TOKEN}"} \
      -o "$f.part" "$BASE/$f"; then
    rm -f "$f.part"
    fail "download failed: $BASE/$f" 3
  fi
  mv -f "$f.part" "$f"
done

log "verifying against model.sha256"
if ! sha256sum -c "$MANIFEST"; then
  # Do not leave a half-trusted model on disk for a later layer to reuse.
  for f in "${FILES[@]}"; do rm -f "$f"; done
  fail "checksum mismatch — deleted the downloaded files" 4
fi

log "OK: ${#FILES[@]} files verified in $DEST"
