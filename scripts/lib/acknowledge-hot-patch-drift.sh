#!/bin/bash
# ──────────────────────────────────────────────────────────────
# acknowledge-hot-patch-drift.sh
#
# Sourced by scripts/deploy.sh's Step 4a pre-flight drift check.
# Exposes `acknowledge_announced_hotpatches`, which filters the
# rsync-itemize skills_drift output by removing lines whose
# server-side sha256 matches a fresh entry in the hot-patch
# announce log (written by scripts/lib/announce-skill-hot-patch.sh).
#
# The announce log file is read-only here — we never delete or
# rewrite its entries. "Dropping a line" in this file refers
# strictly to the skills_drift string that this function returns
# (i.e., the input to the deploy halt check), never the log entry,
# which stays on disk for forensic continuity.
#
# Contract:
#   - Reads $HYDRA_HOTPATCH_LOG (default /var/log/hydra-skill-hot-patches.log)
#     on the server.
#   - Considers an entry "fresh" if its EPOCH (first field) is within
#     ${HYDRA_HOTPATCH_ACK_WINDOW:-3600} seconds of `date +%s`.
#   - Matches entry by both sha256 (= current server bytes) AND path
#     (= absolute server path of the drifted file). Both must match
#     exactly; prefix collisions are rejected via awk field-equality.
#
# Critically: this does NOT skip the file from rsync. Step 4b still
# runs and still overwrites server bytes with repo HEAD bytes. The
# only effect is suppressing the Step 4a halt for files the operator
# pre-authorised. The deploy semantics — "repo HEAD wins" — are
# unchanged.
#
# Dependencies inherited from deploy.sh's scope:
#   $HYDRA_LOCAL, $DEPLOY_PATH, $NODE8_USER, $NODE8_IP, $SSH_KEY,
#   $SSH_OPTS_STR, and the `log` function.
# ──────────────────────────────────────────────────────────────

# Snapshot the announce log once. Reads from node-8 over ssh in
# remote mode; reads the local file when deploy.sh is running on
# node-8 itself. Echoes the file contents to stdout; empty if no
# log file exists.
_hot_patch_snapshot_log() {
  local log="$1"
  if $HYDRA_LOCAL; then
    [[ -f "$log" ]] && cat "$log" || true
  else
    # shellcheck disable=SC2086  # SSH_OPTS_STR must word-split into multiple -o args
    ssh -i "$SSH_KEY" $SSH_OPTS_STR "$NODE8_USER@$NODE8_IP" \
      "[ -f '$log' ] && cat '$log' || true" 2>/dev/null || true
  fi
}

# Compute sha256 of $abs on the server. Empty string if the file
# doesn't exist.
_hot_patch_server_sha() {
  local abs="$1"
  if $HYDRA_LOCAL; then
    sha256sum "$abs" 2>/dev/null | awk '{print $1}'
  else
    # shellcheck disable=SC2086  # SSH_OPTS_STR must word-split into multiple -o args
    ssh -i "$SSH_KEY" $SSH_OPTS_STR "$NODE8_USER@$NODE8_IP" \
      "sha256sum '$abs' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true
  fi
}

# Filter the caller's skills_drift string: lines whose server-side
# sha256 is acknowledged by a fresh announce log entry are removed
# from the returned string. The announce log itself is not modified.
# Echoes the filtered drift to stdout.
acknowledge_announced_hotpatches() {
  local drift_in="$1"
  if [[ -z "$drift_in" ]]; then
    return 0
  fi

  local log="${HYDRA_HOTPATCH_LOG:-/var/log/hydra-skill-hot-patches.log}"
  local ack_window="${HYDRA_HOTPATCH_ACK_WINDOW:-3600}"
  local now_epoch min_epoch
  now_epoch=$(date -u +%s)
  min_epoch=$(( now_epoch - ack_window ))

  local log_snapshot
  log_snapshot=$(_hot_patch_snapshot_log "$log")
  if [[ -z "$log_snapshot" ]]; then
    printf '%s' "$drift_in"
    return 0
  fi

  local out=""
  local line rel abs abs_canonical server_sha entry epoch_field iso who
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rel=$(awk '{print $NF}' <<<"$line")
    abs="$DEPLOY_PATH/$rel"

    # Canonicalise so the path matches announce-skill-hot-patch.sh's
    # realpath'd record (matters under symlinks: macOS /tmp → /private/tmp
    # in tests, or any /opt-symlink in production deployments).
    abs_canonical=$(realpath "$abs" 2>/dev/null || echo "$abs")

    server_sha=$(_hot_patch_server_sha "$abs")
    if [[ -z "$server_sha" ]]; then
      out+="$line"$'\n'
      continue
    fi

    # Field-exact match: log lines are
    #   EPOCH ISO WRITER pid=… ppid=… sha256=<sha> <abs>
    # Fields 6 and 7 are the sha and path. awk's `==` is a string
    # compare, so prefix collisions can't match (skills-all/gog/
    # vs skills-all/gogcli/ etc).
    entry=$(printf '%s\n' "$log_snapshot" \
      | awk -v sha="sha256=$server_sha" -v path="$abs_canonical" \
            '$6 == sha && $7 == path { latest = $0 } END { if (latest) print latest }')

    if [[ -n "$entry" ]]; then
      epoch_field=$(awk '{print $1}' <<<"$entry")
      if [[ "$epoch_field" =~ ^[0-9]+$ ]] && (( epoch_field >= min_epoch )); then
        iso=$(awk '{print $2}' <<<"$entry")
        who=$(awk '{print $3}' <<<"$entry")
        log "  drift acknowledged: $rel (announced $iso by $who)"
        continue
      fi
    fi
    out+="$line"$'\n'
  done <<<"$drift_in"

  printf '%s' "${out%$'\n'}"
}
