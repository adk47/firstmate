# Jev pre-turn router for Caroline (Phase 1 of docs/plans/jev-adoption.md)

Status: design contract for PR (2026-09-22). Owner: Nick. Direction: **acting, not shadow.**

## What this does

Before every Caroline turn, one Jev call classifies the customer message against Caroline's
real capabilities and tells her which path, intent, first tool and skill apply. The plugin acts
on three of the answers itself (silence on bad faith, silence on a bare closer, escalation when
no tool path exists) and injects the rest into Caroline's prompt as a `[ROUTING]` block she is
instructed to follow. The dead OpenRouter judge is replaced by the same call.

Every answer is logged with its probability so the bands can be tuned from real data; nothing
about this is a shadow mode.

## Why (from the scouts, 2026-09-22)

- Caroline makes ~25 judgments per turn in prose; eight have closed label sets. The escalation
  judge has never run in production: `channels.intercom.accounts.default.riskAssessment` has
  no `openrouterApiKey`, so `buildRiskOptions` (channel.ts ~978) yields `judge: undefined` and
  the new log line reads `outcome=skipped reason=disabled` on every turn.
- A context-free "needs a human?" scored 0.62 on "my credits are still not approved" — a
  request Caroline resolves with `credit_verification_check` → `credits_verify`. With her
  tool inventory in the question the same message scored caroline_tool 0.85 / human 0.00 and
  first tool `credit_verification_check` 0.88 (live, 2026-09-22).
- Conversation 215476013943381 (2026-09-20): 13 replies to a troll in 9 minutes, ending in a
  human ticket. Bad faith scored 0.07 for a real request; it must score high there.

## Components and owners

### A. Inventory + question generator (scripts, generated JSON)

`scripts/gen-caroline-inventory.sh` (bash + jq/python, deterministic) writes two checked-in
files, and `scripts/check-caroline-inventory.sh` (CI gate, like other `check-*.sh`) regenerates
to a temp dir and fails on any diff:

- `plugins/intercom/src/caroline-inventory.json`
  ```json
  {"generated_from": {"tools": "plugins/support-tools/src/tools/*.ts + workspaces/support/TOOLS.md",
                      "skills": "workspaces/support/skills/*/SKILL.md",
                      "intents": "plugins/support-tools/src/tools/support-action-router.ts"},
   "tools":   [{"name":"credit_verification_check","kind":"read|write|handoff|reference",
                "resolves":"one sentence","requires":"one sentence"}],
   "skills":  [{"name":"customer-credit-verification","activates_when":"one sentence",
                "tools_used":["..."],"outcome":"one sentence"}],
   "intents": [{"intent":"credit_verification","description":"one sentence",
                "first_read_tool":"credit_verification_check","write_tools":["credits_verify"],
                "handoff_when":"one sentence","action_type_on_handoff":"credit-verify"}],
   "human_required": ["identity or ownership cannot be verified", "cross-owner conflict",
                      "refund request", "account deletion / GDPR erasure", "profile deletion or unmerge",
                      "policy exception or waiver", "role-based bulk credit change",
                      "chargeback, fraud or account takeover", "duplicate or post-cancel charge",
                      "founding-member free reinstatement", "on-behalf or cross-account request"],
   "no_reply":       ["bare closer after Caroline already acknowledged once",
                      "third or later identical message"]}
  ```
  Tool names come from the code (`plugins/support-tools/src/tools/*.ts` registered names);
  `resolves`/`requires` sentences from `workspaces/support/TOOLS.md`; a tool in code but not
  in TOOLS.md (today: `company-finder-batch`) is listed with `resolves: "undocumented"` and the
  check script WARNS. Skills from each SKILL.md frontmatter/first paragraph. Intents from the
  router's `SUPPORT_ACTION_ROUTES` table.
