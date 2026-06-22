# QA Review-Trust (Part A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Muso QA Bot from approving / saying "safe to merge" while unaddressed Critical/Important findings exist, by moving the GO gate out of LLM prose into the `qa-pr-approve.sh` wrapper and giving NO-GO a visible red `qa-review` status.

**Architecture:** Three mechanical changes. (1) Harden `scripts/qa-pr-approve.sh` so that before it runs `gh pr review --approve` it independently re-derives the gate — CI must be green and there must be zero unresolved 🔴/🟡 review threads — refusing otherwise. (2) Teach `skills-all/muso-github-code-review/SKILL.md` to carry prior findings forward (read unresolved threads, resolve confirmed-fixed ones, treat the rest as blockers) and to post a `qa-review` commit status (success on GO, failure on NO-GO). (3) Document the mechanism in GOVERNANCE — but deliberately do **not** make `qa-review` a required status check yet (it would block every non-`nsollazzo` PR, since QA only posts that status for Nick's PRs; see Review findings). The wrapper is the load-bearing fix: even if the agent hallucinates "GO", the bash gate holds. This is Part A; Part B (the CTO/Codex autofix loop) is a separate plan gated on PR #397 merging.

**Tech Stack:** Bash (`set -euo pipefail`), `gh` CLI (REST `statuses` + GraphQL `reviewThreads`/`resolveReviewThread`), `jq`, `bats` (gh fully stubbed), Markdown skill doctrine.

---

## Test environment

`bats`, `shellcheck`, `jq`, `gh` are available locally. The `qa-pr-approve.bats` suite PATH-shadows `gh` with a stub, so **Tasks 1–2 run fully offline** — no node-8, no GitHub, no auth (memory `feedback_bats_must_stub_openclaw`: an unstubbed suite once fired 9 real Slack alerts). The skill changes in Tasks 3–5 are LLM-executed doctrine + live `gh` calls the agent makes at runtime; they are verified by a **live Slack smoke on node-8 after deploy** (Task 7), not by unit tests.

## File structure

- `scripts/qa-pr-approve.sh` — **modify.** Add Guard 6 (CI green, exit 8) and Guard 7 (no unresolved Critical/Important threads, exit 9), after the self-approval guard and before the log-before-write. Update the exit-code header.
- `scripts/tests/qa-pr-approve.bats` — **modify.** Extend the `gh` stub to answer the two new queries; add tests for exit 8, exit 9, and the still-passing happy path; add a `#287-replay` test.
- `skills-all/muso-github-code-review/SKILL.md` — **modify.** New "Carry forward prior findings" subsection (A1); a `qa-review` commit-status step (A2); honest Auto-mode DM + Step 7 exit-code docs (A4). **Canonical only** — no `workspaces/qa/` shadow exists; do not create one (`feedback_skill_dual_tree`, drift gate).
- `scripts/qa-dispatch-pr-review.sh` — **modify.** One bullet in the dispatch message pointing at the carry-forward precondition.
- `docs/reference/GOVERNANCE.md` — **modify.** Document the `qa-review` status + the wrapper's mechanical gate, and record that `qa-review` is deliberately **not** a required status check (it would block every non-`nsollazzo` PR; see Task 6 / Review findings).

---

### Task 1: Wrapper Guard 6 — refuse approval when CI is not green

**Files:**
- Modify: `scripts/qa-pr-approve.sh`
- Test: `scripts/tests/qa-pr-approve.bats`

- [ ] **Step 1: Extend the `gh` stub to answer the CI-rollup query**

In `scripts/tests/qa-pr-approve.bats`, replace the `view)` arm of the stub's `case` (currently lines ~26-34) so it recognizes the `statusCheckRollup` query and returns a configurable count. The real script calls `gh pr view ... --json statusCheckRollup --jq '<count of non-passing checks>'`, so the stub just echoes the canned number:

```bash
  pr)
    action="$1"; shift || true
    case "$action" in
      view)
        if printf '%s ' "$@" | grep -q 'statusCheckRollup'; then
          echo "${STUB_BAD_CHECKS:-0}"               # count of non-passing checks
        elif printf '%s ' "$@" | grep -q 'author'; then
          echo "${STUB_AUTHOR:-nsollazzo}"            # PR author login
        else
          echo "  reviewDecision=APPROVED  mergeStateStatus=CLEAN  state=OPEN"
        fi ;;
      review)
        echo "approve" >> "$STUB_CALLS"
        [ -f "${QA_PR_APPROVE_LOG_DIR}/$(date -u +%F).jsonl" ] && echo "log-present-at-approve" >> "$STUB_CALLS"
        exit "${STUB_APPROVE_RC:-0}" ;;
    esac ;;
```

- [ ] **Step 2: Write the failing test for exit 8**

Add to `scripts/tests/qa-pr-approve.bats`:

```bash
@test "CI not green → exit 8, never approves, never logs the approval" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=2 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bats scripts/tests/qa-pr-approve.bats -f "CI not green"`
Expected: FAIL — the script currently never checks CI, so it proceeds and exits 0 (status ≠ 8).

- [ ] **Step 4: Implement Guard 6 in the wrapper**

In `scripts/qa-pr-approve.sh`, insert this block immediately AFTER the Guard 3 self-approval block (after the `fi` that closes the `if [ -n "$me" ]...` at ~line 77) and BEFORE the Guard 5 logging block (`ts="$(date -u ...`):

```bash
# --- Guard 6: CI must be green --------------------------------------------
# Re-derive CI status here rather than trusting the agent's "CI green" claim
# (root cause of the PR #287 mis-approval). Exclude the qa-review context
# itself to avoid a circular dependency (QA sets it just before calling this).
# Fail closed: if the rollup can't be read, refuse.
bad_checks="$("$GH" pr view "$pr" --repo "$owner/$repo" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]?
         | select((.context // .name) != "qa-review")
         | (((.conclusion // .state) // "PENDING") | ascii_upcase)
         | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED")] | length' \
  2>/dev/null || echo "ERR")"
[ "$bad_checks" = "0" ] || die 8 "CI is not fully green for $owner/$repo#$pr (non-passing checks: $bad_checks) — refusing to approve."
```

- [ ] **Step 5: Update the exit-code header comment**

In `scripts/qa-pr-approve.sh`, change the exit-code comment (lines ~28-29) to add code 8:

```bash
# Exit codes: 0 ok | 2 usage | 3 repo-not-muso | 4 self-approval-blocked
#             5 requester-not-allowed | 6 log-failed | 7 gh-approve-failed
#             8 ci-not-green
```

- [ ] **Step 6: Run the new test + the full suite + lint**

Run: `bats scripts/tests/qa-pr-approve.bats`
Expected: all PASS, including the new exit-8 test and the unchanged happy path (which defaults `STUB_BAD_CHECKS=0`).
Run: `shellcheck scripts/qa-pr-approve.sh && bash -n scripts/qa-pr-approve.sh`
Expected: clean (no output, exit 0).

- [ ] **Step 7: Commit**

```bash
git add scripts/qa-pr-approve.sh scripts/tests/qa-pr-approve.bats
git commit -m "fix(qa): qa-pr-approve refuses approval unless CI is green (exit 8)

The wrapper previously trusted the agent's 'CI green' claim; PR #287 was
approved with a stale GO. Re-derive CI status from statusCheckRollup and
refuse (exit 8) on any non-passing check, excluding the qa-review context.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Wrapper Guard 7 — refuse approval when unresolved Critical/Important threads exist

**Files:**
- Modify: `scripts/qa-pr-approve.sh`
- Test: `scripts/tests/qa-pr-approve.bats`

- [ ] **Step 1: Extend the `gh` stub to answer the GraphQL thread query**

In `scripts/tests/qa-pr-approve.bats`, replace the stub's `api)` arm (currently `api)   echo "${STUB_ME:-adk47}" ;;`) so it distinguishes `gh api user` from `gh api graphql`:

```bash
  api)
    if [ "${1:-}" = "graphql" ]; then
      echo "${STUB_OPEN_BLOCKERS:-0}"                 # count of unresolved 🔴/🟡 threads
    else
      echo "${STUB_ME:-adk47}"                        # gh api user --jq .login
    fi ;;
