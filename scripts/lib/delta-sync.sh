#!/usr/bin/env bash
# delta-sync.sh — Step 0 / Step 4b of scripts/deploy.sh apply the GIT DELTA since
# the server's .deployed-sha, never the whole tree (MUS-5069, W2b-1).
#
# Why: the old Step 4b was `rsync -a --delete` over everything, so anything on
# node-8 that git does not have was a deploy victim and a drift gate had to stand
# in front of it. A delta transfer cannot touch a path outside the delta, so
# server-only files are safe by construction.
#
# Sourced by deploy.sh (and scripts/tests/deploy-delta-sync.bats). Inherits from
# deploy.sh: HYDRA_ROOT HYDRA_LOCAL DEPLOY_PATH NODE8_USER NODE8_IP SSH_KEY
# SSH_OPTS RSYNC_EXCLUDES, and the log() function.
#
# Per-path three-way check (server bytes S, baseline blob B, HEAD blob H):
#   S == H                 NOOP      already current, logged
#   S absent               CREATE    write the file, logged
#   S == B                 TRANSFER  the normal case
#   S differs from both    CONFLICT  (a server symlink counts as differing)
#                                    hard stop, named — unless the HEAD blob
#                                    carries the git-wins marker (GITWINS)
#                                    or a fresh hot-patch announcement acks it
# A path in neither side's change set is not in the delta, so it is never read.
# Deletions: S == B -> DELETE, S absent -> NOOP, else CONFLICT.

DELTA_GIT_WINS_MARKER='Reviewed baseline: deploy overwrites'

# Read the marker from the repo's HEAD blob ONLY. Never from the server's bytes:
# an agent on node-8 must not be able to authorise its own overwrite. The marker
# can only make git overwrite the server, never push server content to the fleet.
delta_head_has_git_wins_marker() {
  git -C "$HYDRA_ROOT" cat-file -p "HEAD:$1" 2>/dev/null | grep -qF -- "$DELTA_GIT_WINS_MARKER"
}

_delta_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# <rev> <path> -> sha256 of the blob, or ABSENT
_delta_blob_hash() {
  if git -C "$HYDRA_ROOT" cat-file -e "$1:$2" 2>/dev/null; then
    git -C "$HYDRA_ROOT" cat-file -p "$1:$2" | _delta_hash
  else
    echo ABSENT
  fi
}

# <rev> <path> -> git file mode (empty when absent at rev)
_delta_mode() { git -C "$HYDRA_ROOT" ls-tree "$1" -- "$2" 2>/dev/null | cut -d' ' -f1; }

# <git mode> -> x when executable, - otherwise (what the server probe reports)
_delta_exec_flag() { if [[ "$1" == 100755 ]]; then echo x; else echo -; fi; }

# Runs on the server (stdin: relative paths): `<path>\t<sha256|ABSENT|SYMLINK|DIR>\t<x|->` each (x = exec bit set).
_DELTA_SERVER_HASH_SH='cd "$1" || exit 3
h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d" " -f1; }
while IFS= read -r p; do
  if [ -L "$p" ]; then printf "%s\tSYMLINK\t-\n" "$p"  # never hashed through: its target is not the tracked file
  elif [ -d "$p" ]; then printf "%s\tDIR\t-\n" "$p"  # a directory is neither absent nor the tracked file
  elif [ -f "$p" ]; then if [ -x "$p" ]; then x=x; else x=-; fi; printf "%s\t%s\t%s\n" "$p" "$(h "$p")" "$x"
  else printf "%s\tABSENT\t-\n" "$p"; fi
done'

# Runs on the server (stdin: relative paths): remove each file, then any parent
# directory the removal emptied (rmdir refuses a non-empty one, so this is safe).
_DELTA_SERVER_DELETE_SH='cd "$1" || exit 3
while IFS= read -r p; do
  rm -f -- "$p" || exit 4
  d=$(dirname "$p")
  while [ "$d" != "." ] && [ "$d" != "/" ]; do rmdir -- "$d" 2>/dev/null || break; d=$(dirname "$d"); done
done'

# <script> <args...>; stdin passes through. Local on node-8, ssh elsewhere.
_delta_on_server() {
  local script="$1"; shift
  if $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
    bash -c "$script" _ "$@"
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NODE8_USER@$NODE8_IP" \
      "bash -c $(printf '%q' "$script") _ $(printf '%q ' "$@")"
  fi
}

