#!/usr/bin/env bash
# qa-handoff.sh — sourceable, fail-safe transport for CI's advisory QA hand-off.
#
# WHY THIS EXISTS (T10 of data/node8-to-pods-fable-a2/plan.md):
# The two advisory analyzers PR Validation runs —
# scripts/check-rebase-integrity.sh and scripts/check-blast-radius.sh — hand their
# per-head verdict to three consumers: qa-pr-approve.sh Guard 8, Guard 9, and the
# QA review skill (skills-all/muso-github-code-review, Steps 3d/3e). Until T10
# that hand-off was a file under /var/lib/hydra-qa, i.e. a directory on the CI
# host. That works only while the runner, the QA agent and the analyzers are the
# same box. The moment QA reviews from a pod (T9) the file is on a machine the
# consumer cannot read, and the guards — which fail CLOSED — refuse every
# approval. This module moves the hand-off onto the PULL REQUEST itself: a hidden
# comment carrying the analyzers' reports, gzipped and base64-encoded, one per
# head sha. GitHub is then the channel, and any process with repo read access can
# consume it.
#
# WHY A PR COMMENT AND NOT A CHECK RUN OR AN ACTIONS ARTIFACT:
#   * Guard 8's ack carry-forward needs the reports of PRIOR heads of the same PR
#     (the warn_digest comparison). Comments give that history for free in one
#     paginated read; a check run is keyed per-sha (N lookups) and an Actions
#     artifact requires run discovery, an authenticated zip download and unzip.
#   * A comment is one API call and needs no `actions: read` scope.
#   * It is auditable: a human can see on the PR that the hand-off happened.
# The payload is inside an HTML comment, so the rendered PR body shows nothing.
#
# TRUST MODEL. A hand-off is only accepted from a login in QA_HANDOFF_AUTHORS
# (default `github-actions`, the author of a comment posted with the workflow's
# GITHUB_TOKEN). Deliberately NOT policies/qa-approval-policy.json's bot_logins:
# that list includes the host account, which a human can drive, so folding it in
# here would let a human forge a CLEAN hand-off. Note the residual exposure is
# the same one the on-disk hand-off always had — PR Validation executes
# PR-controlled code, so a hostile insider PR can forge its own analyzer output.
# The interior cross-checks in qa-pr-approve.sh catch mixups, not that adversary.
#
# FAIL-SAFE BY CONSTRUCTION. Everything here returns 0 and reports "no usable
# hand-off" as EMPTY OUTPUT, because the callers run under `set -euo pipefail`
# and a throw inside a command substitution would abort an approval run in a way
# that looks like a script bug rather than a refusal. An unreadable GitHub, a
# mangled payload and "CI never published one" are deliberately indistinguishable
# here: every consumer's next move (fall back to the on-disk report, else refuse
# where a report is required) is the same for all three, and it is fail-closed.
#
# EXCEPT FOR MUTATING CALLERS. A reader can treat "unreadable" as "no hand-off";
# a PUBLISHER cannot, because it is about to delete and post — "I could not read
# the existing hand-offs" must never silently mean "there are none to withdraw"
# (that is how a stale CLEAN survives a rerun). qa_handoff_payloads therefore
# ALSO sets QA_HANDOFF_READ_RC — 0 read OK (with or without hand-offs), 2 the
# read failed. Only the publisher branches on it, and only when it is invoked
# WITHOUT a command substitution (a subshell would discard the global).
#
# Usage (sourcing has no side effects — the qa-policy.sh doctrine):
#   source "$(dirname "$0")/lib/qa-handoff.sh"
#   all="$(qa_handoff_payloads "$gh" "$owner/$repo" "$pr")"      # NDJSON, may be empty
#   ri="$(qa_handoff_report "$all" "$owner/$repo" "$pr" rebase-integrity "$head")"
#
# Env: QA_HANDOFF_AUTHORS  space-separated trusted logins (default github-actions);
#                          `[bot]` and `app/` spellings are normalised away.
#      QA_HANDOFF_GH        the gh INVOCATION PREFIX as a bash array (default
#                          (gh)). The guard sets it to `qa-gh.sh --repo <o/r>`
#                          because the identity shim CONSUMES --repo to scope its
#                          token; `gh api` itself does NOT accept --repo ("unknown
#                          flag: --repo"), so a publisher running as plain `gh`
#                          must not be handed it. Passing the prefix explicitly is
#                          what keeps both callers correct — this exact confusion
#                          shipped a publisher that 100% failed in CI while every
#                          test passed, because the stubs tolerated the flag.

