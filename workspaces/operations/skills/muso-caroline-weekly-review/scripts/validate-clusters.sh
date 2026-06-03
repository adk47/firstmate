#!/usr/bin/env bash
# Mechanical gate before PR creation.
# Validates: every conversation_id exists; unique_customers matches; target
# path canonicalizes inside workspaces/support/reference/; insertion has no
# em-dash or voice-blacklist hit.
#
# Usage: validate-clusters.sh <clusters.json> <conversations.jsonl> <repo_root>
# Exit 0 = all clusters valid. Non-zero = at least one rejected; reasons printed to stderr.

set -euo pipefail

CLUSTERS="${1:?clusters.json required}"
CONVERSATIONS="${2:?conversations.jsonl required}"
REPO_ROOT="${3:?repo root required}"

PATH_REGEX='^workspaces/support/reference/[^/]+\.md$'
BLACKLIST=(
  "Great question"
  "I understand your frustration"
  "investigate"
  "sorry the analytics are delayed"
  "sorry for the latency"
)

# Build set of known conversation IDs
KNOWN_IDS=$(jq -r '.id' "$CONVERSATIONS" | sort -u)

errors=0

cluster_count=$(jq '.clusters | length' "$CLUSTERS")
for i in $(seq 0 $((cluster_count - 1))); do
  topic=$(jq -r ".clusters[$i].topic" "$CLUSTERS")

  # 1. Every cited conversation_id exists
  cited=$(jq -r ".clusters[$i].conversation_ids[]" "$CLUSTERS")
  while IFS= read -r cid; do
    if ! grep -qFx "$cid" <<<"$KNOWN_IDS"; then
      echo "ERROR: cluster '$topic': conversation_id '$cid' not in conversations.jsonl (HALLUCINATED?)" >&2
      errors=$((errors + 1))
    fi
  done <<<"$cited"

  # 2. unique_customers matches recomputed value
  claimed=$(jq -r ".clusters[$i].unique_customers" "$CLUSTERS")
  recomputed=$(jq -c ".clusters[$i] | {topic, conversation_ids}" "$CLUSTERS" \
    | "$(dirname "$0")/cluster-questions.sh" "$CONVERSATIONS" \
    | jq -r '.unique_customers')
  if [ "$claimed" != "$recomputed" ]; then
    echo "ERROR: cluster '$topic': unique_customers mismatch (claimed=$claimed, recomputed=$recomputed)" >&2
    errors=$((errors + 1))
  fi

  # 2b. Enforce the hard evidence bar mechanically — the gate cannot trust the
  # LLM to apply the N>=3 threshold (an honestly-labelled 1-customer cluster
  # otherwise passes). Use the recomputed value, not the claimed one.
  if [ "$recomputed" -lt 3 ]; then
    echo "ERROR: cluster '$topic': only $recomputed unique customer(s); PR requires >= 3" >&2
    errors=$((errors + 1))
  fi

  # 3. Path allowlist (regex)
  target=$(jq -r ".clusters[$i].target_path" "$CLUSTERS")
  if ! [[ "$target" =~ $PATH_REGEX ]]; then
    echo "ERROR: cluster '$topic': target_path '$target' fails regex path allowlist" >&2
    errors=$((errors + 1))
    continue
  fi

  # 4. realpath canonicalization (rejects .. and symlink escape)
  full_target="$REPO_ROOT/$target"
  if [ ! -e "$full_target" ]; then
    echo "ERROR: cluster '$topic': target_path '$target' does not exist under $REPO_ROOT" >&2
    errors=$((errors + 1))
    continue
  fi
  canonical=$(realpath "$full_target")
  expected_prefix=$(realpath "$REPO_ROOT/workspaces/support/reference")
  if [[ "$canonical" != "$expected_prefix"/* ]]; then
    echo "ERROR: cluster '$topic': target_path '$target' canonicalizes outside reference/ ($canonical)" >&2
    errors=$((errors + 1))
    continue
  fi

  # 5. Em-dash in insertion
  insertion=$(jq -r ".clusters[$i].insertion" "$CLUSTERS")
  if [ "$insertion" = "null" ] || [ -z "$insertion" ]; then
    echo "ERROR: cluster '$topic': insertion field is missing or empty" >&2
    errors=$((errors + 1))
    continue
  fi
  if [[ "$insertion" == *"—"* ]]; then
    echo "ERROR: cluster '$topic': insertion contains em-dash" >&2
    errors=$((errors + 1))
  fi

  # 6. Voice blacklist (case-insensitive)
  shopt -s nocasematch
  for phrase in "${BLACKLIST[@]}"; do
    if [[ "$insertion" == *"$phrase"* ]]; then
      echo "ERROR: cluster '$topic': insertion contains blacklist phrase '$phrase'" >&2
      errors=$((errors + 1))
    fi
  done
  shopt -u nocasematch
done

if [ "$errors" -gt 0 ]; then
  echo "validate-clusters: $errors error(s)" >&2
  exit 1
fi
