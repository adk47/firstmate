---
name: muso-github-code-review
description: |
  Review and (when satisfied) approve a GitHub PR in Muso-AI repos: fetch the diff,
  run an 8-lens checklist, post a severity-tagged Slack summary, and on a GO verdict
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

End-to-end PR review: gather → diff → 8-lens analysis → Slack summary → human
approval → batched GitHub review. You run the whole thing yourself in one session.

## When Clio or CTO delegate a review

PR review is your job — do NOT bounce it back to CTO. Run the review, then relay your
finished summary to whoever delegated so they can post it under their own identity.

## Auto mode (automated dispatch — no human in the loop)

When the triggering message says **AUTO-REVIEW** (dispatched by
`scripts/qa-dispatch-pr-review.sh` from the `qa-autoreview` GitHub Action), you are
running headless: there is no person in the thread to approve, and the dispatch +
the gates below ARE the authorization. You keep the PR author updated in a Slack DM
(opening note → threaded result) and run the same review — diff fetch, 8 lenses,
CI check, batched-review API, the `qa-pr-approve.sh` wrapper, logging — with these
overrides. The dispatch message gives you the author's Slack UID.

**Identity — make the automation legible.** Every GitHub call goes through
`qa-gh.sh`, which records the write under the `muso-qa-bot` App on repos listed in
`policies/qa-approval-policy.json` `.identity.app_repos`, and under the ambient host
account elsewhere. Never call bare `gh` — a write from the wrong identity cannot
satisfy an app-pinned required check. So lead the
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
   - **CI is green, EXCEPT for policy-listed advisory checks** — every check
     passed, with none `fail` or `pending`, other than those named in the policy's
     `advisory_checks` (the deploy pre-flight and friends). **Changed 2026-08-03:**
     this used to say "be strict — any non-green check means do not approve",
     which held hydra#780 at a clean GO for days because a live rsync dry-run was
     red against pre-existing server drift that had nothing to do with the diff.
     Those checks now alert instead of blocking; every OTHER red check still holds
     the approval. (Ignore the `qa-review` row — that is your OWN status from
     Step 6b; the wrapper excludes it to avoid a circular dependency.)
   - **Verdict is GO** — no 🔴 Critical and no 🟡 Important findings, AND every prior
     unresolved 🔴/🟡 thread cleared per "Carry forward prior findings". A fresh-pass
     0/0 is not GO if an earlier blocker is still open. **This is the gate that
     matters**: block on unresolved issues, never on unresolved paperwork.
   - **Rebase integrity is clear** — the Step 3d report is CLEAN, or its WARN has
     been resolved. Missing counts as no-data ONLY for external repos; for
     **hydra** a missing report is a failed hand-off and holds approval (say so in
     the verdict/DM). A WARN holds approval until the 🟡 REBASE WARNING thread is
     resolved — **you may resolve it yourself once you have verified the deletions
     were intended** (Step 3d.3); an ERROR holds it outright. The wrapper's Guard 8
     re-derives the structural part mechanically (exit 10).
   - The gated wrapper accepts the author UID.
4. **Publish the `qa-review` commit status (Step 6b)** (best-effort on an UNGATED repo; on a repo in `.merge_gate_repos` it is a hard requirement — a missing terminal status leaves the required check pending and the PR unmergeable) — `failure` on NO-GO,
   `success` on GO — before the result DM, so the PR shows a red/green QA signal.
