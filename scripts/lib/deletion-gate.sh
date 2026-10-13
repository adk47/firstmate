#!/usr/bin/env bash
# deletion-gate.sh — Step 4a's inverted deletion halt (MUS-1374 design).
#
# WHY. Today's Step 4a in deploy.sh only halts a pending `rsync --delete`
# when the deletion matches `workspaces/|skills-all/`; everything else —
# root-level money artifacts (payout reports, billing CSVs) and customer
# data (Intercom attachments) included — takes the `else` branch, logs a
# one-line warning, and is deleted with no backup. Verified live on the
# 28 Sep strays: 2 Stripe payout reports, a payout debug CSV, a payout
# workbook, and 2 customer Intercom attachments were all classified
# non-suspicious; only an unrelated workspaces/ file happened to halt that
# run. The fix inverts the default: ANY pending deletion halts, full stop.
#
# SHAPE. Matches the sibling gates in this directory (drift-check.sh,
# acknowledge-hot-patch-drift.sh): a pure function, no top-level side
# effects, no `log`/`fail` calls — the caller (deploy.sh's
# preflight_drift_check()) owns the halt and the HYDRA_FORCE override.
# No associative arrays — some hydra bats suites still run under bash 3.2.
#
# WIRING. Called from deploy.sh's preflight_drift_check(), which sources
# this lib and branches on this function's refusal (rc 1) to fail the
# deploy. The briefing text was carried out of deploy.sh into this lib and
# extended with root-level remedy guidance; the `workspaces/|skills-all/`
# suspicious-only filter is gone, so every deletion left after
# classify_workspace_deletions is routed here.
#
# USAGE
#   . scripts/lib/deletion-gate.sh
#   pending_deletion_briefing <deletions-blob>
#   # <deletions-blob>: newline-delimited `*deleting <path>` lines, the
#   # same shape as deploy.sh's $deletions (rsync --itemize-changes output
#   # filtered to '^\*deleting').
#
# EXIT CODES
#   0 — deletions-blob was empty; nothing to delete, no briefing printed.
#   1 — briefing printed on stdout; caller must halt (subject to its own
#       HYDRA_FORCE override).

pending_deletion_briefing() {
  local deletions="${1-}"

  local del_count
  del_count=$(printf '%s\n' "$deletions" | grep -c . || true)
  if (( del_count == 0 )); then
    return 0
  fi

  local paths
  paths=$(printf '%s\n' "$deletions" | sed -E 's/^\*deleting[[:space:]]*//')

  local shown overflow=""
  shown=$(printf '%s\n' "$paths" | head -30)
  if (( del_count > 30 )); then
    overflow="  ... ($((del_count - 30)) more)"
  fi

  local remedies=""
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    remedies+="  ${p}"$'\n'
    remedies+="    --exclude line:        --exclude=/${p}"$'\n'
    remedies+="    pre-commit entry:      \"/${p}\""$'\n'
  done <<< "$shown"

  cat <<DEL_BRIEFING
================================================================================
✗ DEPLOY BLOCKED — sync would delete server state
================================================================================

WHAT THIS MEANS:
  rsync --delete is about to remove files from /opt/hydra/ that exist
  on the server but NOT in the repo. There is no backup. This is no
  longer filtered to workspaces/ or skills-all/ — root-level files
  (payout reports, billing CSVs, Intercom attachments, any other money
  or customer data that accumulates at the repo root) halt exactly like
  a workspaces/ file always has.

FILES THAT WOULD BE DELETED ($del_count total):
$(printf '%s\n' "$shown" | sed 's/^/  /')
$overflow

THE ONLY SAFE FIX (do this, in order):
  1. For each path above, decide:
     (a) Is it real data? → Pull it into the repo. scripts/sync-from-server.sh
         pulls only files git already TRACKS, so a path the repo has never
         seen (every path listed above is one: it exists on node-8 and not
         in the pushed tree) is NOT pulled by it, and it refuses audit/
         outright. Capture it by hand and review it first (no secrets/tokens):
           scp -i "\$SSH_KEY" "\$NODE8_USER@\$NODE8_IP:$DEPLOY_PATH/<path>" ./<path>
           git add <path>
         (an already-tracked file only: sync-from-server.sh skills --apply --only <path>
          or workspaces --apply --only <path>; audit/* is gitignored: audit --apply,
          without --only.)
         NEVER bulk-pull workspaces/: 125 GB / 6.2M files on node-8,
         and a bare "skills --apply" clobbers your other skill edits.
         Then commit.
     (b) Is it runtime state we want server-owned? → Add the matching
         --exclude line to RSYNC_EXCLUDES at the top of scripts/deploy.sh
         (hoisted there because Step 0 also reads it), and the matching
         required_excludes entry in .githooks/pre-commit (Check 2 enforces
         RSYNC_EXCLUDES ⊇ required_excludes). Then re-run pre-commit:
           bash .githooks/pre-commit
         Per-path suggestions:
$remedies
  2. Re-run deploy. Pre-flight should now report clean.

WHEN BYPASSING IS ACTUALLY OK (HYDRA_FORCE=1):
  - You've individually verified every file in the list is regenerable
    or genuinely garbage, AND
  - You're certain no human or agent will need it again.

  If you're not sure, STOP. Pull first.
================================================================================
DEL_BRIEFING

  return 1
}
