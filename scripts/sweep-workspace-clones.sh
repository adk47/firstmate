#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Stale agent-clone sweeper (node-8)
#
# Agents (CTO, DevOps, coordinator, …) clone repos for triage/PR
# work into /opt/hydra/workspaces/repos/ and workspaces/*/tmp/,
# and nothing ever cleans them: both paths are RSYNC_EXCLUDES in
# deploy.sh, so deploys never touch them. Survey 2026-07-23: 90
# clones / 26GB under repos/, 296 dirs / ~9GB under */tmp — many
# frozen at revisions from before merged fixes (they were the
# false-positive wall in the PR #737 deploy verification).
#
# Policy — delete a candidate ONLY if ALL hold:
#   • past TTL: repos/ 14d, */tmp + */.tmp 7d, where age = newest
#     mtime of anything in the tree EXCLUDING .git/ (git probes and
#     fetches bump .git internals; only worktree writes mean "in use")
#   • not on the keep-list (exact basename match, repos/ lane only)
#   • git-clean AND fully pushed: status --porcelain empty,
#     `git log --all --not --remotes` empty (--all covers detached
#     HEAD, tags, and the newest stash), `git stash list` empty,
#     every local branch has a same-named remote ref, and every
#     local tag exists on origin (ls-remote; ref NAMES and annotated
#     tag objects are data too, not just commits)
#
# Everything else lands in a fail-closed HELD lane (reported, never
# deleted): dirty/unpushed/stashed, git-probe-failed (a git error is
# never treated as "clean" — includes any future safe.directory
# refusal; today all clones are root-owned and we run as root),
# .git-is-a-file (linked worktree/submodule), nested inner repo,
# no-remote scratch repos, mountpoint-under-candidate.
# A TTL-expired dir with NO .git at all is plain junk: deleted by
# mtime alone (covers rsync'd non-git trees and half-deleted wrecks).
#
# Probes run with GIT_OPTIONAL_LOCKS=0 so `git status` never writes
# .git/index. Pre-rm recheck refuses in-progress operations
# (index.lock / MERGE_HEAD / rebase-*) and any write inside the
# fresh-window. rm is contained: symlink candidates are unlinked
# (never followed), mountpoints are skipped, --one-file-system.
#
# Invoked weekly with --apply by scripts/weekly-cleanup.sh
# (hydra-weekly-cleanup.timer, Mon 04:30 UTC); also human-runnable.
# Posts a Block Kit summary to #clio_devops on apply runs.
#
# Exit contract (mirrors weekly-cleanup.sh):
#   0  normal run — per-entry rm errors are counted + reported
#   1  structural refusal (root missing/symlinked/suspicious)
#   2  usage error / missing dependency
#
# Flags:
#   --apply     actually delete (default is a full dry-run walk)
#   --dry-run   explicit no-op mode (the default)
#
# Env knobs (mainly for tests — defaults target production):
#   SWEEP_REPOS_ROOT        default /opt/hydra/workspaces/repos
#   SWEEP_WS_ROOT           default /opt/hydra/workspaces
#   SWEEP_REPOS_TTL_DAYS    default 14
#   SWEEP_TMP_TTL_DAYS      default 7
#   SWEEP_KEEP_LIST         space-separated basenames under repos/;
#                           REPLACES the default list when set
#   SWEEP_FRESH_WINDOW_SECS default 3600 (pre-rm recheck window)
#   SWEEP_LOCKFILE          single-run lock (apply mode)
#   SWEEP_SLACK_CHANNEL     default C0ADV2W76G4 (#clio_devops)
#   SWEEP_SKIP_HOST_GUARD   1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[sweep-clones $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
REPOS_ROOT="${SWEEP_REPOS_ROOT:-/opt/hydra/workspaces/repos}"
WS_ROOT="${SWEEP_WS_ROOT:-/opt/hydra/workspaces}"
REPOS_TTL_DAYS="${SWEEP_REPOS_TTL_DAYS:-14}"
TMP_TTL_DAYS="${SWEEP_TMP_TTL_DAYS:-7}"
FRESH_WINDOW_SECS="${SWEEP_FRESH_WINDOW_SECS:-3600}"
LOCKFILE="${SWEEP_LOCKFILE:-/var/run/hydra-sweep-clones.lock}"
SKIP_HOST_GUARD="${SWEEP_SKIP_HOST_GUARD:-0}"
APPLY=0