5. **Never merge** (unchanged). A human merges.
6. **LAST, DM the author the result as a threaded reply under the opening ts.** Lead
   with the state emoji (✅ approved / ⛔ not approved) and make `#<PR>` a clickable
   Slack link to the PR (`<url|#N>` mrkdwn) so it is scannable at a glance:
   ```bash
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "✅ Approved <https://github.com/Muso-AI/hydra/pull/<PR>|#<PR>> — CI green and 0 unresolved blocking findings (fresh pass + carried-forward threads). Safe to merge." "$ts"
   ```
   **Report what the post-check ACTUALLY says, not what the policy predicts.**
   `require_human_codeowner_repos` only matters where the repo is ALSO in
   `identity.app_repos` — a GitHub App can never be a CODEOWNER, but the host
   account (`adk47`) IS the universal code owner under hydra's CODEOWNERS, and
   `app_repos` is currently empty. So on hydra today the bot's approval DOES clear
   the code-owner gate (verified: hydra#786 and #777 both went APPROVED → CLEAN).
   Saying "still needs a human CODEOWNER" when it does not is exactly the friction
   this skill was told to remove. Read the wrapper's post-check
   `reviewDecision`/`mergeStateStatus` and relay THAT. Only if it still reports
   blocked should you say so, naming the real reason:
   ```bash
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "✅ Approved <https://github.com/Muso-AI/hydra/pull/<PR>|#<PR>> — CI green, 0 blocking findings. GitHub still reports <mergeStateStatus>: <what is outstanding>." "$ts"
   # or, if not approved:
   bash /opt/hydra/scripts/qa-slack-dm.sh <author-uid> "⛔ Reviewed <https://github.com/Muso-AI/hydra/pull/<PR>|#<PR>> — <N> blocking finding(s), not approved (<one-line reason>). Details on the PR." "$ts"
   ```
   Keep it to one line; the full review lives on the PR. (If you never got an opening
   ts, send it un-threaded rather than skipping it.) When the hold is a rebase
   warning (Step 3d), name it: "⛔ Reviewed <url|#N> — REBASE WARNING: I could not
   confirm the deletions were intended; needs a human to check and resolve the thread."

## Access control

- **Requesting a review** (read-only): any Tier 0–2 user. Tier 3 / unknown users
  get the Slack summary only, never a GitHub write.
- **Posting the review to GitHub is an external write.** It requires (a) explicit
  human approval in-thread and (b) a write-activity log entry before execution
  (see "Logging" below). Never post without both. *(Exception: **Auto mode** above
  substitutes the automated dispatch + the CI-green/GO/allowlist gate for the
  in-thread approval; the write-activity log is still required.)*

## Setup

Use `bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" <gh args...>` for every
GitHub call — never bare `gh`. The shim picks the identity (App vs host) per repo and
mints a repo-scoped token. A 404 on a repo you can see in the browser means the App is
not installed there: report it, do not fall back to bare `gh`. Never invoke
`qa-github-app-token.sh` yourself — it prints a live token to stdout.

Resolve the target from the request (a URL, or "PR 123 in core-backend"):

```bash
# From a URL like https://github.com/Muso-AI/core-backend/pull/123
OWNER=Muso-AI
REPO=core-backend
PR=123
```

If only a number + repo name are given, default `OWNER=Muso-AI`.

## Step 1 — Gather PR context

```bash
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" pr view "$PR" --repo "$OWNER/$REPO" \
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
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" pr diff "$PR" --repo "$OWNER/$REPO"                 # full diff
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" pr diff "$PR" --repo "$OWNER/$REPO" --name-only     # changed files
```

To view **one file's** diff, use the files API — `gh pr diff` has **no** path
filter:

```bash
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api "repos/$OWNER/$REPO/pulls/$PR/files" \
  --jq '.[] | select(.filename=="<path>") | .patch'
```

> **Do NOT** write `gh pr diff "$PR" -- <path>`. `gh pr diff` does not accept a
> `-- <pathspec>` (git-style path filtering); it fails with
> *"accepts at most 1 arg(s), received 2"*. For a single file use the files-API
> recipe above; to drop noise from the full diff, use `--exclude '<glob>'`.

For full-file context around a hunk (diffs alone hide issues), read the file at the
PR head:

```bash
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api "repos/$OWNER/$REPO/contents/<path>?ref=$(bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" pr view "$PR" --repo "$OWNER/$REPO" --json headRefOid --jq .headRefOid)" \
  --jq '.content' | base64 -d
```

**Stacked PRs (important):** if `baseRefName` is not the repo's default branch, this
PR is stacked on a parent branch. Review only the changes that belong to THIS PR,
not the parent's. `gh pr diff` already scopes to the PR's base, so prefer it over
`git diff main...HEAD` (which would include the parent's changes and produce
confused findings). Call out the stacked relationship in the summary.

## Step 3 — Walk the 8-lens checklist (the review)

Go over every changed file once, through all eight lenses. This is the merged
doctrine — be specific, cite `file:line`, and prefer real problems over style nits.

1. **Correctness & edge cases** — Does the code do what the PR claims? Empty/null
   inputs, large inputs, boundary values, concurrent access, off-by-one.
2. **Silent failures & error handling** — Bare `catch`/`except` that swallow errors,
   fail-open fallbacks that mask outages, errors logged-but-not-surfaced, missing
   logging on failure paths, ignored return/err values. (Treat this lens as
   highest-value — silent failures are the costliest class.)
3. **Test coverage** — Behavioral coverage of the new paths and their error cases,
   not line %. New functionality with no test? Critical paths only covered on the
   happy path? Flag the specific missing case. Four false-green patterns have shipped
   here already — check each by name:
   - **Verb/route gap** — the probe asserts one verb (`PUT`) while a sibling route
     (`PATCH`) reaches the same handler ungated.
   - **Single-gate control** — a deny-all control wired to only one of several gates,
     so a broken sibling gate still satisfies every assertion. Run the control *per
     gate*.
   - **Empty-file pass** — `bash <empty file>` exits 0, so a generator that failed
     part-way yields a green run. Assert the emitter's exit status *and* the file's
     size.
   - **Function, not wiring** — sourcing a script proves the function works, not that
     the entrypoint still calls it. Assert end-to-end through the real dispatcher.
   - **Vacuous negation in bats** — `! cmd` is exempt from `set -e`, and bats takes
     the test result from the LAST command only. So a failing `! grep …` that is not
     the final statement passes silently, and the "it must NOT do X" half of the
     suite proves nothing. Verified in this repo: a `! grep -q FORBIDDEN` followed by
     any passing line still reports `ok`. Use `if cmd; then false; fi`, which `set -e`
     does honour.
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
8. **Gate weakening & evasion** — Applies when the diff adds or edits an *enforcement
   gate*: `check-*.sh`, `ensure-*.sh`, `validate-*.sh`, a `Guard` block, a CI gate
   step, or any code whose job is to refuse. Gates authored in this repo have
   repeatedly shipped with holes in them, so hold this lens to a higher bar than the
   diff's size suggests — and read the *refusal* branch, not the success branch.
   - **grep vs. parse** — a gate that decides by literal-byte `grep` is evaded by an
     inter-token newline or `\uXXXX`-escaped quotes that `jq`/`JSON.parse` still
     decode to the same value. Require the union of both checks, never the weaker one.
   - **Fail-open on missing input** — an absent, empty, or unreadable config/policy
     key must refuse (non-zero), never degrade to "allow all".
   - **Unwired enforcement** — the gate function exists and is tested, but nothing
     invokes it on the real path (see lens 3).
   - **Concurrency & clock** — a gate keeping persistent state (history, lock,
     cooldown file) needs `flock` for cross-process atomicity, must reject
     future-dated stamps rather than compute a negative `NOW - t`, and must validate
     non-numeric env overrides before arithmetic.
   - **Discrimination without stability** — a change making a digest or detector
     *more* discriminating must keep the test proving it stays **stable** when the
     flagged content is unchanged. A digest that merely churns silently destroys the
     feature it protects.

### Every 🔴 and 🟡 needs a failure scenario

These eight lenses push toward flagging more; this is the counterweight. A finding is
Critical or Important only if you can state the concrete way it fails — specific
inputs or state → the wrong output, a crash, or a silent pass — and that sentence
belongs *in the finding*.

If you cannot write it, the finding is 🟢/🔵 or it is nothing. "This looks risky",
"this could be a problem", and "consider hardening this" are not findings.
Over-flagging is the documented failure mode of automated reviewers, and here it has a
mechanical cost: every false 🔴/🟡 is a thread a human must open, read, and resolve
before Guard 7 will let the PR through.

## Step 3b — Run the tests (when warranted)

The 8-lens pass is static (diff + file reads, no checkout). When the test-coverage or
correctness lens needs it — or the requester asks — actually run the PR's tests. That
needs a checkout:

```bash
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" pr checkout "$PR" --repo "$OWNER/$REPO"   # inside a clone of the repo
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
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" pr checks "$PR" --repo "$OWNER/$REPO" || true   # every check, its state, and a run link
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

These gates are now also listed in the policy's `advisory_checks`, so the approval
wrapper stops counting them too — previously this paragraph said "not a finding"
while Guard 6 refused anyway, and the two disagreed. If you judge that a red
advisory check IS caused by this diff (the PR edits `deploy.sh`, or adds a file the
rsync gate rejects), that is a real 🔴/🟡 finding and the GO verdict must reflect it —
the exemption is for pre-existing drift, not a blanket pass.

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
  3. **You MAY resolve the REBASE WARNING thread yourself** once you have
     actually checked the signals against the diff and concluded the deletions
     were intended rather than a clobber. **Changed 2026-08-03 (Nick,
     explicit):** this used to say "never resolve it yourself — a human
     resolving it IS the acknowledgment", which made every rebase warning a
     manual step for a team that does not have review capacity. Resolution is
     now yours to make, under the same rule as every other finding: never
     resolve a thread you have not confirmed, and write the confirmation into
     the thread so the judgment is auditable.

     When you resolve one, reply in the thread FIRST with what you checked —
     which signals fired, which files, and why the deletion is intentional
     (e.g. "the 6 deleted lines in X are the old implementation this PR
     replaces; base's version is not lost"). A resolution with no reasoning is
     indistinguishable from rubber-stamping.

     If you CANNOT convince yourself the deletions were intended, leave it
     unresolved. That is a real 🔴/🟡 and Guard 7 will correctly hold the PR —
     which is the behaviour you want: block on unresolved *issues*, never on
     unresolved *paperwork*.

     > `QA_REBASE_ACK_REQUIRE_INDEPENDENT` must stay `0`. Setting it to `1` makes
     > Guard 8 refuse (exit 10) any warning resolved by the bot or the author,
     > which contradicts the rule above — and it would also break the carryover
     > in step 4, whose prior-head ack is now frequently yours. It is retained
     > only so the stricter posture can be restored deliberately.
  4. **Skip step 2 when a prior head's ack CARRIES FORWARD.** The marker is
     head-tagged, so a merge-from-`main` or any no-op push re-files a finding
     already judged; hydra PRs have collected up to 11 acks of one unchanged
     warning, and an ack that cheap gets clicked unread. The report's
     `warn_digest` (sha256 over the warn signals' flagged LINES, not their
     summaries — two different 10-line deletions in one file share a summary but
     never a digest) makes "same finding" checkable. It carries forward only if
     ALL of these hold:
     ```bash
     # this head's digest, then every OTHER head of this PR that shares it
     # (the grep lists this head's own report too — ignore that one)
     jq -r '.warn_digest' "/var/lib/hydra-qa/rebase-integrity/${OWNER}__${REPO}-pr-${PR}-<headRefOid>.json"
     grep -l "<that digest>" "/var/lib/hydra-qa/rebase-integrity/${OWNER}__${REPO}-pr-${PR}-"*.json
     ```
     - this head's `warn_digest` is a real 64-hex value (reports predating the
       field cannot carry — no identity, no carry), **and**
     - another head of this PR has a WARN report with the identical digest,
       **and**
     - that head's `REBASE WARNING [<sha7>]` thread was filed by the bot and is
       **resolved** — i.e. this exact finding was already acknowledged, whether
       by a human or by you under step 3. A carried-forward ack clears exactly
       the same bar as a fresh one, never a lower one.

     Then: still write the ⚠️ section in the body (step 1), but say the ack
     carries forward from `<prior sha7>` and do **not** file a second 🟡. Guard 8
     re-checks every leg itself and approves without a new thread; if any
     leg fails it exits 10, so filing the 🟡 is always the safe fallback. If the
     digest changed, the finding changed — file it.
  5. Verdict impact: an open rebase warning is a 🟡 blocker → **NO-GO** until it
     is resolved — by you, once verified, or by a human. A carried-forward ack
     is not open, so it does not block.
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

## Step 3e — Blast radius (advisory CI hand-off)

PR Validation runs `scripts/check-blast-radius.sh` (advisory — it never fails CI)
and writes a per-head report on this host: what a wrong change would *reach*,
which is the question diff size cannot answer. Read it with ONE exec —
`<headRefOid>` comes from Step 1:

```bash
cat "/var/lib/hydra-qa/blast-radius/${OWNER}__${REPO}-pr-${PR}-<headRefOid>.json"
```

- **File missing** → for **external repos** this is genuine no-data (the analyzer
  only runs in hydra's CI): note it as context and review on the 8 lenses alone.
  For **hydra** PRs the hand-off failed — say so in the review body and do not
  invent a radius from the diff.
- **`status: "CLEAN"`** → the analyzer ran and found no reviewable files (the diff
  was entirely generated/vendored paths — lockfiles, `dist/`, `node_modules/`).
  This is a normal, valid report: treat it as `Blast radius: LOW` and move on.
- **`status: "ERROR"`** → the analyzer could not verify impact. Say "blast radius
  unverified — analyzer errored; re-run PR Validation" and review on the lenses alone.
- **`status: "OK"`** → prepend a one-line **`Blast radius: <TIER>`** to the review
  body, listing each fired signal's `id` and its evidence. Then scale depth by tier:

| Tier | What it adds to the review |
|---|---|
| `LOW` | Nothing. The 8 lenses as written. |
| `MEDIUM` / `HIGH` | **Reverse-caller contract check** — for every caller the report names, ask whether this diff changed something that caller depends on: output format, exit codes, or side effects. Plus: how is this reverted? |
| `CRITICAL` | The above **plus a mandatory adversarial pass**: how would I evade this gate? What breaks fleet-wide if this is wrong? Assume the change is subtly incorrect and go looking for the evidence. |

- **If `skipped` is non-empty, relay it too and say the tier is a LOWER BOUND.**
  Above `BR_MAX_FILES` the analyzer stops computing `reverse-callers` and
  `cron-reach`, so a big PR can report a low tier purely because the expensive
  signals never ran. Reporting the tier without the skips is the confident
  false-negative the limitations exist to prevent.
- **Relay the report's `limitations` array verbatim** in the radius block. It is
  load-bearing, not boilerplate: grep cannot prove a negative, a reference found
  is not proof the path executes, and no runtime or concurrency behaviour is
  modelled. Without it the tier reads as authoritative and invites confident
  false findings — the documented failure mode of automated reviewers.
- **The tier is not a finding.** It changes how hard you look, never what you
  report. A `CRITICAL` radius with nothing wrong in the diff is still a GO. Every
  🔴/🟡 still needs its own concrete failure scenario (Step 3).
- Severity calibration: a real finding in a file the report flags `critical`
  escalates one rung, because the same defect reaches further there.
- Do **not** re-derive these signals yourself from `gh pr diff` — relay the
  CI-computed report only, exactly as with the rebase-integrity report.

> `deploy-path` is reported as `info` and **never lowers the tier**. An
> undeployed file is unproven, not proven safe — do not argue a finding down
> from it.

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
  "body": "🤖 **Muso QA Bot** (automated review) — see inline comments.",
  "comments": [
    {"path": "src/auth.js", "line": 45, "side": "RIGHT", "body": "🔴 **Critical:** user input passed straight into the query — parameterize it."},
    {"path": "src/util.js", "line": 8,  "side": "RIGHT", "body": "🔵 **Suggestion:** duplicates logic in core/utils.js:34."}
  ]
}
JSONEOF

bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api "repos/$OWNER/$REPO/pulls/$PR/reviews" --method POST --input /tmp/pr-review.json
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

Post it through `qa-review-status.sh` — **never** with a bare `gh api ... /statuses/`
call. On repos where `qa-review` is a required check it is pinned to the QA bot App
(`checks: [{context, app_id}]`), and a status posted by any other identity does not
satisfy the pin: the check would sit unsatisfied and the PR would be unmergeable. The
wrapper routes through the identity shim so the App is what posts it, and it applies the
140-char description limit.

```bash
verdict_state=success     # use "failure" when the verdict is NO-GO
verdict_desc="GO — 0 blocking findings"   # or: "NO-GO — <N> blocking finding(s)"
HEAD_SHA="$(bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" \
  pr view "$PR" --repo "$OWNER/$REPO" --json headRefOid --jq .headRefOid)"
