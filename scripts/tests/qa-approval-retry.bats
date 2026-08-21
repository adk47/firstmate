#!/usr/bin/env bats
# Tests for scripts/qa-approval-retry.sh — the sweeper that re-asks for an
# approval the CI race caused to be withheld.
#
# Every helper the script shells out to is STUBBED via its env override, so the
# suite never touches real GitHub and never invokes the real approve wrapper
# (memory: an unstubbed bats test once fired 9 real Slack alerts).
#
# The highest-risk logic here is the verdict parser, because "NO-GO" CONTAINS
# "GO": a naive matcher approves exactly the PRs the reviewer blocked. Those
# cases are pinned first and deliberately over-represented.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-approval-retry.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export QA_APPROVAL_RETRY_POLICY="$TEST_TMPDIR/policy.json"
  cat > "$QA_APPROVAL_RETRY_POLICY" <<'JSON'
{ "identity": { "bot_logins": ["muso-qa-bot", "muso-qa-bot[bot]", "adk47"], "app_repos": [] } }
JSON

  export APPROVE_CALLS="$TEST_TMPDIR/approve-calls"; : > "$APPROVE_CALLS"
  export COMMENT_CALLS="$TEST_TMPDIR/comment-calls"; : > "$COMMENT_CALLS"
  export STATUS_CALLS="$TEST_TMPDIR/status-calls";   : > "$STATUS_CALLS"
  export DM_CALLS="$TEST_TMPDIR/dm-calls";           : > "$DM_CALLS"
  # Never let a test write the real /var/lib/hydra audit dir.
  export QA_APPROVAL_RETRY_LOG_DIR="$TEST_TMPDIR/api-logs/github"

  # ── repo allowlist stub: one repo unless STUB_REPOS says otherwise ──
  export QA_REPO_ALLOWLIST="$TEST_TMPDIR/allowlist.sh"
  cat > "$QA_REPO_ALLOWLIST" <<'SH'
#!/usr/bin/env bash
printf '%s\n' ${STUB_REPOS:-Muso-AI/web-credits-next}
SH
  chmod +x "$QA_REPO_ALLOWLIST"

  # ── author -> UID stub: mapped unless STUB_UNMAPPED=1 ──
  export QA_AUTHOR_UID="$TEST_TMPDIR/uid.sh"
  cat > "$QA_AUTHOR_UID" <<'SH'
#!/usr/bin/env bash
[ "${STUB_UNMAPPED:-0}" = "1" ] && exit 1
echo "U03LP8YHLPK"
SH
  chmod +x "$QA_AUTHOR_UID"

  # ── approve wrapper stub: records every invocation; rc from STUB_APPROVE_RC ──
  # STUB_ALERTS (newline-separated) reproduces the real wrapper's alert shape:
  # each alert is printed ONCE inline on stderr and ONCE again in the stdout
  # replay block, and the caller captures both streams into one variable. The
  # double-print is deliberate upstream, so the fixture must carry it — a stub
  # that printed each alert once would hide a de-duplication bug.
  export QA_APPROVE="$TEST_TMPDIR/approve.sh"
  cat > "$QA_APPROVE" <<'SH'
#!/usr/bin/env bash
echo "$1 $2 $3" >> "$APPROVE_CALLS"
rc="${STUB_APPROVE_RC:-0}"
# Record WHICH sha the approval landed on, so the reviews stub can serve it back
# the way GitHub records commit_id on the review.
# `-` not `:-`: an intentionally EMPTY value must stay empty (it models a
# readback that cannot name the sha), which `:-` would silently replace.
# STUB_APPROVE_WROTE=1 records the approval even on a non-zero exit — that is
# exactly the ambiguous exit 7: GitHub accepted the write, the client errored.
if [ "$rc" = "0" ] || [ "${STUB_APPROVE_WROTE:-0}" = "1" ]; then
  printf '%s' "${STUB_APPROVED_SHA-abc123}" > "$TEST_TMPDIR/approved-sha"
fi
if [ -n "${STUB_ALERTS:-}" ]; then
  while IFS= read -r a; do
    [ -n "$a" ] && echo "qa-pr-approve: ⚠️ ALERT — $a" >&2
  done <<< "$STUB_ALERTS"
  echo "qa-pr-approve: ── ALERT(S) on this run — relay ALL of these ──"
  while IFS= read -r a; do
    [ -n "$a" ] && echo "qa-pr-approve: ⚠️ ALERT — $a"
  done <<< "$STUB_ALERTS"
fi
[ "$rc" = "0" ] || echo "qa-pr-approve: CI not green for $1#$2 — refusing to approve." >&2
exit "$rc"
SH
  chmod +x "$QA_APPROVE"

  # ── qa-review-status stub: records the state it was asked to set ──
  export QA_REVIEW_STATUS="$TEST_TMPDIR/status.sh"
  cat > "$QA_REVIEW_STATUS" <<'SH'
#!/usr/bin/env bash
echo "$1 $2 $3 $4" >> "$STATUS_CALLS"
exit "${STUB_STATUS_RC:-0}"
SH
  chmod +x "$QA_REVIEW_STATUS"

  # ── slack-notify stub: slack_notify_critical sends a REAL page via
  # `muso slack dm`, so it must never reach the live lib from a test ──
  export PAGE_CALLS="$TEST_TMPDIR/page-calls"; : > "$PAGE_CALLS"
  export QA_SLACK_NOTIFY_LIB="$TEST_TMPDIR/slack-notify.sh"
  cat > "$QA_SLACK_NOTIFY_LIB" <<'SH'
# Mirrors the REAL contract, which an earlier version of this stub did not:
# slack_notify_critical wraps slack_notify and is best-effort — it returns 0
# even when delivery failed. Only slack_notify_payload_file_status reports
# status. A stub more capable than production made a dead rollback path look
# tested.
slack_notify_critical() { echo "$1" >> "$PAGE_CALLS"; return 0; }
slack_notify_payload_file_status() {
  # <path-to-json {channel,text}>
  if [ "${STUB_PAGE_RC:-0}" = "0" ]; then
    jq -r '.text' "$1" >> "$PAGE_CALLS" 2>/dev/null
    return 0
  fi
  return "$STUB_PAGE_RC"
}
SH
  export QA_APPROVAL_RETRY_BLACKOUT_STAMP="$TEST_TMPDIR/blackout-stamp"
  export QA_APPROVAL_RETRY_TRUNCATION_STAMP="$TEST_TMPDIR/truncation-stamp"
  export DEFAULT_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'

  # ── qa-slack-dm stub ──
  export QA_SLACK_DM="$TEST_TMPDIR/dm.sh"
  cat > "$QA_SLACK_DM" <<'SH'
#!/usr/bin/env bash
echo "$1 :: $2" >> "$DM_CALLS"
exit "${STUB_DM_RC:-0}"
SH
  chmod +x "$QA_SLACK_DM"

  # ── gh stub: `pr list` -> STUB_PRS_JSON, reviews API -> STUB_REVIEWS_JSON ──
  export QA_GH="$TEST_TMPDIR/qa-gh.sh"
  cat > "$QA_GH" <<'SH'
