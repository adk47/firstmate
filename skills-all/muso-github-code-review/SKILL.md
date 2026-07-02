---
name: muso-github-code-review
description: |
  Review and (when satisfied) approve a GitHub PR in Muso-AI repos: fetch the diff,
  run a 7-lens checklist, post a severity-tagged Slack summary, and on a GO verdict
  approve via the gated wrapper (never merge). Triggers: "review PR"/"review this
  pull request", "approve PR", "code review", "check/audit this PR", any
  github.com/<owner>/<repo>/pull/<n> link.
depends-on:
  - muso-slack-formatter
compatibility: |
  Requires the gateway `gh` CLI (authenticated at host level) and `git`. Reading a
  PR works with the default token; POSTING a review needs a token with PR-write
  scope. If the write fails on scope, stop at the Slack summary and tell the
  requester a human must post it. Running a PR's tests additionally needs `pnpm`
  (present on the gateway).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
  adapted-from: "NousResearch/hermes-agent github-code-review (gh/git mechanics) + Claude pr-review-toolkit lenses (review doctrine)"
allowed-tools:
  - exec
---

# Muso — GitHub Code Review

End-to-end PR review: gather → diff → 7-lens analysis → Slack summary → human
approval → batched GitHub review. You run the whole thing yourself in one session.

## When Clio or CTO delegate a review

PR review is your job — do NOT bounce it back to CTO. Run the review, then relay your
finished summary to whoever delegated so they can post it under their own identity.

## Auto mode (automated dispatch — no human in the loop)

When the triggering message says **AUTO-REVIEW** (dispatched by
`scripts/qa-dispatch-pr-review.sh` from the `qa-autoreview` GitHub Action), you are
running headless: there is no person in the thread to approve, and the dispatch +
the gates below ARE the authorization. You keep the PR author updated in a Slack DM
(opening note → threaded result) and run the same review — diff fetch, 7 lenses,
CI check, batched-review API, the `qa-pr-approve.sh` wrapper, logging — with these
overrides. The dispatch message gives you the author's Slack UID.

**Identity — make the automation legible.** GitHub records the review/approval
under the host account (Aaron / adk47); there is no separate bot user. So lead the
GitHub **review body** and the **approval body** with a clear `🤖 Muso QA Bot
(automated review)` banner so it reads as automation, not a manual review by Aaron.
The Slack DMs go out as the QA app, so they don't repeat the bot name in the text —
the opening note names the `repo#PR` link (which identifies the source) and the
result leads with the ✅/⛔ state.

1. **FIRST, DM the author an opening note and keep the returned thread ts.** This is
   how they know a review started. Use the per-PR thread helper (not `qa-slack-dm.sh`
   directly) so re-reviews of the same PR land in ONE Slack thread instead of a new
   top-level message each push. It owns the opening wording (first review vs
   "re-reviewing … after a new push") and prints the canonical thread-root ts —
   capture it so the result threads under it:
   ```bash
   ts=$(bash /opt/hydra/scripts/qa-pr-thread-dm.sh <owner>/<repo> <pr> <author-uid>)
   ```
   Best-effort: if it fails (empty ts), log it and continue the review anyway.
2. **Skip Step 5 (the human-approval gate).** Do not ask "Want me to post this?" —
   post the batched review to GitHub yourself (Step 6), after writing the
   Step-"Logging" audit line (set `"requester"` to the author UID and
   `"authorization":"auto-review-dispatch"`).
