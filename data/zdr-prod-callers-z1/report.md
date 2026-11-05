# Production LLM caller inventory + ZDR migration

Task `zdr-prod-callers-z1`. Captain 2026-11-04: *"we need [ZDR]"*, *"only use
the fastest cheapest ZDR deepseek models ... fireworks is more expensive should
we remove it ... make sure we aren't wasting money and protect our code"*.
Ruling: **every production DeepSeek/GLM caller uses the one OpenRouter ZDR
routing block; Fireworks is retired from production paths.** Claude stays on the
token factory (CLIProxyAPI), never Bedrock.

Measured 2026-11-04 on ak47 (live OpenRouter calls) and node-8 (`/opt/hydra`,
`/var/lib/hydra*`). No secret value appears in this document — env var and
Vault path names only.

## 0. The routing block (the one thing every caller now sends)

```json
{"zdr": true, "data_collection": "deny", "sort": "price",
 "quantizations": ["fp8", "bf16", "fp16"],
 "max_price": {"prompt": 0.30, "completion": 1.20},
 "ignore": ["Google"]}
```

Model: `deepseek/deepseek-v4.1-flash-1017`.

**Live measurement (ak47, 2026-11-04, 8 requests):**

| request | provider chosen | quantization | price /M in-out |
| --- | --- | --- | --- |
| with the block (5 + 3 runs) | **Morph** (8/8) | fp8 | **$0.032 / $0.50** |
| same model, no block (3 runs) | InferenceNet (3/3) | fp8 | $0.08 / $0.55 |

The block is *also* the cheap route, not a tax on privacy. The cheapest listed
endpoint for this model is Particle AI at $0.025/$0.25, but it is not
ZDR-eligible — which is exactly what `zdr: true` excludes. Fireworks is listed
on the same model at **$0.21/$0.84 and $0.30/$1.20** (6.5x–9.4x Morph) with
`quantization: unknown`.

## 1. Inventory

Legend — **ZDR**: does the caller send a ZDR provider filter today (before this
change)? **Key source**: env var / file / Vault path name only.

### A. hydra scripted callers (node-8, `/opt/hydra`)

| # | surface | file | model | provider | ZDR before | key source | volume |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | doc-verify claim extraction (shadow) | `scripts/credit_verify/docverify/extract.py` | `deepseek/deepseek-v4.1-flash-1017` | OpenRouter direct HTTP | **no** — `data_collection: deny` only, no `zdr`, no quantization pin | `OPENROUTER_API_KEY` (env) else `/opt/hydra/secrets/llm-provider-keys.json` | **12,268 non-cached calls / 8 days** (10-28→11-04), **$8.55**; recent days 450–700 calls/day ⇒ **~15–20k calls, ~$10/mo** |
| A2 | model chain tier 2 (credit judge, credit-trust deepseek rung, doc-verify free/paid chain) | `scripts/lib/model_chain.py` | `deepseek/deepseek-v4.1-flash-1017` | OpenRouter | **no** — same `data_collection: deny` only | same | **0 production calls yet** (26 ledger rows, all canaries) — #1693 merged, not deployed |
| A3 | credit-trust ladder | `scripts/credit_trust/llm.py` | `codex` (tier 1) → `jev` → deepseek (A2) | subscription / Jev / OpenRouter | n/a (tier 1 is $0) | codex OAuth store; `JEV_*` | **6,544 calls** in `ledger.sqlite3`, 6,541 codex + 3 jev, **0 deepseek** |
| A4 | credit judge legacy direct transport | `scripts/credit_review/judge.py` | `deepseek/...` (default) or `CREDIT_REVIEW_MODEL` | OpenRouter | **no** — `payload()` had no provider block at all | same | off by default (`CREDIT_REVIEW_LEGACY_TRANSPORT=0`) |
| A5 | outbound-copy batch judge | `scripts/credit_review/batch_judge.py` | `x-ai/grok-4.3` (evaluated pin) | OpenRouter | **no** | same | low (batch runs) — **out of the DeepSeek/GLM ruling**, flagged below |
| A6 | DR AI healer (layer 2) | `scripts/dr-ai-healer.sh` | `openai/gpt-5.6-luna` | OpenRouter direct curl | **no** | `OPENROUTER_API_KEY` / `DR_OPENROUTER_KEY_FILE` | only on a CRITICAL signature — **out of ruling**, flagged |
| A7 | prod-log alert classifier | `scripts/prod-log-alert-watchdog.sh` | `openai/gpt-5.6-luna` | OpenRouter | **no** | same | every tick, only when a candidate appears — **out of ruling**, flagged |
| A8 | jev eval labeller | `scripts/jev-eval-build.sh` | `openai/gpt-5.6-sol` | OpenRouter | **no** | same | eval only, not production |

