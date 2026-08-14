#!/usr/bin/env bash
set -euo pipefail

# qa-pr-approve.sh — gated "approve-only" for the QA agent's PR-review skill.
# ===========================================================================
# The QA agent calls this AFTER a GO-verdict review (via muso-github-code-review)
# to record a GitHub approval on a PR. It is the ONLY sanctioned path for QA to
# approve — the skill must never call `gh pr review --approve` directly, because
# this wrapper enforces the guardrails and the audit log that prose alone can't.
#
# Hard rules enforced here (the checkable ones — judgment stays with the agent):
#   1. APPROVE ONLY. This never merges. Humans merge.
#   2. Muso-AI repos only.
#   3. Never self-approve: GitHub 422s if the PR author == the authenticated
#      account, so refuse early with a clear message instead of a confusing API
#      error.
#   3b. Sensitive paths (policies/, secrets/, CODEOWNERS, workflow files, this
#      script) ALERT and the approval PROCEEDS — see "Notice 3b" below. Only a
#      path in the policy's `sensitive_paths_blocking` still refuses (exit 11).
#      Changed 2026-08-03; it used to refuse for the whole list.
#      NARROWED BACK 2026-08-14: that key is no longer empty. It now carries the
#      AUTHORITY SURFACE — this script, policies/qa-approval-policy.json, and the
#      three CODEOWNERS spellings — because the bot approves as adk47, the
#      universal code owner, so an allowlist widening would otherwise satisfy
#      require_code_owner_reviews with no Aaron in the loop (Tier 3 is Aaron-only,
#      docs/reference/GOVERNANCE.md). Everything else stays alert-only, so the
#      blanket refusal that made the bot unusable is NOT back.
#   3c. Never approve a PR by an author in the policy's author_deny list.
#   4. Requester must be in the approval allowlist — either UNSCOPED (Aaron,
#      Nick) or SCOPED (Mariia, restricted to her own web-credits-next PRs on
#      base `develop`). Checked in two stages: Guard 4 (membership, no network)
#      and Guard 4b (scope, once the PR's author and base branch are known).
#      NOTE: the agent supplies the UID, so this is defense-in-depth, not a
#      cryptographic gate. The real identity signal is the Slack UID the gateway
#      put in the message metadata; the agent is trusted to pass it faithfully.
#   5. Log BEFORE the write (SECURITY.md "Write Activity Logging"): if it can't
#      log, it doesn't approve.
#
# Usage:
#   qa-pr-approve.sh <repo> <pr-number> <requester-slack-uid> [approval-body]
#     <repo>  short name (e.g. core-backend) or owner/repo (owner must be Muso-AI)
#
# Exit codes: 0 ok | 2 usage | 3 repo-not-muso | 4 self-approval-blocked
#             5 requester-not-allowed (Guard 4: not on the allowlist at all, OR
#                Guard 4b: a scoped requester outside their scope — the message
#                says which condition failed) | 6 log-failed | 7 gh-approve-failed
#             8 ci-not-green | 9 open-blocking-findings
#             10 rebase-warning-unfiled-or-unverified
#             11 sensitive-path-blocked | 12 author-policy-blocked
#             13 blast-radius-critical-or-unverified (Guard 9; only reachable
#                when QA_BLAST_RADIUS_GATE=1, which is NOT the default)
#
# Env (mainly for tests): QA_GH override the identity shim (GH overrides the gh
# binary inside it);
# QA_APPROVAL_POLICY override the policy file; QA_PR_APPROVE_LOG_DIR override log
# dir; QA_REBASE_STATE_DIR override the rebase-integrity report dir (Guard 8);
# QA_REBASE_REQUIRED_REPOS space-separated short names whose CI must have
# written a report (default "hydra") — missing report there refuses (Guard 8);
# QA_BLAST_RADIUS_GATE=1 enables Guard 9 (default 0 = off, a pure no-op);
# QA_BLAST_STATE_DIR override the blast-radius report dir (Guard 9).

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/qa-policy.sh
. "$_here/lib/qa-policy.sh"
# NOTE: there is deliberately no `GH=` here. Every call goes through $QA_GH, and
# a live-looking $GH next to it would invite a call that silently bypasses the
# identity shim, the kill switch, and the per-repo token scoping. To override the
# gh binary itself, set GH — qa-gh.sh honours it (GH_BIN).
# Every GitHub call goes through the identity shim, which decides per repo
# whether to run as the QA bot App or the ambient host login, and mints a scoped
# installation token when it is the former. See scripts/qa-gh.sh.
QA_GH="${QA_GH:-$_here/qa-gh.sh}"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"
LOG_DIR="${QA_PR_APPROVE_LOG_DIR:-api-logs/github}"

# Identity note: the approval is recorded under whichever identity the shim
# selected for this repo — the `muso-qa-bot` GitHub App where it is enabled,
# otherwise the ambient host account. The *body* is branded "Muso QA Bot" either
# way so the write always reads as automation.
#
# A GitHub App can never be a CODEOWNER (CODEOWNERS takes users and teams only),
# so where the shim runs AS THE APP (repo in `identity.app_repos`) the approval
# counts toward the required review but does NOT unblock the merge. Where it runs
# as the host account, that account IS the universal code owner under hydra's
# CODEOWNERS, so the approval DOES clear the gate. `app_repos` is empty today, so
# the second case is the live one. The skill must relay the wrapper's post-check
# `reviewDecision`/`mergeStateStatus` rather than predicting either outcome.

# ===========================================================================
# Approval allowlist — the ONLY people who may trigger an approval. Two tiers.
# Last changed 2026-08-13 on Nick's explicit authorization (U0AL36NADEY).
#
# UNSCOPED_UIDS — may approve any Muso-AI PR the other guards allow.
#   Aaron U7RP6HKUZ, Nick U0AL36NADEY. Both are Tier 0 owners
#   (workspaces/coordinator/SECURITY.md "Known User IDs").
#
# SCOPED_APPROVERS — may approve ONLY where every scope condition holds.
#   Format (pipe-separated, positional):  UID|owner/repo|pr-author|base-branch
#   Mariia (azure-kirin, U03LP8YHLPK) is scoped to her OWN azure-kirin PRs in
#   Muso-AI/web-credits-next targeting base `develop`, and nothing else. WHY
#   scoped rather than unscoped: her PRs were already auto-REVIEWED (see
#   scripts/lib/qa-author-slack-uid.sh) but approval was withheld because a
#   broad grant to a UI-focused author would let the bot sign off anywhere in
#   the org. Narrowing the grant to one repo + one base branch + her own
#   authorship keeps the automation's blast radius equal to the surface she
#   already owns day to day, and every other guard (CI green, GO verdict, no
#   unresolved blocking findings, never merge, no self-approval) still applies
#   unchanged — this table only decides WHO may ask.
#
# REMOVED 2026-08-13: Serhii (liflovs, U03TYGJF1N3). His PRs are still
#   auto-REVIEWED — he stays in scripts/lib/qa-author-slack-uid.sh, which drives
#   review dispatch and the DM — but the bot must no longer record a formal
#   approval on them. An `exit 5` on one of his PRs is the intended outcome, not
#   a fault to work around.
#
# WIDENING THIS TABLE (adding a UID, or loosening any scope field) requires
# AARON. It is not a Tier 2 doctrine edit that either owner-principal may
# authorize: docs/reference/GOVERNANCE.md keeps the security surface Aaron-only,
# and its test is functional — "if a change would let anyone do something they
# could not do before, it is security surface". Adding a UID here is precisely
# that. (An earlier draft of this comment said "Aaron or Nick", which contradicted
# the governing doc and would have let the widening self-authorize.) Guard 3b now
# enforces it rather than asking: this file is in `sensitive_paths_blocking`, so
# a PR touching it refuses exit 11 and a human has to approve.
# The same PR must also update ALL FOUR docs
# that restate this contract in prose — nothing enforces them mechanically:
#   workspaces/coordinator/SECURITY.md   (there is NO repo-root SECURITY.md)
#   workspaces/qa/SOUL.md
#   workspaces/qa/AGENTS.md
#   skills-all/muso-github-code-review/SKILL.md  (Step 7 + the exit-code crib)
# and add the matching cases to scripts/tests/qa-pr-approve.bats.
# ===========================================================================
UNSCOPED_UIDS=("U7RP6HKUZ" "U0AL36NADEY")
SCOPED_APPROVERS=("U03LP8YHLPK|Muso-AI/web-credits-next|azure-kirin|develop")