3. **Approve (Step 7) only if ALL of these hold** — otherwise post the review and
   stop without approving, and say which gate failed:
   - **CI is fully green** — `gh pr checks <pr> --repo Muso-AI/hydra` shows every
     check passed, with none `fail` or `pending`. In auto mode be strict: do NOT
     apply Step 3c's "unrelated red gate" allowance — any non-green check means do
     not approve. (Ignore the `qa-review` row in `gh pr checks` — that is your OWN status from Step 6b; the approval wrapper excludes it to avoid a circular dependency.)
   - **Verdict is GO** — no 🔴 Critical and no 🟡 Important findings, AND every prior
     unresolved 🔴/🟡 thread cleared per "Carry forward prior findings". A fresh-pass
     0/0 is not GO if an earlier blocker is still open.
   - **Rebase integrity is clear** — the Step 3d report is CLEAN. Missing counts
     as no-data ONLY for external repos; for **hydra** a missing report is a
     failed hand-off and holds approval (say so in the verdict/DM). A WARN holds
     approval until a HUMAN resolves the 🟡 REBASE WARNING thread; an ERROR holds
     it outright. The wrapper's Guard 8 re-derives all of this mechanically
     (exit 10).
   - The gated wrapper accepts the author UID.
4. **Publish the `qa-review` commit status (Step 6b)** (best-effort — skip if the token lacks status scope, same as the Step 6 403 fallback) — `failure` on NO-GO,
   `success` on GO — before the result DM, so the PR shows a red/green QA signal.
5. **Never merge** (unchanged). A human merges.
6. **LAST, DM the author the result as a threaded reply under the opening ts.** Lead
   with the state emoji (✅ approved / ⛔ not approved) and make `#<PR>` a clickable
   Slack link to the PR (`<url|#N>` mrkdwn) so it is scannable at a glance:
   ```bash
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "✅ Approved <https://github.com/Muso-AI/hydra/pull/<PR>|#<PR>> — CI green and 0 unresolved blocking findings (fresh pass + carried-forward threads). Safe to merge." "$ts"
   # or, if not approved:
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "⛔ Reviewed <https://github.com/Muso-AI/hydra/pull/<PR>|#<PR>> — <N> blocking finding(s), not approved (<one-line reason>). Details on the PR." "$ts"
   ```
   Keep it to one line; the full review lives on the PR. (If you never got an opening
   ts, send it un-threaded rather than skipping it.) When the hold is a rebase
   warning (Step 3d), name it: "⛔ Reviewed <url|#N> — REBASE WARNING: possible
   rebase clobber; needs a human to review and resolve the PR thread."

## Access control

- **Requesting a review** (read-only): any Tier 0–2 user. Tier 3 / unknown users
  get the Slack summary only, never a GitHub write.
- **Posting the review to GitHub is an external write.** It requires (a) explicit
  human approval in-thread and (b) a write-activity log entry before execution
  (see "Logging" below). Never post without both. *(Exception: **Auto mode** above
  substitutes the automated dispatch + the CI-green/GO/allowlist gate for the
  in-thread approval; the write-activity log is still required.)*

## Setup

The gateway `gh` CLI is already authenticated at host level — just use it. Resolve
the target from the request (a URL, or "PR 123 in core-backend"):

```bash
# From a URL like https://github.com/Muso-AI/core-backend/pull/123
OWNER=Muso-AI
REPO=core-backend
PR=123
```

If only a number + repo name are given, default `OWNER=Muso-AI`.

## Step 1 — Gather PR context

```bash
gh pr view "$PR" --repo "$OWNER/$REPO" \
  --json title,body,author,baseRefName,headRefName,state,isDraft,additions,deletions,changedFiles,files,headRefOid
```

Read the PR description — it is the requirements context for the review. Note the
author, scope (files / +/-), and whether it is a draft.

## Step 2 — Get the diff

> ⚠️ **No local clone exists.** Your workspace (`/opt/hydra/workspaces/qa`) is **not a
> git repo** — `git status` / `git diff` / `git remote` there fail with "not a git
> repository". Do **not** run local `git` to "orient" yourself. `gh` reads the PR
> remotely; use it for everything. Local `git` is valid **only** inside a fresh clone
> for the optional Step 3b test run — never in your workspace.
>
> **Run only the commands this skill prescribes.** Don't freelance scratch steps — they
> routinely fail and (in this cron context) a failed command can mark the whole run
> `outcome=error` even though your review succeeded. Specifically: do **not** `git clone`
> the repo into `/tmp` unless Step 3b's optional test run genuinely requires it; do **not**
> re-read this SKILL file from disk (it's already in your context; trying to print/read it
> from a managed-skills path just fails); do **not** create scratch folders. The only temp
> file you need is `/tmp/pr-review.json` for the batched review (Step 6).