# Canonical long-lived working clones agents reuse across tasks
# (cto-codex-coding, cto-nightly-issue-fixer, devops SOUL).
if [ -n "${SWEEP_KEEP_LIST:-}" ]; then
  read -r -a KEEP_LIST <<< "$SWEEP_KEEP_LIST"
else
  KEEP_LIST=(
    hydra core-backend H-DevOps muso-cli web-credits
    industry-data-processing platform-data-processing
    analytics-worker hydra-nightly tests-web-e2e
  )
fi

export SLACK_CHANNEL="${SWEEP_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Garbage TTLs must fail loud, not silently sweep nothing (or everything):
# bash arithmetic treats a non-numeric var as 0 → cutoff = now → no-op.
for ttl_var in REPOS_TTL_DAYS TMP_TTL_DAYS FRESH_WINDOW_SECS; do
  case "${!ttl_var}" in
    ''|*[!0-9]*) echo "invalid $ttl_var='${!ttl_var}' — must be a non-negative integer" >&2; exit 2 ;;
  esac
done

_SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_SWEEP_DIR/lib/slack-notify.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required"; exit 2; }
command -v git >/dev/null 2>&1 || { log "ERROR: git required"; exit 2; }

NOW_EPOCH="$(date +%s)"

swept=0; freed_kb=0; junk_deleted=0; active=0; kept=0; rm_errors=0
held_dirty=0; held_probe=0; held_gitfile=0; held_nested=0
held_noremote=0; held_mount=0; held_inuse=0

HELD_FILE="$(mktemp)"
ERRORS_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$HELD_FILE" "$ERRORS_FILE" "$PAYLOAD_FILE"' EXIT

# ── guards lifted from weekly-cleanup.sh (normalization hardened) ────
# Strip ALL trailing slashes ('' if the input was only slashes) so forms
# like '//' cannot dodge the broad-root refusal below.
normalize_root() {
  local root="$1"
  while [ "$root" != "${root%/}" ]; do root="${root%/}"; done
  printf '%s' "$root"
}

guard_root() {
  local root="$1"
  if [ -z "$root" ] || [ "$root" = "/" ]; then
    log "FATAL: refusing to run with root='$root'"; exit 1
  fi
  if [ -L "$root" ]; then
    log "FATAL: swept root is a symlink: $root"; exit 1
  fi
  if [ ! -d "$root" ]; then
    log "FATAL: swept root is not a directory: $root"; exit 1
  fi
  local rp
  rp="$(realpath -- "$root" 2>/dev/null)" || { log "FATAL: realpath failed for $root"; exit 1; }
  if [ "$rp" != "$root" ]; then
    log "FATAL: swept root resolves elsewhere ($root -> $rp)"; exit 1
  fi
}

# True if $1 IS a mountpoint or any mountpoint lives under it. The exact-match
# case matters: rm --one-file-system treats a command-line argument that is
# itself a mountpoint as that filesystem's root and would wipe its contents.
# SWEEP_MOUNTS_FILE overrides the mounts table for hermetic tests.
MOUNTS_FILE="${SWEEP_MOUNTS_FILE:-/proc/self/mounts}"
mount_hazard() {
  # Cannot inspect the mount table → cannot prove absence of a mount → hazard.
  [ -r "$MOUNTS_FILE" ] || return 0
  # The kernel octal-escapes whitespace in mount paths (' ' → \040): decode
  # before comparing, or a mount named "old clone" is invisible to the guard.
  # The candidate path rides in via ENVIRON — awk -v would itself interpret
  # backslash escapes, corrupting a path that literally contains one.
  MH_P="$1" awk '
    {
      m = $2
      gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m)
      gsub(/\\012/, "\n", m); gsub(/\\134/, "\\", m)
      if (m == ENVIRON["MH_P"]) found = 1
      if (index(m, ENVIRON["MH_P"] "/") == 1) found = 1
    }
    END { exit found ? 0 : 1 }' "$MOUNTS_FILE"
}