die() { _replay_alerts; echo "qa-pr-approve: $2" >&2; exit "$1"; }

# alert <message> — surface something the humans must SEE without blocking the
# approval. Every line carries a stable marker so the reviewing skill can lift
# them verbatim into the PR review body and the Slack DM.
#
# Emitted ONCE inline on stderr (ordering context in the cron journal, next to
# whatever produced it) and ONCE at the end on stdout (the authoritative list
# the agent relays). Printing to both streams inline made each alert appear
# three times in a combined capture — and repetition-as-noise is exactly how a
# signal gets tuned out, which for the sole replacement of a removed hard gate
# would be self-defeating.
ALERTS=()
# Printed on EVERY exit path, success or refusal. Alerts are raised before the
# guards that can refuse, so replaying only on success dropped them exactly when
# a human was already being pulled in.
_replay_alerts() {
  [ "${#ALERTS[@]}" -gt 0 ] || return 0
  echo "qa-pr-approve: ── ${#ALERTS[@]} ALERT(S) on this run — relay ALL of these ──"
  local a
  for a in "${ALERTS[@]}"; do echo "qa-pr-approve: ⚠️ ALERT — $a"; done
  ALERTS=()
}
alert() {
  ALERTS+=("$1")
  echo "qa-pr-approve: ⚠️ ALERT — $1" >&2
}

[ "$#" -ge 3 ] || die 2 "usage: qa-pr-approve.sh <repo> <pr-number> <requester-uid> [body]"
repo_arg="$1"
pr="$2"
requester="$3"
body="${4:-🤖 Approved by Muso QA Bot (automated review): CI is green and there are no blocking findings. A human still performs the merge.}"

# --- Guard 2: Muso-AI repos only -------------------------------------------
if [[ "$repo_arg" == */* ]]; then
  owner="${repo_arg%%/*}"
  repo="${repo_arg#*/}"
else
  owner="Muso-AI"
  repo="$repo_arg"
fi
[ "$owner" = "Muso-AI" ] || die 3 "repo owner must be Muso-AI, got '$owner' — refusing."
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'."

# --- Guard 4: requester in allowlist (fail fast, no network) ----------------
# Stage A of the allowlist: membership in the UNION of the unscoped and scoped
# tables. A UID in neither dies here, before any API call, exactly as before.
# Whether a SCOPED requester may approve THIS PR needs the PR's author and base
# branch, which cost a round-trip — that is Guard 4b, below Guard 3.
#
# `${ARR[@]+"${ARR[@]}"}` — NOT a bare `"${ARR[@]}"`. Under `set -u` bash 3.2
# (macOS /bin/bash, which runs these scripts and their tests locally) an EMPTY
# array expansion is an "unbound variable" ABORT: exit 1 with no die message and
# no audit trail. Emptying a table is precisely the edit the header block above
# invites a future maintainer to make, so the crash-on-empty shape must not exist.
# With the guard, an emptied table degrades to a clean `die 5`.
allowed=0
unscoped_match=0   # Stage A matched the UNSCOPED table — see Guard 4b
for uid in ${UNSCOPED_UIDS[@]+"${UNSCOPED_UIDS[@]}"}; do
  [ "$uid" = "$requester" ] && allowed=1 && unscoped_match=1 && break
done
if [ "$allowed" != 1 ]; then
  for spec in ${SCOPED_APPROVERS[@]+"${SCOPED_APPROVERS[@]}"}; do
    [ "${spec%%|*}" = "$requester" ] && allowed=1 && break
  done
fi
[ "$allowed" = 1 ] || die 5 "requester '$requester' is not authorized to approve PRs (unscoped: Aaron U7RP6HKUZ, Nick U0AL36NADEY; scoped: Mariia U03LP8YHLPK — her own azure-kirin PRs in Muso-AI/web-credits-next targeting 'develop'). Serhii U03TYGJF1N3 was removed on 2026-08-13: his PRs are reviewed, never auto-approved."

# --- Identity ---------------------------------------------------------------
# `gh api user` returns 403 "Resource not accessible by integration" under a
# GitHub App installation token — there is no user behind an App token. Left
# unhandled that makes $me empty, which silently voids Guard 3 AND makes Guard 8's
# marker-author test compare against "" and match nothing, so every WARN head
# would die exit 10. So the identity is DECLARED here, not discovered: ask the
# API, and fall back to the policy's first bot login when it cannot answer.
# `|| true` is load-bearing: under `set -e` + `pipefail` a failing jq (unreadable
# policy) aborts the whole script at this assignment with jq's own exit code and
# NO message, before the fallback below can run. `head -1` guards the other shape
# — a file that is valid JSON followed by garbage, where jq emits the real value
# and then fails, which would otherwise make this a two-line string.
bot_logins_json="$(jq -c '(.identity.bot_logins // ["muso-qa-bot"]) | if type == "array" then . else ["muso-qa-bot"] end' "$POLICY" 2>/dev/null | head -1 || true)"
[ -n "$bot_logins_json" ] || bot_logins_json='["muso-qa-bot"]'
me="$("$QA_GH" --repo "$owner/$repo" api user --jq .login 2>/dev/null || true)"
[ -n "$me" ] || me="$(printf '%s' "$bot_logins_json" | jq -r '.[0] // "muso-qa-bot"' 2>/dev/null || echo "muso-qa-bot")"

# norm_login — collapse the THREE forms GitHub reports the same bot identity in,
# so comparisons cannot silently miss. Verified against Muso-AI/auth's dependabot
# PR on 2026-07-27:
#   REST      (gh api .../pulls)          -> "dependabot[bot]"
#   GraphQL   (gh pr view --json author)  -> "app/dependabot"
#   GraphQL   (reviewThreads Bot{login})  -> "dependabot"
# Guard 3 reads the middle one and $me/bot_logins carry the others, so comparing
# raw strings matches nothing and the guard is silently dead.
norm_login() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's,^app/,,' -e 's,\[bot\]$,,'; }