No local checkout is needed; `gh` fetches the diff directly:

```bash
gh pr diff "$PR" --repo "$OWNER/$REPO"                 # full diff
gh pr diff "$PR" --repo "$OWNER/$REPO" --name-only     # changed files
```

To view **one file's** diff, use the files API — `gh pr diff` has **no** path
filter:

```bash
gh api "repos/$OWNER/$REPO/pulls/$PR/files" \
  --jq '.[] | select(.filename=="<path>") | .patch'
```

> **Do NOT** write `gh pr diff "$PR" -- <path>`. `gh pr diff` does not accept a
> `-- <pathspec>` (git-style path filtering); it fails with
> *"accepts at most 1 arg(s), received 2"*. For a single file use the files-API
> recipe above; to drop noise from the full diff, use `--exclude '<glob>'`.

For full-file context around a hunk (diffs alone hide issues), read the file at the
PR head:

```bash
gh api "repos/$OWNER/$REPO/contents/<path>?ref=$(gh pr view "$PR" --repo "$OWNER/$REPO" --json headRefOid --jq .headRefOid)" \
  --jq '.content' | base64 -d
```

**Stacked PRs (important):** if `baseRefName` is not the repo's default branch, this
PR is stacked on a parent branch. Review only the changes that belong to THIS PR,
not the parent's. `gh pr diff` already scopes to the PR's base, so prefer it over
`git diff main...HEAD` (which would include the parent's changes and produce
confused findings). Call out the stacked relationship in the summary.

## Step 3 — Walk the 7-lens checklist (the review)

Go over every changed file once, through all seven lenses. This is the merged
doctrine — be specific, cite `file:line`, and prefer real problems over style nits.

1. **Correctness & edge cases** — Does the code do what the PR claims? Empty/null
   inputs, large inputs, boundary values, concurrent access, off-by-one.
2. **Silent failures & error handling** — Bare `catch`/`except` that swallow errors,
   fail-open fallbacks that mask outages, errors logged-but-not-surfaced, missing
   logging on failure paths, ignored return/err values. (Treat this lens as
   highest-value — silent failures are the costliest class.)
3. **Test coverage** — Behavioral coverage of the new paths and their error cases,
   not line %. New functionality with no test? Critical paths only covered on the
   happy path? Flag the specific missing case.
4. **Type design & invariants** — New types/schemas/models: are illegal states
   representable? Is the invariant enforced at construction, or only by convention?
   Encapsulation leaks, primitive obsession on domain concepts.
5. **Comment & doc accuracy** — Comments that contradict the code, stale TODOs, and
   docs (README / SOUL.md / SKILL.md / API docs) that no longer match the changed
   behavior.
6. **Simplification** — Unnecessary complexity, duplicated logic, dead code, or a
   clearer equivalent — only where it preserves behavior. Don't invent refactors.
7. **Project-guideline & security adherence** — The repo's `CLAUDE.md`/style rules;
   hardcoded secrets/credentials, missing input validation, SQL injection, XSS,
   path traversal, missing auth checks; plus obvious performance traps (N+1 queries,
   blocking calls in hot paths).

## Step 3b — Run the tests (when warranted)

The 7-lens pass is static (diff + file reads, no checkout). When the test-coverage or
correctness lens needs it — or the requester asks — actually run the PR's tests. That
needs a checkout:

```bash
gh pr checkout "$PR" --repo "$OWNER/$REPO"   # inside a clone of the repo
# or: clone the repo, then  git fetch origin pull/$PR/head && git checkout FETCH_HEAD
```

**Hydra in-tree plugins** (`plugins/<name>/`, e.g. `plugins/intercom`) are standalone
pnpm packages — each has its OWN `pnpm-lock.yaml`; there is NO root workspace. A fresh
checkout has no `node_modules`, so `npm test` fails with `vitest: not found`. vitest
isn't missing — it's a declared devDependency that just hasn't been installed yet.
Install deps in the plugin dir first:

