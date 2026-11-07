#!/usr/bin/env bash
set -euo pipefail

# qa-gh.sh — run `gh` as the QA bot identity instead of the host account.
# ===========================================================================
# Every GitHub call the QA reviewer makes should go through this shim rather than
# bare `gh`. It resolves which identity to use, mints a scoped GitHub App
# installation token when appropriate, and execs `gh` with it.
#
#   qa-gh.sh --repo <owner/name> <gh args...>
#   qa-gh.sh <gh args...>                      # unscoped (avoid where possible)
#
# The leading --repo is consumed by the shim to scope the token; the gh command
# after it keeps its own --repo flag as usual. So the call site reads:
#   qa-gh.sh --repo Muso-AI/core-backend pr view 12 --repo Muso-AI/core-backend --json state
#
# ── Identity resolution (first match wins) ───────────────────────────────────
#   1. /var/lib/hydra/qa-gh-host-identity exists -> host  (the kill switch)
#   2. $QA_GH_IDENTITY is "app" or "host"      -> that
#   3. repo listed in policies/qa-approval-policy.json .identity.app_repos -> app
#   4. otherwise                               -> host
#
# The kill switch lives under /var/lib/hydra/ and NOT under /opt/hydra/: deploy.sh
# rsyncs the repo to /opt/hydra with --delete, and the flag is not in
# RSYNC_EXCLUDES, so a deploy would silently disarm an emergency rollback. Same
# deploy-proof convention as /var/lib/hydra/codex-active-account.
#
# (3) is what makes the cutover incremental: app_repos starts empty, so every
# call falls through to the ambient host login and behaviour is byte-identical to
# before this shim existed. Repos are moved onto the App one at a time — that
# list is the ONLY dial, deliberately: a separate "default identity" knob would
# be a second way to say the same thing, and an unvalidated one would turn a typo
# into a fleet-wide identity switch.
#
# ── Why the token is resolved per invocation, not per review ─────────────────
# A review runs under qa-dispatch-pr-review.sh's 1200s timeout against a 3600s
# token, and each call re-checks the cache and re-mints below a 600s floor, so a
# token can never go stale mid-review. A *mint* failure fails one call loudly;
# because every guard in qa-pr-approve.sh is fail-closed, that degrades to "does
# not approve" — never to "approves blind".
#
# ── Why not just export GH_TOKEN globally ────────────────────────────────────
# Do NOT put GH_TOKEN in /etc/openclaw/shared.env. openclaw-main.json has no
# per-agent env, so a shared var would hand the QA bot token to every agent AND
# simultaneously break the deploy/release paths that legitimately need the host
# account's admin scopes. Per-process injection here is the only clean seam.
#
# ── Empty review payloads are refused (exit 6) ──────────────────────────────
# The reviewer posts its verdict as `api repos/<o>/<r>/pulls/<n>/reviews --method
# POST --input <file>` (skill Step 6). GitHub accepts a payload with no body and
# no inline comments and renders it as a bodiless `COMMENTED` review -- which
# every reader downstream (the reconciler's qar_has_bot_review, a human on the
# PR) counts as "the bot reviewed this" while it says NOTHING. A reviewer that
# can succeed with no output cannot gate merges, so that one shape is refused
# here, at the single write surface, with the reason named. A review with a
# body, or with at least one inline comment (the carry-forward thread replies
# legitimately post body-less, comment-only reviews), passes untouched: this
# never decides or reformats a verdict, it only refuses the absence of one.
#
# Exit codes: passes through gh's exit code. 2 usage. 5 token mint failed.
#             6 empty review payload refused (see above).
#
# Env (mainly for tests):
#   QA_GH_HOST_FLAG         kill-switch path (default /var/lib/hydra/qa-gh-host-identity)
#   QA_GH_IDENTITY          force "app" or "host"
#   QA_APPROVAL_POLICY      policy file path
#   QA_GH_TOKEN_SCRIPT      path to qa-github-app-token.sh
#   GH                      the gh binary (default gh)

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_FLAG="${QA_GH_HOST_FLAG:-/var/lib/hydra/qa-gh-host-identity}"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"
TOKEN_SCRIPT="${QA_GH_TOKEN_SCRIPT:-$_here/lib/qa-github-app-token.sh}"
GH_BIN="${GH:-gh}"

die() { echo "qa-gh: $2" >&2; exit "$1"; }

repo_full=""
if [ "${1:-}" = "--repo" ]; then
  repo_full="${2:-}"
  [ -n "$repo_full" ] || die 2 "--repo needs a value"
  shift 2