#!/usr/bin/env bash
# consume the shim's leading --repo <owner/name>, keeping the name: some tests
# need ONE repo of several to fail, so that a per-repo read failure stays a
# counter instead of tripping the all-repos blackout.
repo_arg=""
[ "${1:-}" = "--repo" ] && { repo_arg="$2"; shift 2; }
case "${1:-}" in
  pr)  if [ -n "${STUB_BAD_REPO:-}" ] && [ "$repo_arg" = "$STUB_BAD_REPO" ]; then
         if [ "${STUB_BAD_MODE:-rc}" = "rc" ]; then exit 1; fi
         printf '%s' "$STUB_BAD_JSON"; exit 0
       fi
       [ "${STUB_PRS_RC:-0}" = "0" ] || exit 1
       printf '%s' "${STUB_PRS_JSON:-[]}" ;;
  api)
    case "${2:-}" in
      */issues/*/comments)
        # GET = the idempotency read (what is already on the PR);
        # POST = the alert comment itself. Record the exact JSON body that would
        # go on the wire, so tests assert on the payload rather than on intent.
        is_post=0
        for a in "$@"; do [ "$a" = "POST" ] && is_post=1; done
        if [ "$is_post" = "0" ]; then
          [ "${STUB_COMMENTS_RC:-0}" = "0" ] || exit 1
          printf '%s' "${STUB_COMMENTS_JSON:-[]}"
          exit 0
        fi
        [ "${STUB_COMMENT_RC:-0}" = "0" ] || exit 1
        input=""; prev=""
        for a in "$@"; do [ "$prev" = "--input" ] && input="$a"; prev="$a"; done
        [ -n "$input" ] && cat "$input" >> "$COMMENT_CALLS"
        echo '{"id":1}'
        ;;
      graphql)
        # `gh api graphql` — the reviewThreads read for the
        # "activity after the GO" check. Default: no threads at all.
        [ "${STUB_THREADS_RC:-0}" = "0" ] || exit 1
        # Query-AWARE on purpose: a thread opened before the GO with a reply
        # after it returns different timestamps for comments(first:1) vs
        # comments(last:1). A stub blind to that would let the first:1 bug pass.
        if [ -n "${STUB_THREAD_FIRST_AT:-}" ]; then
          q=""; prev=""
          for a in "$@"; do [ "$prev" = "-f" ] && case "$a" in query=*) q="$a" ;; esac; prev="$a"; done
          at="$STUB_THREAD_FIRST_AT"
          case "$q" in *"comments(last:"*) at="$STUB_THREAD_LAST_AT" ;; esac
          printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"createdAt":"%s"}]}}]}}}}}' "$at"
          exit 0
        fi
        printf '%s' "${STUB_THREADS_JSON:-$DEFAULT_THREADS_JSON}"
        exit 0 ;;
      */timeline*)
        # Base-ref mutation check. Default: nothing ever happened.
        if [ -n "${STUB_TIMELINE_FAIL_PR:-}" ]; then
          case "${2:-}" in */issues/"$STUB_TIMELINE_FAIL_PR"/timeline*) exit 1 ;; esac
        fi
        [ "${STUB_TIMELINE_RC:-0}" = "0" ] || exit 1
        # Models a retarget landing INSIDE the approval write: clean on the
        # pre-write read, stale on the post-write one. The approve stub drops
        # the marker, so "after" is exactly "after the wrapper ran".
        if [ -n "${STUB_TIMELINE_STALE_AFTER:-}" ] && [ -f "$TEST_TMPDIR/approved-sha" ]; then
          printf '%s' '[{"event":"base_ref_changed","created_at":"2026-08-17T12:00:00Z"}]'
          exit 0
        fi
        printf '%s' "${STUB_TIMELINE_JSON:-[]}"
        exit 0 ;;
      */reviews)
        # STUB_REVIEWS_FAIL_PR fails the reviews read for ONE pr number, so a
        # per-candidate failure stays a counter instead of tripping the
        # all-candidates blackout.
        if [ -n "${STUB_REVIEWS_FAIL_PR:-}" ]; then
          case "${2:-}" in */pulls/"$STUB_REVIEWS_FAIL_PR"/reviews) exit 1 ;; esac
        fi
        # A truncated / non-array body returned with exit 0 and non-empty — the
        # shape that slips past an rc-and-emptiness check.
        if [ -n "${STUB_REVIEWS_MALFORMED:-}" ]; then
          printf '%s' "$STUB_REVIEWS_MALFORMED"; exit 0
        fi
        [ "${STUB_REVIEWS_RC:-0}" = "0" ] || exit 1
        # After the wrapper approves, the readback must SEE that approval — the
        # script reads back which sha it actually landed on. The approve stub
        # drops a marker; STUB_APPROVED_SHA models it landing on another head.
        if [ -f "$TEST_TMPDIR/approved-sha" ]; then
          printf '%s' "${STUB_REVIEWS_JSON:-[]}" | jq -c \
            --arg s "$(cat "$TEST_TMPDIR/approved-sha")" \
            '. + [{user:{login:"adk47"}, state:"APPROVED", commit_id:$s, submitted_at:"2999-01-01T00:00:00Z", body:"approved"}]'
          exit 0
        fi
        # Model the real endpoint's paging: without --paginate gh returns page 1
        # only (30 items); with it, gh MERGES the pages into a SINGLE array. Both
        # behaviours are reproduced so that dropping --paginate makes the
        # long-review-history test fail instead of passing silently.
        for _a in "$@"; do
          [ "$_a" = "--paginate" ] && { printf '%s' "${STUB_REVIEWS_JSON:-[]}"; exit 0; }
        done
        printf '%s' "${STUB_REVIEWS_JSON:-[]}" | jq -c '.[0:30]'
        ;;
      *)
        # The pre-write head re-confirmation (repos/<r>/pulls/<n>).
        # STUB_LIVE_HEAD models an author pushing between the verdict read and
        # the approval write. This call passes --jq, so honour it — a stub that
        # ignored --jq would hand back raw JSON and fake a head mismatch.
        # This endpoint is hit twice on the race path: once before the write,
        # and again afterwards to find the at-risk commit when the readback
        # could not name it. STUB_LIVE_HEAD_2 models the head differing by then
        # (or "__FAIL__" for the re-read failing), which a single fixed value
        # could not express.
        _n=$(( $(cat "$TEST_TMPDIR/head-calls" 2>/dev/null || echo 0) + 1 ))
        echo "$_n" > "$TEST_TMPDIR/head-calls"
        if [ "$_n" -ge 2 ] && [ -n "${STUB_LIVE_HEAD_2:-}" ]; then
          [ "$STUB_LIVE_HEAD_2" = "__FAIL__" ] && exit 1
          _sha="$STUB_LIVE_HEAD_2"
        else
          [ "${STUB_LIVE_HEAD_RC:-0}" = "0" ] || exit 1
          _sha="${STUB_LIVE_HEAD:-abc123}"
        fi
        # STUB_PR_STATE_NO_BASE models an API answer with no base fields, so the
        # caller's "omit empty expectations" path is reachable.
        if [ -n "${STUB_PR_STATE_NO_BASE:-}" ]; then
          _out="$(printf '{"head":{"sha":"%s"}}' "$_sha")"
        else
          _out="$(printf '{"head":{"sha":"%s"},"base":{"ref":"develop","sha":"basetip0"}}' "$_sha")"
        fi
        _filt=""; _prev=""
        for a in "$@"; do [ "$_prev" = "--jq" ] && _filt="$a"; _prev="$a"; done
        if [ -n "$_filt" ]; then printf '%s' "$_out" | jq -r "$_filt"; else printf '%s' "$_out"; fi
        ;;
    esac ;;
  *)   exit 1 ;;