# --- Guard 3: never self-approve -------------------------------------------
# ONE round-trip for both PR facts the guards below need: the author (Guard 3,
# Guard 3c, Guard 8) and the base branch (Guard 4b). The filter emits them as
# two lines in a fixed order; `// ""` keeps a null/absent field as an EMPTY LINE
# rather than dropping it, so line 2 can never slide up into $author. `|| true`
# preserves the existing behaviour on a failed call: both stay empty and the
# die 7 below fires with the same message it always did.
pr_meta="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json author,baseRefName --jq '(.author.login // ""), (.baseRefName // "")' 2>/dev/null || true)"
author="$(printf '%s\n' "$pr_meta" | sed -n 1p)"
base_ref="$(printf '%s\n' "$pr_meta" | sed -n 2p)"
[ -n "$author" ] || die 7 "could not read PR author for $owner/$repo#$pr (does the PR exist / is gh authed?)."
# GitHub logins are case-insensitive. Compare against the CURRENT identity only,
# not the whole bot_logins set: GitHub blocks approving your own PR, and that is
# a fact about who is acting right now. Once the App is the actor, a PR by the
# old host account is no longer self-approval — it is a policy question, and
# Guard 3c below is what answers it. Conflating the two would report a misleading
# reason and would wrongly refuse if the set ever grew.
author_n="$(norm_login "$author")"
me_n="$(norm_login "$me")"
if [ -n "$me_n" ] && [ "$me_n" = "$author_n" ]; then
  die 4 "PR #$pr is authored by the acting QA identity ($author) — GitHub blocks self-approval. A different reviewer must approve it."
fi

# --- Guard 3c: author policy ------------------------------------------------
# Authors the bot must never approve, independent of who requested it. Defaults
# to the host account: GitHub's self-approval block used to make approving its
# PRs impossible, and moving to a dedicated identity would otherwise remove that
# protection as an invisible side effect. Widening this is a deliberate policy PR.
# Fail closed on a four-state read. `jq -e` alone cannot distinguish "not in the
# list" from "malformed", and `(.author_deny // [])` is worse: it silently turns a
# MISSING or null key into an empty allow-list, so a policy that lost the key
# would quietly start approving the very authors this guard exists to block. The
# key must be present AND an array; an explicit [] is still honoured, because
# that is the deliberate policy flip.
deny_hit="$(jq -r --arg a "$author_n" '
  if (has("author_deny") | not) or (.author_deny == null) then "__MISSING__"
  elif (.author_deny | type) != "array" then "__BADTYPE__"
  else (.author_deny | map(ascii_downcase | sub("^app/";"") | sub("\\[bot\\]$";""))
        | index($a) | tostring)
  end' "$POLICY" 2>/dev/null || echo "__ERR__")"
case "$deny_hit" in
  __ERR__)     die 12 "cannot read author_deny from $POLICY — refusing to approve (fail closed)." ;;
  __MISSING__) die 12 "author_deny is missing or null in $POLICY — refusing to approve (fail closed; an absent key must not read as an empty allow-list). Set it to [] explicitly to allow all authors." ;;
  __BADTYPE__) die 12 "author_deny in $POLICY is not an array — refusing to approve (fail closed)." ;;
  null)        : ;;
  *)           die 12 "PR #$pr is authored by '$author', who is in the policy's author_deny list — refusing to approve. A human must review it." ;;
esac

# --- Guard 4b: scoped requesters must satisfy EVERY scope condition ---------
# Stage B of the allowlist. A requester listed in SCOPED_APPROVERS must match one
# of their entries in FULL: repo, PR author, and base branch. This is deliberately
# NOT Guard 3: Guard 3 compares the author to the ACTING identity ($me) and blocks
# GitHub's own self-approval 422 — a scoped author requesting approval of their OWN
# PR is the INTENDED case here, and must keep working.
#
# UNSCOPED REQUESTERS NEVER ENTER THIS BLOCK — and that is now enforced by
# `$unscoped_match` from Guard 4, not merely asserted in prose. The loop used to
# run unconditionally, so a UID present in BOTH tables was silently DEMOTED to
# scoped-only: add Nick to SCOPED_APPROVERS and `qa-pr-approve.sh hydra 70
# U0AL36NADEY` started refusing exit 5, i.e. an edit that reads as "grant Nick an
# extra narrow path" quietly REVOKED his org-wide authority. Unscoped wins: the
# tables are additive grants, never intersecting restrictions.
#
# FAIL CLOSED. An empty $base_ref means the API did not give us one (missing
# field, malformed response, or a partial read), which is NOT evidence the base
# matches — it is refused, mirroring the die 7 on an unreadable author above.
# Runs BEFORE the audit log and before any write, so a refusal leaves no trace
# of an approval that never happened.
#
# The author test is a CASE-FOLD ONLY comparison, deliberately NOT norm_login.
# norm_login exists to collapse the three spellings of one BOT identity (Guards
# 3/3c/8 need that), but stripping `app/` and `[bot]` here WIDENS a human scope
# entry: with norm_login, both `app/azure-kirin` and `azure-kirin[bot]` matched the
# `azure-kirin` scope and approved. A scope entry names a HUMAN, so a decorated
# author is refused outright rather than folded onto them.
#
# KNOWN LIMIT (open, documented, deliberately not fixed here): the base branch is
# read once, before the approval. GitHub's retention behaviour for an existing
# approving review when a PR is RETARGETED to another base afterwards was not
# verified — if the review survives the retarget, a scoped approval obtained on
# `develop` could end up sitting on a PR whose base is now something else. What
# would settle it is a live experiment (approve a PR on base develop, retarget it,
# re-read `reviewDecision`); until someone runs it, no re-check mechanism is built
# on an unverified assumption.
scoped_hit=0   # the requester appears in the scoped table at all
scope_ok=0     # some entry of theirs is satisfied in full
scope_why=""
lc_login() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ "$unscoped_match" != 1 ]; then
for spec in ${SCOPED_APPROVERS[@]+"${SCOPED_APPROVERS[@]}"}; do
  IFS='|' read -r s_uid s_repo s_author s_base <<<"$spec"
  [ "$s_uid" = "$requester" ] || continue
  scoped_hit=1
  why=""
  [ "$s_repo" = "$owner/$repo" ] || why="$why; repo must be $s_repo (got $owner/$repo)"
  if [ "${author#app/}" != "$author" ] || [ "${author%\[bot\]}" != "$author" ]; then
    why="$why; PR author '$author' carries GitHub App/bot decoration — a scoped grant names a human ($s_author) and never matches an app or bot identity"
  elif [ "$(lc_login "$s_author")" != "$(lc_login "$author")" ]; then
    why="$why; PR author must be $s_author (got $author)"
  fi
  if [ -z "$base_ref" ]; then
    why="$why; base branch could not be read from the API — refusing (fail closed), it must be $s_base"
  elif [ "$s_base" != "$base_ref" ]; then
    why="$why; base branch must be $s_base (got $base_ref)"
  fi
  if [ -z "$why" ]; then scope_ok=1; break; fi
  scope_why="${scope_why:+$scope_why | }${why#; }"
done
fi
if [ "$scoped_hit" = 1 ] && [ "$scope_ok" != 1 ]; then
  die 5 "requester '$requester' may only approve PRs inside a restricted scope, and $owner/$repo#$pr is outside it — $scope_why. A human reviewer must approve this one; widening the scope is a deliberate PR against SCOPED_APPROVERS in scripts/qa-pr-approve.sh."
fi

# --- Notice 3b: sensitive paths (ALERTS, does not block) ---------------------
# WAS a hard refusal (exit 11). Changed 2026-08-03 on Nick's explicit direction:
# the bot must surface issues and approve once they are resolved, not hand work
# back to humans. Sensitive paths now produce a loud alert on the PR and in
# Slack, and the approval proceeds.
#
# The 2026-08-03 change accepted a known consequence: policies/ and this script
# are in the ALERTING list, so the bot could approve a change that widens its own
# authority, with the alert as the only backstop. That is the case the comment
# below said to fix "if you are reading this because something bad happened" —
# and on 2026-08-14 it was fixed, the prescribed way: the specific authority
# paths moved into `sensitive_paths_blocking`, NOT a re-added blanket refusal.
#
# So the self-reference is closed again for the paths that grant authority (this
# script, the policy, CODEOWNERS) while every other sensitive path keeps the
# alert-only behaviour the team asked for. A path in `sensitive_paths_blocking`
# refuses exit 11; that key is NON-EMPTY now, which also means `file_trouble`
# below fails closed — an unverifiable changed-file list can no longer be waved
# through, because we cannot prove the PR misses a blocking path.
sensitive_json="$(jq -c --arg r "$owner/$repo" \
  '((.sensitive_paths["*"] // []) + (.sensitive_paths[$r] // []))' "$POLICY" 2>/dev/null || true)"
