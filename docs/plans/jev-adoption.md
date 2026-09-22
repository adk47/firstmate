# Jev (TypeSafe System One) adoption plan for hydra

## Context

Jev is TypeSafe's System One model: one POST with `state` plus named questions, back come typed
answers with probabilities (Choice / Noul / Score), ~100 ms, $0.042 per million input tokens,
text only, 64k context. It selects, it never generates. Docs: https://docs.typesafe.ai
(skill `typesafe:typesafe-ai` is installed locally).

Eleven read-only scouts mapped every judgment hydra makes today: the Caroline turn, the twelve
support timers on node-8, all 33 openclaw crons (19 enabled), Jan's queues, dedup, permissions,
triage. The finding that shapes this plan:

- **Most approve/deny decisions are already deterministic code** (UVN under-30 rule, the
  credit-verification batch at 99.34% backtested precision, tier allowlists, reject/bulk-delete
  gates, the $500 wall, ClickUp priority). Those stay. Jev never replaces a coded gate.
- **The prose judgments cluster in customer support.** Caroline makes ~25 judgments per turn in
  prose, eight of them over closed label sets. The escalation judge in the Intercom plugin is
  already a JSON-shaped model call with an 8 s fail-open timeout. Twelve support timers decide by
  timestamps and email equality and lack any text judgment beside them.
- **The grader already exists.** `caroline-daily-review` scores refund-gate skips, action-type
  mismatches and sentiment every morning. Shadow answers logged per conversation turn it into a
  calibration report with no new harness.
- **Jan's work is queues** (UVN residual ~750–900/day by design, claiming sweep, merge tickets,
  CV escalations). Ordering and annotating those queues is the biggest human-time win, and it
  needs no new write path.
- **Three crons were retired on 2026-07-27 for codex token cost.** At Jev's price the
  classification parts can come back without touching the quota.

Sorting rule for the phases: (1) zero write risk and an existing grader, (2) Jan's queues,
(3) money, (4) re-enable retired classification, (5) long tail. Every surface goes through
shadow first; nothing flips on a guess.


## Standing rules (apply to every phase)

1. **Never replace a deterministic gate with a probability.** Jev adds a judgment beside a gate
   or replaces a prose judgment. List of untouchables at the end.
2. **Questions live in code, only data goes in `state`.** Customer messages, commit subjects,
   Sentry strings and ticket text are untrusted; the docs list adversarial content as a Jev
   weakness. Same posture as `release-watch.sh` highlights.
3. **Shadow before act.** Each surface logs Jev's answer next to the decision actually taken for
   at least 7 days and a minimum item count before any threshold is set.
4. **Bands, not booleans.** Each surface ends with three bands (act / ask / escalate) set from its
   own agreement rate. Bands are config, changed by PR.
5. **Fail soft, say so.** Jev unreachable or over budget = the surface behaves exactly as today
   and writes one WARN line. No retries inside a customer turn.
6. **Secrets never in the repo.** The client goes through OpenRouter's decisions endpoint by
   default (`OPENROUTER_API_KEY`, 32k context, endpoint labelled alpha), TypeSafe-direct is
   still selectable via `JEV_PROVIDER=typesafe` (`TYPESAFE_API_KEY`, 64k context). Both keys
   live in `/etc/hydra/jev.env`, loaded by systemd env files and `plugin-env.sh`, same pattern
   as `releases.env`.
7. **Every judgment is logged with its state hash, answer, probabilities, usage and latency.**
   "Never render a probability without its source" (same doctrine as `cq_format_evidence`).

## Phase 0 — Foundation (one PR, no behavior change)

Goal: one client, one log format, one report, vendor prerequisites settled.

- **Vendor gates (Nick/Aaron):** API key issued; confirm the DPA covers customer text (Intercom
  content already reaches OpenRouter, so no new exposure class, but a new processor); note
  zero-data-retention is enterprise-only per https://docs.typesafe.ai/legal.md.