esac
SH
  chmod +x "$QA_GH"

  # Default fixture: one open non-draft PR at head sha "abc123".
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Load the script as a library to exercise the pure parser directly.
verdict_of() {
  QA_APPROVAL_RETRY_LIB=1 . "$SCRIPT"
  qar_verdict "$1"
}

# ── Verdict parsing: the NO-GO/GO substring trap ─────────────────────────

@test "verdict: bold GO parses as GO" {
  run verdict_of '**Verdict: GO** — 0 Critical, 0 Important, 0 Nice-to-have.'
  [ "$status" -eq 0 ]
  [ "$output" = "GO" ]
}

@test "verdict: bold NO-GO parses as NO-GO, NOT GO (the substring trap)" {
  run verdict_of '**Verdict: NO-GO** — 0 Critical, 1 Important, 0 Nice-to-have.'
  [ "$status" -eq 0 ]
  [ "$output" = "NO-GO" ]
}

@test "verdict: markdown heading form parses as GO" {
  run verdict_of '## Verdict: GO

No Critical or Important findings.'
  [ "$status" -eq 0 ]
  [ "$output" = "GO" ]
}

@test "verdict: heading NO-GO parses as NO-GO" {
  run verdict_of '## Verdict: NO-GO'
  [ "$status" -eq 0 ]
  [ "$output" = "NO-GO" ]
}

@test "verdict: lowercase is accepted (case-insensitive)" {
  run verdict_of 'verdict: go — all clear'
  [ "$status" -eq 0 ]
  [ "$output" = "GO" ]
}

@test "verdict: a body carrying BOTH tokens resolves to NO-GO (fail closed)" {
  # A carry-forward section legitimately restates a prior verdict. Section
  # ordering must never decide whether we approve.
  run verdict_of '**Verdict: GO** — 0 Critical.

**Carry-forward:** the prior review was **Verdict: NO-GO** on the old head.'
  [ "$status" -eq 0 ]
  [ "$output" = "NO-GO" ]
}

@test "verdict: NO-GO first then GO also resolves to NO-GO" {
  run verdict_of 'Prior **Verdict: NO-GO**. Now **Verdict: GO**.'
  [ "$status" -eq 0 ]
  [ "$output" = "NO-GO" ]
}