# <baseline> — committed changes only (untracked/uncommitted never ship);
# renames are D + A, never R. Sets DELTA_UPSERT (A/M/T) and DELTA_DELETE (D).
# Git C-quotes names with a control character, `"` or `\` even under
# core.quotePath=false; a quoted name would be probed as a literal path, read as
# absent, and a deletion would silently become a NOOP. Fails closed instead.
delta_compute() {
  # Each assignment is checked on its own: the caller runs this as `delta_compute … || fail`,
  # which turns errexit off in here, so a failed git diff would otherwise leave an empty delta.
  DELTA_UPSERT=$(git -C "$HYDRA_ROOT" -c core.quotePath=false diff --name-only --no-renames --diff-filter=d "$1" HEAD | LC_ALL=C sort -u | sed '/^$/d') || return 1
  DELTA_DELETE=$(git -C "$HYDRA_ROOT" -c core.quotePath=false diff --name-only --no-renames --diff-filter=D "$1" HEAD | LC_ALL=C sort -u | sed '/^$/d') || return 1
  local quoted
  quoted=$(printf '%s\n%s\n' "$DELTA_UPSERT" "$DELTA_DELETE" | grep '^"' || true)
  if [[ -n "$quoted" ]]; then
    echo "delta path(s) with a newline, quote or backslash in the name cannot be applied safely (git quotes them): $quoted" >&2
    return 1
  fi
}

# Baseline guard. A wrong baseline means applying the WRONG delta and silently
# skipping changes, so it fails closed. Returns non-zero with the reason on stdout.
delta_check_baseline() {
  local sha="$1"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "baseline '$sha' is not a 40-char hex SHA"; return 1; }
  git -C "$HYDRA_ROOT" cat-file -e "$sha^{commit}" 2>/dev/null \
    || { echo "baseline $sha is not in this checkout's history (git fetch, then retry)"; return 1; }
  git -C "$HYDRA_ROOT" merge-base --is-ancestor "$sha" HEAD \
    || { echo "baseline $sha is not an ancestor of HEAD (HEAD is behind or on a diverged branch)"; return 1; }
}

# stdin: relative paths. stdout: the ones that survive RSYNC_EXCLUDES. One log
# line per dropped path naming the pattern: --files-from does not disarm the
# excludes, and a committed change that never reaches node-8 must say so.
delta_filter_excludes() {
  local all tree out
  all=$(cat)
  [[ -n "$all" ]] || return 0
  tree=$(mktemp -d) || return 1
  # A trap, not only the inline rm: a return path that forgets its rm still cleans up the dir.
  trap 'rm -rf "$tree"' RETURN
  mkdir -p "$tree/src" "$tree/dst"
  # A path whose placeholder was not created would read as "excluded": fail the gate instead.
  _delta_placeholders "$tree/src" <<<"$all" \
    || { rm -rf "$tree"; log "  could not stage the delta paths for the exclude dry-run — cannot tell which survive the excludes" >&2; return 1; }
  # A failed rsync must fail the gate: an empty listing would read as "every path excluded".
  local raw
  raw=$(rsync -rn --out-format='%n' "${RSYNC_EXCLUDES[@]}" "$tree/src/" "$tree/dst/") \
    || { rm -rf "$tree"; log "  rsync exclude dry-run failed — cannot tell which delta paths survive the excludes" >&2; return 1; }
  out=$(printf '%s\n' "$raw" | { grep -v '/$' || true; } | LC_ALL=C sort -u)
  local dropped
  dropped=$(LC_ALL=C comm -23 <(printf '%s\n' "$all" | LC_ALL=C sort -u) <(printf '%s\n' "$out"))
  if [[ -n "$dropped" ]]; then
    local p pat
    while IFS= read -r p; do
      pat="RSYNC_EXCLUDES"
      local e
      for e in "${RSYNC_EXCLUDES[@]}"; do
        [[ "$e" == --exclude=* ]] || continue
        if _delta_excluded_by "$tree" "$e" "$p"; then pat="${e#--exclude=}"; break; fi
      done
      log "  $p — skipped, matches exclude $pat" >&2
    done <<<"$dropped"
  fi
  rm -rf "$tree"
  printf '%s\n' "$out" | sed '/^$/d'
}