bash /opt/hydra/scripts/qa-review-status.sh "$OWNER/$REPO" "$HEAD_SHA" \
  "$verdict_state" "$verdict_desc" \
  "https://github.com/$OWNER/$REPO/pull/$PR/files" \
  || echo "qa-review-status: could not publish the verdict — report it, do not retry blind"
```

The 5th argument is the "Details" link. On a merge-gated repo it is the operator's
only in-UI route to why the check is red, so always pass it.

**If the repo is in `.merge_gate_repos`, a missing status is a MERGE BLOCK, not a
cosmetic gap.** The workflow armed `qa-review` as `pending` before dispatching; if
you never publish a terminal state the PR cannot merge and GitHub will wait
forever. So on a gated repo: retry once, and if it still fails, DM the author AND
say plainly that the PR is blocked pending a manual status — do not fall back to
"rely on the Slack DM" as you would on an ungated repo.

Never invoke `qa-github-app-token.sh` yourself — it prints a live installation
token to stdout, which would land in the session transcript. Only `qa-gh.sh`
calls it.

`$HEAD_SHA` is the head commit you reviewed. A new push creates a new SHA with no
`qa-review` status yet, so a re-review must run before the PR is green again (pairs
with `dismiss_stale_reviews`). On NO-GO you set `failure` and stop — do not approve.
Best-effort: if the Step 6 review POST already failed with a 403/scope error, the
status POST will too — on an UNGATED repo skip it, rely on the Slack DM, and do not loop or report a hard
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

A fresh 8-lens pass is NOT enough: a GO must also clear every still-open finding
from earlier rounds — yours or a human's. (PR #287 was wrongly approved because a
fresh pass scored 0/0 while its own 🔴/🟡 comments from 9 minutes earlier sat
unaddressed.) Before deciding GO:

1. List the PR's unresolved review threads:

   ```bash
   bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api graphql -f query='
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
     bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -f id="$THREAD_ID"
     ```
     (`$THREAD_ID` is the `id` field of the thread from the list query above.)
   Resolving a thread asserts you verified the fix in the current diff — the approval
   wrapper (Guard 7) trusts that resolution. Never resolve a thread you have not
   confirmed fixed; an un-verified resolution is exactly how a blocker slips through.
   (Mechanical fix-verification arrives with the autofix loop in Part B.)
   - **A human/Clio thread** (no severity emoji): assess it with the 8 lenses. If you
     judge it Critical/Important and it is unaddressed, it is a blocker. Do not resolve
     someone else's thread on their behalf — leave it and call it out.

3. **Verdict rule:** GO requires no 🔴 Critical and no 🟡 Important findings **from the
   fresh pass OR from any unresolved prior thread.** If any blocker remains, the verdict
   is NO-GO even if this run's fresh pass found nothing. A 🟡 REBASE WARNING thread
   counts like any other Important blocker — you may resolve one yourself once you
   have verified the deletions were intended and written that reasoning into the
   thread (Step 3d.3); never resolve one you have not confirmed.

The gated wrapper (Step 7) independently re-checks unresolved 🔴/🟡 threads and CI, and
will refuse to approve (exit 9 / exit 8) if you try to approve with a blocker open — so
keep this ledger honest.

## Step 7 — Approve the PR (approve-only, gated)

Approve **only** when BOTH hold:
- your verdict is **GO** — no 🔴 Critical and no 🟡 Important findings, including any
  carried-forward unresolved thread (see "Carry forward prior findings"); and
- the requester's Slack UID is on the approval allowlist, which has **two tiers**
  (changed 2026-08-13, authorized by Nick):
  - **Unscoped** — **Aaron** (`U7RP6HKUZ`) and **Nick** (`U0AL36NADEY`): any Muso-AI PR.
  - **Scoped** — **Mariia** (`U03LP8YHLPK`): **only** when the repo is
    `Muso-AI/web-credits-next`, the PR author is `azure-kirin` (her own PR), **and**
    the base branch is `develop`. All three must hold. Her PRs on that repo+branch
    therefore auto-approve; anything else of hers is review-only.
  - **Serhii** (`U03TYGJF1N3`) is **no longer on the allowlist** (removed 2026-08-13).
    Keep reviewing and DM'ing his PRs exactly as before — just never approve them. An
    `exit 5` on a Serhii PR is a **normal outcome to relay**, not an error to work
    around, and not a reason to retry or escalate.

Approve through the gated wrapper — **never** call `gh pr review --approve` directly.
The wrapper enforces Muso-AI-only, self-approval refusal, the requester allowlist **and
its scope** (it re-reads the PR's real author and base branch from the API), and the
audit log. The two unreadable cases are **different exits, with different reach**: an
unreadable **author** is `exit 7` and applies to **every** requester, scoped or not; an
unreadable **base branch** is `exit 5` and only reaches a **scoped** requester, because
Guard 4b is the only thing that reads the base. Note self-approval refusal is about the
*gateway account* authoring the PR, not about the requester — a scoped approver asking
for approval of her **own** PR is the intended case:

```bash
bash /opt/hydra/scripts/qa-pr-approve.sh <repo> <pr> <requester-slack-uid> "🤖 Approved by Muso QA Bot (automated review)." \
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
  blocks self-approval — another reviewer is needed); `exit 5` = requester not authorized
  — either they are not on the allowlist at all (e.g. **Serhii**, review-only since
  2026-08-13) or they are a **scoped** approver and this PR is outside their scope (e.g.
  Mariia on a repo other than `Muso-AI/web-credits-next`, on a base other than `develop`,
  on a PR she did not author, or on a PR whose **base branch the API would not return** —
  that last one fails closed and is scoped-requester-only). The message names the
  condition that failed — relay it
  verbatim and say a human reviewer signs this one off; do NOT retry, re-request with a
  different UID, or approve around it;
  `exit 7` = the wrapper could not read the PR's **author** (the PR does not exist, or the
  gh call failed) — or the `gh pr review --approve` write itself failed. This one hits
  **every** requester, unscoped included, and is usually TRANSIENT: say so, and a single
  re-run is reasonable once you have confirmed the PR really exists (unlike exits 5/8/9,
  which are verdicts to relay, not to retry);
  `exit 8` = CI is not green — this ALSO fires when the rollup is unreadable, when
  there are no non-qa-review checks at all, or when EVERY check is advisory-exempt
  (none of which mean a red check; read the message and do not blindly re-run); `exit 9` = an unresolved Critical/Important thread is still
  open (carry it forward — fix it or resolve the thread, do not approve around it);
  `exit 10` = the rebase-integrity report for this head is WARN with no filed
  `REBASE WARNING [<sha7>]` thread **and no prior head's ack carries forward**
  (file the Step 3d finding first), it is ERROR/unreadable (rebase state
  unverified — a human must look), or it is MISSING for a repo that requires one
  (hydra) — re-run PR Validation;
  `exit 11` = the PR touches a path in `sensitive_paths_blocking` (that list ships
  EMPTY, so this is rare and deliberate — a human must approve that one), OR the
  policy's `sensitive_paths_blocking` key is unreadable/malformed, OR the changed-file
  list could not be established while blocking paths are configured — the last two
  mean the POLICY is broken, not the PR;
  `exit 12` = the PR's author is in the policy's `author_deny` list, or `author_deny`
  is missing/null/malformed (fail-closed) — report the policy state, do not retry;
  `exit 13` = Guard 9 blast radius (only when `QA_BLAST_RADIUS_GATE=1`, not the default).