- **`scripts/lib/jev.sh`** (decision-tree item 8: helper, agent + human callable): a curl wrapper.
  `JEV_PROVIDER` (default `openrouter`) picks the endpoint, model, and key variable:
  `openrouter` → OpenRouter's decisions endpoint (alpha), `~typesafe/jev-latest`,
  `OPENROUTER_API_KEY`, 32k context; `typesafe` → TypeSafe direct, `jev-latest`,
  `TYPESAFE_API_KEY`, 64k context. `JEV_API_URL`/`JEV_MODEL`/`--model` override the provider
  default when set. Also reads `JEV_TIMEOUT_MS` (default 1500),
  `JEV_SHADOW_DIR` (default `/var/lib/hydra-jev/shadow`, under `/var/lib` because the deploy
  rsync overwrites `/opt/hydra`). Takes `--surface <name>`, `--item-id <id>`,
  `--state-file <json>`, `--questions-file <json>`. Prints the `answers` object on stdout,
  humans on stderr, rc 0 ok / 2 unreachable-or-timeout / 3 malformed reply. Caps state at a
  configurable byte size and refuses above it (rc 4) rather than truncating silently.
- **Shadow log line** (JSONL, one per call):
  `{ts, surface, item_id, state_sha256, model, questions_sha256, answers, usage, latency_ms,
  actual: <what the existing code decided>, rc}`. `actual` is filled by the caller.
- **`scripts/jev-shadow-report.sh`**: per surface, per question, agreement between Jev's top
  answer and `actual`, bucketed by probability (0.5–0.6 … 0.9–1.0), plus item count and p50/p95
  latency. Prints a table; nothing is posted anywhere in Phase 0.
- **`plugins/intercom/src/jev-client.ts`**: minimal TS equivalent (fetch, timeout, same log
  shape written through the plugin's existing log path). Not shared with support-tools yet
  (DRY rule: abstract on the third use, not the first).
- **Tests:** bats for `jev.sh` with a stubbed curl (ok / timeout / malformed / oversize state);
  vitest for the TS client. Run in CI like the rest of `scripts/tests/`.
- **Docs:** `docs/lessons/openclaw-and-codex.md` gets a short "Jev" section (what it is not for,
  the untrusted-state rule, where the key lives).

Done when: `jev.sh` round-trips one Noul against the live API from node-8, the shadow file
appears under `/var/lib/hydra-jev/shadow/`, and the report script prints a table from it.

## Phase 1 — Caroline pre-turn router (acting, not shadow)

Design contract: `docs/designs/2026-09-22-jev-caroline-router.md`. Direction from Nick,
2026-09-22: no shadow mode; Jev must know what Caroline can do, classify the request and tell
her which tools and skills to use; backtest on real conversations before it ships.

- One Jev call per turn over `{message, last_parts, turn_count, known_facts}` with six
  questions generated from Caroline's inventory (`scripts/gen-caroline-inventory.sh` →
  `plugins/intercom/src/caroline-inventory.json` + `caroline-questions.json`, CI-checked):
  `resolution_path` {caroline_tool, ask_customer, human_required, no_reply}, `intent` (11 router
  intents + other), `first_tool`, `skill`, `off_topic_or_bad_faith`, `frustration`.
- The plugin acts on three answers itself: bad faith above band → one decline, then silence;
  bare closer above band → silence; human_required above band → the existing escalation path
  with the intent's action type. Everything else becomes a `[ROUTING]` block in her prompt
  (path, intent, first tool, skill, each with its probability), which AGENTS.md tells her to
  follow unless a tool result contradicts it.
- The dead OpenRouter judge (never wired: no key in config, `reason=disabled` on every turn)
  is replaced by the same call.
- Every turn logs one `[intercom:jev]` line and one row in
  `/var/lib/hydra-jev/shadow/caroline.jsonl`; `jev-shadow-report.sh --surface caroline` and
  the daily review's Dimension B grade it continuously.
- Bands are set by `scripts/jev-backtest-caroline.sh` on ~60 real conversations from the
  last 14 days with journal and trajectory-log labels (tool actually called, ticket action
  type, rule/user escalations, closers, the 2026-09-20 troll), choosing the smallest threshold
  with zero false positives on the labelled set.
- **Backtested on 202 real turns before shipping** (2026-09-22, report in the design doc): the
  routing block and the bad-faith decline ship ON; `silence` and `escalate` ship OFF behind
  per-branch flags because no threshold reached zero false positives on real customers waiting
  for an answer, and because the customers who asked for a person outright scored a median of
  0.39 (the keyword rule already catches them). Turning those two on needs a hand-labelled set
  of opening messages: Phase 1b.
- Not in this phase: the post-turn honesty Noul (moves to Phase 3).

## Phase 2 — Timers and read-only crons, shadow (support + devops, zero write risk)