_delta_placeholders() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    mkdir -p "$1/$(dirname "$p")" && : > "$1/$p" || return 1
  done
}

# <tree> <single exclude> <path> — true when that exclude alone drops the path.
_delta_excluded_by() {
  local kept
  kept=$(rsync -rn --out-format='%n' "$2" "$1/src/" "$1/dst/")
  ! grep -Fxq -- "$3" <<<"$kept"
}

# <baseline> <upsert|delete>; stdin: relative paths. stdout: `KIND\tpath` lines.
delta_classify() {
  local base="$1" mode="$2" path server b h
  local paths
  paths=$(cat)
  [[ -n "$paths" ]] || return 0
  local hashes
  hashes=$(printf '%s\n' "$paths" | _delta_on_server "$_DELTA_SERVER_HASH_SH" "$DEPLOY_PATH") || return 1
  while IFS=$'\t' read -r path server sx; do
    [[ -n "$path" ]] || continue
    b=$(_delta_blob_hash "$base" "$path")
    if [[ "$mode" == delete ]]; then
      if [[ "$server" == ABSENT ]]; then printf 'NOOP\t%s\n' "$path"
      elif [[ "$server" == "$b" && "$sx" == "$(_delta_exec_flag "$(_delta_mode "$base" "$path")")" ]]; then printf 'DELETE\t%s\n' "$path"  # same bytes AND same exec bit as the baseline
      else printf 'CONFLICT_DELETE\t%s\n' "$path"; fi
      continue
    fi
    h=$(_delta_blob_hash HEAD "$path")
    # Same bytes but a changed git mode (0644 -> 0755) is still a change to ship.
    if [[ "$server" == "$h" && -n "$(_delta_mode "$base" "$path")" \
          && "$(_delta_mode "$base" "$path")" != "$(_delta_mode HEAD "$path")" ]]; then printf 'TRANSFER\t%s\n' "$path"
    elif [[ "$server" == "$h" && "$sx" != "$(_delta_exec_flag "$(_delta_mode HEAD "$path")")" ]]; then printf 'TRANSFER\t%s\n' "$path"  # server bytes match but its exec bit does not
    elif [[ "$server" == "$h" ]]; then printf 'NOOP\t%s\n' "$path"
    elif [[ "$server" == ABSENT ]]; then printf 'CREATE\t%s\n' "$path"
    elif [[ "$server" == "$b" ]]; then printf 'TRANSFER\t%s\n' "$path"
    else printf 'CONFLICT\t%s\n' "$path"; fi
  done <<<"$hashes"
}