# Shellcheck note: this file is sourced, never executed, so there is no main.

# The gh invocation prefix (see QA_HANDOFF_GH above). Array, not a string, so a
# caller can add the shim's flags without word-splitting surprises.
QA_HANDOFF_GH=("${QA_HANDOFF_GH[@]:-gh}")

# qa_handoff_marker_prefix — the literal that identifies a hand-off comment.
# Keep this stable: it is the contract between publisher and consumers across
# deploys. Bump the `v1` only if the payload shape changes incompatibly, and
# teach both sides in the same PR.
qa_handoff_marker_prefix() {
  printf '%s' '<!-- muso-qa-handoff v1 payload='
}

# qa_handoff_body <b64> — the exact comment body the publisher posts.
qa_handoff_body() {
  printf '%s%s -->' "$(qa_handoff_marker_prefix)" "$1"
}

# qa_handoff_encode [<file>|-] — gzip -9 -n (deterministic: no mtime) then base64
# on ONE line. Determinism matters: a re-publish of an unchanged report produces
# an identical body, so the publisher can skip a no-op PATCH.
qa_handoff_encode() {
  local src="${1:--}"
  if [ "$src" = "-" ]; then
    gzip -9 -n 2>/dev/null | base64 2>/dev/null | tr -d '\n'
  else
    gzip -9 -n <"$src" 2>/dev/null | base64 2>/dev/null | tr -d '\n'
  fi
  printf '\n'
  return 0
}

# qa_handoff_decode <b64> — inverse of encode. Non-zero (and no output) when the
# payload is not valid gzip+base64 JSON; callers treat that as "no hand-off".
qa_handoff_decode() {
  local b64="$1" out
  [ -n "$b64" ] || return 1
  out="$(printf '%s' "$b64" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out"
  return 0
}

# qa_handoff_root — where CI's analyzers write the per-head reports.
# /var/lib/hydra-qa when this runner can write it (node-8: the transitional
# on-disk consumers keep working), else a per-run dir under RUNNER_TEMP (ARC
# pods, where the host path is root-owned). Must agree between the analyzer
# steps and the publish step, so it lives here rather than in the workflow.
qa_handoff_root() {
  local root="${QA_HANDOFF_ROOT:-}"
  # An explicit QA_HANDOFF_ROOT wins (pr-validate.yml exports the resolved value
  # so the analyzer steps and the publish step cannot disagree). No writability
  # probe here: a caller that pins the path gets the analyzer's own loud exit 3
  # if it is unwritable, which is the pre-T10 behaviour.
  if [ -n "$root" ]; then
    mkdir -p "$root/rebase-integrity" "$root/blast-radius" 2>/dev/null || true
    printf '%s\n' "$root"
    return 0
  fi
  root=/var/lib/hydra-qa
  if mkdir -p "$root/rebase-integrity" "$root/blast-radius" 2>/dev/null \
    && [ -w "$root/rebase-integrity" ] && [ -w "$root/blast-radius" ]; then
    printf '%s\n' "$root"
    return 0
  fi
  root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/qa-handoff"
  # Say it out loud: on node-8 this is a REGRESSION (the host dir should be
  # writable there, and the transitional on-disk consumers read it), not a
  # normal pod-shaped path. A silent switch here would only surface as a pod
  # failing to find a report weeks later.
  echo "qa-handoff: /var/lib/hydra-qa is not writable on this runner — hand-off state goes to $root (GitHub is the consumers' channel either way)" >&2
  mkdir -p "$root/rebase-integrity" "$root/blast-radius" 2>/dev/null || true
  printf '%s\n' "$root"
  return 0
}

