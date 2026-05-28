---
name: muso-github-code-review
description: |
  Review a GitHub PR for Muso-AI repos: fetch the diff, run a 7-lens checklist, post
  a severity-tagged Slack summary, then post a batched GitHub review after human
  approval. Triggers: "review PR"/"review this pull request", "code review",
  "check/audit this PR", a github.com/<owner>/<repo>/pull/<n> URL.
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

## Access control

- **Requesting a review** (read-only): any Tier 0–2 user. Tier 3 / unknown users
  get the Slack summary only, never a GitHub write.
- **Posting the review to GitHub is an external write.** It requires (a) explicit
  human approval in-thread and (b) a write-activity log entry before execution
  (see "Logging" below). Never post without both.

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

No local checkout is needed; `gh` fetches the diff directly:

```bash
gh pr diff "$PR" --repo "$OWNER/$REPO"                 # full diff
gh pr diff "$PR" --repo "$OWNER/$REPO" --name-only     # changed files
```

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
  "body": "PR review summary (see inline comments).",
  "comments": [
    {"path": "src/auth.js", "line": 45, "side": "RIGHT", "body": "🔴 **Critical:** user input passed straight into the query — parameterize it."},
    {"path": "src/util.js", "line": 8,  "side": "RIGHT", "body": "🔵 **Suggestion:** duplicates logic in core/utils.js:34."}
  ]
}
JSONEOF

gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --method POST --input /tmp/pr-review.json
```

- `event`: use **`COMMENT`** by default. Use `REQUEST_CHANGES` only when the human
  asks to formally block. Use `APPROVE` only on explicit human instruction — never
  auto-approve.
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

## Pitfalls

- **Large PRs**: review file-by-file with `gh pr diff --name-only` then per file;
  don't try to hold a 3000-line diff at once.
- **Draft PRs**: default to `event: COMMENT` and say findings are preliminary.
- **No GitHub write scope**: that's an expected outcome, not a failure — deliver the
  Slack summary and say a human needs to post it.
- **Response hygiene**: present findings naturally; never mention `sessions_send`,
  workspaces, tiers, or internal routing in the Slack output.