### B. OpenClaw gateways (node-8, `/opt/hydra/openclaw-*.json`)

| # | surface | model | provider | ZDR before | key source | volume |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | every agent turn, primary | `openai/gpt-6-sol` (ceo/cmo/scout: `gpt-6-luna`) | codex subscription (OAuth) | n/a — $0, not OpenRouter | codex OAuth store | all agent turns |
| B2 | every agent turn, fallback | **live:** `openrouter/openai/gpt-6-luna` → `openrouter/anthropic/claude-haiku-5.5` (paid frontier). **repo HEAD:** `openrouter/deepseek/deepseek-v4.1-flash-1017` | OpenRouter | **no** | `OPENROUTER_API_KEY` via `hydra-secrets` provider → `/opt/hydra/secrets/llm-provider-keys.json` | **48 fallback decisions / 24h on main, 0 on edge** (all `reason=unknown`, "Session changed before writer admission") — every one landed on paid frontier because live is behind the repo |
| B3 | image model | `codex/gpt-5.6-sol` → `openrouter/google/gemini-3.5-flash` → `openrouter/anthropic/claude-haiku-4.5` | codex / OpenRouter | **no** | same | on image turns only — **out of ruling**, flagged |
| B4 | memory embeddings | `text-embedding-3-small` | OpenRouter | **no** | same | every memory write — **out of ruling**, flagged |
| B5 | 29 `agentTurn` crons | `openai/gpt-6-sol` + `openrouter/deepseek/deepseek-v4.1-flash-1017` | codex / OpenRouter | **no** | same | 12 enabled |
| B6 | QA review gateway (`pods/qa-review-gateway/openclaw-qa.json`) | same chain as B1/B2 | codex / OpenRouter | **no** | its own capped `OPENROUTER_API_KEY` (Vault `k8s/hydra/qa-review`) | QA only |

