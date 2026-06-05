# Caroline review: weekly → daily pulse (+ glanceable message)

**Date:** 2026-06-04
**Branch:** `feat/caroline-daily-review` (off `main`)
**Status:** design, pending implementation plan

## Motivation

The `caroline-weekly-review` cron (PR #287, merged + deployed, now `enabled:true`
live) grades Caroline's Intercom conversations once a week and posts a scored
review to `#cs_chats`. Two problems motivate this change:

1. **Cadence is too slow for what matters most.** The highest-value signal is the
   P0 leak audit (a tool/email leak in an outbound reply). Finding that up to 7
   days late is bad; a daily pulse catches it same-day.
2. **The message is a fixed skeleton.** It always prints every metric line even
   when the value is zero, and `@`-pings on every run. For a daily read it needs
   to be glanceable: status + scores at a glance, detail only when there is detail.

## Scope: decompose into two sub-projects

Running daily changes what the KB-gap dimension can do. KB-gap detection flags a
gap only when **≥3 unique customers** ask the same thing **in one window**; in a
1-day window that essentially never fires. Rather than weaken it, we split:

- **Sub-project 1 — Daily pulse (THIS spec, this branch).** Voice/leak + tools +
  sentiment over a rolling ~30h window, glanceable message, daily, to `#cs_chats`.
  **No KB-gap dimension, no auto-PR.**
- **Sub-project 2 — Weekly KB roll-up (separate spec, next).** Dimension C
  (KB gaps) over 7 days + the existing auto-PR machinery, weekly. **Not built
  here.** Its scripts are retained (see below) so SP2 reuses them.

This spec covers SP1 only.

## Sub-project 1 — design

### Architecture

The skill keeps its single-shell pipeline (preflight → fetch → grade → output, run
in one shell session so exported `WORKDIR` / `CAROLINE_BOT_ADMIN_ID` /
`CV_TOOL_CTX_CONVERSATION_ID` survive). Changes are confined to: the fetch window,
which dimensions are graded, the output template, and the cron entry.