- `plugins/intercom/src/caroline-questions.json` — the exact Jev `questions` object built from
  the inventory (this is the single source for the plugin AND the backtest):
  - `resolution_path` Choice: `caroline_tool` (criteria text = "Caroline resolves it herself
    with: " + every tool name + resolves, and every skill name + activates_when),
    `ask_customer` ("one missing fact or piece of evidence before a tool can act: profile link,
    track list, order number, screenshot of the credit"), `human_required` (criteria = the
    `human_required` list joined), `no_reply` (criteria = the `no_reply` list joined).
  - `intent` Choice over the 11 intents + `other` (criteria = descriptions).
  - `first_tool` Choice over every `read` tool + `create_ticket` + `none` (criteria = resolves).
  - `skill` Choice over every skill + `none` (criteria = activates_when).
  - `off_topic_or_bad_faith` Noul: "unrelated to the customer's own Muso account or support
    need, or clearly not a good-faith request (jokes, essays, tests, insults, spam)".
  - `frustration` Score ["Calm","Concerned","Frustrated","Angry"].
  Instructions for every question start with: "Caroline is Muso's support agent. Judge the
  customer's LAST message in the context of the conversation."
- bats: generator is deterministic (two runs identical), check script fails on a mutated JSON,
  every registered tool name appears exactly once, every skill dir appears, the 11 intents
  appear, the questions file's criteria keys equal the inventory names.

### B. Plugin (plugins/intercom)

- `src/jev-client.ts`: `callJev({apiKey, model, timeoutMs, state, questions, fetchImpl})` →
  POST `https://openrouter.ai/api/alpha/decisions` body `{model, state, questions}`; returns
  `answers` or `null` on timeout / non-2xx / missing `.answers` (never throws; one
  `log.warn("[intercom:jev] ... rc=fail reason=...")`). Model default `typesafe/jev-1.13`.
- `src/jev-router.ts`:
  - `buildJevState(input)`: `{message, last_parts: ≤10 trimmed (author, text ≤500 chars),
    turn_count, known_facts: {founding, plan, subscription_status, prior_chats} when present}`.
    Customer text is data only; questions are the checked-in JSON, never built from input.
  - `decide(answers, bands, state) → {action: "route"|"decline"|"silence"|"escalate"|"none",
    block: string|null, escalation?: RiskAssessment}`:
    - `off_topic_or_bad_faith ≥ bands.bad_faith`: first time in this conversation →
      `decline` (block: "decline in one sentence, do not offer help, no ticket"; set
      `state.jev.badFaithDeclinedAt`); afterwards → `silence`.
    - `resolution_path.no_reply ≥ bands.no_reply` and `turn_count > 1` → `silence`.
    - `resolution_path.human_required ≥ bands.human_required` → `escalate` with a
      `RiskAssessment{triggered:true, source:"judge", reason:"jev:human_required",
      suggestedActionType: intents[intent].action_type_on_handoff ?? "support-general",
      confidence: p≥0.9?"high":"medium"}` so `executeEscalation` runs unchanged.
    - otherwise → `route` with block:
      ```
      [ROUTING]
      path: caroline_tool (0.85)
      intent: credit_verification (0.91)
      first_tool: credit_verification_check (0.88)
      skill: customer-credit-verification (0.86)
      Follow this routing unless a tool result contradicts it. path=caroline_tool means: use
      the tool, do not create a ticket. path=ask_customer means: ask for exactly the one
      missing item, nothing else.
      [/ROUTING]
      ```
      (`frustration` is never a routing input; it is logged only.)
  - `renderJevBlock` is appended in `buildAgentRawBody` (channel.ts ~912) right before
    `[CUSTOMER_MESSAGE]`, same wrapping style as `[KNOWLEDGE_BASE]`.
- Wiring in `handler.ts` after the enrichment/KB `Promise.all` (~300–319): call Jev (bounded
  by `timeoutMs`, default 1500), run `decide`, then: `silence` → return the no-dispatch path
  (post nothing, keep the 👀 ack, `log.info("[intercom:jev] ... action=silence")`);
  `escalate` → hand the RiskAssessment to the existing escalation flow (handler ~249–257);
  `route`/`decline` → store `state.jev = {answers, action, block}` for the raw-body render;
  `none`/Jev failure → proceed exactly as today.
- Replace the judge: in `buildRiskOptions`, when `account.jev.enabled`, `judge` is a Jev-backed
  function returning `JudgeOutput{shouldHandoff, reasons:["human_required"], suggestedActionType,
  confidence}` from the same answers (the pre-turn call is reused, no second request). The
  OpenRouter judge remains for accounts without `jev`.
- One journal line per turn:
  `[intercom:jev] conv=<id> action=<route|decline|silence|escalate|none> path=<x>:<p>
  intent=<x>:<p> tool=<x>:<p> skill=<x>:<p> bad_faith=<p> human=<p> frustration=<label>:<p>
  ms=<n>` — never message text. Plus one JSONL row appended to
  `/var/lib/hydra-jev/shadow/caroline.jsonl` in the jev.sh shadow-line shape (`surface:
  "caroline"`, `provider:"openrouter"`, `answers`, `actual`: the action taken) so
  `scripts/jev-shadow-report.sh --surface caroline` works unchanged. Writing the row is
  best-effort.
- Config (`config.ts`): `account.jev = {enabled: boolean, apiKey: secret-ref, model?: string,
  timeoutMs?: number, bands: {bad_faith: number, no_reply: number, human_required: number}}`.
  Validation: bands in [0,1]; missing `apiKey` with `enabled: true` → plugin start error
  (fail loud, like a missing token).
- Tests (vitest): client (timeout → null, 500 → null, missing answers → null, success shape);
  router (state builder trims and never includes questions text from input; each `decide`
  branch; block rendering exact; bands boundary); handler integration (block reaches the raw
  body; silence skips dispatch and posts nothing; escalate calls the escalation path with the
  mapped action type; Jev failure leaves the turn byte-identical to today); risk options
  (judge is Jev-backed when configured).

### C. Backtest (scripts, node-8, read-only on Intercom)

`scripts/jev-backtest-caroline.sh [--days 14] [--limit 60] [--out DIR]` (bash + embedded
python, like `jev-shadow-report.sh`), run on node-8 with `MUSOAI_INTERCOM_TOKEN` from
`/etc/openclaw/edge.env` and `OPENROUTER_API_KEY` from `/etc/hydra/jev.env`:

1. Sample conversations from the last N days by outcome, using the edge journal and the
   trajectory log the self-serve collector reads: (a) conversations where Caroline called a
   read/write tool (label: first tool actually called, and the `create_ticket` actionType if
   any → intent via `action_type_on_handoff`); (b) `ESCALATED source=rule` with reason
   dispute/chargeback/legal/deletion and all `source=user_request` (label: human_required);
   (c) closed with no ticket and no tool call whose last customer message is a closer
   (label: no_reply on that last message); (d) conversation 215476013943381 (label: bad
   faith from message 4 on). Target ~60, at least 5 per cohort where available.
2. For each conversation, replay turn by turn: state = the customer message + prior parts,
   questions = `plugins/intercom/src/caroline-questions.json`, call through
   `scripts/lib/jev.sh --surface backtest --no-shadow` (same wire path as production).
3. Report (stdout table + `<out>/report.md`): per question, agreement with the label and the
   probability distribution; per cohort, the confusion of `resolution_path`; the troll
   conversation's `off_topic_or_bad_faith` per message; recommended bands = the smallest
   threshold with zero false positives on the labelled set for `bad_faith`, `no_reply`,
   `human_required`. Store per-turn rows redacted with the daily review's
   `redact-core.sed` under `/var/lib/caroline-backtest/`, never message text in the repo.
4. bats with stubbed curl (Intercom) and a stubbed jev.sh: sampling by cohort, label
   extraction from fixture journal lines, agreement math, band recommendation.

### D. Config, secret, doctrine (orchestrator)

- `openclaw-edge.json`: `channels.intercom.accounts.default.jev` block with the bands the
  backtest recommends (fallbacks if the backtest cannot set one: bad_faith 0.85, no_reply
  0.85, human_required 0.80), `apiKey: {source:"env", provider:"hydra-env",
  id:"OPENROUTER_API_KEY"}`, and `OPENROUTER_API_KEY` added to
  `secrets.providers.hydra-env.allowlist`.
- node-8: `OPENROUTER_API_KEY=` appended to `/etc/openclaw/edge.env` (per-profile file, never
  shared.env), value copied server-side from `/etc/hydra/jev.env`. Deploy's
  `verify_plugin_env_for_profile` then passes.
- `workspaces/support/AGENTS.md` (+ one paragraph in SOUL.md "Ground before you answer"): the
  `[ROUTING]` block contract — follow it unless a tool result contradicts it; caroline_tool
  means no ticket; ask_customer means one question; the block never overrides the honesty
  rules or the identity gate. No em-dashes (customer-facing surface lint).
- `docs/plans/jev-adoption.md` Phase 1: rewritten from "shadow" to this design; Phase 3's
  judge swap and refund-activation items fold in here.

## Backtest result (2026-09-22, 202 turns / 30 real conversations, last 14 days)

Run on node-8 through the deployed `scripts/lib/jev.sh` (same wire path as production) with the
generated question set. Labels from the edge journal and the support agent's trajectory log.
Raw rows stay on node-8 under `/var/lib/caroline-backtest/` (redacted); no customer text in the
repo.

# Jev Caroline backtest report

rows: 202 (malformed skipped: 0)

## Per-question agreement
- resolution_path: 57.7% (n=26)
- first_tool: 39.1% (n=23)
- intent: 62.5% (n=16)
- off_topic_or_bad_faith: 97.5% (n=202)

## resolution_path confusion per cohort
- cohort a:
  - expected=caroline_tool: ask_customer=7, caroline_tool=14, human_required=2
- cohort b:
  - expected=human_required: caroline_tool=1, human_required=1, no_reply=1

## Troll conversation (215476013943381) off_topic_or_bad_faith per message
- turn 1: p=0.17 label=False
- turn 2: p=0.85 label=False
- turn 3: p=0.17 label=False
- turn 4: p=0.10 label=True
- turn 5: p=0.75 label=True
- turn 6: p=0.88 label=True
- turn 7: p=0.87 label=True
- turn 8: p=0.54 label=True
- turn 9: p=0.94 label=True
- turn 10: p=0.93 label=True
- turn 11: p=0.93 label=True
- turn 12: p=0.89 label=True
- turn 13: p=0.92 label=True
- turn 14: p=0.93 label=True

## Recommended bands (script output, then corrected by hand — see below)
- bad_faith: 0.95 (fp=0, recall=0.0%) — NOT what ships; the script sweeps in 0.05 steps
  and skipped the band that is both safe and effective. Hand sweep at 0.01 steps:

  | band | true pos | false pos | recall |
  |---|---|---|---|
  | 0.90 | 5 | **1** | 45% |
  | **0.92 (ships)** | 5 | 0 | 45% |
  | 0.93 | 4 | 0 | 36% |
  | 0.95 (script) | 0 | 0 | 0% |
- no_reply: no threshold in 0.5-0.95 achieves zero false positives (best fp=3 at 0.95); recommend manual review
- human_required: no threshold in 0.5-0.95 achieves zero false positives (best fp=2 at 0.95); recommend manual review
- no_reply (closer-guard restricted): no threshold in 0.5-0.95 achieves zero false positives (best fp=1 at 0.95); recommend manual review

## no_reply false positives (p>=0.6, message has '?' or >8 words)
- 10 of them. Two that decide the branch: a customer asking "…got some news ?" at 0.97 and
  one asking about an unexpected charge at 0.93. Snippets are customer text and stay on node-8
  (`/var/lib/caroline-backtest/rows.jsonl`, redacted).
## user_request turns: Jev human_required p distribution
- n=6 min=0.06 median=0.39 max=0.73

### What ships, and what does not

- **`decline` (bad faith): ON at band 0.92.** 97.5% agreement over 202 turns and, at 0.92,
  zero false positives on real customer messages; on the 2026-09-20 troll it climbs from 0.16
  on the opening message to 0.94 once the asks turn into essays and vowel substitution.

  **0.90 was the original band and is disproven.** A real customer opening with "I am the sole
  legal owner and proprietor of the registered entity …" (conversation 215475985153553, a
  cohort-b fraud complaint) scores exactly 0.90, and the comparison is `>=`, so the shipped
  config would have declined a person asserting legal ownership — no help, no ticket. The
  score is stable, not noise: two independent full runs (2026-09-22 15:28 and 15:33) both put
  it at 0.90 to two decimals. 0.92 costs nothing — the same five troll turns still fire — and
  leaves two ticks of margin from the nearest known false positive.

  The FIRST run reported zero false positives at 0.90 only because that turn's Jev call
  returned no answer and the row was silently dropped from the sweep (n=201 rather than 202).
  That is the same fail-open shape as the sampling defect fixed in this PR: a row the
  backtest could not measure must count as unmeasured, never as agreement.
