#!/usr/bin/env bash
set -euo pipefail

# HYDRA Repo Backup
# =================
# Nightly git bundle backup of hydra and hydra-audit repos.
# Uploads to OVH Object Storage with 30-day retention.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_DIR="${BACKUP_DIR:-/tmp/hydra-backups}"
OVH_BUCKET="${OVH_BUCKET:-s3://hydra-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
MINIO_ALIAS="${MINIO_ALIAS:-ovh}"
DATE_STAMP=$(date -u '+%Y-%m-%d')

# Repos to back up
REPOS=(
  "hydra:$HYDRA_ROOT"
  "hydra-audit:${HYDRA_AUDIT_REPO:-$HYDRA_ROOT/../hydra-audit}"
)

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; exit 1; }

mkdir -p "$BACKUP_DIR"

# -------------------------------------------------------------------
# Step 1: Create git bundles
# -------------------------------------------------------------------
log "Step 1/3: Creating git bundles..."

BUNDLE_FILES=()
for entry in "${REPOS[@]}"; do
  REPO_NAME="${entry%%:*}"
  REPO_PATH="${entry##*:}"

  if [[ ! -d "$REPO_PATH/.git" ]]; then
    log "  WARNING: $REPO_PATH is not a git repo, skipping $REPO_NAME"
    continue
  fi

  BUNDLE_FILE="$BACKUP_DIR/${REPO_NAME}-${DATE_STAMP}.bundle"
  log "  Bundling $REPO_NAME..."
  git -C "$REPO_PATH" bundle create "$BUNDLE_FILE" --all
  BUNDLE_SIZE=$(du -h "$BUNDLE_FILE" | cut -f1)
  log "  Created $BUNDLE_FILE ($BUNDLE_SIZE)"
  BUNDLE_FILES+=("$BUNDLE_FILE")
done

if [[ ${#BUNDLE_FILES[@]} -eq 0 ]]; then
  fail "No bundles created. Nothing to upload."
fi

# -------------------------------------------------------------------
# Step 2: Upload to OVH Object Storage
# -------------------------------------------------------------------
log "Step 2/3: Uploading bundles to $OVH_BUCKET..."

for bundle in "${BUNDLE_FILES[@]}"; do
  FILENAME=$(basename "$bundle")
  log "  Uploading $FILENAME..."
  mc cp "$bundle" "${MINIO_ALIAS}/${OVH_BUCKET#s3://}/$FILENAME"
  log "  Uploaded $FILENAME."
done

# -------------------------------------------------------------------
# Step 3: Enforce retention (delete bundles older than N days)
# -------------------------------------------------------------------
log "Step 3/3: Enforcing ${RETENTION_DAYS}-day retention..."

# List all objects, filter by date, delete old ones
CUTOFF_DATE=$(date -u -v-${RETENTION_DAYS}d '+%Y-%m-%d' 2>/dev/null || \
              date -u -d "${RETENTION_DAYS} days ago" '+%Y-%m-%d' 2>/dev/null || \
              echo "")

if [[ -z "$CUTOFF_DATE" ]]; then
  log "  WARNING: Could not compute cutoff date. Skipping retention cleanup."
else
  DELETED=0
  while IFS= read -r line; do
    # Extract date from filename pattern: reponame-YYYY-MM-DD.bundle
    FILE_DATE=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1) || continue
    if [[ -n "$FILE_DATE" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
      log "  Deleting old backup: $line"
      mc rm "${MINIO_ALIAS}/${OVH_BUCKET#s3://}/$line" 2>/dev/null || true
      DELETED=$((DELETED + 1))
    fi
  done < <(mc ls "${MINIO_ALIAS}/${OVH_BUCKET#s3://}/" 2>/dev/null | awk '{print $NF}' | grep '\.bundle$')

  log "  Deleted $DELETED old backup(s) (older than $CUTOFF_DATE)."
fi

# Clean up local temp bundles
rm -f "$BACKUP_DIR"/*.bundle
log "Backup complete."