```

- [ ] **Step 2: Write the failing test for exit 9**

Add to `scripts/tests/qa-pr-approve.bats`:

```bash
@test "unresolved Critical/Important thread → exit 9, never approves" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "#287 replay: CI green but a blocking thread open → exit 9, no approval" {
  # The exact shape that mis-approved #287: green CI, an unresolved 🔴/🟡 thread.
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=4 \
    run "$SCRIPT" hydra 287 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats scripts/tests/qa-pr-approve.bats -f "exit 9|287 replay"`
Expected: FAIL — the script does not yet query threads, so it proceeds to approve (status ≠ 9).

- [ ] **Step 4: Implement Guard 7 in the wrapper**

In `scripts/qa-pr-approve.sh`, insert this block immediately AFTER the Guard 6 block from Task 1 and BEFORE the Guard 5 logging block. The `read -r -d '' ... <<'GQL' || true` pattern mirrors the heredoc slurp already used in `qa-dispatch-pr-review.sh`; the GraphQL heredoc is single-quoted so bash does not touch the `$owner`/`$repo`/`$pr` GraphQL variables (they are bound via `-f`/`-F`). No apostrophes appear in the jq (memory `feedback_apostrophe_in_jq_heredoc`):

```bash
# --- Guard 7: no unresolved Critical/Important review threads ---------------
# Carry findings forward mechanically: any unresolved thread whose first comment
# is tagged Critical/Important is a blocker, regardless of what the agent claims.
# Fail closed: if threads can't be read, refuse.
read -r -d '' gql <<'GQL' || true
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        nodes{ isResolved comments(first:1){ nodes{ body } } }
      }
    }
  }
}
GQL
open_blockers="$("$GH" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]?
         | select(.isResolved == false)
         | (.comments.nodes[0].body // "")
         | select(test("🔴|🟡"))] | length' \
  2>/dev/null || echo "ERR")"