```bash
cd plugins/<name>            # e.g. plugins/intercom
pnpm install --frozen-lockfile
npm test                     # = vitest run
```

- Use **pnpm** — the lockfile is pnpm; `npm install` ignores it and may drift.
- Do NOT `npm install -g vitest` — a global vitest still fails, because the test files
  import the plugin's own deps and the lockfile pins the exact vitest version.
- **`vitest: not found` alone is NOT a finding** — it just means the install step was
  skipped. A real finding is when `pnpm install` or the tests themselves fail.

## Step 3c — Check CI status (read-only, repo-pinned)

CI state is context for the verdict ("hold until green"), not a separate review. Get the
rollup with one repo-pinned command:

```bash
gh pr checks "$PR" --repo "$OWNER/$REPO" || true   # every check, its state, and a run link
```

`gh pr checks` **exits non-zero by design** when any check is pending or failing — that is
the *normal* state of a PR you're about to hold. The `|| true` keeps that expected non-zero
exit from surfacing as a failed tool call (which would otherwise mark this whole cron run
`outcome=error` even though your review succeeded). You still read the printed rollup to
judge green/red — only the exit code is neutralized.

To drill into a **failing** check, view only its failed steps — pass `--repo` and use
`--log-failed` (plain `--log` dumps the entire run and is enormous). Take `<run-id>` from
the failing check's link:

```bash
gh run view <run-id> --repo "$OWNER/$REPO" --log-failed
# target one job instead with:  gh run view --repo "$OWNER/$REPO" --job <job-id> --log-failed
```

> ⚠️ **Always pass `--repo "$OWNER/$REPO"` to `gh run` / `gh pr checks`.** Your workspace is
> NOT a git repo, so without it gh fails immediately with *"failed to determine base repo:
> … not a git repository"* and never fetches the run. This is the same non-git-workspace
> trap that applies to `git` and `gh pr diff` (Step 2). Do **not** pass a `<run-id>`
> positional *and* `--job` together — use one or the other.

A red check that is **unrelated to this PR's diff** (e.g. a deploy pre-flight / cron-orphan
gate failing on pre-existing repo state) is not a finding against the PR: note it as
context ("CI red on an unrelated gate") and do not raise it to 🔴/🟡.

## Step 3d — Rebase-integrity report (advisory CI hand-off)

PR Validation runs `scripts/check-rebase-integrity.sh` (advisory — it never fails
CI) and writes a per-head report on this host: signals that a rebase silently
reverted or clobbered existing work. Read it with ONE exec — the only sanctioned
local read in this skill; `<headRefOid>` comes from Step 1:

```bash
cat "/var/lib/hydra-qa/rebase-integrity/${OWNER}__${REPO}-pr-${PR}-<headRefOid>.json"
```