fi
[ "$#" -gt 0 ] || die 2 "usage: qa-gh.sh [--repo <owner/name>] <gh args...>"

# ── refuse an empty review POST ──────────────────────────────────────────────
# Recognised shape: `api <path ending in /pulls/<n>/reviews> ... --input <file>`
# with `--method POST` / `-X POST` -- the one shape the reviewer skill uses
# (Step 6 always passes a file). Any other call passes straight through,
# including `--input -`: inspecting stdin would mean spooling the review body to
# disk before the token paths below can still die, so it is deliberately not
# inspected. A payload jq cannot parse is left to gh (it 400s loudly on its
# own); only a PARSEABLE payload that is provably content-free is refused.
review_post_payload_check() {
  local is_post=0 is_reviews=0 input="" i a
  [ "${1:-}" = "api" ] || return 0
  for ((i = 1; i <= $#; i++)); do
    a="${!i}"
    case "$a" in
      --method|-X) i=$((i + 1)); [ "${!i:-}" = "POST" ] && is_post=1 ;;
      --method=POST|-XPOST) is_post=1 ;;
      --input) i=$((i + 1)); input="${!i:-}" ;;
      --input=*) input="${a#--input=}" ;;
      */pulls/[0-9]*/reviews|*/pulls/[0-9]*/reviews/) is_reviews=1; REVIEWS_PATH="$a" ;;
    esac
  done
  [ "$is_post" = 1 ] && [ "$is_reviews" = 1 ] && [ -n "$input" ] && [ "$input" != "-" ] || return 0
  [ -r "$input" ] || return 0
  local verdict
  verdict="$(jq -r '
    if type != "object" then "pass"
    elif ((.body // "") | tostring | gsub("\\s"; "") | length) > 0 then "pass"
    elif ((.comments // []) | if type == "array" then length else 0 end) > 0 then "pass"
    else "empty" end' "$input" 2>/dev/null)" || return 0
  [ "$verdict" != "empty" ] || die 6 "refusing to POST an EMPTY review to ${REVIEWS_PATH}: the payload has no body and no inline comments, so GitHub would record a bodiless COMMENTED review that reads as a verdict while saying nothing. Post the verdict body (GO / NO-GO / CANNOT REVIEW with the reason) -- a review that says nothing is a missing review, not a review."
}
REVIEWS_PATH=""
review_post_payload_check "$@"

# ── resolve identity ────────────────────────────────────────────────────────
# Fail-safe reads throughout: an unreadable or malformed policy resolves to the
# host identity (i.e. exactly the pre-migration behaviour), never to a broken
# half-state. The consequence of guessing wrong here is a review attributed to
# the wrong account, not an unguarded approval — every approval guard lives in
# qa-pr-approve.sh and is independent of which identity made the call.
identity=""
# -e is false for a dangling symlink, so test -L too: a kill switch that silently
# fails to engage is the one failure this lever cannot afford.
if [ -e "$HOST_FLAG" ] || [ -L "$HOST_FLAG" ]; then
  echo "qa-gh: $HOST_FLAG present — using the host gh identity (kill switch active)" >&2
  identity="host"
elif [ "${QA_GH_IDENTITY:-}" = "app" ] || [ "${QA_GH_IDENTITY:-}" = "host" ]; then
  identity="$QA_GH_IDENTITY"
elif [ -n "$repo_full" ] && [ -r "$POLICY" ] \
  && jq -e --arg r "$repo_full" '(.identity.app_repos // []) | index($r)' "$POLICY" >/dev/null 2>&1; then
  identity="app"
else
  identity="host"
fi

if [ "$identity" = "host" ]; then
  exec "$GH_BIN" "$@"
fi

# ── app identity ────────────────────────────────────────────────────────────
if [ -n "$repo_full" ]; then
  token="$("$TOKEN_SCRIPT" --repo "$repo_full")" || die 5 "could not mint an App token for $repo_full."
else
  token="$("$TOKEN_SCRIPT")" || die 5 "could not mint an App token."
fi
[ -n "$token" ] || die 5 "App token was empty."

# GH_TOKEN (not GITHUB_TOKEN) is what gh honours for an explicit credential, and
# unsetting GITHUB_TOKEN stops a stray Actions token in the environment winning.
# `-u` MUST precede the NAME=VALUE assignments: env treats the first non-assignment
# argument as the command, so `env FOO=1 -u BAR cmd` tries to exec "-u" (exit 127).
exec env -u GITHUB_TOKEN GH_TOKEN="$token" GH_HOST=github.com "$GH_BIN" "$@"