# sensitive_paths_blocking is the ONLY surviving hard path gate, so it must fail
# CLOSED. `jq … // [] || echo '[]'` would collapse "policy unreadable" and "key
# malformed" into "nothing blocks" — exactly the bug class scripts/lib/qa-policy.sh
# was written to eliminate, and a straight weakening of what this script did
# before sensitive paths stopped blocking. Distinguish the three states:
# readable-and-absent (fine, nothing blocks) vs unreadable/malformed (refuse).
if ! blocking_json="$(jq -ce --arg r "$owner/$repo" '
      if (has("sensitive_paths_blocking") | not) then []
      elif (.sensitive_paths_blocking | type) != "object" then error("not an object")
      else ((.sensitive_paths_blocking["*"] // []) + (.sensitive_paths_blocking[$r] // []))
      end' "$POLICY" 2>/dev/null)" || [ -z "$blocking_json" ]; then
  die 11 "cannot read sensitive_paths_blocking from $POLICY — it is the only hard path gate left; refusing to approve (fail closed)."
fi
if [ -z "$sensitive_json" ] || [ "$sensitive_json" = "[]" ]; then
  # Previously fail-closed. This notice cannot block any more, so an empty list
  # means only that the ALERT is unreliable — but WHICH empty matters:
  #   unreadable/malformed      -> jq failed, $sensitive_json empty       -> alert
  #   `sensitive_paths` absent  -> the key was dropped or renamed         -> alert
  #   present, nothing for repo -> a legitimate "[]", normal operation    -> quiet
  # Alerting on the third case fired on every approval for a repo with no
  # entries, and a "I am broken" line every run is how the signal gets ignored.
  if [ -z "$sensitive_json" ]; then
    alert "could not read sensitive_paths from $POLICY — proceeding without a sensitive-path alert for $owner/$repo#$pr."
  elif ! jq -e 'has("sensitive_paths")' "$POLICY" >/dev/null 2>&1; then
    alert "$POLICY has no sensitive_paths key at all — the sensitive-path alert is disabled for every repo. If that was not deliberate, restore the key."
  fi
  sensitive_json='[]'
fi

# `gh pr view --json files` issues `files(first: 100)` with NO pagination and no
# pageInfo (verified with GH_DEBUG=api on 2026-07-27). Read the independently
# paginated REST endpoint instead, then cross-check its total against
# changedFiles so an API failure or partial response still refuses fail-closed.
# file_trouble <message> — the changed-file list could not be established. That
# no longer blocks the (non-blocking) alert path, but it MUST still fail closed
# whenever `sensitive_paths_blocking` is non-empty, because we cannot prove the
# PR misses those paths.
file_trouble() {
  if [ "$blocking_json" != "[]" ]; then
    die 11 "$1 — refusing to approve (fail closed; sensitive_paths_blocking is configured and cannot be verified)."
  fi
  alert "$1 — proceeding without a sensitive-path alert for $owner/$repo#$pr."
}

# Each step below is a precondition for the next, so one if/elif chain says it
# without a mutable "did we bail?" flag to keep in sync. `changed_files` staying
# unset IS the bail signal — the consumer below already tests for it.
reported_changed_files="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" \
  --json changedFiles --jq .changedFiles 2>/dev/null || true)"
if ! [[ "$reported_changed_files" =~ ^[0-9]+$ ]]; then
  file_trouble "could not read the changed-file count for $owner/$repo#$pr"
elif ! files_json="$("$QA_GH" --repo "$owner/$repo" api --paginate --slurp \
       "repos/$owner/$repo/pulls/$pr/files?per_page=100" 2>/dev/null)"; then
  file_trouble "could not read the paginated changed-file list for $owner/$repo#$pr"
elif ! printf '%s' "$files_json" \
     | jq -e '
         type == "array"
         and all(.[];
           type == "array"
           and all(.[];
             if type != "object" then false
             else ((.filename | type) == "string" and (.filename | length) > 0)
               and (.status as $s
                    | (["added", "removed", "modified", "renamed", "copied", "changed", "unchanged"]
                       | index($s)) != null)
               and (if has("previous_filename")
                    then ((.previous_filename | type) == "string"
                          and (.previous_filename | length) > 0)
                    else .status != "renamed"
                    end)
             end))' \
       >/dev/null 2>&1; then
  file_trouble "could not parse the paginated changed-file list for $owner/$repo#$pr"
else
  returned_changed_files="$(printf '%s' "$files_json" | jq -r '[.[][]] | length')"
  unique_changed_files="$(printf '%s' "$files_json" | jq -r '[.[][] | .filename] | unique | length')"
  if [ "$reported_changed_files" != "$returned_changed_files" ]; then
    file_trouble "PR #$pr reports $reported_changed_files changed files but the API returned $returned_changed_files (partial list)"
  elif [ "$returned_changed_files" != "$unique_changed_files" ]; then
    file_trouble "the paginated API returned duplicate filenames for $owner/$repo#$pr (unstable list)"
  else
    changed_files="$(printf '%s' "$files_json" | jq -r '.[][] | .filename, (.previous_filename? // empty)')"
  fi
fi

# match_paths <patterns-json> → the matching changed paths, one per line
match_paths() {
  printf '%s\n' "$changed_files" \
    | jq -R -s --argjson pats "$1" \
        '[ split("\n")[] | select(length > 0) as $f
           | select(any($pats[]; . as $p | ($f | startswith($p)))) ] | join("\n")' \
        -r 2>/dev/null || echo "__ERR__"
}

if [ -n "${changed_files:-}" ]; then
  # The blocking subset first: it refuses, and since 2026-08-14 it is non-empty
  # (the authority surface — this script, the policy, CODEOWNERS).
  if [ "$blocking_json" != "[]" ]; then
    bhit="$(match_paths "$blocking_json")"
    [ "$bhit" != "__ERR__" ] || die 11 "could not evaluate sensitive_paths_blocking for $owner/$repo#$pr — refusing (fail closed)."
    if [ -n "$bhit" ]; then
      die 11 "PR #$pr touches a BLOCKING sensitive path ($(printf '%s' "$bhit" | head -1)) — a human must approve it, not the QA bot."
    fi
  fi
  # The alerting set: loud, never blocking.
  hit="$(match_paths "$sensitive_json")"
  if [ "$hit" = "__ERR__" ]; then
    alert "could not evaluate sensitive paths for $owner/$repo#$pr — approving without that alert."
  elif [ -n "$hit" ]; then
    hit_count="$(printf '%s' "$hit" | grep -c . || true)"
    alert "PR #$pr touches $hit_count SENSITIVE path(s): $(printf '%s' "$hit" | tr '\n' ',' | sed 's/,$//; s/,/, /g'). These no longer hold the approval for a human — review them yourself."
  fi
fi