**2a. Support timers: add the text judgment beside the timestamp gate.**
- `scripts/cs-needs-human-digest.py`, `close-resolved-conversations.py`, `resolve-notify.py`:
  Noul `last_customer_message_is_closer` over the last customer part. Shadow only; `actual` =
  the bucket the script chose. Customer-last threads that are really done are the target.
- `scripts/close-duplicate-conversations.py`: Noul `same_request` over the two threads'
  first customer messages, per candidate group. `actual` = tier A/B/skip.
- `scripts/resolution-matcher.py`: Noul `row_fixes_reported_issue` over `{customer report,
  action_log row}` for each would-act pair. `actual` = matched/not.
All three scripts already have dry-run / shadow modes and write to `/var/log/*-shadow.jsonl`;
the Jev line goes to the Phase 0 shadow dir keyed by conversation id.

**2b. Support email triage.** `workspaces/operations/skills/muso-support-email-triage/SKILL.md`
runs hourly on gpt-5.6-sol over ≤25 threads with a ~15-category prose rubric. Add a
deterministic pre-pass in the fetch script: Choice `owner` {caroline, human, spam} and Choice
`category` over the rubric's categories. Shadow: `actual` = the verdict in `verdicts.json`.

**2c. Prod-alert severity.** `scripts/prod-log-alert-watchdog.sh` lines ~873–1008 make one
OpenRouter call per digest with a closed list {P0, P1, P2, mute} and a "never round up" rule;
the deterministic persistence gate (≥300 s active, blast radius, burst) stays authoritative and
the model can only downgrade. Add Choice `severity` with the same four labels over the same
evidence fields (`minutes_active`, `occurrences`, `deployments`, `repeat_offender`, sample).
Shadow `actual` = OpenRouter verdict.

**2d. Sentry class.** `skills-all/sentry-issue-triage/SKILL.md` five-class rubric
(code-fixable / config-or-infra / capacity-or-data / client-noise / needs-human). Choice over the
five, written into the ledger `/var/lib/hydra-sentry-triage/seen.jsonl` as `jev_class` next to
the agent's `class`. Low volume (1–2/week); cheap to carry.

Done when: each surface has ≥7 days shadow and its own row in the report.

## Phase 3 — First flips (support)

Flip only surfaces whose act-band agreement meets or beats the current baseline in the report,
one PR per surface, bands in config.

1. **Judge swap.** `judge.ts` calls Jev instead of OpenRouter; timeout drops from 8 s to
   1.5 s; on rc≠0 behave exactly as today's null path. `shouldHandoff = needs_human ≥ band`.
   `suggestedActionType = action_type.choice` only when its confidence ≥ band, else omitted.
2. **Router intent pre-fill.** The pre-turn `router_intent` is injected into the turn context
   as a hint ("classifier suggests: X, p=0.91"). Caroline still calls `support_action_router`
   herself; the hint removes the self-naming failure without changing the router.
3. **Refund-flow activation.** When `refund_flow.retention ≥ band`, the turn context carries the
   refund-retention skill activation line so the 3-gate cannot be skipped.
4. **Email triage pre-sort.** The digest is rendered from Jev's verdict where confidence ≥ band;
   the LLM pass runs only on the ask band. Cuts an hourly gpt-5.6 call to a fraction.
5. **Prod-alert severity.** Replace the OpenRouter call; keep the deterministic corroboration
   gate and the downgrade-only rule unchanged.

Not flipped in this phase: the closer / duplicate / resolution Nouls (they change what a
customer sees; they flip in Phase 5 after a second shadow window with the Phase 3 changes live).

## Phase 4 — Ops queues and money (the agent decides; Jan gets only the residual)

Direction from Nick, 2026-09-17: Jan must not be the decider. The agent (ops or Caroline)
acts on Jev's classification; Jan handles only what Jev classifies as needing a human or what
a hard rule forces to a person. Each queue ends with three bands set from its own shadow week:
**act** = the agent executes through the existing write path, readback and breaker; **ask** =
the agent asks the customer for evidence (never Jan); **escalate** = the only band Jan sees.
Bands start at the zero-reversal threshold the shadow week measured and widen while the
reversal rate stays at zero. The goal is Jan's share of every queue falling, not better labels
on the same queue.