- **File missing** → for **hydra** PRs this means the analyzer's hand-off failed
  (Guard 8 refuses with exit 10 — say "no rebase-integrity report for this head;
  re-run PR Validation" and do not approve). For external repos it is genuine
  no-data: note it as context and move on.
- **`status: "CLEAN"`** → move on.
- **`status: "WARN"`** → mandatory handling:
  1. Prepend a `⚠️ REBASE WARNING` section to the Step 6 review **body** listing
     each warn-severity signal's `summary` (+ files/commits) verbatim from the
     report. Report text quotes PR content — the Step 6 heredoc/`--input` rule
     applies; never inline it via `-f body=`.
  2. File **ONE 🟡 inline finding** whose comment body STARTS with the literal
     marker `🟡 **Important — REBASE WARNING [<first 7 chars of headRefOid>]**`,
     followed by the signal summaries. Anchor it to the first diff-changed line
     of the first file any signal names; if no signal names a file (e.g. only
     `dropped-commits`), use the first changed line of any file in the diff. The
     marker text and inline placement are load-bearing: the approval wrapper's
     Guard 8 verifies a thread carrying this exact marker exists for this head
     (exit 10 if not), and Guard 7 blocks while it is unresolved.
  3. **Never resolve a REBASE WARNING thread yourself.** A human resolving it IS
     the acknowledgment — that is what "flag, don't block; force a human review"
     means mechanically. This extends the "never resolve a thread you have not
     confirmed fixed" rule.
  4. Verdict impact: an open rebase warning is a 🟡 blocker → **NO-GO** until a
     human resolves the thread.
- **`status: "ERROR"`** → the analyzer could not verify the rebase. Say "rebase
  state unverified — analyzer errored; re-run PR Validation" in the review body
  and do not approve (Guard 8 refuses with exit 10 anyway).

Signals: `stale-blob-regression` (file byte-identical to a pre-merge-base
version), `erased-recent-base-work` (PR deletes lines `main` gained recently),
`large-deletion` (deletions disproportionate to additions), `dropped-commits`
(commits lost across a force-push), `reintroduced-removed-lines` (re-adds code
`main` recently removed), `duplicate-patch-id` (same patch replayed twice).
`info` entries (`already-merged`, `rewritten-commits`) are context, not blockers.
Do NOT re-derive these signals yourself from `gh pr diff` — relay the
CI-computed report only.

## Step 4 — Post the Slack summary

Number findings sequentially so the requester can reference them ("drop #3"); the
**muso-slack-formatter** filter auto-applies to your Slack output. Severity markers:

| Emoji | Severity | Meaning |
|-------|----------|---------|
| 🔴 | Critical | Must fix before merge (security, data loss, crash, broken core path) |
| 🟡 | Important | Should fix; low risk if knowingly skipped |
| 🟢 | Nice-to-have | Minor improvement |
| 🔵 | Suggestion | Optional / informational |

Summary shape:

```
PR Review: <title>  (#<PR> in <repo>)
Verdict: <request changes | comment | approve>  — <N critical, N important, ...>

🔴 Critical
1. <file:line> — <what + why + fix>

🟡 Important
2. <file:line> — ...

🟢 Nice-to-have
3. ...

🔵 Suggestions
4. ...

Strengths: <what's done well>
```

Then ask, in-thread:

> Want me to post this to the PR? You can also: "post critical+important only",
> "drop #3 and #5", or "skip".

## Step 5 — Human-approval gate

**Do not write to GitHub until a human replies with approval.** Apply any requested
edits (drops, severity filter) first. If the requester says skip, stop here — the
summary stands on its own.

## Step 6 — Post the batched review (only after approval)

First, log the write (Step "Logging"). Then submit ONE review with all approved
inline comments via the reviews API:

```bash
cat > /tmp/pr-review.json <<JSONEOF
{
  "commit_id": "<headRefOid>",
  "event": "COMMENT",
  "body": "🤖 **Muso QA Bot** (automated review) — see inline comments. Posted via QA automation on the adk47 account, not a manual review by Aaron.",
  "comments": [
    {"path": "src/auth.js", "line": 45, "side": "RIGHT", "body": "🔴 **Critical:** user input passed straight into the query — parameterize it."},
    {"path": "src/util.js", "line": 8,  "side": "RIGHT", "body": "🔵 **Suggestion:** duplicates logic in core/utils.js:34."}
  ]
}
JSONEOF

gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --method POST --input /tmp/pr-review.json
```

- **NEVER pass review/PR/diff text inline via `-f body='...'` or `-f body="..."`.** Always
  build the JSON with a heredoc into a temp file and use `--input <file>` (as above), or
  `--field body=@<file>`. PR titles, diffs, and existing comments routinely contain
  backticks, `$(...)`, `>`, `<`, or `|`; inline `-f body=` re-parses that text through your
  shell, so a code-span like `` `updated_at > seven_days_ago` `` runs as command
  substitution plus a redirect. On PR #287 exactly that silently created
  `workspaces/qa/seven_days_ago` in the deploy tree (broke Deploy pre-flight) — and the
  same path is a latent code-execution vector. This applies to **every** `gh api` write
  whose body is or quotes PR content: the batched review (Step 6), and any comment
  reply/edit (`POST`/`PATCH .../pulls/comments/...`) or issue comment. Fixed, literal,
  metacharacter-free bodies (e.g. the Step 6b commit-status `-f description=`/`-f state=`)
  are fine.
- `event`: use **`COMMENT`** for the inline review comments. Use `REQUEST_CHANGES`
  only when the human asks to formally block. Do **not** use the reviews-API
  `APPROVE` event to record a formal approval — the sanctioned approval path is the
  gated wrapper in Step 7.
- Inline comments use `line` (line number in the NEW file version) + `side: "RIGHT"`;
  for a multi-line range add `start_line` + `start_side`. Do NOT use `position` (it is
  closing down — use `line`), and do NOT add `subject_type` here — the batched reviews
  endpoint does not accept it (that field only exists on the standalone
  `POST .../pulls/<n>/comments` endpoint).
- `line` MUST be a line that appears in the PR diff, or the call 422s. If a finding can't
  be tied to a changed line (file-level or whole-PR), put it in the review `body` summary
  rather than as an inline comment. Prefer placing 🔴 Critical / 🟡 Important findings as inline comments (review threads) whenever possible, so the approval wrapper's carry-forward check (Guard 7) can gate them; a blocker placed only in the review body is invisible to that mechanical gate and rests on the qa-review status plus your verdict.
- If the call returns a 403 / scope error, the gateway token lacks PR-write scope:
  report this to the requester and leave the Slack summary as the deliverable.

## Step 6b — Publish the verdict as a commit status

After posting the review, publish your verdict as a commit status on the head SHA so
it is a visible green/red signal on the PR (and can be made a required check). Set it
on every review — `success` on GO, `failure` on NO-GO:

```bash
verdict_state=success     # use "failure" when the verdict is NO-GO
verdict_desc="GO — 0 blocking findings"   # or: "NO-GO — <N> blocking finding(s)"
HEAD_SHA="$(gh pr view "$PR" --repo "$OWNER/$REPO" --json headRefOid --jq .headRefOid)"
gh api "repos/$OWNER/$REPO/statuses/$HEAD_SHA" --method POST \
  -f state="$verdict_state" \
  -f context="qa-review" \
  -f description="$verdict_desc" \
  -f target_url="https://github.com/$OWNER/$REPO/pull/$PR/files"
```

`$HEAD_SHA` is the head commit you reviewed. A new push creates a new SHA with no
`qa-review` status yet, so a re-review must run before the PR is green again (pairs
with `dismiss_stale_reviews`). On NO-GO you set `failure` and stop — do not approve.
Best-effort: if the Step 6 review POST already failed with a 403/scope error, the
status POST will too — skip it, rely on the Slack DM, and do not loop or report a hard
failure.

## Logging (before any GitHub write)

Per QA Write Activity Logging policy, append one JSON line to a dated log file
BEFORE posting (same convention as the ops skills, e.g. `api-logs/admin/`):

```bash
mkdir -p api-logs/github
cat >> "api-logs/github/$(date +%F).jsonl" <<EOF
{"agent":"qa","action":"github_pr_review","target":"$OWNER/$REPO#$PR","requester":"<name>","timestamp":"$(date -u +%FT%TZ)","authorization":"approved-in-thread"}
EOF
```

If you cannot log it, do not post it.

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
     (`$THREAD_ID` is the `id` field of the thread from the list query above.)
   Resolving a thread asserts you verified the fix in the current diff — the approval
   wrapper (Guard 7) trusts that resolution. Never resolve a thread you have not
   confirmed fixed; an un-verified resolution is exactly how a blocker slips through.
   (Mechanical fix-verification arrives with the autofix loop in Part B.)
   - **A human/Clio thread** (no severity emoji): assess it with the 7 lenses. If you
     judge it Critical/Important and it is unaddressed, it is a blocker. Do not resolve
     someone else's thread on their behalf — leave it and call it out.

3. **Verdict rule:** GO requires no 🔴 Critical and no 🟡 Important findings **from the
   fresh pass OR from any unresolved prior thread.** If any blocker remains, the verdict
   is NO-GO even if this run's fresh pass found nothing. A 🟡 REBASE WARNING thread
   counts like any other Important blocker — and only a HUMAN may resolve one
   (Step 3d); never resolve it yourself.

The gated wrapper (Step 7) independently re-checks unresolved 🔴/🟡 threads and CI, and
will refuse to approve (exit 9 / exit 8) if you try to approve with a blocker open — so
keep this ledger honest.

## Step 7 — Approve the PR (approve-only, gated)

Approve **only** when BOTH hold:
- your verdict is **GO** — no 🔴 Critical and no 🟡 Important findings, including any
  carried-forward unresolved thread (see "Carry forward prior findings"); and
- the requester's Slack UID is one of: **Aaron, Serhii, Nick**.

Approve through the gated wrapper — **never** call `gh pr review --approve` directly.
The wrapper enforces Muso-AI-only, self-approval refusal, the requester allowlist, and
the audit log:

```bash
bash /opt/hydra/scripts/qa-pr-approve.sh <repo> <pr> <requester-slack-uid> "🤖 Approved by Muso QA Bot (automated review). Recorded on the adk47 account, not a manual review by Aaron." \
  || echo "qa-pr-approve: declined (exit $?) — a NO-GO / gate refusal is a normal review outcome; post the review, relay the reason, do not approve."
```

- The `|| echo …` is **intentional and required**: a gate refusal (CI not green, open blocker,
  not allowlisted) is a *normal* review outcome, not a failure. Capturing the wrapper's non-zero
  exit this way keeps that expected decline from surfacing as a failed tool call — which would
  otherwise mark this whole cron run `outcome=error` (and prevent the one-shot from self-deleting)
  even though you reviewed correctly. The wrapper still refuses to approve on non-zero exactly as
  before; you read the captured exit code to relay the reason. Do **not** approve around a decline.
- `<repo>` is the short name (e.g. `core-backend`) or `Muso-AI/<repo>`;
  `<requester-slack-uid>` is the `sender_id` from message metadata — never a name.
- **You approve; you never merge.** A human merges — say so to the requester.
- If the wrapper exits non-zero, relay the reason and do NOT retry blindly:
  `exit 3` = not a Muso-AI repo; `exit 4` = PR authored by the gateway account (GitHub
  blocks self-approval — another reviewer is needed); `exit 5` = requester not authorized;
  `exit 8` = CI is not green; `exit 9` = an unresolved Critical/Important thread is still
  open (carry it forward — fix it or resolve the thread, do not approve around it);
  `exit 10` = the rebase-integrity report for this head is WARN with no filed
  `REBASE WARNING [<sha7>]` thread (file the Step 3d finding first), it is
  ERROR/unreadable (rebase state unverified — a human must look), or it is
  MISSING for a repo that requires one (hydra) — re-run PR Validation.
- Report the wrapper's post-check (`reviewDecision` / `mergeStateStatus`). If GitHub still
  shows the PR blocked (CODEOWNERS, required checks pending), tell the requester what's
  outstanding — don't imply it's ready to merge.
- If the verdict is **not** GO, do NOT approve: post the findings and stop.

## Pitfalls

- **Large PRs**: list files with `gh pr diff --name-only`, then pull each file's
  diff via the files-API recipe in Step 2 — `gh pr diff … -- <path>` is NOT valid
  and will fail. Don't try to hold a 3000-line diff at once.
- **Draft PRs**: default to `event: COMMENT` and say findings are preliminary.
- **No GitHub write scope**: that's an expected outcome, not a failure — deliver the
  Slack summary and say a human needs to post it.
- **Response hygiene**: present findings naturally; never mention `sessions_send`,
  workspaces, tiers, or internal routing in the Slack output.