[ "$open_blockers" = "0" ] || die 9 "$owner/$repo#$pr has $open_blockers unresolved Critical/Important review thread(s) — refusing to approve until they are addressed and the threads resolved."
```

- [ ] **Step 5: Update the exit-code header comment**

In `scripts/qa-pr-approve.sh`, extend the exit-code comment to add code 9:

```bash
# Exit codes: 0 ok | 2 usage | 3 repo-not-muso | 4 self-approval-blocked
#             5 requester-not-allowed | 6 log-failed | 7 gh-approve-failed
#             8 ci-not-green | 9 open-blocking-findings
```

- [ ] **Step 6: Run the full suite + lint**

Run: `bats scripts/tests/qa-pr-approve.bats`
Expected: all PASS (exit-9 test, #287 replay, exit-8 from Task 1, and the happy path which defaults `STUB_OPEN_BLOCKERS=0`).
Run: `shellcheck scripts/qa-pr-approve.sh && bash -n scripts/qa-pr-approve.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/qa-pr-approve.sh scripts/tests/qa-pr-approve.bats
git commit -m "fix(qa): qa-pr-approve refuses approval on unresolved Critical/Important threads (exit 9)

Carry findings forward mechanically: query reviewThreads via GraphQL and
refuse to approve while any unresolved 🔴/🟡 thread exists. Includes a #287
replay test (green CI + open blocker → exit 9). This is the wrapper-side
backstop for the skill's carry-forward doctrine.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Skill A1 — carry prior findings forward before deciding GO

**Files:**
- Modify: `skills-all/muso-github-code-review/SKILL.md`

- [ ] **Step 1: Add the carry-forward subsection**

In `skills-all/muso-github-code-review/SKILL.md`, insert this new subsection immediately BEFORE `## Step 7 — Approve the PR (approve-only, gated)` (currently line 333). It defines the precondition both modes share:

````markdown
## Carry forward prior findings (before any GO)

A fresh 7-lens pass is NOT enough: a GO must also clear every still-open finding
from earlier rounds — yours or a human's. (PR #287 was wrongly approved because a
fresh pass scored 0/0 while its own 🔴/🟡 comments from 9 minutes earlier sat
unaddressed.) Before deciding GO:

1. List the PR's unresolved review threads:

   ```bash
   gh api graphql -f query='
     query($owner:String!,$repo:String!,$pr:Int!){
       repository(owner:$owner,name:$repo){
         pullRequest(number:$pr){
           reviewThreads(first:100){ nodes{
             id isResolved
             comments(first:1){ nodes{ body path line } }
           } }
         }
       }
     }' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR"
   ```

2. For each **unresolved** thread:
   - **Your own prior finding** (body tagged 🔴/🟡/🟢/🔵): re-check the current diff
     at that location. If the fix is in place, resolve the thread; if not, it stays a
     blocker. Resolve with:
     ```bash
     gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -f id="$THREAD_ID"
     ```
   - **A human/Clio thread** (no severity emoji): assess it with the 7 lenses. If you
     judge it Critical/Important and it is unaddressed, it is a blocker. Do not resolve
     someone else's thread on their behalf — leave it and call it out.

3. **Verdict rule:** GO requires no 🔴 Critical and no 🟡 Important findings **from the
   fresh pass OR from any unresolved prior thread.** If any blocker remains, the verdict
   is NO-GO even if this run's fresh pass found nothing.

The gated wrapper (Step 7) independently re-checks unresolved 🔴/🟡 threads and CI, and
will refuse to approve (exit 9 / exit 8) if you try to approve with a blocker open — so
keep this ledger honest.
````

- [ ] **Step 2: Reference it from Auto mode step 3**

In the Auto mode section, change the "Verdict is GO" bullet (currently line 67) from:

```markdown
   - **Verdict is GO** — no 🔴 Critical and no 🟡 Important findings.
```

to:

```markdown
   - **Verdict is GO** — no 🔴 Critical and no 🟡 Important findings, AND every prior
     unresolved 🔴/🟡 thread cleared per "Carry forward prior findings". A fresh-pass
     0/0 is not GO if an earlier blocker is still open.
```

- [ ] **Step 3: Reference it from Step 7's verdict definition**

In `## Step 7`, change the first bullet (currently line 336) from:

```markdown
- your verdict is **GO** — no 🔴 Critical and no 🟡 Important findings; and
```

to:

```markdown
- your verdict is **GO** — no 🔴 Critical and no 🟡 Important findings, including any
  carried-forward unresolved thread (see "Carry forward prior findings"); and
```

- [ ] **Step 4: Sanity-check the embedded bash and commit**

Verify the embedded GraphQL snippets parse as shell (they are fenced examples, but check there are no stray apostrophes that would break a future copy-paste): visually confirm the jq/GraphQL strings use no apostrophes inside single-quoted args.

```bash
git add skills-all/muso-github-code-review/SKILL.md
git commit -m "feat(qa): skill carries prior findings forward before any GO

Add a 'Carry forward prior findings' step: list unresolved review threads,
resolve confirmed-fixed ones, and treat any remaining unresolved 🔴/🟡 (yours
or a human's) as a blocker — a fresh-pass 0/0 is no longer enough to GO. Wired
into Auto mode and Step 7. Directly addresses the #287 amnesia.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Skill A2 — post a `qa-review` commit status (red on NO-GO)

**Files:**
- Modify: `skills-all/muso-github-code-review/SKILL.md`

- [ ] **Step 1: Add the commit-status step after the batched-review post**

In `skills-all/muso-github-code-review/SKILL.md`, insert this new subsection immediately AFTER `## Step 6 — Post the batched review (only after approval)` block (after line 317, before `## Logging`). It runs in BOTH modes and on BOTH outcomes:

````markdown
## Step 6b — Publish the verdict as a commit status

After posting the review, publish your verdict as a commit status on the head SHA so
it is a visible green/red signal on the PR (and can be made a required check). Set it
on every review — `success` on GO, `failure` on NO-GO:

```bash
verdict_state=success     # use "failure" when the verdict is NO-GO
verdict_desc="GO — 0 blocking findings"   # or: "NO-GO — <N> blocking finding(s)"
gh api "repos/$OWNER/$REPO/statuses/$HEAD_SHA" --method POST \
  -f state="$verdict_state" \
  -f context="qa-review" \
  -f description="$verdict_desc" \
  -f target_url="https://github.com/$OWNER/$REPO/pull/$PR/files"
```