@test "verdict: the bare word GO elsewhere is not a verdict" {
  run verdict_of 'This is a GO-forward plan; the GO signal is unrelated. No verdict line here.'
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "verdict: an unparseable body is 'none', never GO" {
  run verdict_of 'LGTM, looks fine to me.'
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "verdict: empty body is 'none'" {
  run verdict_of ''
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

# ── Sweep behaviour ──────────────────────────────────────────────────────

@test "GO verdict on the live head with no approval asks the wrapper" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636 U03LP8YHLPK" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "NO-GO verdict never asks the wrapper" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:08:28Z","body":"**Verdict: NO-GO** — 1 Important."}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an existing bot APPROVED review on the live head makes the tick a no-op" {
  export STUB_REVIEWS_JSON='[
    {"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"},
    {"user":{"login":"adk47"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-08-17T11:00:00Z","body":"approved"}
  ]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an approval on a SUPERSEDED sha does not count as approved (dismiss_stale_reviews)" {
  # Approval on the old head + GO on the live head => still a candidate.
  export STUB_REVIEWS_JSON='[
    {"user":{"login":"adk47"},"state":"APPROVED","commit_id":"OLDSHA","submitted_at":"2026-08-17T09:00:00Z","body":"approved"},
    {"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}
  ]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a GO verdict on a SUPERSEDED sha is ignored (verdict must be on the live head)" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"OLDSHA","submitted_at":"2026-08-17T09:00:00Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a >30-review history (multi-page --paginate) still finds the live-head GO" {
  # The long-review-history case is exactly what this timer exists to repair, so
  # pin it. `gh api --paginate` MERGES array pages into ONE JSON array — measured
  # on gh 2.97.0 locally and gh 2.74.1 on node-8, where
  # `gh api ".../reviews?per_page=1" --paginate | jq -s length` is 1, not the page
  # count, and the merged array carries every page's elements. So the fixture is a
  # single 31-element array (NOT `[...][...]`, and NOT --slurp's array-of-arrays,
  # which would make `.[]` yield arrays and break every select).
  #
  # 30 stale NO-GOs on the old head sit ahead of the live-head GO, past the
  # 30-per-page boundary: an unpaginated read would see only those and skip the
  # PR forever, and a first-token-wins parser would read the stale NO-GO.
  export STUB_REVIEWS_JSON="$(jq -c -n '
    [range(30) | {user:{login:"adk47"}, state:"COMMENTED", commit_id:"OLDSHA",
                  submitted_at:"2026-08-17T09:00:00Z", body:"**Verdict: NO-GO** — 1 Important."}]
    + [{user:{login:"adk47"}, state:"COMMENTED", commit_id:"abc123",
        submitted_at:"2026-08-17T10:51:41Z", body:"**Verdict: GO** — 0 Critical."}]')"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636 U03LP8YHLPK" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a review from a NON-bot login is not a verdict" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"some-human"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an unmapped author is skipped, never approved" {
  export STUB_UNMAPPED=1
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Assert on the script's own output BEFORE any further `run` — `run` resets
  # $output/$lines, so a later `run wc` would silently replace what we check.
  [[ "${lines[*]}" == *"not mapped to a Slack UID"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "draft PRs are skipped" {
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":true}]'
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a wrapper DECLINE (CI still pending) is a normal outcome, tick still exits 0" {
  export STUB_APPROVE_RC=8
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"DECLINED (exit 8)"* ]]
}

@test "a malformed dry-run value REFUSES rather than falling through to live writes" {
  # Every DRY_RUN comparison tests for the literal 1, so `true` would log
  # dry_run=true and then approve for real. A malformed safety flag must never
  # resolve to "do the real thing".
  export QA_APPROVAL_RETRY_DRY_RUN=true
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be 0 or 1"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an explicit dry-run 0 is accepted and approves for real" {
  # The refusal must not swallow the valid off value.
  export QA_APPROVAL_RETRY_DRY_RUN=0
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "dry-run never invokes the approve wrapper" {
  export QA_APPROVAL_RETRY_DRY_RUN=1
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

# ── Head identity around the approval write ──────────────────────────────
# The verdict is selected against a head read at the top of the turn; the write
# approves whatever GitHub then calls the head. A push in that gap would put the
# bot's approval on a commit no review covers.

@test "a head that moved after the verdict was read is NOT approved" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  export STUB_LIVE_HEAD=NEWSHA   # author pushed between the read and the write
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"moved abc123 -> NEWSHA"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a head that cannot be re-confirmed is NOT approved (fail closed)" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  export STUB_LIVE_HEAD_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all of them failed => blackout
  [[ "${lines[*]}" == *"could not read head+base"* ]]
  [[ "${lines[*]}" == *"read_failures=1"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an approval recorded on a sha the review does not cover is flagged CRITICAL and reddened" {
  # The window cannot be closed completely from the caller side, so if it does
  # fire the approval must not be reported as clean — it is already written.
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  export STUB_APPROVED_SHA=RACEDSHA
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"CRITICAL"* ]]
  [[ "${lines[*]}" == *"not the reviewed head abc123"* ]]
  [[ "${lines[*]}" == *"raced=1"* ]]
  [[ "${lines[*]}" != *"approved=1"* ]]
  # reddened on the sha that actually carries the approval, not the reviewed one
  run grep -c "RACEDSHA failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an approval whose landing sha cannot be read is not reported as clean" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  export STUB_APPROVED_SHA=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"CRITICAL"* ]]
  [[ "${lines[*]}" == *"raced=1"* ]]
}

@test "when the readback fails, the red status targets the AT-RISK head, not the reviewed one" {
  # The race fires (head moved to NEWSHA after the pre-write check) AND the
  # readback cannot name where the approval went. Reddening the reviewed sha
  # here would leave NEWSHA holding the approval and its green status, while the
  # log claimed the PR had been made unsafe.
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  export STUB_APPROVED_SHA=""      # readback cannot name the landing sha
  export STUB_LIVE_HEAD_2=NEWSHA   # by then the head has moved
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"CRITICAL"* ]]
  [[ "${lines[*]}" == *"raced=1"* ]]
  run grep -c "NEWSHA failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c "abc123 failure" "$STATUS_CALLS"
  [ "$status" -ne 0 ]
}

@test "when the at-risk commit cannot be established at all, NOTHING is claimed and the author is DM'd" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  export STUB_APPROVED_SHA=""
  export STUB_LIVE_HEAD_2=__FAIL__
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"could NOT establish which commit carries the approval"* ]]
  [[ "${lines[*]}" == *"NO status was set"* ]]
  [[ "${lines[*]}" == *"raced=1"* ]]
  # No status at all — never a red on the wrong commit dressed up as a backstop.
  run wc -l < "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
  run grep -c "DO NOT MERGE" "$DM_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a malformed PR list is a READ FAILURE, not a clean empty sweep" {
  # The candidate loop is fed by a process substitution, whose exit status the
  # parent never sees — so a non-array body with exit 0 would run the loop zero
  # times and report success with read_failures=0.
  export STUB_REPOS="Muso-AI/web-credits-next Muso-AI/other"
  export STUB_BAD_REPO="Muso-AI/other"; export STUB_BAD_MODE=json
  export STUB_BAD_JSON='{"truncated": not-json'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"was not a JSON array"* ]]
  [[ "${lines[*]}" == *"read_failures=1"* ]]
  # The healthy repo in scope is still swept — a bad response for one repo must
  # not silently abort the others.
  [[ "${lines[*]}" == *"considered=1"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a JSON object where an array is expected is also a read failure" {
  export STUB_REPOS="Muso-AI/web-credits-next Muso-AI/other"
  export STUB_BAD_REPO="Muso-AI/other"; export STUB_BAD_MODE=json
  export STUB_BAD_JSON='{"number":636}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"was not a JSON array"* ]]
  [[ "${lines[*]}" == *"read_failures=1"* ]]
}

@test "the normal case still reports a clean approval on the reviewed head" {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"APPROVED: Muso-AI/web-credits-next#636"* ]]
  [[ "${lines[*]}" == *"raced=0"* ]]
  run wc -l < "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "the generated systemd unit body contains no command substitution" {
  # This heredoc is UNQUOTED so $HYDRA_ROOT expands — which also makes any
  # backtick inside it run AS ROOT at install time and silently eat the text
  # from the emitted unit. Backticks elsewhere in the installer (ordinary
  # comments, outside any heredoc) are harmless, so scope the assertion to the
  # heredoc body rather than the whole file.
  run bash -c "awk '/<< QAAPPROVERETRYSVC\$/{f=1;next} /^QAAPPROVERETRYSVC\$/{f=0} f' '$HYDRA_REPO/scripts/install-aux-units.sh' | grep -n '\`'"
  [ "$status" -ne 0 ]
}

# ── Is the GO still ABOUT this PR? ───────────────────────────────────────
# The head sha pins only the right-hand side of the diff. A base retarget and a
# post-GO review thread both keep the sha (and the green checks) while making
# the verdict stale — and only this lane, which approves LATER, is exposed.