entry_kb() {
  local kb
  kb="$(du -skx -- "$1" 2>/dev/null | awk '{print $1}' || true)"
  echo "${kb:-0}"
}

# GNU rm has --one-file-system (prod / CI); BSD rm (dev laptops) does not.
# The has_mount_under skip is the primary rail either way — this is backstop.
RM_ONEFS=()
if rm --one-file-system -rf "$(mktemp -d)" 2>/dev/null; then
  RM_ONEFS=(--one-file-system)
fi

is_kept() {
  local name="$1" k
  for k in "${KEEP_LIST[@]}"; do
    [ "$name" = "$k" ] && return 0
  done
  return 1
}

hold() {  # hold <lane> <path> <detail>
  echo "$1 $2 — $3" >> "$HELD_FILE"
  log "held ($1): $2 — $3"
}

# Reference files carrying the cutoff mtimes: `find -newer <ref>` is portable
# (GNU find's -newermt "@epoch" is not), and a ref file can't be mis-parsed.
epoch_to_stamp() {  # <epoch> -> touch -t stamp
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S
}
make_ref() {  # <epoch> -> path of a file whose mtime is that epoch
  local f
  f="$(mktemp)"
  touch -t "$(epoch_to_stamp "$1")" "$f"
  echo "$f"
}

# Any write in the tree (excluding .git/) newer than the ref file?
# A failed find is treated as FRESH — the age rail must fail safe, not open.
tree_fresh_since() {  # <dir> <ref-file>
  local out rc=0
  out="$(find "$1" -xdev -path "$1/.git" -prune -o -newer "$2" -print -quit 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] && return 0
  [ -n "$out" ]
}

# Portable mtime epoch (GNU stat -c, BSD stat -f); unknown → now (fail-safe).
mtime_epoch() {
  stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo "$NOW_EPOCH"
}

remove_entry() {  # <path> <kb> <label>
  local p="$1" kb="$2" label="$3" err rm_cmd
  if [ "$APPLY" -eq 0 ]; then
    log "DRY-RUN: would delete $label $p (${kb} KB)"
    return 0
  fi
  rm_cmd=(rm -f --)
  if [ ! -L "$p" ] && [ -d "$p" ]; then
    # ${arr[@]+...}: safe under set -u with an empty array on bash 3.2 (macOS dev).
    rm_cmd=(rm -rf ${RM_ONEFS[@]+"${RM_ONEFS[@]}"} --)
  fi
  err="$("${rm_cmd[@]}" "$p" 2>&1)" || {
    rm_errors=$((rm_errors + 1))
    echo "rm failed: $p: ${err:0:200}" >> "$ERRORS_FILE"
    return 1
  }
  log "deleted $label $p (${kb} KB)"
}