`$HEAD_SHA` is the head commit you reviewed. A new push creates a new SHA with no
`qa-review` status yet, so a re-review must run before the PR is green again (pairs
with `dismiss_stale_reviews`). On NO-GO you set `failure` and stop — do not approve.
````

- [ ] **Step 2: Wire it into Auto mode (post on both outcomes)**

In the Auto mode section, change step 4 "Never merge" region so the status is always set. Replace the Auto-mode bullet block at lines 61-69 region's tail — specifically, after the "Approve (Step 7) only if ALL of these hold" list and its "Never merge" line, add an explicit instruction. Change line 69 from:

```markdown
4. **Never merge** (unchanged). A human merges.
```

to:

```markdown
4. **Always publish the `qa-review` commit status (Step 6b)** — `failure` on NO-GO,
   `success` on GO — before the result DM, so the PR shows a red/green QA signal.
5. **Never merge** (unchanged). A human merges.
```

(Renumber the following Auto-mode item — the "LAST, DM the author the result" step — from 5 to 6.)

- [ ] **Step 3: Commit**

```bash
git add skills-all/muso-github-code-review/SKILL.md
git commit -m "feat(qa): publish verdict as a red/green qa-review commit status

Add Step 6b: POST a qa-review commit status on the head SHA (success on GO,
failure on NO-GO) so a QA NO-GO is a visible red signal and can be made a
required check. Always set in Auto mode before the result DM.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Skill A4 — honest DM + wrapper exit-code docs; dispatch note

**Files:**
- Modify: `skills-all/muso-github-code-review/SKILL.md`
- Modify: `scripts/qa-dispatch-pr-review.sh`

- [ ] **Step 1: Make the success DM honest**

In the Auto mode result-DM block, change the approved-case line (currently line 72) from:

```markdown
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "Approved -- CI green, no blocking findings. Safe to merge: <pr-url>" "$ts"
```

to:

```markdown
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "Approved -- CI green and 0 unresolved blocking findings (fresh pass + carried-forward threads). Safe to merge: <pr-url>" "$ts"
```

- [ ] **Step 2: Document the new wrapper exit codes in Step 7**

In `## Step 7`, change the exit-code relay bullet (currently line 350-352) from:

```markdown
- If the wrapper exits non-zero, relay the reason and do NOT retry blindly:
  `exit 4` = PR is authored by Aaron's account (GitHub blocks self-approval — another
  reviewer is needed); `exit 5` = requester not authorized; `exit 3` = not a Muso-AI repo.
```

to:

```markdown
- If the wrapper exits non-zero, relay the reason and do NOT retry blindly:
  `exit 3` = not a Muso-AI repo; `exit 4` = PR authored by the gateway account (GitHub
  blocks self-approval — another reviewer is needed); `exit 5` = requester not authorized;
  `exit 8` = CI is not green; `exit 9` = an unresolved Critical/Important thread is still
  open (carry it forward — fix it or resolve the thread, do not approve around it).
```

- [ ] **Step 3: Add a carry-forward bullet to the dispatch message**

In `scripts/qa-dispatch-pr-review.sh`, in the heredoc dispatch message, add a bullet after the "Skip the Step 5 human gate..." line (currently line 75-76). Insert:

```bash
- Before any GO, carry prior findings forward (skill "Carry forward prior findings"):
  resolve confirmed-fixed threads, treat any unresolved Critical/Important as a blocker.
```

- [ ] **Step 4: Lint the dispatch script and commit**

Run: `shellcheck scripts/qa-dispatch-pr-review.sh && bash -n scripts/qa-dispatch-pr-review.sh`
Expected: clean.