@test "a base retarget after the GO blocks the approval" {
  # Reviewed against develop, retargeted to main: same head, same green checks,
  # entirely different diff. Unscoped requesters are not base-restricted in the
  # wrapper, so nothing downstream would catch it.
  alerting_go
  export STUB_TIMELINE_JSON='[{"event":"base_ref_changed","created_at":"2026-08-17T11:00:00Z"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"base ref changed (retarget or force-push)"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a base retarget BEFORE the GO does not block it" {
  # The review already covers that base — only a change AFTER the verdict
  # invalidates it, or every retargeted PR would be permanently unapprovable.
  alerting_go
  export STUB_TIMELINE_JSON='[{"event":"base_ref_changed","created_at":"2026-08-17T09:00:00Z"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an unresolved thread opened AFTER the GO blocks the approval, even untagged" {
  # Guard 7 only counts 🔴/🟡-tagged threads, so a plain human "hold on" never
  # blocks it there. This lane refuses instead.
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"createdAt":"2026-08-17T12:00:00Z"}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"unresolved review thread(s) from a human"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a RESOLVED thread opened after the GO does not block" {
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true,"comments":{"nodes":[{"createdAt":"2026-08-17T12:00:00Z"}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an unresolved thread OLDER than the GO does not block (the review saw it)" {
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"createdAt":"2026-08-17T09:00:00Z"}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "more than 100 review threads fails closed rather than reading as none" {
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all of them failed => blackout
  [[ "${lines[*]}" == *"could not establish whether"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an unreadable timeline blocks the approval (the base may have moved)" {
  alerting_go
  export STUB_TIMELINE_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all of them failed => blackout
  [[ "${lines[*]}" == *"could not establish whether"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an unreadable threads response blocks the approval" {
  alerting_go
  export STUB_THREADS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all of them failed => blackout
  [[ "${lines[*]}" == *"could not establish whether"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a thread OPENED before the GO but replied to after it blocks the approval" {
  # The question is "has anyone objected since the verdict?", not "when did the
  # thread start". comments(first:1) answers the wrong one and misses this.
  alerting_go
  export STUB_THREAD_FIRST_AT="2026-08-17T09:00:00Z"   # opened before the GO
  export STUB_THREAD_LAST_AT="2026-08-17T12:00:00Z"    # "hold, this is broken"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"unresolved review thread(s) from a human"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a thread with NO activity since the GO still does not block" {
  alerting_go
  export STUB_THREAD_FIRST_AT="2026-08-17T08:00:00Z"
  export STUB_THREAD_LAST_AT="2026-08-17T09:00:00Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a FAILED page clears the cooldown stamp so the next tick retries" {
  # Otherwise one transient Slack error buys a full hour of silence while
  # nothing is being repaired.
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  export STUB_PAGE_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"cooldown stamp cleared"* ]]
  [ ! -f "$QA_APPROVAL_RETRY_BLACKOUT_STAMP" ]
  # next tick: the send works, and it is NOT suppressed
  unset STUB_PAGE_RC
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" != *"page suppressed"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a SUCCESSFUL page keeps its stamp and does suppress the next tick" {
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [ -f "$QA_APPROVAL_RETRY_BLACKOUT_STAMP" ]
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"page suppressed"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "1" ]
}

@test "a base FORCE-PUSH after the GO blocks the approval, not just a retarget" {
  # Same head sha, same green checks, different comparison. GitHub reports this
  # as base_ref_force_pushed, a different event from base_ref_changed.
  alerting_go
  export STUB_TIMELINE_JSON='[{"event":"base_ref_force_pushed","created_at":"2026-08-17T11:00:00Z"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"base ref changed (retarget or force-push)"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "an unrelated timeline event after the GO does not block" {
  # Only base-ref mutations count — a label or a comment must not strand the PR.
  alerting_go
  export STUB_TIMELINE_JSON='[{"event":"labeled","created_at":"2026-08-17T11:00:00Z"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "every GO candidate failing its SAFETY reads pages as a blackout" {
  # timeline/threads/head reads only moved read_fail, so a fleet-wide 403 on
  # them looked like a healthy tick.
  alerting_go
  export STUB_TIMELINE_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"failed a staleness/safety read"* ]]
  [[ "${lines[*]}" == *"safety_read_failures=1/1"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a threads-read blackout across every GO candidate also pages" {
  alerting_go
  export STUB_THREADS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"failed a staleness/safety read"* ]]
}

@test "a pre-write head blackout across every GO candidate also pages" {
  alerting_go
  export STUB_LIVE_HEAD_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"failed a staleness/safety read"* ]]
}

@test "a safety-read failure on SOME candidates does not page" {
  # One flaky PR is a counter; all of them is a page.
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false},{"number":637,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  export STUB_TIMELINE_FAIL_PR=636
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"safety_read_failures=1/2"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "the GO review's OWN thread at the same second does not strand the PR" {
  # Measured on this very PR: an unresolved adk47 thread at 22:40:57Z against a
  # review submitted 22:40:57Z. With >= and no author filter, the review would
  # be an objection to itself and the approval could never fire — the exact
  # failure this timer exists to repair.
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"createdAt":"2026-08-17T10:51:41Z","author":{"login":"adk47"}}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a HUMAN objection in the same second as the GO does block (>= not >)" {
  # GitHub timestamps are second-granular, so a strict > would miss it.
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"createdAt":"2026-08-17T10:51:41Z","author":{"login":"some-human"}}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"unresolved review thread(s) from a human"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a base-ref event in the same second as the GO blocks (>= not >)" {
  alerting_go
  export STUB_TIMELINE_JSON='[{"event":"base_ref_changed","created_at":"2026-08-17T10:51:41Z"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"base ref changed"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a PR that goes stale DURING the approval write is flagged CRITICAL and reddened" {
  # The pre-write read cannot be atomic with the wrapper's write. The residual
  # window is closed by noticing, not by preventing.
  alerting_go
  export STUB_TIMELINE_STALE_AFTER=1   # clean before the write, stale after
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"changed during the approval write"* ]]
  [[ "${lines[*]}" == *"raced=1"* ]]
  [[ "${lines[*]}" != *"approved=1"* ]]
  run grep -c "abc123 failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a human objection followed by a BOT reply still blocks" {
  # Classifying the thread by its LAST author let a routine bot reply erase an
  # explicit human hold.
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"createdAt":"2026-08-17T11:00:00Z","author":{"login":"some-human"}},{"createdAt":"2026-08-17T12:00:00Z","author":{"login":"adk47"}}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"unresolved review thread(s) from a human"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a thread whose comment window is truncated at/after the GO is ERR, not zero" {
  # An older human comment could be hiding past the edge of the window; that is
  # indeterminate, and indeterminate must not read as "nobody objected".
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"pageInfo":{"hasPreviousPage":true},"nodes":[{"createdAt":"2026-08-17T12:00:00Z","author":{"login":"adk47"}}]}}]}}}}}'
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all of them failed => blackout
  [[ "${lines[*]}" == *"could not establish whether"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "the pager uses the CONFIRMED-delivery path, not the best-effort one" {
  # slack_notify_critical returns 0 even when delivery failed (it wraps
  # slack_notify, which is best-effort by contract). Only the status path can
  # tell us whether the page landed, and the cooldown depends on that answer.
  # The stub reports failure ONLY through the status function, so a caller still
  # using slack_notify_critical would see success and keep the stamp.
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  export STUB_PAGE_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"cooldown stamp cleared"* ]]
  [ ! -f "$QA_APPROVAL_RETRY_BLACKOUT_STAMP" ]
}

@test "every channel failing on an approved PR exits 4 and pages, never 0" {
  # The worst state in the flow: approved, green, alert unpublished, red status
  # unset, DM gone. It must not be a tick that reports success.
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENT_RC=1   # alert comment fails
  export STUB_STATUS_RC=1    # both qa-review status attempts fail
  export STUB_DM_RC=1        # author DM fails
  run "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "${lines[*]}" == *"UNSAFE AND UNFLAGGED"* ]]
  [[ "${lines[*]}" == *"unsafe_unflagged=1"* ]]
  run grep -c "UNSAFE AND UNFLAGGED" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "when the escalation page ALSO fails, the tick still exits 4" {
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENT_RC=1
  export STUB_STATUS_RC=1
  export STUB_DM_RC=1
  export STUB_PAGE_RC=1
  run "$SCRIPT"
  [ "$status" -eq 4 ]
  [[ "${lines[*]}" == *"every notification channel this lane has is down"* ]]
}

@test "a go_red that SUCCEEDS does not trip the unsafe escalation" {
  # The backstop worked — red status set — so this is a handled outcome, not an
  # unflagged one, and the tick must not exit 4.
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENT_RC=1   # comment fails, but the red status lands
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"unsafe_unflagged=0"* ]]
  run grep -c "abc123 failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "exit 7 with the approval RECORDED runs the post-write backstops" {
  # gh pr review --approve can fail AFTER GitHub accepted the write. Calling
  # that a decline would skip every backstop on a live approval, and the next
  # tick would skip the PR because an approval exists.
  alerting_go
  export STUB_APPROVE_RC=7
  export STUB_APPROVE_WROTE=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"exited 7 but GitHub DID record the approval"* ]]
  [[ "${lines[*]}" == *"APPROVED: Muso-AI/web-credits-next#636"* ]]
  [[ "${lines[*]}" != *"DECLINED"* ]]
}