# qa_handoff_clear_report <root> <kind> <owner/repo> <pr> <head-sha> — delete this
# head's on-disk report for <kind>, so a STALE one cannot be republished.
#
# WHY THIS EXISTS (QA finding, round 3 on PR #1427). /var/lib/hydra-qa is a
# PERSISTENT host path. Run 1 on head H writes CLEAN there and publishes it. Run 2
# on the same head H starts, and if its analyzer dies in the prologue — before
# even its early `write_state ERROR` sentinel, e.g. during `git fetch` or on a
# usage exit that happens before the trap is installed — the run-1 file is still
# on disk. The publisher then reads it, invalidates the old comment and reposts
# the SAME CLEAN report with a FRESH comment timestamp, while the analyzers' own
# failures are swallowed into ::warning:: by the workflow. Guard 8 sees a
# plausible hand-off and can approve on evidence from a previous run.
#
# Clearing the file BEFORE the analyzer starts makes "the run produced no report"
# indistinguishable from "there was never one", which is exactly what the
# fail-closed consumers expect. Callers: both analyzer steps in pr-validate.yml.
qa_handoff_clear_report() {
  local root="$1" kind="$2" repo="$3" pr="$4" head="$5"
  # Refuse to build a path out of anything unexpected: this function deletes.
  [ -n "$root" ] && [ -n "$kind" ] || return 0
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
  [[ "$pr" =~ ^[0-9]+$ ]] || return 0
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
  local f="$root/$kind/${repo//\//__}-pr-$pr-$head.json"
  rm -f -- "$f" 2>/dev/null || true
  # VERIFY, do not assume. A root-owned/immutable report (or a directory we can
  # read but not write) survives a suppressed `rm`, and a rerun whose analyzer
  # then dies before writing its sentinel would republish that stale CLEAN as
  # this run's evidence — with a green hand-off job (QA finding, round 6). The
  # caller must FAIL here, not warn.
  if [ -e "$f" ]; then
    echo "qa-handoff: could not remove the stale $kind report at $f — refusing to run the analyzer, because that report would be republished as this run's evidence" >&2
    return 1
  fi
  return 0
}

# qa_handoff_comments <owner/repo> <pr> — the PR's comments as ONE JSON array
# (REST, fully paginated). Empty on any failure.
qa_handoff_comments() {
  local repo="$1" pr="$2" raw
  raw="$("${QA_HANDOFF_GH[@]}" api --paginate \
    "repos/$repo/issues/$pr/comments?per_page=100" 2>/dev/null)" || return 0
  [ -n "$raw" ] || { printf '[]'; return 0; }
  # Each --paginate page is its own JSON document, so slurp and concatenate. A
  # non-array page (an error object) becomes [] rather than being iterated as
  # garbage: this is transport, not trust — authorship is checked next.
  printf '%s\n' "$raw" | jq -cs 'if (map(type == "array") | all) then (add // []) else error("non-array page") end' 2>/dev/null \
    || printf '[]'
  return 0
}

