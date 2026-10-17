#!/usr/bin/env bash
# attribute-deletions.sh — split the Deploy pre-flight verdict into "this PR
# caused it" (blocks) and "unrelated node-8 state" (warns). MUS-1390, child 5
# of MUS-1374.
#
# WHY. The pr-validate.yml `Deploy pre-flight` job dry-runs rsync --delete
# against the LIVE /opt/hydra tree and used to fail on ANY remaining deletion,
# so stray agent output on node-8 turned it red on every hydra PR no matter
# what the diff did. A check nobody can act on is ignored, and an ignored check
# stops carrying signal. Now it blocks only on deletions the PR's own diff
# causes (the author can fix those) and warns on the rest.
#
# WHAT STAYS AUTHORITATIVE. deploy.sh Step 4a (deletion-gate.sh, hydra#1117)
# halts the real deploy on ANY pending deletion. This lib only changes what a
# PR is blamed for; the warning says so, so nobody reads it as "safe to deploy".
#
# ATTRIBUTION. Paths the PR removes = `git diff --no-renames --diff-filter=D`
# against the base. --no-renames is deliberate: with rename detection on,
# `--name-only` prints only the NEW name of a renamed file, but the path rsync
# would delete from /opt/hydra is the OLD one. Without it a rename-away would
# be misread as unrelated server state and only warn. A `*deleting dir/` line
# is attributed when the PR removed anything under that dir.
#
# EXCLUDE CHANGES. A PR that removes or narrows an RSYNC_EXCLUDES entry in
# scripts/deploy.sh exposes matching server-only files to rsync --delete while
# git shows no removed path. Callers pass a 4th argument: the deletions rsync
# proposes under the BASE ref's excludes (base_exclude_deletions). A residual
# deletion absent from that baseline exists only because of the PR's own
# diff, so it is attributed to the PR.
#
# SHAPE. Pure function, no top-level side effects; bash 3.2-safe (no
# associative arrays), like the sibling gates in this directory.
#
# USAGE
#   . scripts/lib/attribute-deletions.sh
#   attribute_deletions <deletions-blob> <git-root> [<base-ref>=origin/main] [<baseline-blob>]
#   # <deletions-blob>: newline-delimited `*deleting <path>` lines (rsync
#   # --itemize-changes output filtered to '^\*deleting', after the
#   # classify-deletions auto-exclude).
#
# OUTPUT (stdout): GitHub annotations plus one `PR: <path>` / `OTHER: <path>`
# line per deletion.
#
# EXIT CODES
#   0 — no deletions, or every deletion is unrelated server state (warned).
#   1 — at least one deletion is caused by this PR's own diff (blocking).
#   2 — could not compute the PR's diff; fail closed.