# <baseline>. Needs DELTA_UPSERT/DELTA_DELETE from delta_compute. Sets
# DELTA_TRANSFER and DELTA_REMOVE (newline lists) and logs every decision.
# Returns 1 (after printing the briefing) when a hard stop remains.
# DELTA_HALT_SUPPRESSED=1 (HYDRA_FORCE / HYDRA_SKIP_DRIFT_CHECK) logs the stop
# and carries on.
delta_gate() {
  local base="$1" kind path conflicts="" del_conflicts="" up del line
  DELTA_TRANSFER=""; DELTA_REMOVE=""
  up=$(printf '%s\n' "$DELTA_UPSERT" | delta_filter_excludes) || return 2
  del=$(printf '%s\n' "$DELTA_DELETE" | delta_filter_excludes) || return 2
  # Each pass is checked on its own: a group's status is its last command's, and
  # the delete pass returns 0 on empty input, which would mask a failed upsert.
  local up_c del_c classified
  up_c=$(printf '%s\n' "$up" | delta_classify "$base" upsert) || return 2
  del_c=$(printf '%s\n' "$del" | delta_classify "$base" delete) || return 2
  classified="$up_c"$'\n'"$del_c"

  if [[ -n "$(grep '^CONFLICT' <<<"$classified" | cut -f2 | sed '/^$/d')" ]]; then
    # shellcheck source=acknowledge-hot-patch-drift.sh
    source "$SCRIPT_DIR/lib/acknowledge-hot-patch-drift.sh"
  fi
  while IFS=$'\t' read -r kind path; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      NOOP)     log "  no-op: $path (server already matches the target)" ;;
      CREATE)   log "  create: $path (absent on the server)"; DELTA_TRANSFER+="$path"$'\n' ;;
      TRANSFER) DELTA_TRANSFER+="$path"$'\n' ;;
      DELETE)   log "  delete: $path (removed from git; server copy unchanged since baseline)"; DELTA_REMOVE+="$path"$'\n' ;;
      CONFLICT_DELETE)
        # The source is gone from git: an override must REMOVE the server copy
        # (rsync cannot transfer a deleted path), never put it in the transfer set.
        if [[ -z "$(acknowledge_announced_hotpatches "$path" | grep -Fx -- "$path" || true)" ]]; then
          log "  hot-patch acknowledged: $path — removing"
          DELTA_REMOVE+="$path"$'\n'
        else
          conflicts+="$path"$'\n'; del_conflicts+="$path"$'\n'
        fi ;;
      CONFLICT)
        if [[ -z "$(acknowledge_announced_hotpatches "$path" | grep -Fx -- "$path" || true)" ]]; then
          log "  hot-patch acknowledged: $path — overwriting"
          DELTA_TRANSFER+="$path"$'\n'
        elif delta_head_has_git_wins_marker "$path"; then
          log "  git-wins: $path — server and repo both changed; HEAD blob carries \"$DELTA_GIT_WINS_MARKER\", overwriting"
          DELTA_TRANSFER+="$path"$'\n'
        else
          conflicts+="$path"$'\n'
        fi ;;
    esac
  done <<<"$classified"

  if [[ -n "$conflicts" ]]; then
    delta_conflict_briefing "$base" "$conflicts"
    if [[ "${DELTA_HALT_SUPPRESSED:-0}" != "1" ]]; then return 1; fi
    log "  halt suppressed by HYDRA_FORCE / HYDRA_SKIP_DRIFT_CHECK — the paths above will be overwritten"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if grep -Fxq -- "$line" <<<"$del_conflicts"; then DELTA_REMOVE+="$line"$'\n'; else DELTA_TRANSFER+="$line"$'\n'; fi
    done <<<"$conflicts"
  fi
}

delta_conflict_briefing() {
  local base="$1" path stat
  echo "================================================================================"
  echo "✗ DEPLOY BLOCKED — server and repo both changed these paths since $base"
  echo "================================================================================"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    stat=$(git -C "$HYDRA_ROOT" diff --numstat "$base" HEAD -- "$path" | awk '{print "+" $1 "/-" $2}')
    echo "  $path   (repo since baseline: ${stat:-no content change})"
  done <<<"$2"
  cat <<'BRIEFING'

Deploying would overwrite an edit made directly on node-8. Pull it ONE PATH AT A
TIME, review, commit, then re-run:
  scripts/sync-from-server.sh skills|workspaces|audit --apply --only <path>
If node-8's version is meant to be replaced, the file's repo copy must carry the
reviewed-baseline marker, or announce the hot-patch on node-8 first.
BRIEFING
}

# Apply the gate's verdict: transfer DELTA_TRANSFER with --files-from and NO
# --delete (the push excludes still filter it), then remove DELTA_REMOVE.
delta_apply() {
  local list
  list=$(mktemp) || return 1
  printf '%s' "$DELTA_TRANSFER" | sed '/^$/d' > "$list"
  if [[ ! -s "$list" ]]; then
    log "  Nothing to transfer"
  elif $HYDRA_LOCAL; then  # hydra-hook: reviewed-indirection (boolean flag, not a command name)
    rsync -a --files-from="$list" \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" \
      "$DEPLOY_PATH/"
  else
    rsync -az --files-from="$list" \
      -e "ssh -i $SSH_KEY ${SSH_OPTS[*]}" \
      "${RSYNC_EXCLUDES[@]}" \
      "$HYDRA_ROOT/" \
      "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
  fi
  rm -f "$list"
  if [[ -n "$DELTA_REMOVE" ]]; then
    printf '%s\n' "$DELTA_REMOVE" | sed '/^$/d' | _delta_on_server "$_DELTA_SERVER_DELETE_SH" "$DEPLOY_PATH" || return 1
  fi
  log "  Delta applied: $(printf '%s' "$DELTA_TRANSFER" | sed '/^$/d' | wc -l | tr -d ' ') path(s) written, $(printf '%s' "$DELTA_REMOVE" | sed '/^$/d' | wc -l | tr -d ' ') removed"
}
