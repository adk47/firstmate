#!/usr/bin/env bash
set -euo pipefail

# qa-bundle-diff-fallback.sh — recover per-file patches that GitHub's REST
# files endpoint truncated to nothing, by computing them from a real git
# clone instead of trusting GitHub's payload.
# =============================================================================
# muso-cli's `gh review-bundle` (muso-cli#50/#51, shipped v0.13.2/.3) already
# has a first-level fallback: when the whole-PR diff blows GitHub's 20,000-line
# cap, it reassembles `diff` from the paginated `pulls/<n>/files` per-file
# `patch` field. That works IF the files endpoint actually carries a patch.
#
# It doesn't always. GitHub also truncates the FILES payload itself on very
# large PRs (observed live: Muso-AI/web-credits-next#848 @ 6b88f447, 327 files,
# +37k/-11k — 17 of 327 files came back `additions=0, deletions=0, changes=0,
# patch=null`). The bundle's `diffFallbackFromFiles` cannot tell that shape
# apart from a genuine binary (which reports the exact same
# additions=0/deletions=0/patch=null), so all 17 are silently classed as
# "binary, nothing lost" and never appear in `diffDegraded.filesWithoutPatch`
# — the bot reported "327/327 files, no degradation" while 17 files' content
# was invisible to it. That is the bug this script exists to close: GitHub
# refusing to serve a file's patch is not proof the file has no reviewable
# text, and the only way to find out is to ask git directly instead of GitHub.
#
# THE PRINCIPLE: never trust "no patch" from the GitHub API as "nothing
# changed" when a fetch of the real objects can confirm or refute it. This
# script fetches base and head into a throwaway shallow-ish clone and computes
# `git diff <merge-base>..<head> -- <path>` for exactly the files the bundle
# could not otherwise account for. Binary files still resolve to "binary, no
# text lost" — but now because `git diff --numstat` itself says so (`-\t-`),
# not because GitHub's zeroed counters said so.
#
# Usage:
#   qa-bundle-diff-fallback.sh <owner/repo> <base-sha> <head-sha> <path...>
#
# stdin is NOT read. Paths are positional args (argv, not one-per-line stdin)
# so a filename containing a newline can never be split into two arguments —
# see quoteDiffPath in muso-cli's diffFallbackFromFiles for the same class of
# hostile-path trap on the encoding side.
#
# Paths are matched LITERALLY (git --literal-pathspecs), never as globs. A
# path containing `[`, `]`, `*`, `?` etc (e.g. Next.js's `src/app/[id]/
# page.tsx` — web-credits-next@85fa8c76 has 150 such paths) is otherwise
# interpreted as a glob by `git diff -- <path>`, silently pulling in an
# unrelated file's diff under the requested file's name (QA round 1, finding
# 3: `src/app/[id]/page.tsx` returned a diff blob containing BOTH that file's
# changes AND `src/app/i/page.tsx`'s). --literal-pathspecs is a top-level
# git flag (must precede the subcommand), applies for the whole invocation,
# and is combined with core.quotepath=false via -c, not a competing flag.
#
# Output (stdout, one JSON object, always — even on total failure):
#   {
#     "recovered": [{"path":..., "diff":"<unified diff or \"\" for binary>",
#                    "binary": bool}],
#     "stillMissing": [{"path":..., "reason":"<short machine-readable tag>"}],
#     "cloneOk": bool,                 // false ⇒ recovered is always empty,
#                                       // every requested path is in stillMissing
#     "errors": ["<verbatim git/gh stderr line>", ...]
#                                       // every captured stderr line from a
#                                       // clone/fetch/resolve failure, so a
#                                       // caller posting CANNOT REVIEW can
#                                       // quote the real cause instead of a
#                                       // paraphrase. Per-file diff errors are
#                                       // NOT duplicated here — they live on
#                                       // the specific stillMissing entry.
#   }
#
# A file lands in stillMissing (never in recovered) when: the clone/fetch
# failed entirely (cloneOk=false, every requested path gets reason "clone-
# failed"), the base or head sha could not be resolved (reason "sha-
# unresolved"), git itself could not compute the diff for that specific path
# — e.g. a failed on-demand blob fetch from a --filter=blob:none clone, rc=128
# — (reason "git-diff-failed", NOT silently read as "unchanged"; the
# invocation's stderr is attached), or git's diff genuinely reports no change
# for that path between merge-base and head (reason "no-change" — a real
# finding worth surfacing: GitHub said the file changed but git disagrees,
# e.g. a PR that rebased mid-review, not a silent success).
# CANNOT REVIEW is the caller's job to decide from stillMissing; this script
# only ever reports what git could/could not produce, and WHY.
#
# Exit code: ALWAYS 0. This is a best-effort recovery step consumed by an
# agent that must fail closed itself (CANNOT REVIEW) if recovery comes up
# short — a non-zero exit here would just make that harder to read. Every
# failure mode is instead visible in the JSON (cloneOk, stillMissing, errors).
#
# Env (mainly for tests):
#   QA_GH_SH         path to qa-gh.sh (default: ./qa-gh.sh next to this
#                    script). qa-gh.sh DOES support a `repo clone` passthrough
#                    (it execs `gh "$@"` for any args once identity is
#                    resolved — see qa-gh.sh:95-111), so there is no bare `gh`
#                    exception needed here; SKILL.md:98's "never bare gh"
#                    rule is honoured like every other call site.
#   QA_BUNDLE_FALLBACK_WORKDIR   clone destination (default: a mktemp -d,
#                    removed on exit). Overridable so a test can inspect it.
#   QA_BUNDLE_FALLBACK_SKIP_CLONE=1   test seam: skip the network clone and
#                    operate on a repo QA_BUNDLE_FALLBACK_WORKDIR already
#                    points at (the caller is responsible for its base/head
#                    refs existing).
#   QA_BUNDLE_FALLBACK_FETCH_RETRIES   how many times to retry a failed
#                    `git fetch origin <sha>` (default 1 retry, i.e. up to 2
#                    attempts total) before giving up on that sha. A single
#                    transient network blip must not turn into a false
#                    CANNOT REVIEW on the exact PR this script exists to
#                    recover (QA round 1, finding 1).

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_GH_SH="${QA_GH_SH:-$_here/qa-gh.sh}"
FETCH_RETRIES="${QA_BUNDLE_FALLBACK_FETCH_RETRIES:-1}"
case "$FETCH_RETRIES" in
  ''|*[!0-9]*)
    echo "qa-bundle-diff-fallback: QA_BUNDLE_FALLBACK_FETCH_RETRIES='$FETCH_RETRIES' is not a non-negative integer — falling back to 1." >&2
    FETCH_RETRIES=1 ;;