attribute_deletions() {
  local deletions="${1-}" root="${2-}" base="${3:-origin/main}"
  local have_baseline=0 baseline=""
  if [[ $# -ge 4 ]]; then have_baseline=1; baseline="$4"; fi

  # GNU rsync (CI) prints `*deleting` + 3 spaces + the path; openrsync prints 1
  # space. Strip only that delimiter so a filename's own leading space survives.
  local paths
  paths=$(printf '%s\n' "$deletions" | sed -E -e 's/^\*deleting   //;t' -e 's/^\*deleting //' | grep . || true)
  [[ -n "$paths" ]] || return 0

  local removed
  if ! removed=$(git -C "$root" -c core.quotepath=false diff --no-renames --diff-filter=D --name-only "$base...HEAD" 2>&1); then
    echo "::error::cannot compute the paths this PR removes (git diff $base...HEAD failed) — refusing to attribute deletions: $removed"
    return 2
  fi

  # Paths the PR adds (or retypes). An added path that collides with a server
  # entry (file where a dir lives, or dir where a file lives) makes rsync delete
  # that entry; the baseline proposes the same deletion, so only this set sees it.
  local added
  if ! added=$(git -C "$root" -c core.quotepath=false diff --no-renames --diff-filter=AT --name-only "$base...HEAD" 2>&1); then
    echo "::error::cannot compute the paths this PR adds (git diff $base...HEAD failed) — refusing to attribute deletions: $added"
    return 2
  fi

  local pr_lines="" other_lines="" p
  while IFS= read -r p; do
    # Here-strings, not `printf | grep -q`: grep -q exits on the first match
    # while printf is still writing a large set, and under the CI step's
    # `set -o pipefail` the SIGPIPE (141) would flip a PR-caused deletion to OTHER.
    if grep -Fxq -- "$p" <<< "$removed" ||
      { [[ "$p" == */ ]] && awk -v d="$p" 'index($0, d) == 1 { f = 1 } END { exit !f }' <<< "$removed"; }; then
      pr_lines+="  PR: ${p}"$'\n'
    elif P="$p" awk 'BEGIN { p = ENVIRON["P"]; sub(/\/$/, "", p) }
        { a = $0; if (a == p || index(a, p "/") == 1) f = 1 }
        { q = p; while (sub(/\/[^\/]*$/, "", q)) if (q == $0) f = 1 }
        END { exit !f }' <<< "$added"; then
      pr_lines+="  PR: ${p}  (collides with a path the PR adds)"$'\n'
    elif [[ "$have_baseline" -eq 1 ]] &&
      ! P="$p" awk '{ if (!sub(/^\*deleting   /, "")) sub(/^\*deleting /, "") } $0 == ENVIRON["P"] { f = 1 } END { exit !f }' <<< "$baseline"; then
      # Not removed from git, yet rsync only proposes it under the PR's excludes.
      pr_lines+="  PR: ${p}  (newly exposed: the PR removes or narrows an RSYNC_EXCLUDES entry)"$'\n'
    else
      other_lines+="  OTHER: ${p}"$'\n'
    fi
  done <<< "$paths"

  if [[ -n "$pr_lines" ]]; then
    echo "::error::This PR's own diff removes or renames paths that exist in /opt/hydra/ — the deploy would delete them"
    echo
    echo "Paths this PR deletes (blocking):"
    printf '%s' "$pr_lines"
    echo "  → Intended removal: add an --exclude line to RSYNC_EXCLUDES in scripts/deploy.sh, or clean the file on node-8, before merge."
    echo "  → Not intended: restore the file in this PR."
    echo
  fi

  if [[ -n "$other_lines" ]]; then
    echo "::warning::/opt/hydra/ holds server state this PR did not cause; the deploy would delete it. Not blocking this PR — but NOT safe to deploy: deploy.sh Step 4a halts the real deploy on ANY pending deletion."
    echo
    echo "Unrelated server state (not caused by this PR's diff):"
    printf '%s' "$other_lines"
    echo
    echo "Each deletion means one of three things:"
    echo "  (a) Real data created on the server that the repo doesn't know about"
    echo "      → Pull it in: tracked file: scripts/sync-from-server.sh <target> --apply --only <path>;"
    echo "        a path the repo never tracked is NOT pulled by that script: scp it, review it (no secrets), git add <path>. Then commit"
    echo "  (b) Runtime state the server should own"
    echo "      → Either commit a seed file under the path (auto-exclude will then kick in)"
    echo "        OR add an --exclude line to RSYNC_EXCLUDES in scripts/deploy.sh"
    echo "  (c) Actual garbage left on the server"
    echo "      → Clean it up on node-8"
    echo "Owner of the node-8 cleanup: Nick."
  fi

  [[ -z "$pr_lines" ]]
}

# base_exclude_deletions <git-root> <dest> [<base-ref>=origin/main]
# Prints the `*deleting` lines rsync would produce from <git-root> into <dest>
# using the RSYNC_EXCLUDES array of <base-ref>:scripts/deploy.sh (same sed
# range and eval the CI step uses for the PR's array). rc 2 + ::error:: when
# the base array or the dry-run cannot be read: fail closed.
base_exclude_deletions() {
  local root="${1-}" dest="${2-}" base="${3:-origin/main}" decl
  if ! decl=$(git -C "$root" show "$base:scripts/deploy.sh" 2>&1); then
    echo "::error::cannot read $base:scripts/deploy.sh to compute the baseline deletions: $decl"
    return 2
  fi
  decl=$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' <<< "$decl")
  local declared
  declared=$(grep -cE '^[[:space:]]*--(exclude|include)=' <<< "$decl" || true)
  local RSYNC_EXCLUDES=()
  eval "$decl"
  if [[ "${#RSYNC_EXCLUDES[@]}" -ne "$declared" || "$declared" -lt 1 ]]; then
    echo "::error::baseline RSYNC_EXCLUDES extraction problem: eval'd ${#RSYNC_EXCLUDES[@]} entries but $base:scripts/deploy.sh declares $declared"
    return 2
  fi
  local out rc=0
  out=$(cd "$root" && rsync -an --delete --itemize-changes "${RSYNC_EXCLUDES[@]}" ./ "$dest/" 2>&1) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "::error::baseline rsync dry-run failed (exit $rc): $out"
    return 2
  fi
  grep '^\*deleting' <<< "$out" || true
}