### Relay every ⚠️ ALERT the wrapper prints

**Changed 2026-08-03.** Sensitive paths (`policies/`, `scripts/qa-*`, `CODEOWNERS`,
workflows, gateway config …) used to REFUSE the approval with `exit 11`. They no
longer do — the wrapper approves and prints one or more `⚠️ ALERT — …` lines
instead. A red **advisory** CI check (deploy pre-flight and friends, which fail on
live server drift rather than on the diff) does the same.

Those alert lines are now the ONLY signal that something needing eyes was
auto-approved, so treat them as review content, not as log noise:

**The wrapper runs in Step 7, AFTER Step 6 has already posted the review**, so the
alerts do not exist yet when the review body is written — do NOT try to put them
there, it cannot work. Both channels below come after the wrapper returns:

1. **Post them as a follow-up PR comment**, so they land on the PR itself where the
   person merging will see them (the Slack DM only reaches the author). Same
   heredoc/`--input` rule as Step 6 — never inline via `-f body=`:
   The heading depends on the OUTCOME — the wrapper replays its alerts on refusal
   paths too, so "Auto-approved" would be a lie on a decline. Use
   `## ⚠️ Auto-approved with alerts` when the wrapper exited 0, and
   `## ⚠️ Alerts (NOT approved — <exit code / reason>)` when it refused.

   This POST is a **separate external GitHub write**, so it needs its own
   write-activity log line BEFORE it (same rule as the review POST). Everything
   below is ONE control-flow block on purpose. The approval is already recorded
   by the time any of this runs, so every failure path must end somewhere
   explicit — and there must be exactly ONE post attempt path, or the happy path
   posts the comment twice.
   ```bash
   alerts_json=/tmp/qa-alerts.json
   cat > /tmp/qa-alerts.md <<'EOF'
   ## ⚠️ Auto-approved with alerts
   <every ⚠️ ALERT line, verbatim>
   EOF
   # Wrap the markdown into a JSON object FIRST. `--input` sends the file as the
   # whole request body, so it must already BE {"body": "..."} — handing it raw
   # markdown posts invalid JSON, and any -f/-F alongside --input lands in the
   # query string instead of the payload. `jq -Rs` slurps stdin into one
   # JSON-escaped string, so backticks, quotes and $VAR survive verbatim.
   jq -Rs '{body: .}' < /tmp/qa-alerts.md > "$alerts_json"

   post_alerts() {
     bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api \
       "repos/$OWNER/$REPO/issues/$PR/comments" --method POST --input "$alerts_json"
   }
   go_red() {  # <why> — the PR is already approved; make it visibly unsafe to merge
     # Honours the SAME guarantees Step 6b sets for the verdict status: pass the
     # Details link, retry once, and escalate rather than return quietly. A
     # go_red that silently fails is the worst case in this whole flow — the PR
     # keeps its GREEN status AND its approval while the alert never published.
     local url="https://github.com/$OWNER/$REPO/pull/$PR/files"
     bash /opt/hydra/scripts/qa-review-status.sh "$OWNER/$REPO" "$HEAD_SHA" failure "$1" "$url" && return 0
     sleep 3
     bash /opt/hydra/scripts/qa-review-status.sh "$OWNER/$REPO" "$HEAD_SHA" failure "$1" "$url" && return 0
     # Still failing: the PR is approved, green, and has no alert. Say so as
     # loudly as this skill can, and name it as requiring a manual status.
     echo "CRITICAL: could not publish qa-review=failure for $OWNER/$REPO#$PR — the PR is APPROVED and GREEN with an unpublished alert. It MUST NOT be merged until a human sets the status manually." >&2
     bash /opt/hydra/scripts/qa-slack-dm.sh "<author-uid>" "⛔ <https://github.com/$OWNER/$REPO/pull/$PR|#$PR> — auto-approved, but its ⚠️ ALERT could not be published AND the red QA status could not be set. DO NOT MERGE until a human checks it." "${ts:-}"
     return 1
   }

   if ! printf '{"agent":"qa","action":"github_pr_alert_comment","target":"%s/%s#%s","requester":"%s","timestamp":"%s","authorization":"auto-review-dispatch"}\n' \
        "$OWNER" "$REPO" "$PR" "<author-uid>" "$(date -u +%FT%TZ)" \
        >> "api-logs/github/$(date -u +%F).jsonl"; then
     # No log ⇒ no post. Do NOT just exit: that leaves an approved, green PR with
     # the alert unpublished and nothing on the PR saying so.
     go_red "alert comment could not be audit-logged, so it was not posted — NOT safe to merge"
   elif ! post_alerts; then
     sleep 3
     post_alerts || go_red "auto-approved with ALERTS that could not be published — NOT safe to merge"
   fi
   ```
   A green PR whose alert never published is worse than a red one, because it
   looks reviewed.
2. Repeat them in the Slack result DM, above the verdict.
3. Never summarise them away, and never drop one because the verdict was GO — GO is
   exactly when they matter.
4. The wrapper replays its alerts on EVERY exit path, refusal included — so relay them
   on a decline too, not just on an approval.

The team traded the old hard refusal for speed on the explicit understanding that
the alert is loud. If you swallow it, the trade is a straight loss.
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