# --- Guard 6: CI must be green --------------------------------------------
# Re-derive CI status here rather than trusting the agent's "CI green" claim
# (root cause of the PR #287 mis-approval). Exclude the qa-review context
# itself to avoid a circular dependency (QA sets it just before calling this).
# Fail closed: refuse if the rollup can't be read (ERR), if ANY non-qa-review
# check is not passing, OR if there are NO non-qa-review checks at all -- an
# empty rollup is not proof CI ran, so it must not read as green (QA #398).
#
# ADVISORY CHECKS (added 2026-08-03): some gates here are LIVE — the deploy
# pre-flight rsync dry-run compares the repo against the running /opt/hydra and
# reds on pre-existing server drift that has nothing to do with the diff. The
# review skill already treats such reds as context rather than findings, but
# this guard counted them and refused anyway, so a clean GO could sit blocked on
# unrelated infrastructure (hydra#780). Checks named in the policy's
# advisory_checks are now excluded from the refusal and alerted on instead.
# Matching is by PREFIX, so the policy can carry a short stable token rather than
# a full check title that changes when someone edits the workflow — and so a job
# cannot smuggle the token in from the right. See the note below the read.
#
# The NO-CHECKS refusal is deliberately unchanged: an empty rollup is still not
# proof CI ran. A repo whose ONLY checks are advisory therefore still refuses,
# which is the fail-closed direction.
# Per-repo, exactly like every sibling list in this policy. Matching is by PREFIX
# on the check name, not `contains`: a substring test is fail-OPEN on a surface
# the PR author controls, because .github/workflows/ is only alert-guarded now —
# a PR could add a job named "... Deploy pre-flight ..." and buy itself an
# exemption from Guard 6. A prefix still tolerates the trailing detail in
# "Deploy pre-flight (rsync --delete dry-run vs /opt/hydra/)" without letting a
# new job smuggle the token in from the right.
advisory_json="$(jq -c --arg r "$owner/$repo" \
  '((.advisory_checks["*"] // []) + (.advisory_checks[$r] // []))' "$POLICY" 2>/dev/null || echo '[]')"
[ -n "$advisory_json" ] || advisory_json='[]'
# ...UNLESS this PR edits the workflows that DEFINE the check names. GitHub runs a
# same-repo PR's workflows from the PR HEAD, so job names in the rollup are
# author-controlled: adding `name: Deploy pre-flight — validate` to the `validate`
# job would exempt every gate inside it (skill-drift, secrets scan, JSON lint …)
# and report green on a visibly red PR. Prefix matching does not help — prefixing
# is exactly as reachable as infixing when the author owns the file. Notice 3b no
# longer refuses on .github/workflows/, so this is the gate that closes it: a PR
# touching workflow definitions gets NO advisory exemption at all.
# NOTE the empty-changed_files branch: file_trouble() alerts but leaves
# changed_files UNSET, so requiring `-n "$changed_files"` here meant a transient
# files-API failure SKIPPED this gate and preserved the exemption — a fail-open
# in the very gate that exists to close one. Unknown file list ⇒ we cannot prove
# the PR does not edit workflows ⇒ no exemption.
if [ -z "${changed_files:-}" ]; then
  if [ "$advisory_json" != "[]" ]; then
    alert "the changed-file list for $owner/$repo#$pr could not be established, so NO advisory-check exemption was applied — every check must be green. An unverifiable file list cannot rule out a self-granted exemption via a PR-authored workflow job name."
  fi
  advisory_json='[]'
elif printf '%s\n' "$changed_files" | grep -q '^\.github/workflows/'; then
  if [ "$advisory_json" != "[]" ]; then
    alert "PR #$pr edits .github/workflows/, so NO advisory-check exemption was applied — every check must be green. Check names come from the PR's own workflow files, so an exemption there would be self-granted."
  fi
  advisory_json='[]'
fi
rollup_json="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" \
  --json statusCheckRollup --jq '.statusCheckRollup' 2>/dev/null || echo "__ERR__")"
if [ "$rollup_json" = "__ERR__" ] || [ -z "$rollup_json" ]; then
  die 8 "could not read the CI rollup for $owner/$repo#$pr — refusing to approve (fail closed)."