esac

# ERRORS accumulates every captured git/gh stderr line touching the
# clone/fetch/resolve path (never per-file diff errors — those attach to
# their own stillMissing entry instead), so die_json and the final success
# path can both emit it verbatim. A plain bash array, not jq state: every
# early-exit path before the fetch stage has nothing to add to it, and after
# the fetch stage it is fixed for the rest of the run.
ERRORS=()

# Captures a command's stderr into $1 (its own local var name is passed as
# $1) AND appends every non-empty line of it to ERRORS, then returns the
# command's real exit code. Never lets stderr silently vanish into
# /dev/null the way the pre-fix script did (QA round 1, finding 1: the
# real cause of a clone/fetch failure was unrecoverable because stderr was
# discarded, even though a manual retry of the exact same command worked).
_run_capture() { # <errfile> <cmd...>
  local errfile="$1"; shift
  local rc=0
  "$@" 2>"$errfile" || rc=$?
  if [ -s "$errfile" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      [ -n "$_line" ] && ERRORS+=("$_line")
    done < "$errfile"
  fi
  return "$rc"
}

_errors_json() {
  if [ "${#ERRORS[@]}" -eq 0 ]; then
    printf '[]'
  else
    printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .
  fi
}

die_json() { # <missing-paths-json> <reason>
  # Always emit valid JSON even on a usage error, so a caller that blindly
  # pipes stdout to `jq` never gets an empty/invalid response to choke on.
  local paths_json="$1" reason="$2"
  jq -n --argjson missing "$paths_json" --arg reason "$reason" --argjson errors "$(_errors_json)" \
    '{recovered: [], stillMissing: ($missing | map({path: ., reason: $reason})), cloneOk: false, errors: $errors}'
  exit 0
}

if [ "$#" -lt 3 ]; then
  echo "qa-bundle-diff-fallback: usage: qa-bundle-diff-fallback.sh <owner/repo> <base-sha> <head-sha> <path...>" >&2
  die_json '[]' "usage-error"
fi

repo="$1"; base_sha="$2"; head_sha="$3"; shift 3

if [ "$#" -eq 0 ]; then
  # Nothing was asked for — a valid, boring call. Report cleanly rather than
  # dying, so a caller that computes an empty missing-set upstream doesn't
  # have to special-case "zero paths" before calling this script.
  jq -n --argjson errors "$(_errors_json)" '{recovered: [], stillMissing: [], cloneOk: true, errors: $errors}'
  exit 0
fi

# Build the JSON path array once, up front, so every early-exit path (repo
# format, sha format, clone failure) can report exactly the paths it failed
# on without re-deriving the list.
paths_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"

[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo "qa-bundle-diff-fallback: repo must be owner/name, got '$repo'" >&2; die_json "$paths_json" "usage-error"; }
[[ "$base_sha" =~ ^[0-9a-fA-F]{7,40}$ ]] \
  || { echo "qa-bundle-diff-fallback: base-sha must be a 7-40 char hex sha, got '$base_sha'" >&2; die_json "$paths_json" "usage-error"; }
[[ "$head_sha" =~ ^[0-9a-fA-F]{7,40}$ ]] \
  || { echo "qa-bundle-diff-fallback: head-sha must be a 7-40 char hex sha, got '$head_sha'" >&2; die_json "$paths_json" "usage-error"; }

CLEANUP_DIR=""
on_exit() { [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"; return 0; }
trap on_exit EXIT

if [ -n "${QA_BUNDLE_FALLBACK_WORKDIR:-}" ]; then
  WORKDIR="$QA_BUNDLE_FALLBACK_WORKDIR"
else
  WORKDIR="$(mktemp -d)"
  CLEANUP_DIR="$WORKDIR"
fi

ERRFILE="$(mktemp)"
clone_ok=1
if [ "${QA_BUNDLE_FALLBACK_SKIP_CLONE:-0}" != 1 ]; then
  clone_ok=0
  # --filter=blob:none: a partial clone that still resolves history/trees so
  # `git diff` and `git merge-base` work, but defers blob bytes to on-demand
  # fetch — the same trade the "shallow/--filter=blob:none clone" note in the
  # task calls for, cheaper than a full clone on a repo the size of
  # web-credits-next. No --depth: a shallow (depth-bounded) clone truncates
  # the merge-base walk (the exact trap check-blast-radius.sh's shallow-repo
  # guard exists for), and merge-base is load-bearing here — the whole point
  # is diffing against the PR's actual merge-base, not the two tips in
  # isolation, so history depth cannot be sacrificed the way blob bytes can.
  #
  # Routed through qa-gh.sh (`repo clone` passthrough, qa-gh.sh:95/111
  # `exec ... "$GH_BIN" "$@"` for any argv), not bare `gh` — SKILL.md:98
  # ("never bare gh anywhere") applies here exactly as everywhere else; the
  # cloning IS a read of repo content the QA App token's `contents: read`
  # grant already covers, and qa-gh.sh's identity resolution decides whether
  # that read runs as the App or the host account the same way every other
  # QA call does (QA round 1, finding 7).
  if _run_capture "$ERRFILE" "$QA_GH_SH" --repo "$repo" repo clone "$repo" "$WORKDIR" -- --filter=blob:none --quiet; then
    clone_ok=1
  fi
fi

if [ "$clone_ok" != 1 ] || [ ! -d "$WORKDIR/.git" ]; then
  echo "qa-bundle-diff-fallback: could not clone $repo — git fallback unavailable for $# file(s)" >&2
  rm -f "$ERRFILE"
  die_json "$paths_json" "clone-failed"
fi

# Fetch both refs by SHA, retrying each once (or QA_BUNDLE_FALLBACK_FETCH_
# RETRIES times) before giving up. A PR's head commit is not necessarily
# reachable from any branch the default clone already has (force-pushes,
# PRs from forks), so `git fetch origin <sha>` — not a branch name — is what
# actually guarantees the object exists locally afterward.
#
# The retry exists because a transient failure here is not hypothetical: QA
# round 1 hit exactly this on the card's own repro PR
# (web-credits-next#848) — the script reported "could not resolve base/head
# ... after fetch" on its first run, and a manual fetch of the identical
# shas moments later succeeded. Retrying once absorbs that class of blip
# instead of returning a false CANNOT REVIEW on the PR this script exists
# to fix.
_fetch_sha() { # <sha>
  local sha="$1" attempt=0 rc=1
  # NOTE: unlike the clone above, this fetch uses git's own credential
  # helper, not qa-gh.sh's identity resolution — fine today because the QA
  # App's repos are cloned with an embedded token URL by `gh repo clone`, so
  # a subsequent `git fetch` on that same clone inherits it. If a repo is
  # ever added to `.identity.app_repos` and cloned as the App while the host
  # account has no git credential for it, this fetch would run under a
  # different identity than the clone or fail outright (QA round 2, latent
  # auth issue — worth a card when app_repos first grows beyond empty).
  while [ "$attempt" -le "$FETCH_RETRIES" ]; do
    if _run_capture "$ERRFILE" git -C "$WORKDIR" fetch origin "$sha" --quiet; then
      rc=0
      break
    fi
    attempt=$((attempt + 1))
  done
  return "$rc"
}

fetch_ok=1
_fetch_sha "$base_sha" || fetch_ok=0
_fetch_sha "$head_sha" || fetch_ok=0

if [ "$fetch_ok" != 1 ] \
   || ! git -C "$WORKDIR" rev-parse -q --verify "${base_sha}^{commit}" >/dev/null \
   || ! git -C "$WORKDIR" rev-parse -q --verify "${head_sha}^{commit}" >/dev/null; then
  echo "qa-bundle-diff-fallback: could not resolve base=$base_sha / head=$head_sha in $repo after fetch — git fallback unavailable" >&2
  rm -f "$ERRFILE"
  die_json "$paths_json" "sha-unresolved"
fi

merge_base="$(git -C "$WORKDIR" merge-base "$base_sha" "$head_sha" 2>"$ERRFILE" || true)"
if [ -s "$ERRFILE" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    [ -n "$_line" ] && ERRORS+=("$_line")
  done < "$ERRFILE"
fi
if [ -z "$merge_base" ]; then
  echo "qa-bundle-diff-fallback: no merge-base between $base_sha and $head_sha — git fallback unavailable" >&2
  rm -f "$ERRFILE"
  die_json "$paths_json" "sha-unresolved"
fi
rm -f "$ERRFILE"

recovered_file="$(mktemp)"
missing_file="$(mktemp)"
printf '[]' > "$recovered_file"
printf '[]' > "$missing_file"

_missing_add() { # <path> <reason> <detail-or-empty>
  local p="$1" reason="$2" detail="${3:-}"
  jq --arg p "$p" --arg r "$reason" --arg d "$detail" \
    '. + [{path: $p, reason: $r} + (if $d == "" then {} else {detail: $d} end)]' \
    "$missing_file" > "$missing_file.tmp" && mv "$missing_file.tmp" "$missing_file"
}

for path in "$@"; do
  # --literal-pathspecs (top-level flag, must precede the subcommand): a
  # pathspec like `src/app/[id]/page.tsx` is otherwise glob-matched by git,
  # silently also matching `src/app/i/page.tsx` and blending two files'
  # diffs into one recovered entry under the requested file's name. Every
  # invocation below must carry this flag — it applies per-process, not
  # globally, so there is no "set once" shortcut (QA round 1, finding 3).
  #
  # core.quotepath=false: an unquoted UTF-8 path in a pathspec still has to
  # ROUND-TRIP through the same setting the diff was read with, or a non-ASCII
  # filename silently fails to match and the file falls through to
  # stillMissing for the wrong reason (a resolvable path misreported as
  # unreadable, not a genuine git-diff failure).
  numstat_err="$(mktemp)"
  numstat_rc=0
  numstat="$(git -C "$WORKDIR" -c core.quotepath=false --literal-pathspecs diff --numstat \
    "$merge_base" "$head_sha" -- "$path" 2>"$numstat_err")" || numstat_rc=$?
  numstat_stderr="$(cat "$numstat_err" 2>/dev/null || true)"
  rm -f "$numstat_err"

  # `git diff --numstat` exits 1 on a real diff (not an error) and 0 on no
  # diff at all — never 1 for "nothing changed". So a non-{0,1} exit here is
  # a genuine git failure (a promisor remote unable to fetch a blob from a
  # --filter=blob:none clone is the observed real-world case: rc=128,
  # `fatal: could not fetch <oid> from promisor remote`), and it must NOT be
  # swallowed into "no numstat line, therefore unchanged" the way the
  # pre-fix script's `2>/dev/null || true` did (QA round 1, finding 2) — that
  # made a failed blob fetch indistinguishable from git saying "no change".
  if [ "$numstat_rc" != 0 ] && [ "$numstat_rc" != 1 ]; then
    _missing_add "$path" "git-diff-failed" "$numstat_stderr"
    continue
  fi

  if [ -z "$numstat" ]; then
    # No numstat line at all: the path did not change between merge-base and
    # head as far as git is concerned. That is itself a finding worth
    # surfacing (a path GitHub reported as changed but git disagrees is a
    # PR-moved/rebased-mid-review case, not a silent success) — report it as
    # still missing rather than silently dropping it, matching this script's
    # "never invent a clean result" contract.
    _missing_add "$path" "no-change" ""
    continue
  fi

  is_binary=0
  # git numstat prints literal "-\t-\t<path>" for a binary file — the ONE
  # place git itself, not GitHub, makes this call, which is the entire point
  # of this script existing.
  if printf '%s' "$numstat" | cut -f1 | grep -qx -- '-'; then
    is_binary=1
  fi

  if [ "$is_binary" = 1 ]; then
    diff_json='""'
    jq --arg p "$path" --argjson d "$diff_json" --argjson b true \
      '. + [{path: $p, diff: $d, binary: $b}]' "$recovered_file" > "$recovered_file.tmp" \
      && mv "$recovered_file.tmp" "$recovered_file"
    continue
  fi

  diff_err="$(mktemp)"
  diff_rc=0
  diff_text="$(git -C "$WORKDIR" -c core.quotepath=false --literal-pathspecs diff --unified=3 \
    "$merge_base" "$head_sha" -- "$path" 2>"$diff_err")" || diff_rc=$?
  diff_stderr="$(cat "$diff_err" 2>/dev/null || true)"
  rm -f "$diff_err"

  # Same rc discipline as the numstat call above: only 0/1 is success, and
  # numstat already told us a text diff exists, so 1 here means "diff
  # produced output" (it always does when numstat said something changed) —
  # anything else is a real failure and must be reported as such, not folded
  # into the "diff came back empty" branch below.
  if [ "$diff_rc" != 0 ] && [ "$diff_rc" != 1 ]; then
    _missing_add "$path" "git-diff-failed" "$diff_stderr"
    continue
  fi

  if [ -z "$diff_text" ]; then
    # numstat said something changed but the diff itself came back empty —
    # do not fabricate a patch. Report as still missing; CANNOT REVIEW is the
    # honest outcome for this one file, not a silently blank recovery.
    _missing_add "$path" "no-change" ""
    continue
  fi

  jq --arg p "$path" --arg d "$diff_text" --argjson b false \
    '. + [{path: $p, diff: $d, binary: $b}]' "$recovered_file" > "$recovered_file.tmp" \
    && mv "$recovered_file.tmp" "$recovered_file"
done

missing_json="$(cat "$missing_file")"
recovered_json="$(cat "$recovered_file")"
rm -f "$recovered_file" "$missing_file" "$recovered_file.tmp" "$missing_file.tmp" 2>/dev/null || true

jq -n --argjson recovered "$recovered_json" --argjson missing "$missing_json" --argjson errors "$(_errors_json)" \
  '{recovered: $recovered, stillMissing: $missing, cloneOk: true, errors: $errors}'