@test "exit 7 with the approval recorded on ANOTHER head is flagged unsafe" {
  # The dangerous interleaving: a push lands after the pre-write head read,
  # GitHub records the approval on the unreviewed head, the client errors.
  alerting_go
  export STUB_APPROVE_RC=7
  export STUB_APPROVE_WROTE=1
  export STUB_APPROVED_SHA=RACEDSHA
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"CRITICAL"* ]]
  [[ "${lines[*]}" == *"raced=1"* ]]
  run grep -c "RACEDSHA failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "exit 7 with NO approval recorded is a normal decline" {
  # The other half of exit 7: a pre-write read failure. Nothing was approved,
  # so it must not be escalated.
  alerting_go
  export STUB_APPROVE_RC=7
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"DECLINED (exit 7, no approval recorded)"* ]]
  [[ "${lines[*]}" == *"raced=0"* ]]
  run wc -l < "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "exit 7 whose approval state cannot be read is flagged unsafe, not declined" {
  alerting_go
  export STUB_APPROVE_RC=7
  export STUB_APPROVE_WROTE=1
  export STUB_REVIEWS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate: the reviews read also fails => blackout
  [[ "${lines[*]}" == *"could not be read back"* ]] || [[ "${lines[*]}" == *"READ-FAILURE"* ]]
}

# ── ⚠️ ALERT relay ───────────────────────────────────────────────────────
# Sensitive paths no longer BLOCK the approval — they alert and it proceeds. So
# the alert line is the only signal that something needing eyes was
# auto-approved, and a lane that swallows it leaves a PR approved, green, and
# looking reviewed. These pin the whole publish contract.

# Shared fixture: a GO verdict on the live head, so the wrapper is reached.
alerting_go() {
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO** — 0 Critical."}]'
}

@test "an approval carrying an ALERT posts it as a follow-up PR comment" {
  alerting_go
  export STUB_ALERTS='PR #636 touches 1 SENSITIVE path(s): .github/workflows/ci.yml. These no longer hold the approval for a human — review them yourself.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"ALERTS PUBLISHED"* ]]
  run cat "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-approved with alerts"* ]]
  [[ "$output" == *"SENSITIVE path"* ]]
}

@test "the alert comment is valid JSON of the shape --input requires" {
  # --input sends the file as the WHOLE body, so it must already BE {"body":...}.
  # Raw markdown there posts invalid JSON and the alert is silently lost.
  alerting_go
  export STUB_ALERTS='RED advisory check(s) NOT counted by Guard 6 — confirm before merging.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run jq -e 'has("body") and (.body|type=="string") and (keys|length==1)' "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
}

@test "the inline+replay double-print is posted once, but two DIFFERENT alerts both survive" {
  alerting_go
  export STUB_ALERTS='first alert about workflows
second alert about advisory checks'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "jq -r .body '$COMMENT_CALLS' | grep -c 'first alert about workflows'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run bash -c "jq -r .body '$COMMENT_CALLS' | grep -c 'second alert about advisory checks'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "alerts are relayed on a DECLINE too, with a heading that does not claim approval" {
  # The wrapper replays its alerts on every exit path. "Auto-approved" on a
  # refusal would be a straight lie.
  alerting_go
  export STUB_APPROVE_RC=8
  export STUB_ALERTS='could not evaluate sensitive paths — approving without that alert.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT approved"* ]]
  [[ "$output" != *"Auto-approved with alerts"* ]]
}

@test "the alert comment is audit-logged BEFORE it is posted" {
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "cat '$TEST_TMPDIR'/api-logs/github/*.jsonl"
  [ "$status" -eq 0 ]
  run bash -c "jq -e '.action==\"github_pr_alert_comment\" and .target==\"Muso-AI/web-credits-next#636\"' '$TEST_TMPDIR'/api-logs/github/*.jsonl"
  [ "$status" -eq 0 ]
}

@test "an unloggable alert is NOT posted, and the PR is turned RED instead" {
  # No audit log => no post. Returning quietly here would leave an approved,
  # green PR with the alert unpublished and nothing on the PR saying so.
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  # A FILE where the log dir should be: mkdir -p cannot succeed, even as root
  # (CI runs bats as root, so a permission-based fixture would not hold).
  : > "$TEST_TMPDIR/blocked"
  export QA_APPROVAL_RETRY_LOG_DIR="$TEST_TMPDIR/blocked/api-logs/github"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"ALERT-PUBLISH FAILURE"* ]]
  [[ "${lines[*]}" == *"alerts_unpublished=1"* ]]
  run wc -l < "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
  run grep -c "abc123 failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an alert comment that cannot be posted turns the qa-review status RED" {
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENT_RC=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"alerts_unpublished=1"* ]]
  run grep -c "abc123 failure" "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "when the comment AND the red status both fail, the author is DM'd and it is logged CRITICAL" {
  # The worst case in the whole flow: approved, green, no alert, no red status.
  # It must not end quietly.
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENT_RC=1
  export STUB_STATUS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"CRITICAL"* ]]
  [[ "${lines[*]}" == *"MUST NOT be merged"* ]]
  run grep -c "DO NOT MERGE" "$DM_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an approval with NO alerts posts no comment and touches no status" {
  alerting_go
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"alerts_unpublished=0"* ]]
  run wc -l < "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
  run wc -l < "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "the approve wrapper's audit-log dir is pinned to an absolute path" {
  # qa-pr-approve.sh's LOG_DIR default is RELATIVE and a systemd service has no
  # WorkingDirectory, so an unpinned run would write /api-logs/github as root.
  alerting_go
  export QA_APPROVE="$TEST_TMPDIR/echo-env.sh"
  cat > "$QA_APPROVE" <<'SH'
#!/usr/bin/env bash
echo "$QA_PR_APPROVE_LOG_DIR" >> "$APPROVE_CALLS"
SH
  chmod +x "$QA_APPROVE"
  unset QA_APPROVAL_RETRY_LOG_DIR
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]
  [[ "$output" == *"/var/lib/hydra/qa-approval-retry/api-logs/github"* ]]
}