- **`silence` (no_reply): OFF.** No threshold in 0.50-0.95 reaches zero false positives, even
  behind the deterministic closer guard. The failures are customers waiting for an answer, and
  silencing one of those costs more than every token the branch would save.
- **`escalate` (human_required): OFF.** Same reason, and the six customers who asked for a
  person outright scored a median of 0.39, so the existing keyword rule is the better detector.
  That rule is untouched and still escalates them.
- **Routing block: ON for every turn.** `path`, `intent`, `first_tool` and `skill` reach Caroline
  on every message, which is the part of Phase 1 the evidence supports and the part that changes
  what customers get.

`resolution_path` (58%) and `first_tool` (39%) agreement are not a verdict on the classifier:
only 25 turns carry a label, and the label is "which tool Caroline happened to call first in
that conversation", a weak proxy for what the opening message asked for. Hand-checked probes on
eight known-shape messages were correct on all eight. Re-labelling (a human pass over ~60 opening
messages) is the prerequisite for turning `silence` and `escalate` on, and is Phase 1b.

## Phase 1b: hand-labelled result (2026-09-22)

The cohort labels above are proxies ("which tool Caroline called first"), so
they cannot set a safe band for `silence` or `escalate`. Phase 1b labels by
hand, with context. Only turns Jev scores HIGH can become false positives at a
strict band, so the labelled set is every turn in the 15:33 run with
`no_reply >= 0.60` or `human_required >= 0.50`: **47 turns across 23
conversations**, each read with Caroline's message before it and her reply
after it. Labels: *no_reply is right* = the message needs no answer at all;
*human_required is right* = Caroline has no tool path and a person must act.
Raw set, redacted: node-8 `/var/lib/caroline-backtest-v3/label-set.json`.