```bash
git add skills-all/muso-github-code-review/SKILL.md scripts/qa-dispatch-pr-review.sh
git commit -m "fix(qa): honest approved-DM + document exit 8/9; dispatch carry-forward note

The approved DM now states '0 unresolved blocking findings (fresh + carried
forward)' instead of the bare 'no blocking findings' that masked #287. Step 7
documents wrapper exits 8 (CI not green) and 9 (open blocker). Dispatch message
points the agent at the carry-forward precondition.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Governance — document the `qa-review` status gate (and why it is NOT a required check)

**Files:**
- Modify: `docs/reference/GOVERNANCE.md`

- [ ] **Step 1: Read the current branch-protection section**

Run: `grep -n "required status checks\|qa-review\|dismiss_stale_reviews\|Branch Protection" docs/reference/GOVERNANCE.md`
Expected: locate the branch-protection block (PR #392 recorded "No required status checks — 'PR Validation' CI is informational… the QA auto-review is what gates approval on green.").

- [ ] **Step 2: Update the branch-protection block (document the gate; do NOT request a required check)**

Edit the branch-protection block in `docs/reference/GOVERNANCE.md` (keep the surrounding lines intact; match the file's existing prose). Leave line 199's "No required status checks" as-is and append the new mechanism + the explicit reason `qa-review` is **not** made required:

```markdown
- **QA verdict gate (PR #391+ hardening):** the QA bot publishes a `qa-review` commit
  status — `success` on GO, `failure` on NO-GO (see `skills-all/muso-github-code-review/SKILL.md`
  Step 6b) — so a NO-GO is visibly red on the PR. Enforcement is mechanical, not on the
  agent's word: the gated `scripts/qa-pr-approve.sh` refuses to record the code-owner
  approval unless CI is green (exit 8) and no unresolved Critical/Important review thread
  remains (exit 9). Because the required code-owner approval (`* @adk47`) is what gates
  merge, withholding the approval blocks the merge.
- **`qa-review` is intentionally NOT a required status check.** Required checks are
  repo-wide, but the QA auto-review only runs on `nsollazzo` PRs (`qa-autoreview.yml`),
  so requiring `qa-review` would permanently block every other contributor's PR on a
  status that is never reported. Revisit only if/when QA reviews **all** PRs to `main`
  (scope expansion — out of scope here). Until then the red status is a visible signal +
  defense-in-depth, and the wrapper refusal (no approval) is the real merge block for
  Nick's PRs.
```

- [ ] **Step 3: Commit**

```bash
git add docs/reference/GOVERNANCE.md
git commit -m "docs(governance): record qa-review status gate; explain why it is NOT a required check

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Full verification + live smoke prep

**Files:** none (verification only)

- [ ] **Step 1: Run the complete wrapper suite and linters**

Run:
```bash
bats scripts/tests/qa-pr-approve.bats
shellcheck scripts/qa-pr-approve.sh scripts/qa-dispatch-pr-review.sh
bash -n scripts/qa-pr-approve.sh scripts/qa-dispatch-pr-review.sh
```
Expected: all bats PASS; shellcheck/`bash -n` clean.

- [ ] **Step 2: Confirm no skill drift / no shadow introduced**

Run: `bash scripts/check-skill-drift.sh` (or the repo's documented drift command)
Expected: PASS — only the canonical `skills-all/muso-github-code-review/SKILL.md` changed; no `workspaces/qa/skills/...` shadow exists.

- [ ] **Step 3: Push the branch and let PR Validation run**

Run: `git push -u origin HEAD`
Expected: the "PR Validation" workflow runs the bats + shellcheck + py jobs green on the self-hosted hydra runner.

- [ ] **Step 4: Record the post-deploy live smoke (do not mark done until run on node-8)**

After this PR merges and CD deploys the skill to the gateway, run a live smoke on node-8 (the only place the skill-load + live `gh` calls are exercised — memory `feedback_test_on_node8_not_local`):
  1. Open a throwaway hydra PR with one deliberate 🔴 finding.
  2. Confirm the QA auto-review posts the finding, sets `qa-review=failure` (red), and does NOT approve.
  3. Push a fix, confirm the re-review resolves the thread, sets `qa-review=success`, and only then approves via the wrapper.
  4. Confirm a tampered attempt (approve with a blocker still open) is refused by exit 9.

---

## Review findings & known limitations

Surfaced by reviewing this plan against the code (Rule 13 — fail loud, not hide):

1. **[Fixed in this plan] Making `qa-review` a required check would break all non-Nick PRs.** Required status checks are repo-wide; QA only runs on `nsollazzo` PRs and `CODEOWNERS` is `* @adk47`, so a required `qa-review` would permanently block everyone else's PRs on a never-reported check. Task 6 now documents the gate and explicitly defers the required-check toggle. The merge block for Nick's bad PRs comes from the wrapper refusing the code-owner approval, not from a required check.

2. **Guard 7 only gates *inline-threaded* findings.** A Critical finding that can't be tied to a diff line lives in the review *body* (SKILL.md:313-315) and has no review thread, so the GraphQL `reviewThreads` query won't count it. #287's findings were all inline, so this plan catches #287 — but body-level Criticals rely on the skill's carry-forward doctrine + the `qa-review=failure` status, not the wrapper. Mitigation: the skill should prefer inline comments for 🔴/🟡 so they are mechanically gated. Accepted limitation for Part A; revisit in Part B.

3. **The jq/GraphQL extraction is NOT exercised by the bats tests** — the stub returns canned counts, so Tasks 1-2 verify the wrapper's *control flow* (given a count → refuse/proceed), not the filter correctness. The real `gh --jq` runs gojq (not local jq), and the emoji `test("🔴|🟡")` regex is the riskiest line. It is validated only by the Task 7 live smoke on node-8. **Recommended strengthening:** during implementation, run the exact jq filters against a captured `statusCheckRollup` / `reviewThreads` JSON sample with `gh api ... --jq` on node-8 once, before trusting them.

4. **Fail-closed is intentional.** If `gh` can't read the rollup or threads (transient API error), the guards emit `ERR` → non-`0` → refuse to approve. This can cause an occasional false NO-approval on a GitHub blip; the trade favors safety (never approve blindly) and the agent can re-run.

5. **Line numbers in Tasks 3-5 are hints, not anchors.** Sequential edits to `SKILL.md` shift line numbers, and Task 4 renumbers the Auto-mode list (items 4/5 → 5/6). Each step quotes exact old text — match on the **quoted text**, not the line number. Use the skill's existing head-SHA reference convention (`<headRefOid>` / the dispatched `${sha}`) when filling `$HEAD_SHA` in Step 6b.

6. **Spec amended to match.** `docs/designs/2026-06-02-qa-autofix-loop-design.md` §3/§5 originally listed "Aaron makes `qa-review` required" as the human step; corrected there too (deferred, same reason as #1).

7. **Self-resolution trust boundary (named, not closed in Part A).** Guard 7 trusts GitHub's `isResolved` thread state, and the skill lets QA resolve its own threads once it judges the fix is in place. So the wrapper closes "agent says GO while a blocker is open" but NOT "agent wrongly resolves a thread, then says GO" — that still rides on agent honesty. This is acceptable for Part A (strictly better than the status quo); mechanical fix-verification is Part B's CTO-fixes-then-QA-re-reviews loop. The Guard 7 comment and the skill's carry-forward section now state this explicitly rather than implying more safety than exists.

## Self-review

**Spec coverage:**
- A1 carry-forward → Task 3 (skill) + Task 2 (wrapper backstop). ✓
- A2 red `qa-review` status → Task 4. ✓
- A3 wrapper re-derives the gate → Tasks 1 (CI) + 2 (threads). ✓
- A4 honest DM → Task 5. ✓
- Required-check decision → Task 6 (documented as deliberately NOT required; no Aaron action). ✓
- Testing (bats stubbed, #287 replay, live smoke) → Tasks 1, 2, 7. ✓
- Part B is explicitly out of scope (separate plan, gated on #397). ✓

**Placeholder scan:** No TBD/TODO; every code step shows the exact code/command and expected output. The live smoke (Task 7 Step 4) is intentionally deferred to post-deploy on node-8, clearly marked, not a placeholder.

**Type/identifier consistency:** Exit codes 8/9, env knobs `STUB_BAD_CHECKS`/`STUB_OPEN_BLOCKERS`, context name `qa-review`, and variable names (`bad_checks`, `open_blockers`, `gql`) are used consistently across the wrapper, the stub, and the tests.