fi
# Three DIFFERENT questions, three separate reads. Answering them all from one
# filtered array made "no checks exist" and "every check is advisory-exempt"
# indistinguishable, so an all-advisory repo refused with a message asserting CI
# never ran. Both still REFUSE — neither is proof CI meaningfully gated the PR,
# and that is the fail-closed direction — but they now say which one happened.
counts="$(printf '%s' "$rollup_json" | jq -r --argjson adv "$advisory_json" '
  [ .[]? | select((.context // .name) != "qa-review") ] as $all
  | ($all | map(select((.context // .name) as $n
        | any($adv[]; . as $a | ($n | startswith($a))) | not))) as $gating
  | "\($all | length) \($gating | length) \(
      $gating | map((((.conclusion // .state) // "PENDING") | ascii_upcase)
                    | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED")) | length)"
  ' 2>/dev/null || echo "ERR")"
[ "$counts" != "ERR" ] || die 8 "could not evaluate the CI rollup for $owner/$repo#$pr — refusing to approve (fail closed)."
read -r all_checks gating_checks bad_checks <<< "$counts"
[ "$all_checks" != "0" ] \
  || die 8 "no non-qa-review checks exist on $owner/$repo#$pr — an empty rollup is not proof CI ran; refusing to approve (fail closed)."
[ "$gating_checks" != "0" ] \
  || die 8 "every check on $owner/$repo#$pr is advisory-exempt ($all_checks total) — nothing actually gates this PR; refusing to approve (fail closed)."
[ "$bad_checks" = "0" ] \
  || die 8 "CI not green for $owner/$repo#$pr ($bad_checks non-passing of $gating_checks gating checks) — refusing to approve."

# Any advisory check that is red gets said out loud — approved, not ignored.
red_advisory="$(printf '%s' "$rollup_json" | jq -r --argjson adv "$advisory_json" '
  [ .[]? | select((.context // .name) as $n | any($adv[]; . as $a | ($n | startswith($a))))
         | select((((.conclusion // .state) // "PENDING") | ascii_upcase)
                  | . != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED")
         | (.context // .name) ] | join(", ")' 2>/dev/null || true)"
if [ -n "$red_advisory" ]; then
  alert "RED advisory check(s) NOT counted by Guard 6 on $owner/$repo#$pr: $red_advisory. These are treated as infrastructure/live-state gates rather than findings against this diff — confirm that is true before merging."
fi

# --- Guard 7: no unresolved Critical/Important review threads ---------------
# Carry findings forward mechanically: any unresolved thread whose first comment
# is tagged Critical/Important blocks the approval. This re-reads thread-resolution
# state independently of the agent's GO verdict -- but note it TRUSTS isResolved,
# which QA itself can set. It catches an UN-resolved blocker, not a wrongly-resolved
# one; mechanical fix-verification is Part B (the CTO fix-and-re-review loop).
# For the one finding where the resolver's identity IS the signal — the rebase
# warning — Guard 8 below additionally checks resolvedBy.
# Fail closed: if threads can't be read, refuse.
read -r -d '' gql <<'GQL' || true
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        pageInfo{ hasNextPage }
        nodes{ isResolved resolvedBy{ login } comments(first:1){ nodes{ body author{ login } } } }
      }
    }
  }
}
GQL
# Fail closed on >100 threads: if there is a second page we cannot see a blocker
# that lives past the first 100, so refuse rather than approve blind (QA #398).
open_blockers="$("$QA_GH" --repo "$owner/$repo" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" \
  --jq '.data.repository.pullRequest.reviewThreads
         | if .pageInfo.hasNextPage then "MORE"
           else ([.nodes[]? | select(.isResolved == false)
                  | (.comments.nodes[0].body // "")
                  | select(test("🔴|🟡"))] | length | tostring)
           end' \
  2>/dev/null || echo "ERR")"
[ "$open_blockers" = "0" ] || die 9 "$owner/$repo#$pr has unresolved Critical/Important review thread(s), or >100 threads to verify ($open_blockers) — refusing until they are addressed/resolved (or a human reviews)."

# --- Guard 8: rebase-integrity warnings must be surfaced ---------------------
# The advisory CI analyzer (scripts/check-rebase-integrity.sh, pr-validate.yml)
# writes a per-head report under /var/lib/hydra-qa/rebase-integrity. The chain
# "CI writes WARN → skill files a 🟡 REBASE WARNING thread → Guard 7 blocks
# while it is unresolved" has exactly one prose link: the skill remembering to
# file the finding. This guard closes it mechanically:
#   missing report  → for repos whose CI writes reports (QA_REBASE_REQUIRED_REPOS,
#                     default: hydra) this is a FAILED HAND-OFF → refuse; for
#                     external repos it is genuine no-data → pass
#   CLEAN           → pass
#   WARN            → a review thread whose first comment carries the literal
#                     "REBASE WARNING [<head sha7>]" marker must EXIST, be filed
#                     by the bot, AND be RESOLVED — by anyone, including the
#                     reviewing bot itself once it has verified the deletions
#                     were intended and written that reasoning into the thread
#                     (SKILL.md Step 3d.3). That is the DEFAULT and current
#                     posture. Setting QA_REBASE_ACK_REQUIRE_INDEPENDENT=1
#                     additionally demands a human who is neither the PR author
#                     nor the bot; it is OFF and stays off. The paragraph below
#                     describes that stricter mode, not today's behaviour:
#                     an author clearing their own
#                     warning is self-certification, which is what that mode
#                     exists to prevent (observed on hydra#747 — all eight
#                     threads filed by the bot, all eight resolved by the author).
#   ERROR/unreadable→ rebase state unverified → refuse (fail closed)
# The sha7 in the marker forces re-filing per push; a new push lands with the
# new head's checks pending, so Guard 6 covers the report-not-yet-written race.
# Known limits (documented, accepted): the head can move between Guard 6's
# rollup read and this guard's headRefOid read — the same push-mid-approval race
# every guard in this file has; and the state dir lives on the CI host where
# pr-validate executes PR-controlled code, so a hostile insider PR could forge
# reports — same trust model as the self-hosted runner itself. The interior
# field cross-check below catches accidental key mixups, not that adversary.
RI_DIR="${QA_REBASE_STATE_DIR:-/var/lib/hydra-qa/rebase-integrity}"
head_oid="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
# 40-hex only: this value is spliced into a filesystem path and a jq program —
# anything else (gh error text, multiline) must refuse, not degrade to
# missing-file=pass.
[[ "$head_oid" =~ ^[0-9a-f]{40}$ ]] || die 10 "could not read a valid headRefOid for $owner/$repo#$pr (got '$head_oid') — cannot verify rebase-integrity state; refusing (fail closed)."
ri_file="$RI_DIR/${owner}__${repo}-pr-${pr}-${head_oid}.json"
if [ ! -f "$ri_file" ]; then
  # A missing report must not read as clean where the analyzer is EXPECTED to
  # have run: if the state hand-off failed (dir unwritable, analyzer died before
  # its ERROR sentinel), the only trace is this absence — pass here and the
  # fail-closed guarantee silently evaporates. Repos in the required list get
  # refused; external repos (no analyzer in their CI) legitimately have no file.
  for ri_required in ${QA_REBASE_REQUIRED_REPOS:-hydra}; do
    [ "$repo" = "$ri_required" ] && die 10 "no rebase-integrity report for $owner/$repo#$pr head ${head_oid:0:7} — the PR Validation analyzer should have written one (failed hand-off?); re-run CI or investigate $RI_DIR (fail closed)."
  done
else
  # Interior fields must match the filename-derived key (catches key-format
  # drift between analyzer and guard, and stale/mis-filed reports).
  ri_key_ok="$(jq -r --arg repo "$owner/$repo" --arg pr "$pr" --arg head "$head_oid" \
    'if (.repo == $repo) and ((.pr | tostring) == $pr) and (.head_sha == $head)
     then "OK" else "MISMATCH" end' "$ri_file" 2>/dev/null || echo ERR)"
  [ "$ri_key_ok" = "OK" ] || die 10 "rebase-integrity report $ri_file interior fields do not match its key ($ri_key_ok) — refusing (fail closed)."
  ri_status="$(jq -r '.status // "ERROR"' "$ri_file" 2>/dev/null || echo ERROR)"
  case "$ri_status" in
    CLEAN) : ;;
    WARN)
      ri_marker="REBASE WARNING [${head_oid:0:7}]"
      # Same reviewThreads query as Guard 7, reading the threads that carry the
      # marker AND were filed by the bot — a marker comment posted by anyone else
      # (e.g. the PR author pre-empting the finding) must not satisfy this gate.
      # Match against the whole bot_logins SET rather than one login: GraphQL
      # reports an App as Bot{login:"muso-qa-bot"} while REST uses
      # "muso-qa-bot[bot]", and PRs open across the cutover (or across a
      # kill-switch rollback) carry threads filed under the host account. Testing
      # one value would silently match nothing and refuse every WARN head.
      # Fail closed on unreadable threads or a second page.
      # One line per bot-filed marker thread: "<OK|SKIP> <resolver-or-unresolved>".
      # OK means an independent human closed it; the resolver identity is compared
      # through the same norm/$logins set as the filer, so a bot resolving under
      # any of its three login spellings is still recognised as the bot.
      #
      # We do NOT also assert `resolvedBy.__typename == "User"`. That looks like a
      # missing defence against an unlisted GitHub App resolving the thread, but
      # PullRequestReviewThread.resolvedBy is typed `User` (a concrete OBJECT), not
      # `Actor` — `Bot` implements Actor/Node/UniformResourceLocatable and is a
      # DIFFERENT type, so the schema cannot produce one here. GitHub rejects the
      # query at validation:
      #   resolvedBy { ... on Bot { login } }
      #   -> "Fragment on Bot can't be spread inside User" (parentName: "User")
      # The check would therefore be unfalsifiable, and any test for it would pass
      # with the check reverted — a vacuous assertion in a security gate. Were the
      # type ever to loosen, a non-User actor could only arrive as null, which the
      # jq maps to NONE -> SKIP -> exit 10 (covered by the "resolvedBy absent"
      # test). The residual risk the type system CANNOT see is a machine USER
      # account on a PAT; `bot_logins` is the control for that, which is why the
      # resolver is tested against that set rather than against its type.
      #
      # Fetched ONCE into a variable rather than piped straight into jq: the
      # cross-head carryover below re-reads these same threads looking for OTHER
      # heads' markers, and a second graphql round-trip could observe a different
      # thread state mid-approval. Empty means the call failed — refuse there and
      # then rather than letting jq turn a transport failure into "no threads".
      ri_threads_json="$("$QA_GH" --repo "$owner/$repo" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" 2>/dev/null || true)"
      [ -n "$ri_threads_json" ] || \
        die 10 "cannot read review threads for $owner/$repo#$pr (graphql call failed) — refusing (fail closed)."
      ri_threads="$(jq -r --arg marker "$ri_marker" --arg author "$author" --argjson logins "$bot_logins_json" \
            'def norm: ascii_downcase | sub("^app/";"") | sub("\\[bot\\]$";"");
             def isbot($l): ($logins | map(norm) | index($l)) != null;
             .data.repository.pullRequest.reviewThreads
               | if .pageInfo.hasNextPage then "MORE"
                 else ([.nodes[]?
                        | select(((.comments.nodes[0].body // "") | contains($marker))
                                 and (((.comments.nodes[0].author.login // "") | norm) as $a
                                      | isbot($a)))
                        | ((.resolvedBy.login // "") | norm) as $r
                        | (if (.isResolved == true) and ($r != "")
                                and ($r != ($author | norm)) and ((isbot($r)) | not)
                           then "OK" else "SKIP" end)
                          + " " + (.resolvedBy.login // "unresolved")]
                       | join("\n"))
                 end' <<<"$ri_threads_json" \
        2>/dev/null || echo "ERR")"
      case "$ri_threads" in
        MORE|ERR)
          die 10 "cannot verify the REBASE WARNING thread for $owner/$repo#$pr (threads unreadable or >100: $ri_threads) — refusing (fail closed)." ;;
      esac
      if [ -z "$ri_threads" ]; then
        # No thread for THIS head. Before refusing, try the cross-head carryover:
        # a human resolving a REBASE WARNING judges the flagged CONTENT, not the
        # sha, so that judgement still holds on a head whose report carries a
        # byte-identical warn_digest (analyzer rolls it up from the warn signals'
        # line-level digests). This is what stops the ack treadmill — hydra PRs
        # have collected up to 11 acks of one unchanged finding, and an ack that
        # cheap gets clicked unread, which is worse than the risk it guards.
        # Every leg must hold, else fall through to the original refusal:
        #   * this head's report has a real 64-hex warn_digest (a report predating
        #     the field can never carry — no identity, no carry);
        #   * some OTHER head of THIS pr has a report with the SAME digest whose
        #     interior key matches its filename (no stale/mis-filed reports); and
        #   * that head's marker thread was filed by the bot AND is RESOLVED — by
        #     an INDEPENDENT human too, once the staged rollout below is enabled.
        # The resolved check is load-bearing HERE specifically: Guard 7 only sees
        # unresolved threads, so it cannot vouch for a prior head's ack the way it
        # does for the current one. A carried-forward ack must clear exactly the
        # same bar as a freshly-filed one — carrying a weaker ack forward would
        # make this the cheapest way around the independence rule.
        ri_digest="$(jq -r '.warn_digest // ""' "$ri_file" 2>/dev/null || echo "")"
        ri_carried=""
        if [[ "$ri_digest" =~ ^[0-9a-f]{64}$ ]]; then
          # "<OK|SKIP> <sha7>" per RESOLVED bot-filed marker thread of ANY head,
          # graded by the same independence test as $ri_threads above.
          ri_acked_sha7s="$(jq -r --arg author "$author" --argjson logins "$bot_logins_json" \
                'def norm: ascii_downcase | sub("^app/";"") | sub("\\[bot\\]$";"");
                 def isbot($l): ($logins | map(norm) | index($l)) != null;
                 .data.repository.pullRequest.reviewThreads
                   | if .pageInfo.hasNextPage then empty
                     else (.nodes[]? | select(.isResolved == true)
                           | select(((.comments.nodes[0].author.login // "") | norm) as $a
                                    | isbot($a))
                           | select((.comments.nodes[0].body // "")
                                    | test("REBASE WARNING \\[[0-9a-f]{7}\\]"))
                           | ((.resolvedBy.login // "") | norm) as $r
                           | (if ($r != "") and ($r != ($author | norm)) and ((isbot($r)) | not)
                              then "OK" else "SKIP" end)
                             + " " + ((.comments.nodes[0].body // "")
                                      | capture("REBASE WARNING \\[(?<s>[0-9a-f]{7})\\]").s))
                     end' <<<"$ri_threads_json" 2>/dev/null || true)"
          # Mirrors the staged rollout: while the flag is off a resolved ack of
          # any provenance carries, exactly as it satisfies the fresh-thread path.
          if [ "${QA_REBASE_ACK_REQUIRE_INDEPENDENT:-0}" = "1" ]; then
            ri_ack_re='^OK '
          else
            ri_ack_re='^(OK|SKIP) '
          fi
          for ri_prior in "$RI_DIR/${owner}__${repo}-pr-${pr}-"*.json; do
            [ -f "$ri_prior" ] || continue
            ri_p_head="${ri_prior##*-pr-"${pr}"-}"; ri_p_head="${ri_p_head%.json}"
            [[ "$ri_p_head" =~ ^[0-9a-f]{40}$ ]] || continue
            [ "$ri_p_head" != "$head_oid" ] || continue
            printf '%s\n' "$ri_acked_sha7s" | grep -Eq -- "${ri_ack_re}${ri_p_head:0:7}\$" || continue
            [ "$(jq -r --arg repo "$owner/$repo" --arg pr "$pr" --arg head "$ri_p_head" --arg d "$ri_digest" \
                 'if (.repo == $repo) and ((.pr | tostring) == $pr) and (.head_sha == $head)
                     and (.status == "WARN") and (.warn_digest == $d)
                  then "OK" else "NO" end' "$ri_prior" 2>/dev/null || echo NO)" = "OK" ] || continue
            ri_carried="$ri_p_head"; break
          done
        fi
        [ -n "$ri_carried" ] || die 10 "rebase-integrity report for ${head_oid:0:7} is WARN but no '$ri_marker' review thread exists — file the finding (muso-github-code-review Step 3d) before approving."
        echo "qa-pr-approve: REBASE WARNING for ${head_oid:0:7} carries forward the human ack on ${ri_carried:0:7} — identical warn_digest ${ri_digest:0:12}…"
      else
        # STAGED ROLLOUT. Tightening an approval gate in one shot is a trap: the very
        # PR that ships the rule is judged against it, and no head created before the
        # rule existed can satisfy it — the change becomes unmergeable by
        # construction. So the independence requirement ships DISABLED and is turned
        # on by config once this is deployed. Default (0) is byte-for-byte the
        # previous behaviour: the marker thread must exist, and Guard 7 above blocks
        # while it is unresolved. Flip QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 in the
        # follow-up (see muso-github-code-review SKILL.md "Scope") to require that
        # the resolver be a human who is neither the PR author nor the bot.
        if [ "${QA_REBASE_ACK_REQUIRE_INDEPENDENT:-0}" = "1" ]; then
          if ! printf '%s\n' "$ri_threads" | grep -q '^OK '; then
            ri_seen="$(printf '%s\n' "$ri_threads" | sed 's/^SKIP /rejected:/' | paste -sd' ' -)"
            die 10 "the '$ri_marker' thread for $owner/$repo#$pr was never acknowledged by an independent human ($ri_seen) — neither the PR author ($author) nor the bot can clear its own rebase warning; ask another reviewer to resolve the thread."
          fi
        fi
      fi
      ;;
    *) die 10 "rebase-integrity report for ${head_oid:0:7} is '$ri_status' — rebase state unverified; refusing to approve (fail closed)." ;;
  esac
fi

# --- Guard 9: blast radius (SHIPPED DISABLED — see below) --------------------
# CI's check-blast-radius.sh writes a per-head report naming what a wrong change
# would reach. When enabled, a CRITICAL tier holds auto-approval for a human.
#
# THIS SHIPS OFF (QA_BLAST_RADIUS_GATE unset/0 ⇒ this block is a pure no-op) and
# is enabled in a follow-up once the code is on node-8. Enabling it in the PR
# that introduces it would judge that PR against a rule no earlier head could
# satisfy — the same trap ac67c64f documents for the rebase-ack rule — and this
# PR's own diff trips the gate-edit signal, so it would refuse itself.
#
# Fails CLOSED once enabled: an unreadable or malformed report refuses rather
# than defaulting to LOW. A gate that treats "I could not tell" as "safe" is the
# fail-open pattern Guard 3b/3c exist to avoid.
if [ "${QA_BLAST_RADIUS_GATE:-0}" = "1" ]; then
  br_dir="${QA_BLAST_STATE_DIR:-/var/lib/hydra-qa/blast-radius}"
  br_file="$br_dir/${owner}__${repo}-pr-${pr}-${head_oid}.json"
  # Same repo-gating Guard 8 uses, and for the same reason: check-blast-radius.sh
  # runs only in hydra's pr-validate.yml, but this script approves every repo in
  # the external allowlist. Without this, flipping the flag would refuse EVERY
  # core-backend / industry-data-processing approval on a report their CI never
  # writes — a missing report is a failed hand-off only where one was expected.
  br_required=0
  for _r in ${QA_BLAST_REQUIRED_REPOS:-hydra}; do
    [ "$_r" = "$repo" ] && br_required=1
  done
  if [ ! -r "$br_file" ]; then
    if [ "$br_required" = 1 ]; then
      die 13 "no blast-radius report for ${head_oid:0:7} ($br_file) — impact unverified; refusing to approve (fail closed). Re-run PR Validation."
    fi
    echo "qa-pr-approve: no blast-radius report for $owner/$repo (no analyzer in that repo's CI) — Guard 9 passes on no-data."
  else
  # Cross-check the interior fields against the filename, exactly as Guard 8
  # does — INCLUDING .repo. Both report kinds live under /var/lib/hydra-qa/ and
  # share the ${owner}__${repo}-pr-${pr}-${sha} key, so .repo is precisely the
  # field that catches a cross-repo mis-file.
  br_json="$(jq -e --arg r "$owner/$repo" --arg h "$head_oid" --arg p "$pr" \
    'select(.repo == $r and .head_sha == $h and ((.pr | tostring) == $p))' "$br_file" 2>/dev/null)" \
    || die 13 "blast-radius report at $br_file does not describe $owner/$repo#$pr @ ${head_oid:0:7} (interior repo/head_sha/pr mismatch) — refusing to approve."
  br_status="$(printf '%s' "$br_json" | jq -r '.status // "MISSING"')"
  br_tier="$(printf '%s' "$br_json" | jq -r '.tier // "MISSING"')"
  case "$br_status" in
    OK|CLEAN) ;;
    *) die 13 "blast-radius analysis for ${head_oid:0:7} is '$br_status' — impact unverified; refusing to approve (fail closed)." ;;
  esac
  case "$br_tier" in
    LOW|MEDIUM|HIGH) ;;
    CRITICAL)
      br_why="$(printf '%s' "$br_json" \
        | jq -r '[.signals? // [] | .[]? | select(.severity? == "critical") | .id] | join(", ")' \
        2>/dev/null || true)"
      die 13 "blast radius is CRITICAL for $owner/$repo#$pr (${br_why:-unspecified}) — this change reaches too far to auto-approve; a human must review and approve it."
      ;;
    *) die 13 "blast-radius report for ${head_oid:0:7} has unrecognized tier '$br_tier' — refusing to approve (fail closed)." ;;
  esac
  echo "qa-pr-approve: blast radius $br_tier — below the CRITICAL hold."
  fi
fi

# --- Guard 5: log BEFORE the write ------------------------------------------
ts="$(date -u +%FT%TZ)"
mkdir -p "$LOG_DIR" || die 6 "cannot create log dir $LOG_DIR — refusing to approve unlogged."
# "identity" records WHICH account made the write, so the audit trail can be
# separated pre/post identity migration (and per repo during the staged cutover).
log_line="$(printf '{"agent":"qa","action":"github_pr_approve","target":"%s/%s#%s","requester":"%s","identity":"%s","timestamp":"%s","authorization":"qa-review-go-verdict"}' \
  "$owner" "$repo" "$pr" "$requester" "$me" "$ts")"
printf '%s\n' "$log_line" >> "$LOG_DIR/$(date -u +%F).jsonl" || die 6 "cannot write audit log — refusing to approve unlogged."

# --- Approve (NEVER merge) --------------------------------------------------
if ! "$QA_GH" --repo "$owner/$repo" pr review "$pr" --repo "$owner/$repo" --approve --body "$body"; then
  die 7 "gh pr review --approve failed for $owner/$repo#$pr."
fi
echo "qa-pr-approve: approved $owner/$repo#$pr as $me (requester $requester). NOT merged."

# A GitHub App cannot be a CODEOWNER, so where we run AS THE APP the approval
# counts toward the required review but does NOT clear the code-owner gate.
#
# This used to fire on every repo in require_human_codeowner_repos, which was
# misleading: identity.app_repos is empty, so every call falls through to the
# host login (adk47) — and CODEOWNERS grants `* @adk47`, so the bot's approval
# DOES satisfy the code-owner gate today (verified on hydra#786 and hydra#777,
# both APPROVED → mergeStateStatus CLEAN). Telling people the PR "still needs a
# human" when it does not is exactly the friction this pass exists to remove.
# The note now fires only when the repo is actually served by the App identity.
# Read through lib/qa-policy.sh rather than spelling `(.key // []) | index($r)`
# inline: that idiom collapses "not a member" and "key missing / file malformed"
# into one answer, which is the bug class the helper was written to close. Here
# it would silently SUPPRESS the note — the same false-negative direction this
# change set is trying to remove.
# `|| _rc=$?` is load-bearing: qa_policy_has returns 1 for "not a member", which
# is a NORMAL answer — as a bare command under `set -e` that would abort the
# script after the approval was already recorded.
_rc_co=0; qa_policy_has "$POLICY" '.require_human_codeowner_repos' "$owner/$repo" || _rc_co=$?
_rc_app=0; qa_policy_has "$POLICY" '.identity.app_repos' "$owner/$repo" || _rc_app=$?
if [ "$_rc_co" = 2 ] || [ "$_rc_app" = 2 ]; then
  # 2 = key missing/null/not-an-array/unreadable. Never silently read as "no".
  alert "could not determine the code-owner posture for $owner/$repo from $POLICY (rc $_rc_co/$_rc_app) — verify manually whether this approval clears the code-owner gate."
elif [ "$_rc_co" = 0 ] && [ "$_rc_app" = 0 ]; then
  echo "qa-pr-approve: NOTE — $owner/$repo is served by the GitHub App identity, which can never be a CODEOWNER. This approval counts as a review but does NOT clear the code-owner gate."
fi

# --- Post-check: report real review/merge state, don't assume "done" --------
echo "qa-pr-approve: post-approval state —"
"$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json reviewDecision,mergeStateStatus,state \
  --jq '"  reviewDecision=\(.reviewDecision)  mergeStateStatus=\(.mergeStateStatus)  state=\(.state)"' 2>/dev/null \
  || echo "  (could not read post-approval state; check the PR on GitHub)"
echo "qa-pr-approve: if anything other than reviewDecision=APPROVED / a clean mergeStateStatus shows, tell the requester what still blocks (CODEOWNERS, required checks). A human performs the merge."

# Replay every alert LAST — after the post-check, so nothing prints below them.
# The earlier inline echoes are for ordering context; this block is what the
# agent is instructed to relay, and on a truncated tail it is what survives.
_replay_alerts