**`silence` stays OFF.** Of the 28 turns scoring `no_reply >= 0.60`, 15 were
customers who needed an answer, up to 0.97 (a status ping; a profile link sent
to be added to a merge). No band below 0.98 is clean, and 0.98 fires on
nothing. Behind the closer guard it was worse than it looked: the guard
treated any message of three words or fewer as a closer, so "urgent" after an
escalation (0.89) and a bare profile link (0.64) both passed it. **Fixed in
this PR**: the guard is an exact closer-phrase match only, pinned by tests
built from those turns. With the fixed guard no labelled non-closer passes, but
only a handful of real closers score high enough to fire, so the branch would
save a few "Anytime!" replies a day and nothing of Jan's. Not worth turning on.
One class stays open if it ever is: "ok" in reply to a yes/no question is
consent, not a closer; the guard would need to read Caroline's previous turn.

**`escalate` stays OFF, permanently for this surface.** The highest-scoring
false positive is a policy question Caroline answered correctly ("could my
account get deleted?", 0.93); status pings on cases already with a person
score 0.58-0.76; a "thanks" after an escalation scores 0.75. The only turns
above 0.93 are one fraud claim. More fundamentally, escalation cannot make Jan
work less: it can only route to him sooner. Explicit "I want a person" asks are
already caught by the keyword rule, and the fraud and legal claims Jev does
score high are already escalated by the rule layer (cohort b). Jev's value on
this surface is the routing block and `decline`, both ON.

## Rollout

Merge → the next deploy (config change needs the gateway restart the deploy performs). The
first hour is watched on the `[intercom:jev]` line and `jev-shadow-report.sh --surface
caroline`; the daily review's Dimension B (gate skips, action-type mismatches) is the ongoing
grader. Rollback = `jev.enabled: false` in config (one PR line) or the plugin's fail-soft path
if Jev is unreachable.

## Untouched

The identity gate (verified Intercom email), every server-side ownership check inside the
write tools, the honesty rules, the escalation ladder's hard walls, and the ticket tiers.
