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
  version: "2.0"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# Muso — GitHub Code Review

Bundle → 8-lens analysis → Slack summary → approval → batched review.
Relay your summary to whoever delegated this, not CTO.

## Auto mode (AUTO-REVIEW dispatch, no human in the loop)

Dispatched by `scripts/qa-dispatch-pr-review.sh` — dispatch + gates below
ARE the authorization. Message carries the author's Slack UID.

- Writes via the three mandatory paths in Setup (review → `qa-gh.sh`,
  status → `qa-review-status.sh`, approval → `qa-pr-approve.sh`; never
  substitute one for another), lead body `🤖 Muso QA Bot (automated
  review)`. Open with `qa-pr-thread-dm.sh`, keep `ts`. Skip Step 5; log
  then post yourself.
- Approve (Step 7) only if `checks` are green **EXCEPT for the policy's
  `advisory_checks`** — every check passed, none `fail` and none `pending`,
  other than those the policy names advisory (the deploy pre-flight and
  friends, which fail on live server drift rather than on the diff).
  **Changed 2026-08-03:** this used to say "be strict — any non-green check
  means do not approve", which held hydra#780 at a clean GO for days because
  a live rsync dry-run was red against pre-existing server drift that had
  nothing to do with the diff. Advisory checks now alert instead of blocking;
  every OTHER red check still holds the approval. (Ignore only your own
  `qa-review` row — the wrapper excludes it too, to avoid a circular
  dependency.) Plus: GO incl. carried-forward; `rebaseIntegrity` clear —
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
(path, status, patch), `diff`, `checks`, `threads[]`, `rebaseIntegrity`
(parsed report or `null`).

### Check the bundle's integrity flags FIRST — before reviewing

The bundle reports when its own view is incomplete. Both are fail-closed
signals: acting on a partial view is how a real blocker gets missed.

- **`filesCountMismatch` set** → `pr.changedFiles` disagrees with the number of
  files returned. You are looking at an incomplete diff. Do NOT review it and do
  NOT approve. Post NO-GO, say the file list could not be verified, and stop.
- **`threadsTruncated` true** → more unresolved threads exist than the bundle
  returned (page cap). Carry-forward is therefore unreliable, and an unresolved
  blocker may be invisible to you. Re-query with
  `muso gh threads "$PR" --repo "$OWNER/$REPO" --json` (it hard-fails rather than
  silently truncating). If it still cannot return a complete list, post NO-GO and
  say so — never approve off a truncated thread list.

Neither flag is a style nit. `scripts/qa-pr-approve.sh` refuses for these same
reasons independently (Guards 7 and 11), so ignoring them here just moves the
failure later and makes it more confusing.

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

**Tests** (when warranted): `qa-gh.sh ... pr checkout "$PR"` then `pnpm
install --frozen-lockfile && npm test`.

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

**Use a per-run payload file, never a fixed `/tmp` path.** Reviews run
concurrently across repos, so a shared name (the old `/tmp/pr-review.json`) is a
real race: another review overwrites the file between your heredoc and the POST,
and you submit ITS payload — a 422 commit mismatch, no review, no status, and a
gated PR stuck. Observed live on hydra#790, where a core-backend payload replaced
the file mid-run.

```bash
payload=$(mktemp "/tmp/pr-review-${REPO}-${PR}-XXXXXX.json")
trap 'rm -f "$payload"' EXIT
cat > "$payload" <<JSONEOF
{"commit_id":"<pr.headRefOid>","event":"COMMENT","body":"🤖 **Muso QA Bot** (automated review)",
 "comments":[{"path":"src/auth.js","line":45,"side":"RIGHT","body":"🔴 **Critical:** ..."}]}
JSONEOF
bash /opt/hydra/scripts/qa-gh.sh --repo "$OWNER/$REPO" api \
  "repos/$OWNER/$REPO/pulls/$PR/reviews" --method POST --input "$payload"
```

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
`success` on GO, `failure` on NO-GO.** Publishing `success` after finding
blockers turns the app-pinned required check green and defeats the merge gate —
copy the variable, never the literal:

```bash
verdict_state=success                       # NO-GO  -> failure
verdict_desc="GO — 0 blocking findings"     # NO-GO  -> "NO-GO — <N> blocking finding(s)"
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
on unresolved paperwork.**

## Step 7 — Approve the PR (approve-only, gated)

Approve only if GO (incl. carried-forward) AND requester UID is **Aaron,
Serhii, or Nick**, via the gated wrapper — **never** bare `gh pr review
--approve`:

```bash
bash /opt/hydra/scripts/qa-pr-approve.sh <repo> <pr> <requester-slack-uid> \
  "🤖 Approved by Muso QA Bot (automated review)." || echo "declined (exit $?)"
```

`|| echo` keeps a decline's exit from surfacing as a failed tool call.
`<requester-slack-uid>` is `sender_id`, never a name. You approve, never
merge. Not GO → post findings and stop.

**Relay the wrapper's exit code, never retry blindly** — each one is a distinct
thing the author must fix: `3` not a Muso-AI repo · `4` PR authored by the
gateway account (GitHub blocks self-approval — another reviewer is needed) ·
`5` requester not authorized · `8` CI not green — **this ALSO fires when the
rollup is unreadable, when there are no non-`qa-review` checks at all, or when
EVERY check is advisory-exempt**, none of which mean a red check, so read the
message rather than blindly re-running · `9` an unresolved Critical/Important
thread is still open (fix or resolve it, never approve around it) · `10` rebase
integrity — WARN with no filed `REBASE WARNING [<sha7>]` thread **and no prior
head's ack carrying forward**, ERROR/unreadable, or MISSING on hydra (re-run PR
Validation) · `11` the PR touches a path in `sensitive_paths_blocking` (that
list ships EMPTY, so this is rare and deliberate — a human must approve that
one), OR that policy key is unreadable/malformed, OR the changed-file list could
not be established while blocking paths are configured — the last two mean the
POLICY is broken, not the PR · `12` the author is in the policy's `author_deny`
list, or `author_deny` is missing/null/malformed (fail-closed) — report the
policy state, do not retry · `13` Guard 9 blast radius (only when
`QA_BLAST_RADIUS_GATE=1`, not the default).

Then report the wrapper's post-check (`reviewDecision` / `mergeStateStatus`). If
GitHub still shows the PR blocked (required checks pending, a real CODEOWNERS
gap), tell the requester what is outstanding — and if it does NOT, do not invent
a blocker the post-check did not report.

### Relay every ⚠️ ALERT the wrapper prints

**Changed 2026-08-03.** Sensitive paths (`policies/`, `scripts/qa-*`,
`CODEOWNERS`, workflows, gateway config …) used to REFUSE the approval with
`exit 11`. They no longer do — the wrapper approves and prints one or more
`⚠️ ALERT — …` lines instead. A red **advisory** CI check does the same.

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
  3,000-line diff in one reasoning pass. Walk `files[]` file by file.
