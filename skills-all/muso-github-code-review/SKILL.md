---
name: muso-github-code-review
description: |
  Review, and on GO approve, a GitHub PR in Muso-AI repos: bundle, 8-lens
  checklist, Slack summary, gated approval (never merge). Triggers:
  "review/approve PR", "code review", any github.com PR link.
depends-on:
  - muso-slack-formatter
compatibility: |
  Requires `muso` (reads); writes via `qa-gh.sh` (review),
  `qa-review-status.sh` (status), `qa-pr-approve.sh` (approval); `pnpm`.
metadata:
  version: "2.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# Muso — GitHub Code Review

Bundle → 8-lens analysis → Slack summary → approval → batched review.
Relay your summary to whoever delegated this, not CTO.

Three verdicts, not two: **GO**, **NO-GO**, and **CANNOT REVIEW** (the tool
failed; nothing was reviewed). All three are defined below; CANNOT REVIEW has
its own section because getting it wrong costs a whole diagnostic cycle.

## Auto mode (AUTO-REVIEW dispatch, no human in the loop)

Dispatched by `scripts/qa-dispatch-pr-review.sh` — dispatch + gates below
ARE the authorization. Message carries the author's Slack UID.

- Writes via the three mandatory paths in Setup (review → `qa-gh.sh`,
  status → `qa-review-status.sh`, approval → `qa-pr-approve.sh`; never
  substitute one for another), lead body `🤖 Muso QA Bot (automated
  review)`. Open with `qa-pr-thread-dm.sh`, keep `ts`. Skip Step 5; log
  then post yourself.
- Approve (Step 7) through the wrapper only. **Never gate approval on `checks`
  yourself.** `scripts/qa-pr-approve.sh` decides CI greenness, fail-closed (Guard 6):
  it excludes the policy's `advisory_checks` (the deploy pre-flight and friends,
  which fail on live server drift rather than on the diff), accepts `SUCCESS`,
  `NEUTRAL` and `SKIPPED`, and holds on any other failing or pending check. A prose
  restatement of that rule can only diverge from the wrapper, so do not write one.
  **Changed 2026-08-03:** this used to say "be strict — any non-green check
  means do not approve", which held hydra#780 at a clean GO for days because
  a live rsync dry-run was red against pre-existing server drift that had
  nothing to do with the diff. Advisory checks now alert instead of blocking;
  every OTHER red check still holds the approval, enforced by the wrapper. (Ignore
  only your own `qa-review` row — the wrapper excludes it too, to avoid a circular
  dependency.) **Changed 2026-10-13 (MUS-7727, CTO ruling 12 Oct):** the removed
  rule came back as "requires every CI check to pass" and withheld approval on
  hydra#1119 and hydra#1107, two clean GOs with a red `Deploy pre-flight` advisory
  check. A red advisory check is normally relayed as an `⚠️ ALERT` line, never a withhold.
  Plus: GO incl. carried-forward; `rebaseIntegrity` clear —
  **`WARN` holds only while its thread is still UNRESOLVED**; once it is
  resolved — by a human, or **by you** once you have verified the deletions
  were intended (Step 3) — the warning is acknowledged and no longer blocks,
  exactly as Guard 7 treats it. `ERROR` holds outright. **Missing = hold on
  hydra only**, no-data elsewhere. Reading `WARN` as an unconditional hold
  would make every PR that touches a recently-changed file permanently
  unapprovable, since the signal never clears on its own. Requester UID
  authorized. **Block on unresolved issues, never on unresolved paperwork.**
- Publish `qa-review` status before the DM — required on
  `.merge_gate_repos`. Never merge; close with a threaded DM, ✅/⛔ + link.
  **If you could not review at all, the verdict is CANNOT REVIEW, not NO-GO** —
  see the "CANNOT REVIEW" section. There is no human in this thread to notice
  the difference for you, which is exactly why the token has to be in the
  output.
  **Report what the wrapper's post-check ACTUALLY says, not what the policy
  predicts.** `.require_human_codeowner_repos` only bites where the repo is
  ALSO in `identity.app_repos` — a GitHub App can never be a CODEOWNER, but
  the host account (`adk47`) IS the universal code owner under hydra's
  CODEOWNERS and `app_repos` is currently empty, so on hydra today the bot's
  approval DOES clear the code-owner gate (verified: hydra#786 and #777 both
  went APPROVED → CLEAN). Saying "still needs a human CODEOWNER" when it does
  not is exactly the friction this skill exists to remove. Read the wrapper's
  `reviewDecision`/`mergeStateStatus` and relay THAT; only if it still reports
  blocked do you say so, naming the real reason.

## Access control

Requesting: Tier 0–2 only. Posting is an external write — needs in-thread
approval AND a pre-write log entry; auto mode substitutes dispatch+gate,
log still required.

## Setup + Step 1 — Get the review bundle

```bash
OWNER=Muso-AI REPO=core-backend PR=123
muso gh review-bundle "$PR" --repo "$OWNER/$REPO" --json
```

Reads: `muso gh` directly. **Writes have three distinct mandatory paths —
they are not interchangeable, and `qa-gh.sh` is only one of them:**

| write | path | why |
|---|---|---|
| the batched review | `qa-gh.sh ... api .../pulls/$PR/reviews` | identity shim |
| the `qa-review` status | **`qa-review-status.sh`** (Step 6) | App-pinned; applies the 140-char limit |
| approval | **`qa-pr-approve.sh`** (Step 7) | the 12 fail-closed guards live here |

Never reach for `qa-gh.sh` to publish a status or to approve — that bypasses
the guards and the App pin. The two wrappers call the identity shim
internally, so you are not losing it by using them. Never bare `gh` anywhere.
404 on a visible repo = App not installed, report it.
**Never invoke `qa-github-app-token.sh` yourself** — it prints a live
installation token to stdout, which would land in the session transcript. Only
`qa-gh.sh` may call it.

Bundle fields: `pr` (title, body, author, baseRefName, headRefName, state,
isDraft, additions, deletions, changedFiles, headRefOid), `files[]`
(path, status, patch, additions, deletions), `diff`, `diffSource`,
`checks`, `threads[]`, `rebaseIntegrity` (parsed report or `null`).