# qa_handoff_payloads <owner/repo> <pr> — one JSON object per TRUSTED
# hand-off comment, oldest first:
#   {"comment_id":"…","created_at":"…","head_sha":"…","repo":"…","pr":"…",
#    "reports":{"rebase-integrity":{…},"blast-radius":{…}},"missing":[…]}
# Empty output = no trusted hand-off on this PR (published yet, for this repo, or
# never). A payload that fails to decode or validate is dropped SILENTLY, which
# is fail-closed: the guard then sees no report for that head.
qa_handoff_payloads() {
  local repo="$1" pr="$2"
  local raw entries line cid created b64 json
  QA_HANDOFF_READ_RC=2
  raw="$("${QA_HANDOFF_GH[@]}" api --paginate \
    "repos/$repo/issues/$pr/comments?per_page=100" 2>/dev/null)" || return 0
  [ -n "$raw" ] || return 0
  # NOTE: RC becomes 0 only once the response has actually PARSED. A successful
  # HTTP status carrying a malformed or non-array body is an UNREADABLE list, not
  # an empty one — the publisher must not read it as "nothing to withdraw" (QA
  # finding, round 6). Hence the strict error() below instead of coercing bad
  # pages to [].
  entries="$(printf '%s\n' "$raw" | jq -cs --arg authors "${QA_HANDOFF_AUTHORS:-github-actions}" '
      def norm: ascii_downcase | sub("^app/"; "") | sub("\\[bot\\]$"; "");
      ($authors | ascii_downcase | split(" ") | map(select(length > 0))) as $ok
      | if (map(type == "array") | all) then (add // []) else error("non-array page") end
      | .[]
      | select((.body // "") | test("<!-- muso-qa-handoff v1 "))
      | select(((.user.login // "") | norm) as $l | ($ok | index($l)) != null)
      | {id: (.id | tostring), created_at: (.created_at // ""),
         b64: ([.body | scan("payload=([A-Za-z0-9+/=]+)")]
               | if length > 0 then .[-1][0] else "" end)}
      | select(.b64 != "")
    ' 2>/dev/null)" || return 0
  # shellcheck disable=SC2034  # read by the publisher (mutating caller), see the header
  QA_HANDOFF_READ_RC=0
  [ -n "$entries" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cid="$(printf '%s' "$line" | jq -r '.id' 2>/dev/null || true)"
    created="$(printf '%s' "$line" | jq -r '.created_at' 2>/dev/null || true)"
    b64="$(printf '%s' "$line" | jq -r '.b64' 2>/dev/null || true)"
    json="$(qa_handoff_decode "$b64" 2>/dev/null || true)"
    [ -n "$json" ] || continue
    printf '%s' "$json" | jq -c --arg id "$cid" --arg created "$created" '
        select(.version == 1)
        | select((.repo // "") != "" and (.head_sha // "") != "")
        | {comment_id: $id, created_at: $created, head_sha: .head_sha,
           repo: .repo, pr: ((.pr // "") | tostring),
           reports: (.reports // {}), missing: (.missing // [])}
      ' 2>/dev/null || true
  done <<<"$entries"
  return 0
}

# qa_handoff_report <payloads-ndjson> <owner/repo> <pr> <kind> <head-sha> — the
# report JSON for exactly this head and kind, from the NEWEST hand-off that
# covers it. Empty when absent. Pure: no network, so Guards 8 and 9 can share
# one fetch (the guard calls qa_handoff_payloads once for both).
qa_handoff_report() {
  local all="$1" repo="$2" pr="$3" kind="$4" head="$5"
  [ -n "$all" ] || return 0
  printf '%s\n' "$all" | jq -cs --arg repo "$repo" --arg pr "$pr" \
    --arg head "$head" --arg kind "$kind" '
      map(select(.repo == $repo and .pr == $pr and .head_sha == $head))
      | sort_by(.created_at) | last
      | if . == null then empty else (.reports[$kind] // empty) end
    ' 2>/dev/null || true
  return 0
}

# qa_handoff_prior <payloads-ndjson> <owner/repo> <pr> <kind> <head-sha> —
# NDJSON {"head":"<sha40>","report":{…}} for every OTHER head of this PR that
# carries a report of <kind>. Guard 8's carry-forward reads this instead of
# globbing the on-disk state dir.
qa_handoff_prior() {
  local all="$1" repo="$2" pr="$3" kind="$4" head="$5"
  [ -n "$all" ] || return 0
  printf '%s\n' "$all" | jq -c --arg repo "$repo" --arg pr "$pr" \
    --arg kind "$kind" --arg head "$head" '
      select(.repo == $repo and .pr == $pr and .head_sha != $head)
      | (.reports[$kind] // null) as $r
      | select($r != null)
      | {head: .head_sha, report: $r}
    ' 2>/dev/null || true
  return 0
}

# qa_handoff_comment_ids <payloads-ndjson> <owner/repo> <pr> <head-sha> — EVERY
# trusted hand-off comment id for this head, oldest first.
#
# Why plural: the publisher INVALIDATES before it publishes (delete, then post),
# so that a hand-off can never outlive the run that produced it. Returning only
# the newest id would leave an older same-head comment behind on a re-run whose
# publish then failed — and Guards 8/9 would read that stale CLEAN report as
# this head's evidence. (QA finding on the first review of this PR.)
qa_handoff_comment_ids() {
  local all="$1" repo="$2" pr="$3" head="$4"
  [ -n "$all" ] || return 0
  printf '%s\n' "$all" | jq -rs --arg repo "$repo" --arg pr "$pr" --arg head "$head" '
      map(select(.repo == $repo and .pr == $pr and .head_sha == $head))
      | sort_by(.created_at) | .[] | .comment_id
    ' 2>/dev/null || true
  return 0
}