**4a. UVN residual.** `scripts/uvn-under30-cron.py` already lists every UVN row it did
not approve with a reason line per row and writes `approve_verified` / `reversal_observed` audit
records. Add Score `evidence_strength` per residual row over `{role claimed, track metadata,
profile.creditCount, profile.popularity, approvedCredits by role, rule_risk_percent}` Act band: the cron
approves the row itself through the same `PUT /admin/credit-requests` + readback +
`ReversalCircuitOpen` breaker it already has. Ask band: the agent posts an evidence request to
the customer and the row stays in `user_verification_needed`. There is no reject band: the
backend has no path back from `rejected` (2026-07-22), so "not enough evidence" is always an
ask. Escalate band only reaches Jan. Reversal records are the label; the act band widens while
reversals stay at zero.

**4b. Claiming recommendation.** `skills-all/muso-ops-claiming/SKILL.md` step 7 is the one
prose line ("Recommendation: APPROVE") in an otherwise coded flow (seven fraud flags, same-team
duplicate rule, contested-claim rule stay authoritative). Replace the line with Choice
`recommendation` {approve, reject, escalate} plus probability computed from the already-extracted
fields (IPIs, credit counts, industry-credit %, link name-match, ID-doc verified, flags).
Act band: the agent runs `muso claiming verify`
itself. Ask band: the agent requests links or ID. Escalate band and the hard rules (2+ fraud
flags, contested profile, same-team duplicate) are the only things Jan sees.

**4c. Profile dedup pairs.** `scripts/dedup/score-pair.sh` emits hard_dupe / candidate_dupe /
soft_partial / no_match and logs to `/var/log/dedup-shadow.jsonl`. Add Score `same_entity`
(leave unlinked / curator queue / assert same, per the TypeSafe Entity Alignment cookbook) over
`{names, knownAsNames, raw_ids, ipis, credit counts, shared track count, claim state}`. Backtest
against the 258 real merges used on 2026-05-20 (baseline 20.2% recall; 62% of misses are
stage-name vs legal-name). Act band: the agent runs the merge with the score as its evidence, through
the existing reverse-direction guard, pre-state capture and landing watchdog. Letting a Jev band
count as the Tier-2 approval source is a policy change Nick and Aaron co-own
(`tier2-approvers`); the backtest is the case for it, and until it lands the agent files the
ticket pre-approved so Jan's step is one click.

**4d. CV escalations to Jan.** When the batch routes "UNVERIFIABLE — NEEDS REVIEW" to Jan with
gathered evidence, add one Noul per evidence source: `source_supports_claim` over
`{claim, source excerpt}` (citation-check cookbook). Sources agree above the band: the agent approves
through the existing evidence gate (`enforce_credit_approve_gate` unchanged, the Nouls are
extra evidence lines, not a bypass). Sources disagree: the agent asks the customer. Only a
contradiction between strong sources reaches Jan.

**4e. Stripe disputes.** `skills-all/muso-stripe-disputes/SKILL.md` lines ~196–240: daily
FIGHT / ACCEPT / BORDERLINE with strength, from activity counts, dates, card/address match.
Choice `verdict` + Score `strength` over those fields, shadow against the agent's call, then
label with dispute outcomes (won/lost) as they close. Money on every item; flip when the
outcome-labelled agreement beats the agent.

**4f. Company finder tiering.** `scripts/company-finder/finalize-batch.sh` tiers survivors with
undocumented logic. Write the tier rubric down first, then Score. Spec before code.

## Phase 5 — Customer-visible timer flips and retired crons

- **Closer / duplicate / resolution Nouls** flip by band, each behind its script's existing
  ceiling and de-confliction guards; the closer Noul only ever moves a thread from
  "needs-human" to "closable", never the reverse.
- **B2B reply scanner** (`cron-jobs.json` `b2b-reply-scanner-hourly`, disabled 2026-07-27 for
  token cost): the 11-way reply classification comes back as a Jev Choice in the fetch script;
  only replies in the "answer" band reach an LLM for drafting.
- **api-change-watch / daily-pr-review** (disabled): Choice over the documented change classes
  as a cheap daily pass that posts only when a class fires with confidence ≥ band.
- **Daily review sentiment**: Dimension D uses an explicit-frustration regex today; replace with
  the Phase 1 Score already logged per conversation.

## Phase 6 — CI/CD (route and triage around the QA bot; never replace a check)

The eight deterministic checks (bats, vitest, shellcheck, py_compile, watchdog tests, deploy
pre-flight, pr-title, validate) finish in minutes and stay exactly as they are. The slow, flaky
part is the LLM review: PR #970 took five rounds on 2026-09-17/21 and three attempts died for
reasons unrelated to the code. Jev cannot do the review (its docs list multi-step reasoning and
large noisy state as weaknesses), but it can decide what the review should be and what to do
with its output.