@test "an alert already published for this head+outcome is not reposted" {
  # The sweep is stateless and re-considers every unapproved PR each tick, so
  # without this a declining PR gets a fresh comment and DM every 10 minutes —
  # forever for one that declines permanently (an out-of-scope approver exits 5
  # on every tick by design).
  alerting_go
  export STUB_APPROVE_RC=8
  export STUB_ALERTS='sensitive path touched'
  d="$(printf 'qa-pr-approve: ⚠️ ALERT — sensitive path touched' | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -c1-16)"
  export STUB_COMMENTS_JSON="$(jq -c -n --arg m "<!-- qa-approval-retry:alerts:abc123:declined:$d -->" '[{body:("## ⚠️ Alerts (NOT approved)\n" + $m)}]')"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"ALERTS ALREADY PUBLISHED"* ]]
  run wc -l < "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
  run wc -l < "$DM_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "the marker is keyed per head+outcome, so a later APPROVAL still publishes" {
  # Suppressing the approval's alerts because a "NOT approved" comment already
  # exists would leave the PR's only alert comment contradicting its real state.
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENTS_JSON='[{"body":"<!-- qa-approval-retry:alerts:abc123:declined -->"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-approved with alerts"* ]]
  [[ "$output" == *"qa-approval-retry:alerts:abc123:approved"* ]]
}

@test "a marker from a SUPERSEDED head does not suppress the current head's alerts" {
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENTS_JSON='[{"body":"<!-- qa-approval-retry:alerts:OLDSHA:approved -->"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Auto-approved with alerts" "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "an unreadable comment list posts anyway — a duplicate beats a lost alert" {
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENTS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "Auto-approved with alerts" "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a publish failure on a DECLINE does NOT redden the PR (no approval to make unsafe)" {
  # Reddening here would strand a failure status the lane can never clear: once
  # the approval lands, has_approval skips the PR and no tick revisits it.
  alerting_go
  export STUB_APPROVE_RC=8
  export STUB_ALERTS='sensitive path touched'
  export STUB_COMMENT_RC=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"ALERT-PUBLISH FAILURE on a DECLINE"* ]]
  [[ "${lines[*]}" == *"alerts_unpublished=1"* ]]
  run wc -l < "$STATUS_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a missing qa-review-status helper refuses the tick rather than losing the backstop" {
  rm -f "$QA_REVIEW_STATUS"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"required helper missing"* ]]
}

# ── Alert-set changes must still publish ─────────────────────────────────

@test "a LARGER alert set on a later tick is published, not swallowed by the old marker" {
  # The marker exists for the earlier, smaller set. An advisory check has since
  # turned red and the wrapper now emits an extra required ALERT line — keying
  # on head+outcome alone would return before ever comparing it.
  alerting_go
  export STUB_ALERTS='sensitive path touched
RED advisory check(s) NOT counted by Guard 6 — confirm before merging.'
  # Marker for the one-line set from the previous tick.
  prev="$(printf 'qa-pr-approve: ⚠️ ALERT — sensitive path touched' | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -c1-16)"
  # BOTH marker shapes are seeded: the digest one an implementation with the fix
  # would have written, and the digest-less one an implementation without it
  # would have written. Otherwise removing the digest makes the lookup miss for
  # an unrelated reason and this test passes while the bug is present.
  export STUB_COMMENTS_JSON="$(jq -c -n \
    --arg a "<!-- qa-approval-retry:alerts:abc123:approved:$prev -->" \
    --arg b "<!-- qa-approval-retry:alerts:abc123:approved -->" \
    '[{body:$a},{body:$b}]')"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RED advisory check"* ]]
}

@test "an UNCHANGED alert set on a later tick is still suppressed" {
  # The anti-spam property the digest must not break.
  alerting_go
  export STUB_ALERTS='sensitive path touched'
  same="$(printf 'qa-pr-approve: ⚠️ ALERT — sensitive path touched' | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -c1-16)"
  export STUB_COMMENTS_JSON="$(jq -c -n --arg m "<!-- qa-approval-retry:alerts:abc123:approved:$same -->" '[{body:$m}]')"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"ALERTS ALREADY PUBLISHED"* ]]
  run wc -l < "$COMMENT_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

# ── Total read blackout ──────────────────────────────────────────────────

@test "every repo failing its list read pages and exits non-zero" {
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"TOTAL READ BLACKOUT"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the blackout page is deduped — a second tick inside the cooldown does not page again" {
  # The sibling reconciler's undeduped read-failure watchdogs paged every 15min
  # for hours during the 2026-08-17 GitHub outage; a 10-min timer must not.
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"page suppressed"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "1" ]
}

@test "a FUTURE-dated cooldown stamp does not suppress the page" {
  # now-last goes negative and reads as "still inside the cooldown" for as long
  # as the skew lasts — silence during exactly the outage the page reports.
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  printf '%s' "$(( $(date -u +%s) + 86400 ))" > "$QA_APPROVAL_RETRY_BLACKOUT_STAMP"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"dated in the future"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a non-numeric cooldown override falls back to the default instead of silencing the page" {
  # `[ 5 -ge abc ]` is an integer error, and a failing elif condition falls
  # through to the suppression branch — so a typo would withhold the only
  # out-of-band signal for the whole outage.
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  export QA_APPROVAL_RETRY_BLACKOUT_COOLDOWN="one-hour"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"not a non-negative integer"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # And the fallback is a REAL cooldown, not "always page": the next tick is
  # still deduped.
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "1" ]
}

@test "a fleet-wide REVIEWS-endpoint outage also pages and exits non-zero" {
  # The other half of the blackout. On 2026-08-17 `pr list` kept working while
  # pulls/<n>/reviews errored for hours: repo_fail stays 0 and considered is
  # non-zero, so a PR-list-only detector would report success every 10 minutes
  # while repairing nothing.
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false},{"number":637,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
  export STUB_REVIEWS_RC=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"every one of the 2 candidate PR(s) failed its reviews read"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a reviews failure on SOME candidates is counted but does not page" {
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false},{"number":637,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
  export STUB_REVIEWS_FAIL_PR=636
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"reviews_read_failures=1/2"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a MALFORMED reviews body (exit 0, non-array) counts as a reviews-read failure" {
  # rc 0 and non-empty, so the rc/emptiness checks pass; only the shape check
  # can catch it. Counted in reviews_fail, or a fleet-wide version could never
  # trip the blackout.
  export STUB_REVIEWS_MALFORMED='{"truncated": not-json'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"was not a JSON array"* ]]
  [[ "${lines[*]}" == *"reviews_read_failures=1/1"* ]]
}