**Live drift found:** node-8's `/opt/hydra/openclaw-main.json` (mtime 11-04
10:54) still carries the *old* paid-frontier fallback chain and has **no
deepseek model entry at all**. The repo at HEAD has the deepseek chain (#1693).
So the money leak the captain is asking about is live right now: 48 fallbacks
in 24h onto `gpt-6-luna`/`haiku-5.5`. Deploying this branch closes it.

### C. core-backend / core-ai

| # | surface | model | provider | ZDR | key source | volume |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | core-ai (the chat product's model service) | `MODEL_PRIMARY=google/gemma-4-26b-a4b-it`, `MODEL_FALLBACK=openai/gpt-5-mini` | OpenRouter | **no** — no provider block anywhere in the manifest | Vault `k8s/muso-prod/core-ai` → `OPENROUTER_API_KEY` (ESO) | product chat turns |
| C2 | core-backend → core-ai hop | no model call of its own (SSE proxy, `src/services/ai/coreAiClient.ts`) | — | n/a | scope token | — |

C1 is **not** a DeepSeek/GLM caller today, so it is outside the letter of the
ruling but inside its intent ("only use the fastest cheapest ZDR deepseek
models"). It needs a change in the **core-ai repo** (send the provider block)
plus an **H-DevOps** manifest change (`MODEL_PRIMARY`/`MODEL_FALLBACK`). Neither
repo is in this worktree — see §5.

### D. H-DevOps manifests

| # | path | finding |
| --- | --- | --- |
| D1 | `k8s/prod/core-ai/deployment.yaml` | `MODEL_PRIMARY`/`MODEL_FALLBACK` as C1; no ZDR block; `OPENROUTER_API_KEY` from Vault |
| D2 | `k8s/prod/hydra-qa/identity.yaml` | QA gateway's own capped OpenRouter key (good: separate blast radius) |
| D3 | `k8s/prod/hydra/verifier-identity.yaml` | doc reader + judge key = edge's `OPENROUTER_API_KEY` |
| D4 | `k8s/prod/hydra/handoff/network-policies.yaml` | egress to `openrouter.ai:443` only — consistent with the ruling |
| D5 | `hydra/openclaw-main.json`, `hydra/openclaw-edge.json`, `hydra/openclaw-dev.json` | **stale vendored copy of the hydra repo (last touched 2026-04-09)** still on `fireworks/glm-5` primary + `fireworks/deepseek-v3p2` fallback, `apiKey: VAULT:secret/hydra/fireworks#api_key`. Not the node-8 deploy path, but it is a Fireworks reference in a production repo — see §5 |
| D6 | `scripts/node8-provision/hydra-secrets-hydrate.sh` | hydrates `secret/hydra/fireworks` → `/opt/hydra/secrets/fireworks.json {FIREWORKS_API_KEY}`. The key reference to remove (the key itself stays — that is Aaron's) |

### E. Claude callers — unchanged, on the token factory

| # | surface | route |
| --- | --- | --- |
| E1 | Caroline (edge/support) + every agent's Claude models | CLIProxyAPI sidecar `127.0.0.1:8317` (`hydra/cliproxyapi.conf`), `ANTHROPIC_API_KEY` from Vault; direct `api.anthropic.com` is denied by the egress allowlist |
| E2 | Bedrock | **not used anywhere** — no `aws-sdk` auth mode, no Bedrock model ref in any config |

## 2. What this change does

**Runtime guard** — `scripts/lib/model_chain.py`:

- `ZDR_ROUTING` is the one block, and `validate_routing()` **refuses** a block
  that is not `zdr: true`, whose `data_collection` is not `deny`, whose
  `quantizations` is missing/empty or contains anything outside
  `fp8/bf16/fp16` (int4, int8, fp4, mxfp4, nf4, awq, gptq, unknown), whose
  `max_price` is not a CEILING at `MAX_PROMPT_PRICE`/`MAX_COMPLETION_PRICE`
  ($0.30/$1.20 per M — an over-cap block selects the same hosts as no cap), or
  that is not sorted by price.
- `call_deepseek` sends `validate_routing(ZDR_ROUTING)` on **every** metered
  call. `sensitive=False` can no longer opt out (the parameter is kept for API
  compatibility only).
- The constant is validated at **import** time, so a bad edit fails the process
  rather than a customer's document.

**Config guard** — `scripts/check-zdr-routing.py`, wired into
`validate-config-matrix.sh` as check 10 (so it runs in PR Validation):

- every `openrouter/deepseek|z-ai|zai|qwen|thudm` ref in
  `openclaw-main.json`, `openclaw-edge.json`, `cron-jobs.json` and
  `pods/*/openclaw-*.json` must resolve to a catalog entry whose
  `compat.openRouterRouting` passes `validate_routing`;
- no `fireworks/` ref may survive;
- every Python caller that builds an OpenRouter body is **probed**, not grepped:
  the guard asks `call_deepseek`, `extract.request_body` and `Judge.payload`
  what block they would actually send, and judges the answer. A grep for the
  token was defeated by deleting the assignment while keeping a comment that
  mentions `ZDR_ROUTING`;
- the required profile set is pinned (a renamed profile is a red job) and an
  explicitly-named config that does not exist is a failure, never a skip.

**Callers moved:**

| caller | before | after |
| --- | --- | --- |
| `model_chain.call_deepseek` (A2, and everything behind it) | `{"data_collection": "deny"}` | the validated ZDR block |
| doc-verify `extract.py` (A1) | `{"data_collection": "deny"}` | the validated ZDR block |
| credit judge `judge.py` `payload()` (A4) | **no provider block** | the validated ZDR block (both transports) |
| OpenClaw deepseek model entry (B2, B5, B6) | no `compat` | `compat.openRouterRouting` = the block, in all three configs |
| OpenClaw declared cost for that model | `$0.025/$0.25` per M | `$0.032/$0.50` (the measured ZDR price) |
| `policies/egress-allowlist.yaml` | `api.fireworks.ai:443` allowed | rule removed, with the reason recorded in place |
| `scripts/rollback.sh` comment | named `FIREWORKS_API_KEY` as a repo secret | names `OPENROUTER_API_KEY` |

**Tests** — `scripts/tests/test_zdr_routing.py` (24 cases, in PR Validation):
the guard accepts the one block and refuses each weakening (no zdr, zdr false,
`data_collection: allow`, int4/int8/fp4/mxfp4/nf4/awq/gptq/unknown, unpinned
list, uncapped AND over-cap price, non-price sort, non-object); `call_deepseek`
sends the block and `sensitive=False` cannot drop it; every shipped config
passes and the required set is pinned; a config mutated to allow int4, to drop
`zdr`, to reference `fireworks/`, or to hide the OpenRouter routing behind a
decoy provider fails; a model id declared twice fails; a missing config fails; no
production config contains a Fireworks ref; and each Python caller's outgoing
block is probed (an absent or unprobeable caller fails).

## 3. Fireworks retention terms (read-only, 2026-11-04)

Sources: `docs.fireworks.ai/guides/security_compliance/data_handling`,
`docs.fireworks.ai/accounts/zero-data-retention`, `fireworks.ai/privacy-policy`,
Terms of Service §3.6 (last updated 2026-07-10).

- **ZDR is the default for open-model inference.** Prompts and generations
  exist only in volatile memory for the duration of the request (plus a few
  minutes of KV cache if prompt caching is on); they are not written to
  persistent storage. Metadata (token counts) is logged to deliver and bill.
- **No training on customer content** without explicit opt-in (privacy policy;
  TOS §3.6: "We will not use your Content to train our own models or to improve
  the Service").
- **Carve-outs:** the Responses API with `store=True` (the default) retains the
  full conversation for **up to 30 days**; training/fine-tuning artifacts and
  traces are retained **30 days**; Nexus service metadata is de-identified
  after 30 days.
- **The enforceable, account-wide ZDR policy is an Enterprise-only toggle**
  (Settings → Governances → Zero Data Retention). It rejects Responses
  `store: true`, batch inference, fine-tuning, training, evaluators, dataset
  uploads and custom-model imports. **We have no evidence our account has it
  enabled** — the default is a policy statement, not a switch we control.
- **Verdict:** Fireworks' default terms are *not* worse than OpenRouter's ZDR
  filter on paper, but (a) we cannot verify the account-wide toggle is on, (b)
  it is 6.5x–9.4x the price for the same model, and (c) it is a second
  credential and a second egress path to keep audited. Retiring it removes all
  three problems, and the OpenRouter block gives us a per-request, verifiable
  `zdr: true` instead of an account setting we cannot read.

## 4. Live verification

| check | result |
| --- | --- |
| routing block, 8 live requests (ak47) | 8/8 → **Morph, fp8, $0.032/$0.50 per M** |
| same model without the block, 3 requests | 3/3 → InferenceNet, $0.08/$0.55 |
| `scripts/check-zdr-routing.py` on the repo | clean (4 configs, 3 python callers) |
| `scripts/validate-config-matrix.sh` | all checks passed |
| `test_zdr_routing.py` / `test_model_chain.py` / `test_doc_verify.py` / `test_credit_trust_llm.py` / `test_credit_review.py` / `test_credit_batch_judge.py` | 17 / 81 / 209 / 50 / ok / 25 — all pass |
| production OpenRouter key usage (node-8) | `usage_monthly` **$20.39**, `usage_weekly` $16.32, `usage_daily` $3.79 |
| ak47 OpenRouter key usage | `usage_monthly` $274.72, `usage_daily` $126.86 (personal key, not production) |

**+15m error-rate read** is a post-deploy step: the moved callers only take the
new block once this branch is deployed to node-8. The read is
`journalctl -u openclaw-gateway-main --since -15m | grep -c 'model-fallback/decision'`
plus `python3 scripts/model-chain-watchdog.py --canary` and the doc-verify
`dv_llm_calls` error rate (`outcome='error'` share, 849/36,535 = 2.3% baseline
over 8 days).

## 5. Follow-ups this worktree cannot do (different repos)

1. **core-ai (C1)** — needs the ZDR block in its OpenRouter client and
   `MODEL_PRIMARY=deepseek/deepseek-v4.1-flash-1017` in
   `H-DevOps/k8s/prod/core-ai/deployment.yaml`. Two repos, neither in this
   worktree. Until then core-ai is the one production model path with no ZDR
   filter.
2. **H-DevOps `hydra/` vendored copy (D5)** — still on `fireworks/glm-5` +
   `fireworks/deepseek-v3p2` with `VAULT:secret/hydra/fireworks#api_key`. It is
   a stale mirror (2026-04-09) of the hydra repo, not the node-8 deploy path,
   but it is a Fireworks reference in a production repo and should be either
   re-synced from hydra or deleted.
3. **`scripts/node8-provision/hydra-secrets-hydrate.sh` (D6)** — stop hydrating
   `secret/hydra/fireworks` → `fireworks.json`. The Vault secret and the key
   itself stay (Aaron's call to revoke).
4. **Out-of-ruling OpenRouter callers with no ZDR filter** — A5 (`grok-4.3`
   batch judge), A6 (`dr-ai-healer`), A7 (`prod-log-alert-watchdog`), B3 (image
   model), B4 (embeddings). None is DeepSeek/GLM, so the ruling does not name
   them, but each sends production data to an unverified host. Recommend the
   same block (or an explicit, recorded exception) as a follow-up decision.
5. **`~/.config/llm-route/README.md`** (ak47, outside this worktree) still
   documents "Fireworks at peak" while `pick.py` has already moved to
   ZDR-only. The README is stale, not the code.

## 6. Env var names seen (names only, no values)

`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_API_KEY_CMO`,
`FIREWORKS_API_KEY` (present in `/opt/hydra/secrets/llm-provider-keys.json`,
now unreferenced by any production path), `CREDIT_DOC_VERIFY_MODEL`,
`CREDIT_DOC_VERIFY_DAILY_USD`, `CREDIT_DOC_VERIFY_LEGACY_TRANSPORT`,
`CREDIT_REVIEW_MODEL`, `CREDIT_REVIEW_LEGACY_TRANSPORT`,
`CREDIT_TRUST_DEEPSEEK_MODEL`, `MODEL_CHAIN_FALLBACK_MODEL`,
`MODEL_CHAIN_DAILY_USD`, `MODEL_CHAIN_KEY_FILE`, `MODEL_CHAIN_LEDGER`,
`DR_MODEL`, `DR_OPENROUTER_KEY_FILE`, `PROD_LOG_ALERT_MODEL`,
`PROD_LOG_ALERT_KEY_FILE`, `JEV_EVAL_LABEL_MODEL`, `JEV_EVAL_LABEL_KEY_FILE`,
`MODEL_PRIMARY`, `MODEL_FALLBACK` (core-ai).