**Prerequisites, not Jev (do these first, they buy more minutes than anything below):**
- The `adk47` bot account exhausts GitHub's 5,000/h limit every hour (`qa-review-reconcile`
  ticks scan 21–76 repos). Reviews only succeed right after a reset. Scope or pace the
  reconciler; until then re-fire a review with `gh run rerun <PR Validation run id>`.
- `codex app-server client closed before turn completed` on the main gateway (10/h after the
  2026-09-17 17:05Z restart, zero on edge, guards clean, no watchdog rule) killed two reviews
  mid-turn. Add the signature to the codex-health watchdog.

**6a. Review-depth routing.** In `scripts/qa-dispatch-pr-review.sh` before the one-shot cron is
created: Choice `review_depth` over {docs-only, tests-only, scripts, plugin-runtime,
config-or-gates} from `{changed file list, commit subjects, diff stat}` (subjects are
author-controlled: data in state, never instructions). docs-only and tests-only above the band
get a short check and keep the existing approval; everything else gets the full eight-lens
review. Shadow: log the Choice next to the tier the bot's blast-radius analyzer assigned.
Removes whole review rounds (a one-line plan edit today costs a full review and a fresh
approval cycle).

**6b. Finding triage.** Over each posted finding: Noul `has_concrete_evidence` ("cites a file,
a line, and a reproduction or command output") and Score `severity` on the bot's own scale.
Shadow against the bot's label and against what the author accepted; findings below the
evidence band are folded into a single "unverified" line instead of blocking. All seven
findings on #970 were real, so the target is consistency, not volume.

**6c. Infra-vs-code failure triage.** A oneshot (registered in `AUX_ONFAILURE_UNITS`, never a
hardcoded OnFailure) over a failed job's log tail on an open PR: Noul `infra_failure` ("rate
limit, runner offline, network, timeout, not the change"). Above the band: one automatic
re-run, once per head sha; below it: page. Never re-runs a job that failed on an assertion.

**6d. Release highlights.** `scripts/release-watch.sh` already makes a tool-less model call
over commit subjects. Replace with Choice `audience` {user-facing, internal} per commit plus
the existing bounded rendering; same untrusted-input posture, cheaper, logged.

**6e. Drift halt annotation.** The Step 0 skills-drift halt in `scripts/deploy.sh` stays
deterministic. Beside it, Noul `removes_safety_rule` over the sync diff ("this drift deletes a
rule, gate, or never-clause that the repo version carries") — the 2026-09-16 case where a
workshop rewrite dropped five merge-safety rules and was waved through. Above the band the
halt message names the removed rules; the halt itself is unchanged.

Order: prerequisites, 6a, 6c, 6b, 6d, 6e. Each goes through the same shadow-then-band path as
every other phase.

## Untouchables (never a Jev call)

Tier membership and allowlists; Slack-ID → person resolution; credit reject gate; bulk
destructive gate; refund > $500 wall; prompt-injection canary escalation path; UVN under-30
approval rule; credit-verification batch verdicts (`score-backend-signals.sh`,
`verdict-engine.sh`, Tier-0 recompute gate); ClickUp priority map; the "verified owner" check
(Intercom author metadata, not a judgment); merge direction guard.

## Verification

- **Phase 0:** `bats scripts/tests/jev.bats` (stubbed curl); `pnpm test` in
  `plugins/intercom`; on node-8 `scripts/lib/jev.sh --surface smoke ...` returns rc 0 and a
  line lands in `/var/lib/hydra-jev/shadow/smoke.jsonl`; `jev-shadow-report.sh` prints it.
- **Phases 1–2:** deploy via the normal PR → `main` → deploy path (Step 0 drift halt applies;
  `.deployed-sha` is the proof). Confirm with `grep -c '"surface":"caroline"'` on the shadow
  file after one day, and the daily review post carrying the agreement table.
- **Each flip:** the surface's report row for the 7 days before the flip is attached to the PR;
  after the flip, the same row for 7 days; the daily review Dimension B/D counts must not
  regress; `caroline-behavior-digest.py` reopen count is the customer-visible regression alarm
  for Phase 5.
- **Rollback:** every flip is a config band; setting the act band to 1.01 restores today's
  behavior without a deploy of code.
