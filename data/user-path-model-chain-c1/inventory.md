# User-path model-call inventory (before this change)

Task `user-path-model-chain-c1`. Scope: every model call that can decide
something about a **user's** credit, claim, merge, deletion, refund, support
ticket or proof request. Measured on node-8 (`/opt/hydra`) at `94a5bd735`
plus the two committed configs, 2026-11-03.

"Quota/rate/auth today" = what happened when the subscription was capped, the
token was dead, or the provider 429'd/5xx'd, BEFORE this change.

## A. OpenClaw agent turns (the user-facing agents)

| agent / lane | config | primary | fallbacks (before) | on quota / rate / auth today |
| --- | --- | --- | --- | --- |
| support (Caroline) | `openclaw-edge.json` → `agents.list[support].model` | `openai/gpt-6-sol` | `openrouter/openai/gpt-6-luna`, `openrouter/anthropic/claude-haiku-5.5` | silently rode **paid frontier** OpenRouter models; the `↪️ Model Fallback:` banner was stripped from the customer reply by `plugins/intercom/src/sanitize-model-fallback.ts` (2026-06-19 Nitin incident), so neither the customer nor ops saw the tier change |
| clio, cto, qa, finance, operations, devops | `openclaw-main.json` → `agents.list[*].model` | `openai/gpt-6-sol` | same two paid hops | same, no page |
| ceo, cmo, scout | same | `openai/gpt-6-luna` | `openrouter/openai/gpt-6-luna`, haiku-5.5 | same |
| `agents.defaults.model` | both configs | `openai/gpt-6-sol` | same two paid hops | same |

Observability that existed: `codex-health.sh` / `codex-quota.sh` watch the
subscription itself (`[model-fallback/decision]` journal lines, three-state
quota: healthy / capped / **unknown**). **Nothing watched the user path as a
whole**: there was no signal for "the user path is being served by the fallback
tier", and no page for "every tier failed".

Crons (`cron-jobs.json`, 29 `agentTurn` payloads, 12 enabled) carried the same
`gpt-6-sol` + luna + haiku chain. On the user path specifically:
`support-email-triage-hourly` (→ Caroline), `daily-dispute-handler`,
`credit-fleet-fraud-scan-weekly`.

## B. Scripted paths (hydra services)

| surface | file | model before | how failure was handled before |
| --- | --- | --- | --- |
| credit judge — audit / review / decide's metered fallback | `scripts/credit_review/judge.py` | one OpenRouter model, `x-ai/grok-4.3` by default (+`web` plugin, 5 excluded domains), pinned by `CREDIT_REVIEW_MODEL` | `_post` = one HTTP POST, one attempt. No subscription tier in front. A 429/5xx/quota became `res.error` → the caller DEFERs (decide) or HOLDS (audit/review). The $25/day + per-run caps live in `credit_review/decide.py:CappedJudge` |
| credit trust ladder (the decider's evidence judge) | `scripts/credit_trust/llm.py` | `codex` (subscription, tool-less) → `jev` | codex rc 3 (quota) / 4 (tool violation) / 9 (safety) were classified and the rung was SKIPPED; **there was no metered rung at all**, so a subscription outage meant every credit decision DEFERred for as long as the quota was out. Append-only `llm_calls` ledger (`/var/lib/hydra/credit-trust/ledger.sqlite3`) |
| doc-verify claim extraction (shadow) | `scripts/credit_verify/docverify/extract.py` | `deepseek/deepseek-v4.1-flash-1017` (captain 2026-10-26), `data_collection: deny`, $5/day cap, one in-call retry on an unusable answer, `dv_llm_calls` row per attempt | the **subscription was never tried**, even though a document is text-only and needs no search: a $0 tier sat unused behind a metered one |
| outbound copy batch judge | `scripts/credit_review/batch_judge.py` (`OpenRouterBatchJudge`) | `x-ai/grok-4.3` (pinned, inside `CappedJudge`) | one attempt, no subscription in front |
| Caroline's reply guard / jev router | `plugins/intercom/src/caroline-output-guard.ts`, `jev-router.ts` | no direct model call (jev over `/tools/invoke`, code rules) | n/a |
| verify asks, uvn-status, gap-ask copy | `scripts/credit_review/*.py` | none — fixed copy, captain-approved (`answer-bank.ts` is pinned) | n/a (deliberately model-free; unchanged) |

Search capability note, decisive for the tier order: on codex-cli 0.156.1 the
subscription tier **cannot do headless web search** (search only lives behind
Code Mode's `exec` host, which `codex-judge-exec.sh` disables on purpose —
`docs/credit-verification/credit-trust-llm.md`). So a web-needing caller must
SKIP tier 1 explicitly instead of answering blind.

## C. What this change made uniform

| surface | tier 1 (subscription, $0) | tier 2 (metered) |
| --- | --- | --- |
| OpenClaw agents + all 29 `agentTurn` crons | `openai/gpt-6-sol` (unchanged primary; ceo/cmo/scout keep luna) | `openrouter/deepseek/deepseek-v4.1-flash-1017` **only** (the two paid frontier hops are gone) |
| credit judge (audit / review / decide fallback) | now tried first (`_post_chain`) — skipped with a reason when the call needs web | `deepseek/deepseek-v4.1-flash-1017` by default; `CREDIT_REVIEW_MODEL` or an explicit `Judge(model=…)` (batch_judge's evaluated `grok-4.3`) pins a different tier-2 model |
| credit trust ladder | `codex` (unchanged) → `jev` | **new** `deepseek` rung, last, capped by `MODEL_CHAIN_DAILY_USD` |
| doc-verify | **new**: `_free_tier` before the spend cap and the OpenRouter key gate | unchanged deepseek (only when tier 1 declines or the answer is unusable) |

One implementation (`scripts/lib/model_chain.py`): tier order, retry/backoff
(2 attempts on `rate_limited`/`server_error`/`timeout`, 0.5 s then 1.5 s),
`$10/day` cap across all scripted surfaces, append-only
`/var/lib/hydra/model-chain/calls.jsonl`, and one
`[model-chain] surface=… step=… tier=… outcome=…` line per attempt naming the
tier that served the call.

Alarm: `scripts/model-chain-watchdog.py` (timer every 15 min) pages
`#clio_devops` when **>20%** of user-path calls in an hour ride tier 2 (min 5
calls to judge) and **immediately** when a chain is exhausted on either surface
(scripted ledger or an agent turn reaching `next=none`).

Unchanged on purpose: every kill switch, cap, approval rule, identity gate and
customer-facing string. This chain is a client; it approves nothing.