@test "malformed reviews for EVERY candidate pages as a total blackout" {
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false},{"number":637,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
  export STUB_REVIEWS_MALFORMED='{"number":636}'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"every one of the 2 candidate PR(s) failed its reviews read"* ]]
  run grep -c "TOTAL READ BLACKOUT" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a PR list landing exactly on the --limit cap is treated as TRUNCATED and pages" {
  # gh pr list silently returns the first N. The overflow would contain exactly
  # the withheld approvals this timer exists to repair, and every tick would
  # report success.
  export QA_APPROVAL_RETRY_PRLIST_LIMIT=2
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false},{"number":637,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"TRUNCATED PR LIST"* ]]
  [[ "${lines[*]}" == *"truncated_repos=1"* ]]
  run grep -c "TRUNCATED PR LIST" "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a truncated sweep still processes the PRs it DID get" {
  # Truncation means incomplete, not useless — the returned candidates must
  # still be swept, so it pages without changing the exit code.
  export QA_APPROVAL_RETRY_PRLIST_LIMIT=1
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"TRUNCATED PR LIST"* ]]
  run grep -c "Muso-AI/web-credits-next 636" "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a PR list below the cap does not page" {
  export QA_APPROVAL_RETRY_PRLIST_LIMIT=300
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"truncated_repos=0"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "the truncation page has its OWN cooldown stamp, so it cannot mask a blackout page" {
  export QA_APPROVAL_RETRY_PRLIST_LIMIT=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$QA_APPROVAL_RETRY_TRUNCATION_STAMP" ]
  [ ! -f "$QA_APPROVAL_RETRY_BLACKOUT_STAMP" ]
}

@test "a malformed PR-list limit falls back to 300 rather than disabling the guard" {
  export QA_APPROVAL_RETRY_PRLIST_LIMIT="lots"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"is not a positive integer"* ]]
  [[ "${lines[*]}" == *"truncated_repos=0"* ]]
}

@test "a PARTIAL read failure is counted but never pages or fails the unit" {
  # One flaky repo is a counter; a fleet-wide blackout is a page.
  export STUB_REPOS="Muso-AI/web-credits-next"
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: NO-GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"considered=1"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "dry-run never pages on a blackout" {
  export STUB_REPOS="Muso-AI/a Muso-AI/b"
  export STUB_PRS_RC=1
  export QA_APPROVAL_RETRY_DRY_RUN=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "${lines[*]}" == *"WOULD PAGE"* ]]
  run wc -l < "$PAGE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

# ── Fail-closed reads ────────────────────────────────────────────────────

@test "a bot_logins OBJECT refuses the tick (wrong type = silent no-op, not an error)" {
  # `{} | index($login)` matches nothing and never raises: every candidate would
  # be skipped, read_failures would stay 0, and the tick would report success
  # forever while GO PRs sat at REVIEW_REQUIRED.
  echo '{"identity":{"bot_logins":{}}}' > "$QA_APPROVAL_RETRY_POLICY"
  export STUB_REVIEWS_JSON='[{"user":{"login":"adk47"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-08-17T10:51:41Z","body":"**Verdict: GO**"}]'
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bot_logins"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a bot_logins STRING refuses the tick (index() would degrade to a substring test)" {
  # Worse than a no-op: with "adk47" as a bare string, the unrelated login
  # "adk4" classifies as the bot.
  echo '{"identity":{"bot_logins":"adk47"}}' > "$QA_APPROVAL_RETRY_POLICY"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bot_logins"* ]]
}

@test "an EMPTY bot_logins array refuses the tick" {
  echo '{"identity":{"bot_logins":[]}}' > "$QA_APPROVAL_RETRY_POLICY"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bot_logins"* ]]
}

@test "a bot_logins array of non-strings refuses the tick" {
  echo '{"identity":{"bot_logins":[123,""]}}' > "$QA_APPROVAL_RETRY_POLICY"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bot_logins"* ]]
}

@test "an unreadable bot_logins list refuses the tick (never a guessed default)" {
  echo '{"identity":{}}' > "$QA_APPROVAL_RETRY_POLICY"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bot_logins"* ]]
}

@test "a PR-list read failure is counted, not treated as 'nothing to do'" {
  export STUB_REPOS="Muso-AI/web-credits-next Muso-AI/other"
  export STUB_BAD_REPO="Muso-AI/other"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"READ-FAILURE"* ]]
  [[ "${lines[*]}" == *"read_failures=1"* ]]
}

@test "a reviews read failure is counted, not treated as 'no verdict'" {
  export STUB_PRS_JSON='[{"number":636,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false},{"number":637,"headRefOid":"abc123","author":{"login":"azure-kirin"},"isDraft":false}]'
  export STUB_REVIEWS_FAIL_PR=636
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[*]}" == *"READ-FAILURE"* ]]
  [[ "${lines[*]}" == *"read_failures=1"* ]]
}

@test "an empty repo allowlist refuses rather than silently sweeping nothing" {
  cat > "$QA_REPO_ALLOWLIST" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$QA_REPO_ALLOWLIST"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"enumerated empty"* ]]
}

# ── The wrapper contract is actually HANDED OVER ───────────────────────────
# Guard 14 is inert unless its caller sets the expectations, so "the wrapper can
# check this" and "the wrapper does check this" are different claims. These pin
# the second one.

@test "the approve call passes the reviewed head and verdict time to the wrapper" {
  alerting_go
  export QA_APPROVE="$TEST_TMPDIR/echo-expect.sh"
  cat > "$QA_APPROVE" <<'SH'
#!/usr/bin/env bash
{
  echo "HEAD=${QA_PR_APPROVE_EXPECT_HEAD:-unset}"
  echo "QUIET=${QA_PR_APPROVE_EXPECT_QUIET_SINCE:-unset}"
  echo "BASE=${QA_PR_APPROVE_EXPECT_BASE:-unset}"
  echo "BASEOID=${QA_PR_APPROVE_EXPECT_BASE_OID:-unset}"
  echo "ARGC=$#"
} >> "$APPROVE_CALLS"
SH
  chmod +x "$QA_APPROVE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^HEAD=abc123$' "$APPROVE_CALLS"
  grep -q '^QUIET=2026-08-17T10:51:41Z$' "$APPROVE_CALLS"
  # ...and BOTH base expectations. Asserting only HEAD/QUIET left the base pair
  # unpinned: deleting or misspelling either export here would keep this suite
  # green while Guard 14 went inert for retargets and base rewrites in this
  # lane — the exact wiring this end-to-end test exists to prove.
  grep -q '^BASE=develop$' "$APPROVE_CALLS"
  grep -q '^BASEOID=basetip0$' "$APPROVE_CALLS"
  # argv must stay exactly <repo> <pr> <uid> <body> — a prefix built by
  # expansion would have leaked the expectations in as positional arguments.
  grep -q '^ARGC=4$' "$APPROVE_CALLS"
}

@test "a PR read missing either base field REFUSES, never approves with half a contract" {
  # Omitting the empty expectations failed OPEN: the wrapper's base checks would
  # be silently skipped while the approval still went through, so a retarget or
  # base rewrite in the gap would sail past.
  alerting_go
  export STUB_PR_STATE_NO_BASE=1
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all of them failed => blackout
  [[ "${lines[*]}" == *"could not read head+base"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}

@test "a 200-with-errors GraphQL envelope is a read failure, not 'no objections'" {
  # Same fail-open the wrapper had: pullRequest:null + errors[] flowing through
  # a .reviewThreads-rooted filter as "no threads".
  alerting_go
  export STUB_THREADS_JSON='{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"Resource not accessible"}]}'
  run "$SCRIPT"
  [ "$status" -eq 3 ]   # single candidate => all failed a safety read => blackout
  [[ "${lines[*]}" == *"could not establish whether"* ]]
  run wc -l < "$APPROVE_CALLS"
  [ "$status" -eq 0 ]
  [ "${output// /}" = "0" ]
}
