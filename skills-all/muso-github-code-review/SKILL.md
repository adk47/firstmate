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

**Identity — brand everything "Muso QA Bot".** GitHub records the review/approval
under the host account (Aaron / adk47); there is no separate bot user. So lead the
GitHub **review body** and the **approval body** with a clear `🤖 Muso QA Bot
(automated review)` banner so it reads as automation, not a manual review by Aaron.
The Slack DMs go out as the QA app — still self-identify as Muso QA Bot in the text.

1. **FIRST, DM the author an opening note and keep the returned thread ts.** This is
   how they know a review started. Capture the ts so the result threads under it:
   ```bash
   ts=$(bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "Muso QA Bot here -- reviewing PR #<pr> (Muso-AI/<repo>) now. I will post the full review on GitHub and update you in this thread.")
   ```
   Best-effort: if it fails, log it and continue the review anyway.
2. **Skip Step 5 (the human-approval gate).** Do not ask "Want me to post this?" —
   post the batched review to GitHub yourself (Step 6), after writing the
   Step-"Logging" audit line (set `"requester"` to the author UID and
   `"authorization":"auto-review-dispatch"`).
3. **Approve (Step 7) only if ALL of these hold** — otherwise post the review and
   stop without approving, and say which gate failed:
   - **CI is fully green** — `gh pr checks <pr> --repo Muso-AI/hydra` shows every
     check passed, with none `fail` or `pending`. In auto mode be strict: do NOT
     apply Step 3c's "unrelated red gate" allowance — any non-green check means do
     not approve.
   - **Verdict is GO** — no 🔴 Critical and no 🟡 Important findings.
   - The gated wrapper accepts the author UID.
4. **Never merge** (unchanged). A human merges.
5. **LAST, DM the author the result as a threaded reply under the opening ts:**
   ```bash
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "Approved -- CI green, no blocking findings. Safe to merge: <pr-url>" "$ts"
   # or, if not approved:
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "Reviewed -- <N> blocking finding(s), not approved (<one-line reason>). Details on the PR: <pr-url>" "$ts"
   ```
   Keep it to one line; the full review lives on the PR. (If you never got an opening
   ts, send it un-threaded rather than skipping it.)

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
gh pr checks "$PR" --repo "$OWNER/$REPO"        # every check, its state, and a run link
```

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
  rather than as an inline comment.
- If the call returns a 403 / scope error, the gateway token lacks PR-write scope:
  report this to the requester and leave the Slack summary as the deliverable.

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

## Step 7 — Approve the PR (approve-only, gated)

Approve **only** when BOTH hold:
- your verdict is **GO** — no 🔴 Critical and no 🟡 Important findings; and
- the requester's Slack UID is one of: **Aaron, Fede, Serhii, Nick**.

Approve through the gated wrapper — **never** call `gh pr review --approve` directly.
The wrapper enforces Muso-AI-only, self-approval refusal, the requester allowlist, and
the audit log:

```bash
bash /opt/hydra/scripts/qa-pr-approve.sh <repo> <pr> <requester-slack-uid> "🤖 Approved by Muso QA Bot (automated review). Recorded on the adk47 account, not a manual review by Aaron."
```

- `<repo>` is the short name (e.g. `core-backend`) or `Muso-AI/<repo>`;
  `<requester-slack-uid>` is the `sender_id` from message metadata — never a name.
- **You approve; you never merge.** A human merges — say so to the requester.
- If the wrapper exits non-zero, relay the reason and do NOT retry blindly:
  `exit 4` = PR is authored by Aaron's account (GitHub blocks self-approval — another
  reviewer is needed); `exit 5` = requester not authorized; `exit 3` = not a Muso-AI repo.
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