1. **Fix user-facing names only — do NOT rename the skill directory.** The cron
   `name` `caroline-weekly-review` → `caroline-daily-review` (same cron `id`, a JSON
   field edit), the Slack headline → "Caroline daily", and the payload `message` →
   daily. The skill **directory keeps its name** `muso-caroline-weekly-review`.

   Why not rename the directory (changed from the original proposal — see "Decision:
   directory rename" below): renaming a workspace skill dir deletes tracked files
   under `workspaces/operations/skills/`, which the deploy deletion-classifier
   (`scripts/lib/classify-deletions.sh`) routes to **REMAIN (real drift)** — the
   `skills/` subdir is tracked, so the deletion is not auto-excluded. That **reds the
   CI deploy-preflight gate** (the gate the QA bot needs green to approve) and
   **blocks `deploy.sh` Step 4a** (it blocks `workspaces/`/`skills-all/` deletions),
   requiring an rm-on-server + `gh run rerun --failed` bridge and `HYDRA_FORCE=1` to
   get through — for a cosmetic, internal-only gain. Keeping the directory means
   **zero file deletions → a clean deploy**. A one-line note in `SKILL.md` records
   that the dir name is legacy and the job is daily. (Rule 5 surgical, Rule 3 KISS.)

2. **Window** — `scripts/fetch-conversations.sh`: replace the hardcoded
   `SEVEN_DAYS_AGO=$((NOW - 7*86400))` with a configurable rolling window:

   ```bash
   WINDOW_HOURS="${CAROLINE_WINDOW_HOURS:-30}"   # daily default; SP2 sets 168
   WINDOW_START=$((NOW - WINDOW_HOURS * 3600))
   ```

   Rename the `$SEVEN_DAYS_AGO` references (`build_query`'s `--argjson since`, the
   per-id `--argjson cutoff`) to `$WINDOW_START`. Update the header comment.
   Rationale for 30h at a 09:00 run: covers from 03:00 the prior day, ~6h overlap
   with the previous run so a late/missed run never leaves an ungraded gap. The
   default lives in the script (the daily cron sets no env); SP2's weekly job will
   export `CAROLINE_WINDOW_HOURS=168`. (Rule 3 KISS/YAGNI: a single env knob with a
   daily default, not a per-job env field that `cron-jobs.json` does not support.)

3. **Dimensions A/B/D only.** Edit `references/grading-rubric.md`: remove Dimension
   C (KB gaps) and its Slack-template section. Dimension C's rubric text is
   recoverable from this commit's parent for SP2.

4. **Glanceable output** — rewrite the "Slack output template" section (see below).
   The agent still assembles plain Slack mrkdwn text and pipes it through
   `scripts/redact-output.sh`; the cron `announce` path delivers that text (no Block
   Kit). `redact-output.sh` is unchanged.

5. **SKILL.md** — update prose to daily cadence; remove Phase-3 auto-PR step and the
   `OPS_CAROLINE_REVIEW_PR_OPEN` environment note (both move to SP2). Phases 0/1 and
   the hard rules ("never post to Slack directly", "no em-dashes", redaction) are
   unchanged.

6. **cron-jobs.json** — update the existing entry (id `03695380-...`):
   `schedule.expr: "0 9 * * *"` (was `0 9 * * 1`), `name`/`description` to daily,
   payload `message` to daily (use the script default window, grade A/B/D only, no
   KB/PRs, do NOT post to Slack directly). **`enabled: false`** — land disabled, run
   the shadow proof, then flip `enabled: true` in a separate one-line PR (see Rollout).
   This closes the proof-run-before-09:00 race the review flagged: `deploy.sh` takes
   `enabled`/`delivery.to` from the repo entry and restarts the gateway, so a disabled
   repo entry means the post-deploy restart cannot arm a 09:00 fire at the real channel.
   A disabled job also clears `nextRunAtMs`, so enabling later recomputes a fresh daily
   slot rather than inheriting a stale weekly-Monday `nextRunAtMs`. Channel unchanged
   (`C0ANM0PN9L5` = `#cs_chats`); model/fallbacks/thinking/timeout unchanged.

### KB scripts: parked, not deleted

`cluster-questions.sh`, `validate-clusters.sh`, `open-kb-pr.sh`, and
`references/pr-template.md` stay in the (renamed) skill directory, unreferenced by
the daily path, parked for SP2. Zero deletion, no lost work. SP2 will either move
them into a dedicated `muso-caroline-kb-rollup` skill or keep them here behind a
weekly entry point — that architecture decision belongs to SP2's spec.

### Glanceable message

Principles: (a) status emoji + scores readable in one second on line 1; (b)
`@`-mention **only on a P0** — quiet days ping no one; (c) collapse clean dimensions
(DETAIL bullets only, never the two header lines) — print a finding bullet only when
non-zero, no `• Missed: 0` skeleton; (d) header carries date, window, conversation
count, severity counts. Conversation ids are cited as the real 15-16 digit Intercom
id (which survives output redaction).

**Header contract (enforced mechanically, not just instructed):** line 1 MUST carry
the `<p0> P0 / <p1> P1 / <p2> P2` triplet (zeros included) + the `<N> convs` count;
line 2 MUST carry the `Voice | Tools | Sentiment` scores. Assembly pipes through
`redact-output.sh` then `scripts/assert-digest-contract.sh`, which fails the run if
either is missing — so a header-less partial digest can never reach `#cs_chats`.

**Quiet day (the common case — no ping):**

```
🟢 Caroline daily · Wed Jun 4 · last 30h · 23 convs · 0 P0 / 0 P1 / 1 P2
Voice 5 | Tools 5 | Sentiment 4
• Sentiment: 1 frustrated · conv 215474545718046 "are you actually checking?"
• Good catch: conv 998877665544001 · clean refund-gate run
```

**P0 day (rare — pings the reviewer):**

```
<@U0AL36NADEY> 🔴 Caroline daily · Wed Jun 4 · last 30h · 31 convs · 1 P0 / 2 P1 / 3 P2
Voice 3 | Tools 4 | Sentiment 4
*P0 leak:* 1 tool-leak line
*Voice (3):* 2 em-dashes (conv 215474545718046), blacklist "Great question" (conv 220033445566778)
*Tools (4):* 1 missed profile_status · conv 445566778899001
*Sentiment (4):* 2 frustrated · top: conv 556677889900112 "this is useless"
```

Status emoji rule: 🔴 if any P0; 🟡 if any P1 (no P0); 🟢 otherwise. The Tools score
renders `Tools skipped` when the join-key prereq is unavailable (existing
`CV_TOOL_CTX_CONVERSATION_ID=unavailable` behavior) — never a bare dash (which
`redact-output.sh` would produce from a normalized em/en-dash) and never a fabricated
score.

### Decision: directory rename — declined

Originally proposed to rename `muso-caroline-weekly-review` →
`muso-caroline-daily-review`. Declined after verifying the deploy mechanics (above):
a workspace skill-dir rename is a tracked-file deletion → REMAIN drift → CI
deploy-preflight red + `deploy.sh` Step 4a block. The user-facing honesty (cron
label, Slack headline, payload) is fully achieved without touching the directory, so
the rename buys only an internal name change at the cost of a multi-step deploy
unblock. Net: keep the directory, edit only its contents. All file changes below are
**edits, not deletions** → no deploy-gate friction.

## Files touched (all edits/additions — no deletions, no renames)

- `.../muso-caroline-weekly-review/scripts/fetch-conversations.sh` — window env +
  `$SEVEN_DAYS_AGO`→`$WINDOW_START` var rename (in-file) + header comment.
- `.../scripts/fetch-audit.sh` — **(Blocker 1)** journal `--since "7 days ago"` →
  `--since "${CAROLINE_WINDOW_HOURS:-30} hours ago"` so the leak audit rolls in
  lockstep (leak markers carry no timestamp; a fixed 7d window re-fires a stale leak
  as a fresh P0 daily for a week).
- `.../scripts/assert-digest-contract.sh` — **new.** Fail-loud header-contract guard,
  the last stage of Phase 3.
- `.../references/grading-rubric.md` — H1 → daily; drop Dimension C section + the
  "KB gap cluster" P2 token (rubric:9); rewrite the Slack template (drop KB column /
  KB section / Auto-PR line) into the glanceable digest + header contract.
- `.../SKILL.md` — daily prose + legacy-dir note; Phase 2 drops KB clustering; Phase 3
  drops the auto-PR step and adds the contract-guard pipe; re-scope hard rules 12-14
  (em-dash guard is `redact-output.sh`, not `validate-clusters.sh`; auto-PR parked);
  env note swaps `OPS_CAROLINE_REVIEW_PR_OPEN` (parked) for `CAROLINE_WINDOW_HOURS`.
- `.../scripts/tests/` — `fetch-conversations.bats` (window default/boundary/override +
  intent-comment fixes), `fetch-audit.bats` (journal-window test), `redact-output.bats`
  (10-13 digit boundary guard), `assert-digest-contract.bats` (**new**, 6 cases).
- `cron-jobs.json` — the `03695380-...` entry: `schedule.expr`, `name`, `description`,
  payload `message` (stays `enabled: false`; flip in the follow-up enable PR).
- Memory: update `project_caroline_weekly_review_pr287.md` after merge.

Unchanged: `preflight.sh`, `redact.sh`, `redact-output.sh`, `validate-clusters.sh`,
`cluster-questions.sh`, `open-kb-pr.sh`, `references/pr-template.md` (the last three
parked for SP2).

## Testing (Rule 9 TDD — red → green)

- `fetch-conversations.bats`: default window is 30h (`NOW-20h` kept, `NOW-40h`
  dropped); a 30h boundary pin (`NOW-29h` kept, `NOW-31h` dropped) guarding against a
  24h/7d regression; and `CAROLINE_WINDOW_HOURS=168` override (`NOW-100h` now kept).
  New per-part offsets, NOT the shared `$OLD` (=`NOW-720h`, excluded even at 168h).
  Existing window cases stay green (`$OLD`/`$NOW` classify identically under 30h and
  7d); only their intent comments/titles change (Rule 10) — no assertion changes.
- `fetch-audit.bats`: the journal `--since` tracks the 30h default and honors the
  168h override (custom stub records the arg verbatim; the shared stub's `%q` escapes
  the spaces in "30 hours ago").
- `redact-output.bats`: boundary guard — a bare 12-digit run scrubs to `<phone>`, a
  15-digit Intercom id survives, a real phone is still scrubbed.
- `assert-digest-contract.bats` (new): 6 cases — well-formed/Tools-skipped/P0-ping
  pass; missing-triplet / missing-score-label / missing-conv-count fail loud with no
  passthrough.
- The rubric Dimension-C removal and the glanceable message format are intentionally
  NOT unit-tested (LLM-assembled text / agent-read documentation); they are verified
  by the shadow proof-run (Verification). The one structurally-enforceable invariants
  (no em-dash; header contract) ARE covered by `redact-output.bats` /
  `assert-digest-contract.bats`.
- **Verified 2026-06-04: full suite 92/92 green** (was 81; +11), `shellcheck
  scripts/*.sh` clean. The suite is hermetic (curl/journalctl/openclaw/gh all stubbed
  by `helpers.bash`), so it now runs on the mac too — bats 1.13 / shellcheck 0.11 / jq
  are installed locally (the `feedback_test_on_node8_not_local` note predates them).
  These suites are node-8/local hand-run only, NOT a CI gate, so green CI does not
  imply they passed.

## Verification (the real gate)

Same shadow-proof procedure as PR #287/#414/#418. The job lands **`enabled: false`**,
so there is no scheduled-fire race; proof it, then enable. After merge + deploy:

1. `ssh root@40.160.32.80`; operate the cron by id via `openclaw --profile main cron …`
   (the default/legacy profile lacks write scope — `--token` does not bypass it).
2. `openclaw --profile main cron edit 03695380-8cee-4305-bedd-96dfbd3fbb18 --to C0B0A27QQKY`
   (shadow channel; `--to` sets the dest, not `--channel`).
3. `openclaw --profile main cron run 03695380-...` (enqueues async; `run` is a forced
   fire that works on a disabled job and does NOT validate scheduling). Poll
   `cron get … | jq .state` until `lastRunStatus` changes; expect `ok` +
   `lastDeliveryStatus: delivered`.
4. Eyeball the new glanceable digest in the shadow channel: line 1 has the emoji +
   `<N> convs` + the `P0/P1/P2` triplet, line 2 has the three scores, clean dimensions
   are collapsed, and no `@`-ping on a no-P0 run.
5. **Restore** `--to C0ANM0PN9L5`. Leave `enabled: false` for now.

### Enable (separate one-line PR, after the proof passes)

6. Flip `enabled: true` in `cron-jobs.json`; merge + deploy.
7. **Force a clean reschedule and verify** (the review confirmed `deploy.sh` carries
   live `state` forward by id and restarts the gateway, so a stale `nextRunAtMs` could
   otherwise pin the first fire to next Monday):
   `openclaw --profile main cron update 03695380-... --schedule '0 9 * * *' --tz Europe/Rome`,
   then `cron get … | jq '.state.nextRunAtMs, .enabled'` and confirm `nextRunAtMs`
   resolves to the next **daily** 09:00 Rome slot, not next Monday. (Because the job was
   disabled, `nextRunAtMs` was cleared, so enabling already recomputes from the daily
   expr — this step verifies rather than assumes.)

## Out of scope (note, don't build)

- **SP2 weekly KB roll-up** — separate spec. No weekly-mode plumbing added here.
- **Relocating the skill to `skills-all/`** — it is workspace-only today and that is
  the shipped state; not relitigated here (Rule 5 surgical).
- **Block Kit / structured Slack blocks** — `announce` delivers the assistant's text;
  glanceable improvements stay within mrkdwn.
- **Model / fallbacks / thinking / timeout** — unchanged (correct surgical scope).
  Cost note: cadence rises 7x (weekly → daily), but the per-run dataset shrinks from a
  200-capped weekly grade (~1166 candidates) to a ~20-30-conv ~30h window over fewer
  dimensions (A/B/D, no KB clustering), so per-run `gpt-5.5` high-thinking cost drops
  and net spend is well under a literal 7x. Accepted explicitly (per the PR #393
  precedent of treating per-cron model spend as tracked).
- **DST precision**: the "~6h overlap" is really `30h - prior-local-day-length`: 6h
  normally, 7h on the spring-forward (23h) day, 5h on the fall-back (25h) day. Minimum
  5h, never negative — no gap at either DST boundary. Do NOT lower `WINDOW_HOURS`
  toward 24h. (Documented in the `fetch-conversations.sh` window comment.)
- **SP2 window env is inline, not gateway-wide**: SP2's weekly job must run
  `CAROLINE_WINDOW_HOURS=168 scripts/...` inline at invocation, never set it in
  `/etc/openclaw/main.env` (a gateway-wide value would force both Caroline jobs to the
  same window). Recorded in `SKILL.md`'s env note.
- **Weekend suppression** — runs every day; quiet-day compaction keeps weekend posts
  to one line. A `1-5` schedule would need a 72h Monday window; not worth it.

## Rollout

PR (lands `enabled: false`) → QA-bot review (address findings, reply in-thread) →
human merge → Deploy HYDRA (cron-sync writes the daily, still-disabled entry to the
live store) → shadow proof-run (Verification steps 1-5) → **separate one-line PR**
flips `enabled: true` → deploy → force-reschedule + verify `nextRunAtMs` (step 7) →
the next 09:00 Rome fire posts the daily digest to `#cs_chats`. If the digest reads
poorly, disable via `openclaw --profile main cron disable 03695380-...` and iterate.

## Review outcome (2026-06-04)

Adversarial multi-dimension review (deploy mechanics, window/overlap, Dimension-C
drop, message format, tests, scope/risk) verified against the real code: **GO_WITH_FIXES**,
19 real findings, 2 blockers — both fixed above before any code was written:

1. **Blocker — `fetch-audit.sh` 7d journal window.** Was marked Unchanged; the leak
   audit (the #1 motivation for going daily) carries no per-leak timestamp, so a fixed
   7d window re-fires a stale leak as a fresh P0 daily for a week. Fixed: the audit
   `--since` now tracks `CAROLINE_WINDOW_HOURS` (30h default) in lockstep with the
   conversation fetch.
2. **Blocker — incomplete Dimension-C removal.** SKILL.md Phase 2 KB-clustering, the
   rubric P2 "KB gap cluster" token (outside Dimension C's own section), the KB
   headline column, KB section, and Auto-PR line were all still present. All struck;
   `cluster-questions.sh`/`open-kb-pr.sh` are now genuinely unreferenced by the daily
   path.

Should-fix items folded in: `enabled: false` rollout + reschedule verification (race +
stale `nextRunAtMs`); the `assert-digest-contract.sh` header guard (mechanical, per
`feedback_llm_instruction_insufficient`); `Tools skipped` token (not a dash); 15-16
digit conv-id citation + a `redact-output.bats` boundary guard; the cost note; DST
precision; SP2 inline-env precision; and the corrected test-plan framing (comment-rot,
not assertion breakage). Verified: 92/92 bats green, shellcheck clean.

## Addendum (2026-06-04): reasoning-leak / guard-health section (Dimension E)

Added to the same PR after a second design + multi-agent review pass. Reports the
PR #421 outbound reasoning-leak guard's health each morning from TWO independent,
never-conflated sources, so a guard *gap* (a leak that actually shipped) cannot hide
behind a quiet guard log.

- **Source 1 (guard-caught):** `fetch-audit.sh` extended to parse the edge
  `[intercom:reasoning-leak]` journal lines into `{kind:reasoning_leak, action, conv,
  reason, markers, sample}` (sample scrubbed). `preflight.sh` resolves
  `CAROLINE_REASONING_LEAK_SOURCE` (journalctl | syslog | none) and fetch-audit reads
  from it; a degraded source is surfaced, never silently skipped. `check-escalated.sh`
  GETs each ESCALATED conv (which is absent from the Caroline-authored fetch) to flag
  unanswered ones as action items.
- **Source 2 (guard-missed):** new `scan-shipped-leaks.sh` deterministically scans the
  redacted shipped Caroline replies for the guard's own INTERNAL+META_STRONG signatures,
  MIRRORED verbatim from `sanitize-reasoning-leak.ts` (META_WEAK excluded as too noisy
  context-free; apostrophes encoded `[\x27\x{2019}]` so no literal quote breaks the jq).
  A hit is a P0 (a leak reached a customer). A `scan-shipped-leaks.bats` drift sentinel +
  the CI bats-find widen (`pr-validate.yml`) fail if the mirror drifts from the guard.
- **Severity drives the headline** (Nick's call): source-2 hit = P0 (red + ping),
  unanswered escalation = P1, stripped/answered = silent FYI. The guard block is always
  present (healthy one-liner when zero) and `assert-digest-contract.sh` now requires it.
- `intercom_request` extracted to `scripts/lib/intercom-request.sh` (shared by
  fetch-conversations + check-escalated). Verified: 112/112 bats green, shellcheck clean.