### Check the bundle's integrity flags FIRST — before reviewing

The bundle reports when its own view is incomplete. These are fail-closed
signals: acting on a partial view is how a real blocker gets missed.
`filesCountMismatch`, `threadsTruncated`, and a failed `review-bundle` call
are each an immediate **CANNOT REVIEW** condition, never a NO-GO — see
"CANNOT REVIEW" below for why the distinction is load-bearing and how to
publish it. `diffSource`/`diffDegraded` is different: it is reviewable, with
a recovery step, not an immediate CANNOT REVIEW — see its own bullet below.

- **`filesCountMismatch` set** → `pr.changedFiles` disagrees with the number of
  files returned. You are looking at an incomplete diff. Do NOT review it and do
  NOT approve. Post **CANNOT REVIEW**, say the file list could not be verified,
  and stop.
- **`threadsTruncated` true** → more unresolved threads exist than the bundle
  returned (page cap). Carry-forward is therefore unreliable, and an unresolved
  blocker may be invisible to you. Re-query with
  `muso gh threads "$PR" --repo "$OWNER/$REPO" --json` (it hard-fails rather than
  silently truncating). If it still cannot return a complete list, post
  **CANNOT REVIEW** and say so — never approve off a truncated thread list.
- **`diffSource` is `"per-file-patches"`** → `diff` is not GitHub's own bytes.
  GitHub refused the whole-PR diff for size (its 20,000-line cap) and the CLI
  reassembled it from the paginated per-file patches. **That is a normal,
  reviewable bundle — review it as usual.** It is how a release promotion above
  the cap gets reviewed at all; before it existed the whole bundle died and the
  PR got a bare NO-GO (web-credits-next#740, 2026-08-25: 234 files / 15,730
  lines). Say one line in the review body that the diff was paged per file, so
  the reader knows why the byte-for-byte diff differs from `gh pr diff`.
  (An **absent** `diffSource` means the deployed `muso` predates this field —
  read it as `"pr-diff"`, because that older CLI has no fallback at all: on an
  over-cap diff it fails the whole bundle, which is the last bullet below. Never
  read an absent field as "degraded".)

  **This is also the ONLY condition under which the git-clone recovery step
  below applies.** It is deliberately gated on `diffSource`, not on
  `diffDegraded.filesWithoutPatch` alone (that field is a symptom of this
  mode, not a trigger in its own right — see why below) — on a normal
  `"pr-diff"` bundle a `patch:null` entry is an ordinary binary file, full
  stop, and must NOT trigger a clone: every PR that merely touches an image
  would otherwise pay for a full clone, and a clone failure on one of THOSE
  (a PR whose diff was actually complete) would manufacture a brand-new false
  CANNOT REVIEW where none was warranted.

  When `diffSource == "per-file-patches"`, GitHub already truncated
  something once (the whole-diff call), and it can truncate the FILES
  payload the same way on a large enough PR — `additions=0, deletions=0,
  changes=0, patch=null` for a file that is not actually binary, which is
  byte-for-byte indistinguishable from a genuine binary file from GitHub's
  response alone (observed live: Muso-AI/web-credits-next#848 @ 6b88f447,
  327 files — 17 came back exactly this shape, none of them binary).

  `diffDegraded.filesWithoutPatch` is `muso gh`'s own attempt to flag that,
  but it **under-reports and must not be trusted alone**: it only adds a
  file when `patch==""` AND (`additions!=0` OR `deletions!=0`) — a file with
  an EMPTY patch AND additions=0/deletions=0 (exactly the #848 shape) is
  classified "binary, nothing lost" and never appears in
  `filesWithoutPatch` at all, so the bundle can report `327/327 files, no
  degradation` while 17 files' real content is invisible. `muso gh` is right
  to pick that reading in isolation (it has no other signal, and a false
  CANNOT REVIEW on every real binary file would be worse) — but it means
  `filesWithoutPatch` is a *lower bound*, not the complete list, and reading
  it as "empty ⇒ nothing missing" is exactly the bug this section exists to
  close.

  **So, whenever `diffSource == "per-file-patches"`, build your own
  candidate list instead of trusting `filesWithoutPatch`.** For every entry
  in `files[]` where `patch` is empty/absent AND `status` is not `removed`,
  treat it as a candidate needing verification — regardless of whether it is
  also in `filesWithoutPatch`:

  ```bash
  candidates="$(echo "$bundle" | jq -r '
    .files[] | select((.patch // "") == "" and .status != "removed") | .path')"
  ```

  Feed EVERY candidate through the git-clone fallback, binary or not, and
  let git's own diff decide — this stops trusting GitHub's zeroed counters
  for this decision at all. Read `$candidates` into an ARRAY first — do not
  pass the bare `$candidates` string as argv. Unquoted, a newline-joined
  string is word-split on spaces AND glob-expanded before the script ever
  sees it: `public/My Logo.svg` becomes two args (`public/My`, `Logo.svg`),
  and a bracket path like `src/app/[id]/page.tsx` becomes whatever it
  glob-matches in the agent's own cwd (QA round 2, finding 1 — the exact
  hostile-input class `--literal-pathspecs` closes *inside* the script is
  reopened by splitting *before* the script if the caller isn't careful).
  Bash 3.2 (this runner's shell) has no `mapfile`, so read line-by-line:

  ```bash
  candidate_args=()
  while IFS= read -r c; do
    [ -n "$c" ] && candidate_args+=("$c")
  done <<< "$candidates"

  bash /opt/hydra/scripts/qa-bundle-diff-fallback.sh \
    "$OWNER/$REPO" "<pr.baseRefOid>" "<pr.headRefOid>" "${candidate_args[@]}"
  ```

  Read the result:
  - `cloneOk: false` → the clone/fetch itself failed (network, auth, or the
    shas could not be resolved). Check `errors[]` first — it carries git's
    own stderr verbatim from the clone/fetch/resolve attempt, so a real cause
    (auth, DNS, a genuinely unreachable sha) is distinguishable from a
    transient blip the script already retried once and still lost; quote it
    in the CANNOT REVIEW rather than paraphrasing. The fallback bought
    nothing — treat exactly as before: post **CANNOT REVIEW**, name the
    candidate files, and stop.
  - `cloneOk: true` → for every path in `recovered[]`, review its `diff` field
    normally (`binary: true` with an empty `diff` means git independently
    confirms it is genuinely binary — nothing was lost, do not flag it; this
    is what most candidates will turn out to be, and that's fine — the point
    was never to assume it without checking).
    Any path still left in `stillMissing` is a real, unrecovered hole — each
    entry there is `{path, reason, detail?}`, not a bare string: `reason` is
    one of `git-diff-failed` (git itself could not compute the diff — a
    failed on-demand blob fetch is the observed real case; `detail` carries
    git's stderr) or `no-change` (git disagrees the file changed at all
    between merge-base and head — a rebase-mid-review case, not a recovery
    failure, but still worth naming since GitHub said otherwise). Name *only
    those* in a **CANNOT REVIEW**, using their `reason`/`detail` rather than
    a generic "could not recover" (or, if `stillMissing` ends up empty, there
    is no CANNOT REVIEW from this signal at all — proceed with the recovered
    diffs folded into the normal review).
  - Say one line in the review body when this fired: `N file(s) had no patch
    from GitHub's API; recovered via git clone.` — same spirit as the
    `diffSource: "per-file-patches"` note above, so the reader knows why a
    file's diff came from git instead of the bundle.
  - This is a hydra-side recovery step, not a `muso gh` fallback — the script
    lives at `scripts/qa-bundle-diff-fallback.sh` in this repo, run it, don't
    hand-roll `git diff` yourself (it handles binary detection, renames,
    literal (non-glob) path matching, and the throwaway-clone lifecycle
    consistently; see its header for the exact contract). It routes its own
    clone through `qa-gh.sh` (the same identity shim as every other write in
    this skill), never bare `gh`.
- **`muso gh review-bundle` itself failed** (non-zero exit, no bundle at all) →
  there is nothing to review. Post **CANNOT REVIEW** with the command's own
  error, verbatim. Do not retry more than once, and never fall back to a
  hand-assembled `gh pr diff`: if the bundle refused, its integrity checks
  refused with it.

None of these is a style nit. `scripts/qa-pr-approve.sh` refuses for the same
reasons independently (Guards 7 and 11), so ignoring them here just moves the
failure later and makes it more confusing.

**Known gap (tracked separately, not fully closed by the above):** muso-cli's
own `diffDegraded.filesWithoutPatch` builder (`internal/cli/gh.go
diffFallbackFromFiles`) still under-reports exactly as described above — this
skill works around it by deriving candidates from `files[]` directly, so no
review here is blocked by it. The upstream field itself has a fix: muso-cli
commit `ac996ab` (branch `fix/diff-degraded-files-patch-unknown`, tracked by
hydra card `t_ec4e1d1d`) adds a superset field, `diffDegraded.filesPatchUnknown`
— every no-patch, non-removed file regardless of additions/deletions, not just
the ones `filesWithoutPatch` catches — without needing a git-level check
(contrary to what an earlier draft of this note assumed). That fix is
committed locally in the muso-cli repo but not yet merged/deployed; until it
ships everywhere hydra's node-8 runner calls `muso gh`, THIS skill's own
`files[]`-derived candidate list (above) remains the load-bearing check, not
`filesPatchUnknown`. Once `filesPatchUnknown` is confirmed deployed, a
follow-up card can simplify this skill's candidate derivation to read it
directly instead of re-deriving from `files[]` — do not make that
simplification before then.

### The head you reviewed vs. the head the dispatch named

The dispatch message carries `head commit <sha>` — the head **at dispatch
time**. The bundle reads the PR's head as it is **now** (`pr.headRefOid`), and
that is the correct thing to review: it is what the review, the status, and any
approval are all keyed to. But the two can differ, because a push can land
between the dispatch and the bundle.

Compare them once, right after Step 1. If they differ, say so in one line in
the review body and in the Slack DM: `Reviewed <pr.headRefOid[:7]> — the branch
had moved from the dispatched <dispatch sha[:7]>.` This costs nothing and
prevents the author reading a verdict as being about the commit they were told
was reviewed. It is **not** a blocker: the bundle is internally consistent (the
CLI re-reads head and base after gathering and refuses a mixed-revision bundle),
and a newer head is more current, not less valid. Do not chase the branch — a
further push will re-dispatch and get its own review.

## CANNOT REVIEW — the third verdict (tool failure, not objection)

**Added 2026-08-26, from web-credits-next#740.** That release PR (234 files /
15,730 lines) blew past GitHub's 20,000-line whole-diff cap, the bundle died,
and the bot posted a bare **NO-GO**. A NO-GO says *"I read this change and it is
wrong."* Nothing had been read. The author and the orchestrator both spent a
full diagnostic cycle hunting for the objection that did not exist.

So there are **three** verdicts, and the third has its own token:

| Verdict | Means | `qa-review` state | Approve? |
|---|---|---|---|
| `GO` | reviewed, no 🔴/🟡 | `success` | yes, if Step 7's gates pass |
| `NO-GO` | reviewed, blocking findings | `failure` | no |
| `CANNOT REVIEW` | **could not review — the tool failed** | `failure` | **no** |

**CANNOT REVIEW is blocking.** It is not a softer NO-GO and it is emphatically
not a GO: an unreviewed PR must not merge, and `qa-review` stays `failure`
exactly as on a NO-GO. What changes is only that a human reading it knows the
diff is not the problem. Fail-closed in the direction of "blocking but honest".

**When to use it — any INFRASTRUCTURAL reason review is impossible**, not just
the diff cap: a failed/degraded bundle (every case under "Check the bundle's
integrity flags FIRST"), a 403/404 that hides the PR, an unreadable file list,
a thread list that cannot be completed, and a GitHub 403 that blocks the bundle
or the CI lookup. **Never assume a 403 is an empty quota** (MUS-11176): read the
bucket, then pipe the failing `gh` error text through the classifier and use its
output verbatim as the reason:

```bash
read -r rem rst < <(gh api rate_limit --jq '.resources.core | "\(.remaining) \(.reset)"')
QA_GH_RATELIMIT_REMAINING=$rem QA_GH_RATELIMIT_RESET=$rst \
  bash /opt/hydra/scripts/lib/qa-gh-error-class.sh "<failing gh error text>"
```

It tells a primary hourly quota (`API rate limit exceeded`) from a secondary
burst limit and from a plain permission 403, and prints the remaining count and
reset time. Exit 1 means it is not a 403; keep your own concrete reason.
If you could read the change and chose to block it, that is NO-GO. If you could
not read the change, that is CANNOT REVIEW. **Never mix them in one verdict**,
and never dress a tool failure up as a finding to make the verdict look normal.

**On a quota failure, do not self-retry.** Publish the verdict and stop: re-asking
spends the bucket that just emptied. Do not read a prior GO on the same sha and
adopt it as your verdict either. Whether a CANNOT REVIEW overwrites a standing GO
is the status writer's call (`scripts/qa-review-status.sh` keeps the GO), not
yours.

**How to publish it** — same three writes as any other review, with the token
carried through all three so no reader has to infer it:

1. **Review body** (Step 6, `event: COMMENT` as always). Lead with it and give
   the reason in the same sentence:
   `⛔ **Verdict: CANNOT REVIEW** — <what failed, concretely>.`
   Then say what a human has to do. File **no** 🔴/🟡 findings you did not
   actually derive from code — the counts are 0, and saying so is the honest
   report.
2. **Commit status** (Step 6). State is `failure`; the description **must start
   with the literal `CANNOT REVIEW: `** — that prefix is what makes the merge
   gate's red readable in the GitHub UI without opening the review:
   ```bash
   verdict_state=failure
   verdict_desc="CANNOT REVIEW: diff exceeds GitHub's 20,000-line cap and could not be paged"
   ```
   Keep the reason short: `qa-review-status.sh` truncates at 140 chars, and the
   prefix must survive.
3. **Slack DM** (the closing threaded reply). `⛔` + the PR link + one line:
   *not approved — QA could not review this (\<reason\>); this is a tool failure,
   not a finding on your code.* Never report it as "found issues".

**Never approve on a CANNOT REVIEW**, for any reason, including "CI is green
and it is only a promotion". Step 7's gate is a GO verdict, and this is not one.
`scripts/qa-approval-retry.sh` parses the token independently and will not
re-ask for the approval either — its parser ranks CANNOT REVIEW above NO-GO
precisely so a carried-forward `Verdict: GO` from an older head cannot be read
as this head's verdict.

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
   happy path? Flag the specific missing case. Five false-green patterns have
   shipped here already — check each by name:
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

A red `checks` entry **unrelated to this PR's diff** (a deploy pre-flight / gate
failing on pre-existing server state) is context, not a finding — and those gates are
now also in the policy's `advisory_checks`, so the approval wrapper stops counting
them too. But if you judge that a red advisory check IS caused by this diff (the PR
edits `deploy.sh`, or adds a file the rsync gate rejects), that is a real 🔴/🟡 and
the verdict must reflect it. The exemption is for pre-existing drift, not a blanket
pass.

**`rebaseIntegrity`:** `null` is repo-scoped — for **hydra** it means the
analyzer's hand-off failed, so hold approval and say "re-run PR Validation";
for every other repo it is genuine no-data (they don't publish this host-local
report), so note it as context and move on. Guard 8 re-derives exactly this
(exit 10). `CLEAN` → move on. `WARN` → prepend `⚠️ REBASE WARNING` to the Step 6 body, file one
🟡 finding starting `🟡 **Important — REBASE WARNING [<headRefOid[:7]>]**`;
open = NO-GO. `ERROR` → say rebase unverified. **Relay the CI-computed
signals verbatim — never re-derive them yourself from the diff**; the report
is the authority and a hand-rolled version will disagree with Guard 8.

**You MAY resolve the REBASE WARNING thread yourself** once you have actually
checked the signals against the diff and concluded the deletions were intended
rather than a clobber. **Changed 2026-08-03 (Nick, explicit):** this used to say
"never resolve it yourself — a human resolving it IS the acknowledgment", which
made every rebase warning a manual step for a team that does not have review
capacity. Resolution is now yours to make, under the same rule as every other
finding: never resolve a thread you have not confirmed, and **reply in the thread
FIRST** with what you checked — which signals fired, which files, and why the
deletion is intentional ("the 6 deleted lines in X are the old implementation this
PR replaces; base's version is not lost"). A resolution with no reasoning is
indistinguishable from rubber-stamping. If you CANNOT convince yourself the
deletions were intended, leave it unresolved: that is a real 🟡 and Guard 7 will
correctly hold the PR.

> `QA_REBASE_ACK_REQUIRE_INDEPENDENT` must stay `0`. Setting it to `1` makes
> Guard 8 refuse (exit 10) any warning resolved by the bot or the author, which
> contradicts the rule above — and it would also break the ack carry-forward
> below, whose prior-head ack is now frequently yours. It is retained only so the
> stricter posture can be restored deliberately. Judge acknowledgments by what is
> DEPLOYED, never by what a diff proposes.

**Ack carry-forward.** The marker is head-tagged, so a merge-from-`main` or any
no-op push re-files a finding already judged — hydra PRs have collected 11 acks
of one unchanged warning, and an ack that cheap gets clicked unread.
Skip the 🟡 (still write the ⚠️ body section, saying the ack carries forward
from `<prior sha7>`) only when EVERY leg holds: this head's
`rebaseIntegrity.warn_digest` is a real 64-hex value (a report predating the
field carries nothing — no identity, no carry); another head of THIS PR has a
`WARN` report with the identical digest; and that head's marker thread was
bot-filed and is **resolved** — i.e. this exact finding was already
acknowledged, whether by a human or by you under the rule above. A carried ack
clears exactly the same bar as a fresh one, never a lower one. The digest keys on
the warn signals' flagged LINES, never their summaries (two different 10-line
deletions in one file share a summary but never a digest), so **digest changed
= finding changed → file it**. Guard 8 re-checks every leg itself and exits 10
if any fails, so filing the 🟡 is always the safe fallback.

Prior heads' digests are the one thing the bundle cannot serve — it reads only
this head's report — so this cross-head glob is the sole sanctioned local read
(the grep lists this head's own report too; ignore that one):

```bash
grep -l "<this head's warn_digest>" \
  "/var/lib/hydra-qa/rebase-integrity/${OWNER}__${REPO}-pr-${PR}-"*.json
```

### Blast radius (advisory CI hand-off)

PR Validation also runs `scripts/check-blast-radius.sh` and writes a per-head
report on this host: what a wrong change would *reach*, which is the question
diff size cannot answer. **The bundle does not carry this** — `muso gh
review-bundle` has no `blastRadius` field — so it is the second sanctioned local
read alongside the digest glob above:

```bash
cat "/var/lib/hydra-qa/blast-radius/${OWNER}__${REPO}-pr-${PR}-<pr.headRefOid>.json"
```

- **Missing** → for **external repos** genuine no-data (the analyzer only runs in
  hydra's CI): note as context, review on the 8 lenses alone. For **hydra** the
  hand-off failed — say so in the body and do not invent a radius from the diff.
- **`CLEAN`** → the analyzer ran and found no reviewable files (diff was entirely
  generated/vendored — lockfiles, `dist/`, `node_modules/`). Normal and valid:
  treat as `Blast radius: LOW` and move on.
- **`ERROR`** → say "blast radius unverified — analyzer errored; re-run PR
  Validation" and review on the lenses alone.
- **`OK`** → prepend a one-line **`Blast radius: <TIER>`** to the review body,
  listing each fired signal's `id` and its evidence, then scale depth by tier:

| Tier | What it adds to the review |
|---|---|
| `LOW` | Nothing. The 8 lenses as written. |
| `MEDIUM` / `HIGH` | **Reverse-caller contract check** — for every caller the report names, ask whether this diff changed something that caller depends on: output format, exit codes, or side effects. Plus: how is this reverted? |
| `CRITICAL` | The above **plus a mandatory adversarial pass**: how would I evade this gate? What breaks fleet-wide if this is wrong? Assume the change is subtly incorrect and go looking for the evidence. |

- **`skipped` non-empty → relay it and say the tier is a LOWER BOUND.** Above
  `BR_MAX_FILES` the analyzer stops computing `reverse-callers` and `cron-reach`,
  so a big PR can report a low tier purely because the expensive signals never
  ran. Reporting the tier without the skips is the confident false-negative the
  limitations exist to prevent.
- **Relay the report's `limitations` array verbatim.** Load-bearing, not
  boilerplate: grep cannot prove a negative, a reference found is not proof the
  path executes, and no runtime or concurrency behaviour is modelled. Without it
  the tier reads as authoritative and invites confident false findings.
- **The tier is not a finding.** It changes how hard you look, never what you
  report. A `CRITICAL` radius with nothing wrong in the diff is still a GO; every
  🔴/🟡 still needs its own failure scenario. A real finding in a file the report
  flags `critical` escalates one rung, because the same defect reaches further.
- Do **not** re-derive these signals from the diff — relay the CI-computed report
  only, exactly as with `rebaseIntegrity`.

> `deploy-path` is reported as `info` and **never lowers the tier**. An undeployed
> file is unproven, not proven safe — do not argue a finding down from it.

**Tests** (when warranted): never `pr checkout` into a fresh full clone — each
one left 1.4-2.1G that nothing removed (MUS-5557). Run the tests through
`qa-review-clone.sh`, which borrows objects from a shared bare mirror and
deletes its checkout when the command ends, whatever the verdict:

```bash
/opt/hydra/scripts/qa-review-clone.sh "$OWNER/$REPO" "$PR" -- \
  bash -c 'pnpm install --frozen-lockfile && npm test'
```

The command runs with cwd = the PR head; its exit code is yours. Do the whole
test run inside that one call — the checkout is gone afterwards, so there is no
cleanup step to remember, including on a NO-GO or an aborted run.

## Step 4 — Post the Slack summary

Number findings; **muso-slack-formatter** auto-applies. 🔴 Critical, 🟡
Important, 🟢 Nice-to-have, 🔵 Suggestion, each `<file:line> — what/why/fix>`,
plus Verdict + Strengths. Ask: "Post this? Or 'important only', 'drop #3',
'skip'."

## Step 5 — Human-approval gate

**Do not write to GitHub until a human approves.** Apply requested edits
first. "Skip" → stop, summary stands alone.

## Step 6 — Log, post the review, publish the status (only after approval)

**Logging, before any write** — cannot log it, do not post it:

```bash
mkdir -p api-logs/github
cat >> "api-logs/github/$(date +%F).jsonl" <<EOF
{"agent":"qa","action":"github_pr_review","target":"$OWNER/$REPO#$PR","requester":"<name>","timestamp":"$(date -u +%FT%TZ)","authorization":"approved-in-thread"}
EOF
```

**In AUTO mode there is no approving human, so those two fields would be a
false audit trail.** Override them: `"requester"` = the author's Slack UID from
the dispatch message, `"authorization":"auto-review-dispatch"`.

**Post one review** via the reviews API:

**Use a per-run payload file under the run's scratch root, never a `/tmp` path.** Reviews run
concurrently across repos, so a shared name (the old `/tmp/pr-review.json`) is a
real race: another review overwrites the file between your heredoc and the POST,
and you submit ITS payload — a 422 commit mismatch, no review, no status, and a
gated PR stuck. Observed live on hydra#790, where a core-backend payload replaced
the file mid-run.

```bash
scratch="${PAPERCLIP_RUN_SCRATCH_DIR:-/opt/hydra/workspaces/qa/tmp}"; mkdir -p "$scratch"
payload=$(mktemp "$scratch/pr-review-${REPO}-${PR}-XXXXXX.json")
cat > "$payload" <<JSONEOF
{"commit_id":"<pr.headRefOid>","event":"COMMENT","body":"🤖 **Muso QA Bot** (automated review)",
 "comments":[{"path":"src/auth.js","line":45,"side":"RIGHT","body":"🔴 **Critical:** ..."}]}
JSONEOF
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api \
  "repos/$OWNER/$REPO/pulls/$PR/reviews" --method POST --input "$payload"
rc=$?; rm -f "$payload"; [ $rc -eq 0 ] || echo "review POST failed rc=$rc" >&2
(exit $rc)  # keep the POST status as the block result
```

**Why no `trap 'rm -f "$payload"' EXIT` (MUS-5643):** this skill used to carry
that trap and `/tmp` held 536 leftover `pr-review-*.json` files (1G), plus 1,171
`*-review-*` clones (27G). Each agent Bash call is its own shell, so the trap
fires at the end of the call that created the file, before the next call uses
it, or the agent drops the line. You cannot turn a multi-call session into one
process lifetime. Fix the **location**, not the cleanup: scratch goes under
`$PAPERCLIP_RUN_SCRATCH_DIR` when a Paperclip run sets it (the runtime deletes it),
otherwise under the qa workspace's `tmp/` (`/opt/hydra/workspaces/qa/tmp`, TTL-swept,
`docs/lessons/working-in-hydra.md`). The block creates, POSTs and `rm`s in one call, so
nothing outlives it. Clone into the same root, never `/tmp`.
`scripts/check-no-tmp-scratch.sh` fails a PR that adds a hard-coded tmp path here.

**NEVER inline PR/diff text via `-f body='...'`** — always heredoc +
`--input <file>` (backticks/`$(...)` re-parse through your shell; PR #287
wrote a stray file this way — a code-exec vector). `COMMENT` only, never
reviews-API `APPROVE` (Step 7 owns approval). Inline 🔴/🟡 so Guard 7 sees
them. 403/scope → report it, Slack summary is the deliverable.

**Comment anchoring — get this wrong and the whole POST 422s, so no review
lands at all:**
- `line` = line number in the NEW file + `side:"RIGHT"`; multi-line range adds
  `start_line` + `start_side`.
- **Do NOT use `position`** (deprecated diff-offset) — use `line`.
- **Do NOT add `subject_type`** — the batched *reviews* endpoint rejects it; it
  exists only on standalone `POST .../pulls/<n>/comments`.
- `line` MUST appear in the PR diff. A finding you cannot tie to a changed line
  (file-level or whole-PR) goes in the review `body`, not as an inline comment.

**Publish the verdict as a commit status** on **every** review — no
terminal status hangs the PR unmergeable. **The state MUST track the verdict:
`success` on GO, `failure` on NO-GO, `failure` on CANNOT REVIEW.** Publishing
`success` after finding blockers turns the app-pinned required check green and
defeats the merge gate — and publishing it after failing to review at all would
be worse, because the PR would look reviewed. Copy the variable, never the
literal:

```bash
verdict_state=success                       # NO-GO -> failure; CANNOT REVIEW -> failure
verdict_desc="GO — 0 blocking findings"     # NO-GO -> "NO-GO — <N> blocking finding(s)"
                                            # CANNOT REVIEW -> "CANNOT REVIEW: <reason>"
bash /opt/hydra/scripts/qa-review-status.sh "$OWNER/$REPO" "<pr.headRefOid>" \
  "$verdict_state" "$verdict_desc" "https://github.com/$OWNER/$REPO/pull/$PR/files"
```

Always pass the 5th arg — it becomes the check's "Details" link, and on a gated
repo it is the operator's only in-UI route to why `qa-review` is red.

Always via `qa-review-status.sh`, never bare `gh api .../statuses/` —
`qa-review` is App-pinned on gated repos; missing = merge block on
`.merge_gate_repos`: retry once, then DM the author.

## Carry forward prior findings (before any GO)

A fresh 0/0 pass isn't enough — GO also requires clearing every still-open
finding from earlier rounds (PR #287 was wrongly approved otherwise).
`bundle.threads[]` (refresh via `muso gh threads "$PR" --repo
"$OWNER/$REPO"` after a push) lists unresolved threads. Own prior tagged
finding, now fixed: resolve it — never resolve one unconfirmed. There is no
`muso gh` verb for this, so use the mutation directly:

```bash
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api graphql \
  -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -f id="$THREAD_ID"
```

Human/Clio thread (no emoji): assess with the 8 lenses; unaddressed
Critical/Important is a blocker, leave it — do not resolve someone else's
thread on their behalf.

**Verdict:** GO requires no 🔴/🟡 fresh OR unresolved-prior, incl. an open
🟡 REBASE WARNING — which you may resolve yourself once you have verified the
deletions were intended and written that reasoning into the thread (Step 3);
never resolve one you have not confirmed. Step 7 independently re-checks
this + CI. **This is the gate that matters: block on unresolved issues, never
on unresolved paperwork.** And GO requires that you actually reviewed: if any
CANNOT REVIEW condition fired, the verdict is CANNOT REVIEW regardless of how
few findings the part you *could* see produced.

## Step 7 — Approve the PR (approve-only, gated)

Approve **only** when BOTH hold:
- your verdict is **GO** — no 🔴 Critical and no 🟡 Important findings, including any
  carried-forward unresolved thread (see "Carry forward prior findings"). A
  **CANNOT REVIEW** verdict is not a GO and never becomes one: skip Step 7
  entirely; and
- the requester's Slack UID is on the approval allowlist, which has **two tiers**
  (changed 2026-08-13, authorized by Nick):
  - **Unscoped** — **Aaron** (`U7RP6HKUZ`) and **Nick** (`U0AL36NADEY`): any Muso-AI PR.
  - **Scoped** — **Mariia** (`U03LP8YHLPK`): **only** when the PR author is
    `azure-kirin` (her own PR) **and** the repo + base branch are one of these exact
    pairs (widened 2026-08-17):
    `Muso-AI/web-credits-next` + `develop`, `Muso-AI/auth` + `main`,
    `Muso-AI/ads-manager` + `main`. The base is **not** uniform across the three —
    a PR in `auth`/`ads-manager` targeting `develop` is out of scope, as is one in
    `web-credits-next` targeting `main`. Her PRs on those repo+branch pairs
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
bash /opt/hydra/scripts/qa-pr-approve.sh <repo> <pr> <requester-slack-uid> \
  "🤖 Approved by Muso QA Bot (automated review)." || echo "declined (exit $?)"
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
  blocks self-approval — another reviewer is needed; this one must ALSO be posted
  on the PR — see "A refusal has to leave a trace ON THE PR"); `exit 5` = requester not authorized
  — either they are not on the allowlist at all (e.g. **Serhii**, review-only since
  2026-08-13) or they are a **scoped** approver and this PR is outside their scope (e.g.
  Mariia on a repo outside {`web-credits-next`, `auth`, `ads-manager`}, on a base other
  than that repo's allowed one (`develop` for web-credits-next, `main` for the other two),
  on a PR she did not author, or on a PR whose **base branch the API would not return** —
  that last one fails closed and is scoped-requester-only). The message names the
  condition that failed — relay it
  verbatim and say a human reviewer signs this one off; do NOT retry, re-request with a
  different UID, or approve around it;
  `exit 7` = one of TWO different failures, and they need OPPOSITE responses — tell them
  apart by whether an audit-log line for this PR already exists (the wrapper logs
  immediately BEFORE the write, so its presence proves the approve was attempted):
  **no log line** = the wrapper could not read the PR's **author** (the PR does not exist,
  or the gh call failed); nothing was written, it is usually TRANSIENT, and a single re-run
  is reasonable once you have confirmed the PR really exists.
  **a log line already exists** = the `gh pr review --approve` write itself failed AFTER
  logging; do NOT re-run (that double-writes the audit trail and may double-approve) —
  check `gh pr view --json reviewDecision` to see whether the approval actually landed,
  and relay that. This exit hits **every** requester, unscoped included.
  (Unlike exits 5/8/9, which are verdicts to relay and never to retry.);
  `exit 8` = CI is not green — this ALSO fires when the rollup is unreadable, when
  there are no non-qa-review checks at all, or when EVERY check is advisory-exempt
  (none of which mean a red check; read the message and do not blindly re-run); `exit 9` = an unresolved Critical/Important thread is still
  open (carry it forward — fix it or resolve the thread, do not approve around it);
  `exit 10` = the rebase-integrity report for this head is WARN with no filed
  `REBASE WARNING [<sha7>]` thread **and no prior head's ack carries forward**
  (file the Step 3d finding first), it is ERROR/unreadable (rebase state
  unverified — a human must look), or it is MISSING for a repo that requires one
  (hydra) — re-run PR Validation;
  `exit 11` = the PR touches a path in `sensitive_paths_blocking`. Since 2026-08-14
  that list carries the AUTHORITY SURFACE — `policies/qa-approval-policy.json`,
  `scripts/qa-pr-approve.sh`, and the three `CODEOWNERS` spellings — so a PR that
  changes who may approve is refused here BY DESIGN and needs Aaron, not the bot
  (Tier 3, `docs/reference/GOVERNANCE.md`). Relay it as "a human must approve this
  one", never as a fault to work around. Also `exit 11` if the
  `sensitive_paths_blocking` key is unreadable/malformed, OR the changed-file list
  could not be established — those two mean the POLICY is broken, not the PR;
  `exit 12` = the PR's author is in the policy's `author_deny` list, or `author_deny`
  is missing/null/malformed (fail-closed) — report the policy state, do not retry;
  `exit 13` = Guard 9 blast radius (only when `QA_BLAST_RADIUS_GATE=1`, not the default).
  `exit 14` = Guard 14, the OPT-IN expected-state contract. Only reachable when a
  caller sets `QA_PR_APPROVE_EXPECT_HEAD`, `QA_PR_APPROVE_EXPECT_BASE`,
  `QA_PR_APPROVE_EXPECT_BASE_OID` and/or `QA_PR_APPROVE_EXPECT_QUIET_SINCE`;
  unset (which is this skill's case) the guard is skipped entirely. It means the PR
  changed between the verdict and the write — the HEAD moved (exact equality, no
  benign case), the base was retargeted (name) or
  REWRITTEN under the same name (OID, distinguished from an ordinary
  fast-forward via GitHub's compare status), or an
  unresolved NON-bot review thread with activity at/after the verdict timestamp
  (Guard 7 only blocks 🔴/🟡-tagged ones). It is the wrapper refusing to approve a
  PR its caller's verdict no longer describes, so it is a CORRECT outcome, never a
  fault to work around: a fresh review must supply the verdict.
- A red `checks` entry is never a reason to skip the wrapper. When the verdict is GO
  and the requester is authorized, **always invoke it**, then report its exit code and
  message. Whether CI blocks is the wrapper's decision, not yours; a red advisory check
  normally arrives as an `⚠️ ALERT` line (the wrapper withholds it only when the PR edits
  `.github/workflows/`).
- If the verdict is **not** GO, do NOT approve: post the findings and stop.

Then report the wrapper's post-check (`reviewDecision` / `mergeStateStatus`). If
GitHub still shows the PR blocked (required checks pending, a real CODEOWNERS
gap), tell the requester what is outstanding — and if it does NOT, do not invent
a blocker the post-check did not report.

### A refusal has to leave a trace ON THE PR, not only in the DM

**Added 2026-09-16 after Muso-AI/H-DevOps#3114.** Step 6 posts the review body
**before** Step 7 runs the wrapper, so the body can never carry the approval
outcome — and the follow-up comment below fires only when the wrapper printed
`⚠️ ALERT` lines. A clean `GO` that the wrapper **declines with no alerts**
therefore leaves **nothing on the PR at all**: the verdict reads `GO`, no
approval appears, and the reason exists only in the cron journal and the Slack
DM to the author.

That is measured, not hypothetical. `Muso-AI/H-DevOps#3114` carried **17 reviews
over six days**, two of them clean `GO` with every required check green, and
never one approval — the PR is authored by the gateway account, so Guard 3
refuses `exit 4`. Its only comment in four days was the dispatch ack. **The
author was an agent**, which has no Slack DM to read, so the single channel
carrying the reason reached nobody who could act on it. The PR read as "GO,
approval withheld, no reason given" and sat.

So: **when the wrapper exits 4, post the reason as a PR comment**, alerts or no
alerts. Use the same one-post-path block below — it already carries a heading for
the refusal case — with the wrapper's own message verbatim:

```
## ⛔ Not approved — a different reviewer must sign this one off
<the wrapper's exit-4 message, verbatim>

This PR is authored by the same account the QA bot reviews as, and GitHub
forbids approving your own pull request. Re-running the review cannot change
it. A different reviewer must approve.
```

**ONE comment, never two.** The block below is deliberately a single post path.
If the wrapper *also* printed alerts, do **not** post this as a second comment —
that path already uses `## ⚠️ Alerts (NOT approved — <exit code / reason>)`, so
put the exit-4 explanation in **that** comment's body and post once. This section
only changes what happens when there are **no** alerts, which today is silence.

**Scoped to `exit 4` on purpose, not to every decline.** The other refusals reach
a human requester who gets the DM, and `exit 5` in particular is a deliberate
per-person policy (Serhii is review-only since 2026-08-13) — publishing that on
his PR every time would annotate a person's work with a policy notice they did
not ask for, which is noise at best. `exit 4` is the case where the author
*cannot* read a DM and the refusal is structural: it will never resolve on a
retry, on a new head, or on CI going green.

### Relay every ⚠️ ALERT the wrapper prints

**Changed 2026-08-03, narrowed 2026-08-14.** Sensitive paths (`policies/`,
`scripts/qa-*`, `CODEOWNERS`, workflows, gateway config …) used to REFUSE the
approval with `exit 11`. Most no longer do — the wrapper approves and prints one
or more `⚠️ ALERT — …` lines instead. A red **advisory** CI check does the same.

The exception is the **authority surface** — `policies/qa-approval-policy.json`,
`scripts/qa-pr-approve.sh`, `CODEOWNERS` — which went back to refusing (`exit 11`)
on 2026-08-14. Those files decide who may approve, and the bot posts as `adk47`,
the universal code owner, so without that refusal a PR widening the bot's own
authority would satisfy the code-owner gate by itself. Everything else alerts.

Those alert lines are now the ONLY signal that something needing eyes was
auto-approved, so treat them as review content, not log noise. **The wrapper
runs in Step 7, AFTER Step 6 already posted the review**, so the alerts do not
exist yet when the review body is written — do NOT try to put them there, it
cannot work. Both channels below come after the wrapper returns:

1. **Post them as a follow-up PR comment**, so they land where the person merging
   will see them (the Slack DM only reaches the author). Same heredoc/`--input`
   rule as Step 6 — never inline via `-f body=`. The heading depends on the
   OUTCOME — the wrapper replays its alerts on refusal paths too, so
   "Auto-approved" would be a lie on a decline: use `## ⚠️ Auto-approved with
   alerts` when the wrapper exited 0, and `## ⚠️ Alerts (NOT approved — <exit
   code / reason>)` when it refused.

   This POST is a **separate external GitHub write**, so it needs its own
   write-activity log line BEFORE it (same rule as the review POST). Everything
   below is ONE control-flow block on purpose. The approval is already recorded
   by the time any of this runs, so every failure path must end somewhere
   explicit — and there must be exactly ONE post attempt path, or the happy path
   posts the comment twice.
   ```bash
   scratch="${PAPERCLIP_RUN_SCRATCH_DIR:-/opt/hydra/workspaces/qa/tmp}"; mkdir -p "$scratch"
   alerts_json=$(mktemp "$scratch/qa-alerts-${REPO}-${PR}-XXXXXX.json")
   alerts_md=$(mktemp "$scratch/qa-alerts-${REPO}-${PR}-XXXXXX.md")
   cat > "$alerts_md" <<'EOF'
   ## ⚠️ Auto-approved with alerts
   <every ⚠️ ALERT line, verbatim>
   EOF
   # Wrap the markdown into a JSON object FIRST. `--input` sends the file as the
   # whole request body, so it must already BE {"body": "..."} — handing it raw
   # markdown posts invalid JSON, and any -f/-F alongside --input lands in the
   # query string instead of the payload. `jq -Rs` slurps stdin into one
   # JSON-escaped string, so backticks, quotes and $VAR survive verbatim.
   jq -Rs '{body: .}' < "$alerts_md" > "$alerts_json"

   post_alerts() {
     bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api \
       "repos/$OWNER/$REPO/issues/$PR/comments" --method POST --input "$alerts_json"
   }
   go_red() {  # <why> — the PR is already approved; make it visibly unsafe to merge
     # Honours the SAME guarantees Step 6 sets for the verdict status: pass the
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
   rc=$?; rm -f "$alerts_json" "$alerts_md"
   (exit $rc)  # keep go_red's status as the block result
   ```
   A green PR whose alert never published is worse than a red one, because it
   looks reviewed.
2. Repeat them in the Slack result DM, above the verdict.
3. Never summarise them away, and never drop one because the verdict was GO — GO
   is exactly when they matter.
4. The wrapper replays its alerts on EVERY exit path, refusal included — so relay
   them on a decline too, not just on an approval.

The team traded the old hard refusal for speed on the explicit understanding that
the alert is loud. If you swallow it, the trade is a straight loss.

## Pitfalls

- **Draft PRs**: review as normal but use `event: COMMENT` and say the findings
  are preliminary. Do not approve a draft.
- **Response hygiene**: the Slack summary is customer-of-the-team output. Present
  findings naturally; never mention `sessions_send`, workspaces, tiers, cron, or
  any internal routing in it.
- **Large PRs**: the bundle returns the whole diff — don't try to hold a
  3,000-line diff in one reasoning pass. Walk `files[]` file by file. Past
  GitHub's 20,000-line whole-diff cap `diff` is reassembled from those same
  per-file patches (`diffSource: "per-file-patches"`), so walking `files[]` is
  the identical procedure and the only thing that changes is the one line you
  add to the body saying the diff was paged. **A big PR is a longer review, not
  an unreviewable one** — reach for CANNOT REVIEW only when a named tool failure
  actually hid something from you, never because the diff was tiring. The same
  rule applies to files recovered via the `qa-bundle-diff-fallback.sh` git
  fallback (Step 1, `diffSource == "per-file-patches"`): fold each recovered
  `diff` into the same file-by-file walk — it is not a separate mini-review, it
  is the rest of the PR you were about to review anyway. If the combined
  file-by-file walk still will not fit in one reasoning pass, split it into
  multiple sequential passes over disjoint file subsets rather than skipping
  any of them — the verdict must account for every file the bundle (plus the
  fallback) returned; a file that was never walked is exactly the silent-gap
  failure CANNOT REVIEW exists to prevent, so name it explicitly if a pass
  genuinely has to be cut short instead of letting it vanish from the review.