# ── per-candidate policy ─────────────────────────────────────
sweep_candidate() {  # <path> <cutoff-epoch> <cutoff-ref-file> <lane:repos|tmp>
  local d="$1" cutoff="$2" ref="$3" lane="$4"
  local name kb head_sha probe_out rc
  name="$(basename "$d")"

  # A depth-1 .git means the swept ROOT is itself a clone worktree — never
  # treat its metadata (or, by extension, this root) as junk.
  if [ "$name" = ".git" ]; then
    held_gitfile=$((held_gitfile + 1))
    hold "clone-root" "$d" "swept root itself looks like a git clone"
    return 0
  fi

  # Symlinks and plain files: never followed; junk-aged by own mtime.
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    if [ "$(mtime_epoch "$d")" -lt "$cutoff" ]; then
      kb="$(entry_kb "$d")"
      if remove_entry "$d" "$kb" "entry"; then
        junk_deleted=$((junk_deleted + 1)); freed_kb=$((freed_kb + kb))
      fi
    else
      active=$((active + 1))
    fi
    return 0
  fi

  if [ "$lane" = "repos" ] && is_kept "$name"; then
    kept=$((kept + 1))
    log "kept (keep-list): $d"
    return 0
  fi

  if [ -f "$d/.git" ]; then
    held_gitfile=$((held_gitfile + 1))
    hold "gitfile" "$d" ".git is a file (linked worktree/submodule)"
    return 0
  fi

  # No .git at all → plain junk, mtime-only policy on the whole tree —
  # UNLESS a repo hides anywhere inside (tmp/build/checkout/.git): a nested
  # clone with unique work must never ride out on the junk lane. A failed
  # scan holds too (cannot prove absence → cannot delete).
  if [ ! -e "$d/.git" ]; then
    local inner rc_inner=0
    inner="$(find "$d" -xdev -name .git -print -quit 2>/dev/null)" || rc_inner=$?
    if [ "$rc_inner" -ne 0 ] || [ -n "$inner" ]; then
      held_nested=$((held_nested + 1))
      hold "nested" "$d" "${inner:+repo at $inner inside a non-git tree}${inner:-nested-repo scan failed}"
      return 0
    fi
    if tree_fresh_since "$d" "$ref"; then
      active=$((active + 1)); return 0
    fi
    if mount_hazard "$d"; then
      held_mount=$((held_mount + 1)); hold "mount" "$d" "mountpoint at or under candidate"; return 0
    fi
    # du over a large tree takes time — re-run every junk-lane guard right
    # before removal so nothing created during the size scan is deleted.
    kb="$(entry_kb "$d")"
    rc_inner=0
    inner="$(find "$d" -xdev -name .git -print -quit 2>/dev/null)" || rc_inner=$?
    if [ "$rc_inner" -ne 0 ] || [ -n "$inner" ]; then
      held_nested=$((held_nested + 1)); hold "nested" "$d" "repo appeared during size scan"; return 0
    fi
    if tree_fresh_since "$d" "$ref"; then
      active=$((active + 1)); return 0
    fi
    if mount_hazard "$d"; then
      held_mount=$((held_mount + 1)); hold "mount" "$d" "mountpoint at or under candidate"; return 0
    fi
    if remove_entry "$d" "$kb" "junk"; then
      junk_deleted=$((junk_deleted + 1)); freed_kb=$((freed_kb + kb))
    fi
    return 0
  fi

  # Git clone lanes.
  if tree_fresh_since "$d" "$ref"; then
    active=$((active + 1)); return 0
  fi
  if mount_hazard "$d"; then
    held_mount=$((held_mount + 1)); hold "mount" "$d" "mountpoint at or under candidate"; return 0
  fi
  if [ -n "$(find "$d" -xdev -mindepth 2 -name .git -print -quit 2>/dev/null)" ]; then
    held_nested=$((held_nested + 1)); hold "nested" "$d" "inner repo present"; return 0
  fi

  # Git probes — a failed probe is NEVER "clean" (fail closed).
  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" remote 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "git remote: ${probe_out:0:120}"; return 0
  fi
  if [ -z "$probe_out" ]; then
    held_noremote=$((held_noremote + 1)); hold "no-remote" "$d" "no remotes configured"; return 0
  fi

  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" status --porcelain 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "git status: ${probe_out:0:120}"; return 0
  fi
  if [ -n "$probe_out" ]; then
    held_dirty=$((held_dirty + 1)); hold "dirty" "$d" "$(echo "$probe_out" | wc -l | tr -d ' ') dirty path(s)"; return 0
  fi

  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" log --all --not --remotes --oneline 2>&1 | head -5)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "git log: ${probe_out:0:120}"; return 0
  fi
  if [ -n "$probe_out" ]; then
    held_dirty=$((held_dirty + 1)); hold "unpushed" "$d" "commits not on any remote"; return 0
  fi

  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" stash list 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "git stash: ${probe_out:0:120}"; return 0
  fi
  if [ -n "$probe_out" ]; then
    held_dirty=$((held_dirty + 1)); hold "stash" "$d" "stash entries present"; return 0
  fi

  # Ref parity, by NAME and OBJECT, against the LIVE server: commit
  # reachability (above) is not ref safety — a local branch or tag whose
  # exact (name, object-id) pair is not on the server right now still loses
  # its pointer (and an annotated tag its message object) on deletion.
  # Cached refs/remotes/* are NOT proof: a branch deleted server-side after
  # the clone's last fetch leaves a stale tracking ref that vouches for
  # itself. One ls-remote snapshot covers heads and tags; it is network, but
  # only candidates that survived every other gate reach this, and any
  # failure holds — never passes.
  local live_refs local_refs bad_ref refsha refname live_sha live_unreachable
  rc=0; live_refs="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" ls-remote origin 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "git ls-remote: ${live_refs:0:120}"; return 0
  fi
  rc=0; local_refs="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" for-each-ref refs/heads refs/tags --format='%(objectname) %(refname)' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "git for-each-ref: ${local_refs:0:120}"; return 0
  fi
  # Tags: exact (sha, refname) live match — tags are immutable by
  # convention, and an annotated tag OBJECT differing from origin's is data.
  # Branches: BOTH conditions —
  #   (a) a cached same-named refs/remotes/*/<name> at the SAME sha (a
  #       diverged local pointer whose tip is merely reachable elsewhere
  #       must hold), and
  #   (b) the name exists on the LIVE server (a branch deleted server-side
  #       after the last fetch leaves a stale tracking ref vouching for
  #       itself — cached refs alone are not proof).
  # Live exact-sha parity for branches would hold every stale clone forever
  # (a stale local main is always behind the live main); (a)+(b) keeps the
  # pointer-safety contract without reducing the sweeper to a no-op.
  bad_ref=""
  while IFS=' ' read -r refsha refname; do
    [ -n "$refname" ] || continue
    case "$refname" in
      refs/tags/*)
        if ! printf '%s\n' "$live_refs" \
            | awk -v s="$refsha" -v r="$refname" '$1 == s && $2 == r { found = 1 } END { exit found ? 0 : 1 }'; then
          bad_ref="$refname"; break
        fi ;;
      *)
        if ! GIT_OPTIONAL_LOCKS=0 git -C "$d" for-each-ref "refs/remotes/*/${refname#refs/heads/}" --format='%(objectname)' 2>/dev/null \
            | grep -qxF -- "$refsha"; then
          bad_ref="$refname"; break
        fi
        live_sha="$(printf '%s\n' "$live_refs" | awk -v r="$refname" '$2 == r { print $1; exit }')"
        if [ -z "$live_sha" ]; then
          bad_ref="$refname"; break
        fi ;;
    esac
  done <<< "$local_refs"

  # Live reachability for EVERY locally retained commit — HEAD included, so
  # a detached HEAD backed only by a stale cached tracking ref (its server
  # branch force-pushed or deleted) can never be lost. One namespace fetch
  # of all live heads, then any commit reachable from --all (HEAD, branches,
  # tags, stash tip, cached remotes) but not from the live snapshot holds.
  live_unreachable=""
  if [ -z "$bad_ref" ]; then
    # A sweep killed after fetching leaves stale refs/sweep-live/* that the
    # --glob check below would trust as live proof: clear the namespace
    # BEFORE fetching, fail-closed, and fetch with pruning as the belt.
    if ! GIT_OPTIONAL_LOCKS=0 git -C "$d" for-each-ref refs/sweep-live --format='%(refname)' 2>/dev/null \
        | while IFS= read -r stale_ref; do
            git -C "$d" update-ref -d "$stale_ref" || exit 1
          done; then
      live_unreachable="probe-failed: could not clear stale sweep-live refs"
    elif ! GIT_OPTIONAL_LOCKS=0 git -C "$d" fetch --quiet --prune origin '+refs/heads/*:refs/sweep-live/heads/*' 2>/dev/null; then
      live_unreachable="fetch-failed"
    else
      rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" log --all --not --glob='refs/sweep-live' --oneline 2>&1 | head -3)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        live_unreachable="probe-failed: ${probe_out:0:100}"
      elif [ -n "$probe_out" ]; then
        live_unreachable="commits not reachable from live origin"
      fi
    fi
  fi
  # Drop the isolated-namespace refs whatever the outcome (a held clone must
  # not accumulate sweep artifacts; fetched objects are unreferenced and gc-able).
  GIT_OPTIONAL_LOCKS=0 git -C "$d" for-each-ref refs/sweep-live --format='%(refname)' 2>/dev/null \
    | while IFS= read -r stale_ref; do
        git -C "$d" update-ref -d "$stale_ref" 2>/dev/null || true
      done
  if [ -n "$bad_ref" ]; then
    held_dirty=$((held_dirty + 1))
    case "$bad_ref" in
      refs/tags/*) hold "local-tag" "$d" "'${bad_ref#refs/tags/}' is absent from origin or at a different object" ;;
      *) hold "local-branch" "$d" "'${bad_ref#refs/heads/}' diverges from its tracking ref or is gone from origin (live)" ;;
    esac
    return 0
  fi
  if [ -n "$live_unreachable" ]; then
    case "$live_unreachable" in
      fetch-failed|probe-failed*)
        held_probe=$((held_probe + 1)); hold "probe-fail" "$d" "live-reachability: $live_unreachable" ;;
      *)
        held_dirty=$((held_dirty + 1)); hold "unpushed-live" "$d" "$live_unreachable" ;;
    esac
    return 0
  fi

  # Pre-rm recheck: in-progress operations and last-minute writes.
  if [ -e "$d/.git/index.lock" ] || [ -e "$d/.git/MERGE_HEAD" ] \
     || [ -e "$d/.git/rebase-merge" ] || [ -e "$d/.git/rebase-apply" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$d" "git operation in progress"; return 0
  fi
  if tree_fresh_since "$d" "$WINDOW_REF"; then
    active=$((active + 1)); return 0
  fi

  # Size and display sha are computed BEFORE the final audit: du over a
  # multi-GB clone takes seconds, and nothing may widen the audit→rm window.
  local audit_head
  audit_head="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse HEAD 2>/dev/null || echo unresolvable)"
  head_sha="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  kb="$(entry_kb "$d")"

  # A clean checkout during du moves HEAD to another pushed commit and
  # freshens the worktree without touching status/stash/refs/unpushed —
  # re-check worktree freshness and HEAD position as part of the audit.
  if tree_fresh_since "$d" "$WINDOW_REF"; then
    active=$((active + 1)); return 0
  fi
  if [ "$audit_head" != "$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse HEAD 2>/dev/null || echo re-unresolvable)" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$d" "HEAD moved between audit and removal"; return 0
  fi

  # TOCTOU rail: the live-network probes above widen the audit→rm window,
  # and the .git-pruned freshness rail cannot see git-only writes (a new
  # ref, stash, or index change made by a concurrent writer mid-sweep).
  # Re-audit the local git state and require it UNCHANGED before removal.
  local recheck
  rc=0; recheck="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" status --porcelain 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$recheck" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$d" "worktree changed between audit and removal"; return 0
  fi
  rc=0; recheck="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" stash list 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$recheck" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$d" "stash appeared between audit and removal"; return 0
  fi
  rc=0; recheck="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" for-each-ref refs/heads refs/tags --format='%(objectname) %(refname)' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$recheck" != "$local_refs" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$d" "refs changed between audit and removal"; return 0
  fi
  # A concurrent detached-HEAD commit changes only HEAD + objects (clean
  # status, no refs) — re-run the unpushed-content probe, which includes
  # HEAD via --all, so such a commit can never be deleted with the clone.
  rc=0; recheck="$(GIT_OPTIONAL_LOCKS=0 git -C "$d" log --all --not --remotes --oneline 2>&1 | head -1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$recheck" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$d" "unpushed commit appeared between audit and removal"; return 0
  fi

  if remove_entry "$d" "$kb" "clone (HEAD $head_sha)"; then
    swept=$((swept + 1)); freed_kb=$((freed_kb + kb))
  fi
}

sweep_root_depth1() {  # <root> <cutoff-epoch> <cutoff-ref-file> <lane>
  local root="$1" cutoff="$2" ref="$3" lane="$4" p
  while IFS= read -r -d '' p; do
    sweep_candidate "$p" "$cutoff" "$ref" "$lane"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

print_summary() {
  log "swept_clones=$swept junk=$junk_deleted freed_kb=$freed_kb"
  log "active_skipped=$active kept=$kept rm_errors=$rm_errors"
  log "held: dirty/unpushed/stash=$held_dirty probe-fail=$held_probe gitfile=$held_gitfile nested=$held_nested no-remote=$held_noremote mount=$held_mount in-use=$held_inuse"
}

build_payload() {
  SWEPT="$swept" JUNK="$junk_deleted" FREED_KB="$freed_kb" ACTIVE="$active" \
  KEPT="$kept" RM_ERRORS="$rm_errors" HELD_DIRTY="$held_dirty" \
  HELD_PROBE="$held_probe" HELD_GITFILE="$held_gitfile" HELD_NESTED="$held_nested" \
  HELD_NOREMOTE="$held_noremote" HELD_MOUNT="$held_mount" HELD_INUSE="$held_inuse" \
  HELD_FILE="$HELD_FILE" ERRORS_FILE="$ERRORS_FILE" PAYLOAD_OUT="$PAYLOAD_FILE" \
  REPOS_TTL="$REPOS_TTL_DAYS" TMP_TTL="$TMP_TTL_DAYS" \
  SLACK_CHANNEL="$SLACK_CHANNEL" python3 - <<'PYEOF'
import json, os

e = os.environ
ints = {k: int(e[k]) for k in (
    "SWEPT", "JUNK", "FREED_KB", "ACTIVE", "KEPT", "RM_ERRORS", "HELD_DIRTY",
    "HELD_PROBE", "HELD_GITFILE", "HELD_NESTED", "HELD_NOREMOTE", "HELD_MOUNT",
    "HELD_INUSE")}
held_total = sum(ints[k] for k in ints if k.startswith("HELD_"))

def human(kb):
    if kb >= 1024 * 1024:
        return f"{kb / 1024 / 1024:.1f} GB"
    if kb >= 1024:
        return f"{kb / 1024:.1f} MB"
    return f"{kb} KB"

text = (
    f":broom: clone-sweep node-8 — freed {human(ints['FREED_KB'])} | "
    f"clones={ints['SWEPT']} junk={ints['JUNK']} | held={held_total} | "
    f"errors={ints['RM_ERRORS']}"
)

blocks = [
    {"type": "header", "text": {"type": "plain_text", "text": "workspace clone sweep — node-8"}},
    {"type": "section", "fields": [
        {"type": "mrkdwn", "text": f"*Freed:*\n{human(ints['FREED_KB'])}"},
        {"type": "mrkdwn", "text": f"*Deleted:*\n{ints['SWEPT']} clones · {ints['JUNK']} junk (repos >{e['REPOS_TTL']}d, tmp >{e['TMP_TTL']}d)"},
        {"type": "mrkdwn", "text": f"*Skipped:*\n{ints['ACTIVE']} active · {ints['KEPT']} keep-list"},
        {"type": "mrkdwn", "text": f"*Held (never deleted):*\n{held_total} — dirty/unpushed {ints['HELD_DIRTY']}, probe-fail {ints['HELD_PROBE']}, worktree {ints['HELD_GITFILE']}, nested {ints['HELD_NESTED']}, no-remote {ints['HELD_NOREMOTE']}, mount {ints['HELD_MOUNT']}, in-use {ints['HELD_INUSE']}"},
    ]},
]

if held_total:
    try:
        with open(e["HELD_FILE"]) as f:
            lines = [l.rstrip() for l in f if l.strip()][:10]
    except Exception:
        lines = []
    detail = "\n".join(f"• {l}" for l in lines) or "(no detail captured)"
    more = held_total - len(lines)
    if more > 0:
        detail += f"\n… and {more} more (see /var/log/hydra-weekly-cleanup.log)"
    blocks.append({"type": "section", "text": {
        "type": "mrkdwn", "text": f":file_folder: held for human review:\n{detail}"}})

if ints["RM_ERRORS"]:
    try:
        with open(e["ERRORS_FILE"]) as f:
            lines = [l.rstrip() for l in f if l.strip()][:10]
    except Exception:
        lines = []
    detail = "\n".join(f"• {l}" for l in lines) or "(no detail captured)"
    blocks.append({"type": "section", "text": {
        "type": "mrkdwn", "text": f":warning: {ints['RM_ERRORS']} rm error(s):\n{detail}"}})

with open(e["PAYLOAD_OUT"], "w") as f:
    json.dump({"channel": e["SLACK_CHANNEL"], "text": text, "blocks": blocks}, f)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

# Normalize BEFORE guarding, and sweep the normalized values — the guard's
# checks must apply to the exact strings the sweep will use.
REPOS_ROOT="$(normalize_root "$REPOS_ROOT")"
WS_ROOT="$(normalize_root "$WS_ROOT")"
guard_root "$REPOS_ROOT"
guard_root "$WS_ROOT"

if [ "$APPLY" -eq 1 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another sweep run holds $LOCKFILE"; exit 0; }
fi

REPOS_CUTOFF=$(( NOW_EPOCH - REPOS_TTL_DAYS * 86400 ))
TMP_CUTOFF=$(( NOW_EPOCH - TMP_TTL_DAYS * 86400 ))
REPOS_REF="$(make_ref "$REPOS_CUTOFF")"
TMP_REF="$(make_ref "$TMP_CUTOFF")"
WINDOW_REF="$(make_ref "$(( NOW_EPOCH - FRESH_WINDOW_SECS ))")"
trap 'rm -f "$HELD_FILE" "$ERRORS_FILE" "$PAYLOAD_FILE" "$REPOS_REF" "$TMP_REF" "$WINDOW_REF"' EXIT

# A swept root that is ITSELF a clone (someone ran `git clone repo .` in it)
# must be skipped whole: its depth-1 entries are that clone's worktree files.
root_is_clone() { [ -e "$1/.git" ]; }

if root_is_clone "$REPOS_ROOT"; then
  log "FATAL: $REPOS_ROOT is itself a git clone — refusing to sweep it"; exit 1
fi

sweep_root_depth1 "$REPOS_ROOT" "$REPOS_CUTOFF" "$REPOS_REF" "repos"
for ws_tmp in "$WS_ROOT"/*/tmp "$WS_ROOT"/*/.tmp; do
  [ -d "$ws_tmp" ] || continue
  [ -L "$ws_tmp" ] && continue
  # A symlinked intermediate (workspaces/x -> elsewhere) must not pull an
  # out-of-scope tree into the sweep: the resolved path stays under WS_ROOT.
  ws_tmp_real="$(realpath -- "$ws_tmp" 2>/dev/null)" || continue
  case "$ws_tmp_real" in "$WS_ROOT"/*) ;; *) continue ;; esac
  # repos/ is a sibling of the agent workspaces; never double-sweep it.
  case "$ws_tmp" in "$REPOS_ROOT"/*) continue ;; esac
  if root_is_clone "$ws_tmp"; then
    hold "clone-root" "$ws_tmp" "tmp root is itself a git clone — skipped whole"
    held_gitfile=$((held_gitfile + 1))
    continue
  fi
  sweep_root_depth1 "$ws_tmp" "$TMP_CUTOFF" "$TMP_REF" "tmp"
done

print_summary

if [ "$APPLY" -eq 0 ]; then
  log "DRY-RUN: no deletions, no Slack post."
  exit 0
fi

build_payload
log "Posting summary to ${SLACK_CHANNEL}."
slack_notify_payload_file "$PAYLOAD_FILE"
