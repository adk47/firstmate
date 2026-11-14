# The user-path model chain

**One chain, every surface.** Any model call that decides something about a
user's credit, claim, merge, deletion, refund, support ticket or proof request
runs the same two tiers in the same order:

| tier | what | who pays | can search the web |
| --- | --- | --- | --- |
| 1 | `openai/gpt-6-sol` — the ChatGPT/Codex **subscription** (`codex-judge-exec.sh`) | $0 | no (codex-cli 0.156.1 has no headless search) |
| 2 | `openrouter/deepseek/deepseek-v4.1-flash-1017` — **the metered tier** | ~$0.03/M in, $0.25/M out | yes, via OpenRouter's `web` plugin |

Captain's ruling, 2026-11-03:

> primary = the OpenClaw subscription token model; when it runs out, OpenRouter
> deepseek 1017

A second fallback is allowed only when DeepSeek is *unsuitable for that call*
with a stated reason. Today there is exactly one such case and it is a
capability gap, not a preference: a rung that needs the ladder's own evidence
rule (only sources hydra fetched server-side count, hydra#1142) skips the web
plugin — see `scripts/credit_trust/llm.py`.

## Where it lives

- `scripts/lib/model_chain.py` — the ONE implementation. Tier walk, retry
  classification, cost cap, append-only ledger, per-call log line.
- `scripts/model-chain-watchdog.py` — the alarm. Pages when the user path
  rides tier 2 or when the chain runs dry.
- Config: `openclaw-main.json`, `openclaw-edge.json` (`agents.defaults` +
  every `agents.list[]`), `pods/qa-review-gateway/openclaw-qa.json` (the qa pod
  profile, asserted identical to main's qa agent by
  `scripts/tests/qa-review-gateway-profile.bats`) and every `agentTurn` payload in
  `cron-jobs.json` have `fallbacks: ["openrouter/deepseek/deepseek-v4.1-flash-1017"]`
  — exactly one entry, enforced by `scripts/validate-config-matrix.sh` check 6b
  (crons: check 5). Check 6b refuses the multi-hop lists the pre-2026-11 chain
  used, so check 6's "no non-GPT-5 mid-chain" cases now assert that check 6 does
  not over-fire while 6b refuses the list.

Callers:

| surface | file | tier-1 path |
| --- | --- | --- |
| credit judge / audit / review / decider's metered fallback | `scripts/credit_review/judge.py` | `_post_chain` → `ModelChain("credit-review")` |
| credit trust ladder (codex → jev → deepseek) | `scripts/credit_trust/llm.py` | native codex rung, then deepseek |
| doc-verify claim extraction | `scripts/credit_verify/docverify/extract.py` | `_free_tier`, then `chain_post` |
| OpenClaw agents + crons | `openclaw-*.json`, `cron-jobs.json` | openclaw's own fallback classifier |

## Failure classes

`quota`, `auth_expired`, `rate_limited`, `server_error`, `timeout`,
`unavailable`, `unsafe`, `bad_answer`, `chain_exhausted`.

- `RETRY_SAME_TIER` = `rate_limited`, `server_error`, `timeout` — the same tier
  is retried (2 attempts, 0.5 s then 1.5 s backoff) before the next tier runs.
- `bad_answer` is in `RETRY_SAME_TIER` too since 2026-11-14 (a node-8 hand edit
  of 2026-11-10, landed): about 10% of deepseek-v4.1-flash calls came back empty
  on 2026-11-09, exhausted the chain and left the row with no decision. It
  differs from the three transport classes: the retry is **billable** (a bad
  answer was served, so each ask is charged and reserved against the cap), and an
  answer cut at the token cap (`finish_reason: length`) is **not** re-sent, since
  the same prompt at the same budget is cut at the same place
  (`retry_same_tier()`).
- `MAX_BILLABLE_ASKS_PER_TIER` = 2 — one budget for the asks a tier is paid for,
  shared by the `bad_answer` retry and the `reasoning_exhausted` raised-budget
  retry, at any `retries`. `bad_answer` then `reasoning_exhausted` stops there:
  no third ask. It counts billed answers, not attempts, so the raised-budget ask
  after a free `rate_limited` is still made.
- `ABORT_CHAIN` = `unsafe` — a refusal or a tool violation is **never laundered
  onto another model**. The chain stops and reports. `credit_trust`'s own ladder
  applies the same rule itself: the codex helper's rc 4 (`tool_violation`) and
  rc 9 (`safety_violation`) are in its `UNSAFE_REFUSALS`, and they end the ladder
  before jev or the paid rung, reporting `meta.aborted` — a paid model must never
  answer what the tool-less subscription refused.
- Everything else advances immediately: a quota spend, a dead token or a
  non-JSON answer is not worth a second round trip on the same tier.
  (Since 2026-11-14 the non-JSON answer is the exception: it is `bad_answer`,
  which gets its one more ask first, as above.)

**A tier that cannot do what the call needs is SKIPPED, not guessed.** A web
call skips tier 1 with `reason=web_search_unavailable`; a tool-less extraction
is not asked to search. `chain_exhausted` means every tier either failed or was
skipped — the caller then DEFERs or HOLDs, exactly as it did before this
change. A model outage must never turn into a wave of support requests.

### Trap: strict structured output (measured live, 2026-11-03)

`codex-judge-exec.sh --schema` passes the schema to OpenAI **strict** structured
output. The first live tier-1 call came back

```
400 invalid_json_schema: 'schema.additionalProperties' is required to be
supplied and to be false when strict is true
```

— and a 400 there is not a one-off: every tier-1 call would fail, silently
pushing the whole user path onto the metered tier. So `call_subscription`
normalizes the schema for every caller (`model_chain.strict_schema`): every
object node gets `additionalProperties: false` (forced, even if the caller said
`true`) and every declared property is listed in `required`. A fake runner
cannot catch this — only a real call can, which is why the canary below is part
of the proof.

## Ledger, cost cap, and the tier log

Every attempt is one JSONL row in `/var/lib/hydra/model-chain/calls.jsonl`
(under `/var/lib` so a deploy cannot erase it):

```json
{"ts": "...", "epoch": 1793600000, "surface": "credit-review", "step": "judge",
 "tier": "deepseek", "outcome": "ok", "kind": null, "model": "deepseek/deepseek-v4.1-flash-1017",
 "cost_usd": 0.00041, "input_tokens": 812, "output_tokens": 61, "latency_ms": 2400,
 "prompt_sha256": "…", "attempt": 1}
```

A tier that was skipped is a row too (`outcome: "skipped"` with a `reason`), so
an outage is visible instead of absent.

`MODEL_CHAIN_DAILY_USD` (default **10**) caps tier 2 across *all* scripted
surfaces. Over the cap the metered tier is skipped with
`reason=daily cap … reached` and the chain exhausts; nothing spends past it.
Callers keep their own narrower caps (`credit_review.decide.CappedJudge`'s
per-run + $25/day, doc-verify's $5/day) — this chain is a client, never an
approver.

`call_deepseek` always sends the ONE ZDR routing block (`ZDR_ROUTING`), and
`validate_routing` refuses anything weaker — a block with no `zdr: true`, with
`data_collection` not `deny`, with an unpinned or lossy `quantizations` list
(int4/int8/fp4/unknown), without a `max_price` cap, or not sorted by price. The
price cap is a CEILING, not a positivity check: `max_price` above
`MAX_PROMPT_PRICE`/`MAX_COMPLETION_PRICE` ($0.30 / $1.20 per M) is refused,
because a cap above them selects the same hosts as no cap at all.
Captain 2026-11-04: "we need [ZDR] ... only use the fastest cheapest ZDR
deepseek models ... protect our code". The block is also the cheap route, not a
tax on privacy: measured on ak47 2026-11-04, 8 of 8 requests landed on Morph at
fp8 for $0.032/$0.50 per M, while the same model WITHOUT the block landed on
InferenceNet at $0.08/$0.55. The cheapest listed endpoint (Particle AI,
$0.025/$0.25) is not ZDR-eligible, which is exactly what `zdr: true` excludes.
`sensitive=True` is still accepted for API compatibility but no longer changes
the provider block: ZDR is not optional per caller.

The config half of the same rule is `scripts/check-zdr-routing.py` (wired into
`validate-config-matrix.sh` check 10): every `openrouter/deepseek|z-ai` ref in
the OpenClaw configs must resolve to a catalog entry — **under the same provider
key** — whose `compat.openRouterRouting` passes `validate_routing`, and no
`fireworks/` ref may survive. The per-provider keying is load-bearing: a flat
model-id map let a second provider declaring the same id with a valid block
overwrite an OpenRouter entry that had lost its routing, so the guard reported
clean while the live route had no ZDR filter. A model id declared twice inside
one provider is refused too, because the guard cannot then say which entry the
runtime resolves. The required profile set is **pinned**, not globbed — a renamed
production profile is a red job, and an explicitly-named config that does not
exist is a failure rather than a skip.

The Python callers are **probed, not grepped**: the guard asks
`call_deepseek`, `extract.request_body` and `Judge.payload` what provider block
they would actually send, and judges the answer. A grep for the token was
defeated by deleting the assignment while keeping a comment that mentions
`ZDR_ROUTING` — the judge's legacy direct transport would then have sent credit
data with no filter at all, with the guard and its test green.
`scripts/tests/test_zdr_routing.py` pins all of it, including the mutant where
the assignment is deleted.

Every attempt logs one line to stderr:

```
[model-chain] surface=credit-review step=judge tier=deepseek outcome=ok kind=None cost_usd=0.00041 attempt=1
```

That line is the contract the watchdog and the canary read.

## The watchdog (`scripts/model-chain-watchdog.py`)

Two alarms over a rolling window (default 1 h, `--window-hours`):

1. **FALLBACK SHARE > 20%** of user-path model calls served by tier 2 (and
   chain exhaustions, which are fallback pressure with nobody answering).
   `MODEL_CHAIN_FALLBACK_SHARE_THRESHOLD` (0.20). Below `MODEL_CHAIN_MIN_CALLS`
   (5) it is **not judged** — and says so, because silence below the minimum is
   not health.
2. **CHAIN EXHAUSTED** — any exhausted chain, or an agent turn whose journal
   record reached `next=none`. Pages immediately, even below the minimum.

**A capability fallback is not an outage.** Some requests the subscription cannot
do at all: the vendored codex-cli has no headless web search, so `credit_review`'s
web reviews skip tier 1 by design (`reason=web_search_unavailable`) and are served
by DeepSeek. A tier-1 skip reason in `CAPABILITY_SKIPS` marks every row beneath it
`capability: true`; `tier_counts()` puts those in their own bucket and the share
ignores them on BOTH sides, so five routine web reviews no longer read as 5/5 =
100% fallback. The watchdog prints the capability count separately.

**The share needs the subscription's successes too, not only its failures.**
`credit_trust` runs its own codex rung and writes SQLite audit rows, so a call it
served on the subscription used to leave no shared-ledger row — 1,000 free
successes beside 5 paid fallbacks read as 100% fallback. `record_served()` writes
that success into the shared ledger (tier `subscription`, cost $0, best-effort:
bookkeeping never fails a request, and a missing row can only make the share look
WORSE). jev is deliberately not recorded — it is neither tier.

**Agent-side counts are an absolute event count, never a share.** The installed
runner logs `[model-fallback/decision]` only when a fallback decision happened —
an ordinary first-choice turn logs nothing, and codex/OAuth turns emit no
`[model-fetch]` line at all — so agent rows can prove an outage but cannot be the
denominator of a percentage. `assess()` therefore computes the fallback share
from the scripted ledger alone (which records every attempt) and pages on
`agent_fallback_breach` when the agent-side fallback count reaches
`MODEL_CHAIN_AGENT_FALLBACK_MIN` (default 3) in the window. `agents_counts_complete`
is `false` so nobody re-derives a percentage from those rows.

A planned fleet maintenance window (`scripts/hydra-maintenance.sh is-active`)
suppresses the page and prints that the run proved nothing: a window stops the
codex subscription tier, so its breach shape is identical to a real outage and
paging through it trains the channel to be ignored.
(`scripts/tests/maintenance-guard-drift.bats` requires the guard on every
fleet-health watchdog.)

A **blind source is never health**: if the usage ledger cannot be read, or
`journalctl` fails, or any configured
gateway unit does not exist on the host, or `systemctl list-unit-files` cannot
answer at all (failed or empty — "unknown", never "nothing exists", because a
stale name then reads as a quiet fleet) (`journalctl -u <missing>` exits 0 and
says nothing, which is how the `openclaw-gateway@main` bug hid), the watchdog
reports `USAGE LEDGER UNREADABLE` / `AGENT SOURCE UNKNOWN` and pages — agent-turn counts become *unknown*,
never zero.

Sources: the JSONL ledger (scripted paths) + `journalctl` for the **installed**
units `openclaw-gateway-main` / `openclaw-gateway-edge` `[model-fallback/decision]`
records (agent turns; `candidate == requested` counts as tier 1; override the
units with `MODEL_CHAIN_GATEWAY_UNITS`). The template spelling
`openclaw-gateway@main` matches no unit on node-8 and read as silence — verified
on the host with `systemctl list-units "openclaw*"` and pinned by a test, because
"no rows" must never be the same answer as "healthy".

```bash
python3 scripts/model-chain-watchdog.py --check      # human report, never pages
python3 scripts/model-chain-watchdog.py --canary     # JSON for +15m and +60m reads
python3 scripts/model-chain-watchdog.py --alert      # what the timer runs
```

`--check` and `--canary` never write state and never post. `--alert` posts to
`#clio_devops` with real `<@UID>` mentions and suppresses a repeat of the same
alarm for `MODEL_CHAIN_ALERT_REPEAT_MIN` minutes (default 360, i.e. 6 h: one
quota outage must not become 96 posts). State:
`/var/lib/hydra/model-chain/watchdog-state.json`.

Installed by `scripts/install-aux-units.sh`: `model-chain-watchdog.timer`,
every 15 min, `OnBootSec=5min`.

## Adding a caller

```python
from lib import model_chain

res = model_chain.ModelChain("my-surface").call(
    messages, schema=my_schema, web=False, sensitive=True, step="decide")
if not res.ok:
    return defer(res.error)          # never guess; the chain already logged why
return res.json
```

Rules that make this safe to copy:

- **Never** hardcode a provider/model at a call site. If a surface needs a
  different metered model, pass `fallback_model=` and say why in a comment.
- **Never** treat `res.ok == False` as "answer anyway". DEFER, HOLD or fall back
  to the surface's own non-model path (catalog-only, regex extraction).
- **Never** re-implement retry/backoff/cost accounting around it — the chain
  owns them, and a second implementation is how this repo accumulated the
  fragmentation this page exists to end.
- A surface that must not touch the metered tier (`CREDIT_REVIEW_MODEL_ENABLE_FILE`
  absent, kill switch present, neither tier usable) keeps its own gate. The
  chain never overrides a kill switch.

Escape hatches, both off by default and both for an operator who needs the
pre-2026-11 transport (no subscription rung, no tier log):

- `CREDIT_REVIEW_LEGACY_TRANSPORT=1`
- `CREDIT_DOC_VERIFY_LEGACY_TRANSPORT=1`

`CREDIT_REVIEW_WEB_ENGINE` implies the legacy transport: the chain's web tier
cannot select a search engine.

## Proof

`scripts/tests/test_model_chain.py` (in PR Validation) forces tier 1 to fail in
every classified way and asserts which tier answered, what the ledger says and
what the watchdog would page:

- quota / 401 / 429 / 5xx / unusable answer → **DeepSeek answers**, tier 2 is
  recorded, `served_by_fallback` is true;
- `unsafe` → the chain aborts and tier 2 is **never** called;
- both tiers dead → `chain_exhausted`, recorded and countable;
- a web call → tier 1 is skipped, tier 2 gets the `web` plugin and the one ZDR
  routing block;
- over the daily cap / no key → a skip, never a spend, never a crash;
- watchdog: 30% fallback pages, 20% does not, below the minimum is not judged,
  a dead chain pages anyway, journal rows map to tiers, and the default journal
  units are the ones actually installed;
- **a broken ledger refuses the metered tier** (`accounting unavailable`) while
  the $0 subscription keeps working, and `call_fallback` — the path
  `credit_trust` uses — meters and records exactly like `call`;
- an `unsafe` verdict in doc-verify aborts the extraction instead of falling
  through to the metered tier; that free tier runs as its own single-tier chain
  call (so the $0 answers are in the ledger and never read as fallback pressure)
  and `chain_post` is the metered tier alone, never a second subscription ask;
- a caller with no schema (`schema=None`) gets the `{"text": ...}` wrapper schema
  and the envelope is unwrapped, because strict mode on an empty object schema
  can only ever produce `{}`; a missing ledger file is a real `$0`, an
  unreadable one is not;
- **`chain_exhausted` means the whole USER PATH is out of tiers** — a mid-ladder
  decline (doc-verify's free tier) records nothing, and the last rung's failure
  always records it, so the immediate alarm can see a real dead end and cannot be
  paged for a request that was served;
- **a metered call is preceded by a durable `reserve` row** (`$0.05` ceiling,
  released by a `settle` row carrying the difference), so a readable-but-
  unwritable ledger cannot let successive processes each spend "the first $10"
  — no reservation, no spend, and the check-plus-reserve is one `flock`ed step
  whose reservation must FIT under the cap (`spent + reserve > cap` is refused);
- **the reservation is the request's own ceiling**: `estimate_upper_usd()` prices
  the worst case for THAT request (a prompt has at least one character per token,
  the answer cannot exceed `max_tokens`, web adds a per-result fee) with a
  per-model ceiling taken from `PRICE_USD_PER_TOKEN` at the model's MOST expensive
  tier, floored at `MODEL_CHAIN_RESERVATION_USD`. A flat reservation let a call
  admitted at $9.95 settle at $10.05, i.e. the "hard $10/day" was a floor;
- **the reservation outlives the call**: the release is written only AFTER the
  attempt's charge row is durable (order: `reserve` → charge → `settle`), so the
  running total never dips below real spend. Releasing first left a window at
  $9.95 where a second process saw $9.95 again and both settled past the cap;
- **a served row is written when the answer is USABLE, not when it arrives**:
  `call(..., defer_served_row=True)` leaves the success row to
  `record_served()` so a caller that validates answers (doc-verify) only counts
  the ones it accepted. Writing it on arrival counted an unusable free answer as
  a subscription success, which quietly understated the fallback share
  (75 good + 25 unusable read 20% instead of 25%) and could silence the alarm;
- **only the chain transport records the terminal marker**: one guarded writer
  (`Extractor._chain_terminal`) skips it when `self.post` is not `chain_post`, so
  the legacy escape hatch (`CREDIT_DOC_VERIFY_LEGACY_TRANSPORT=1`) and injected
  test transports never tell the watchdog "both tiers failed" about a path that
  never called a tier;
- **every dead end of the ladder records it**: `chain_post` (rung failure), the
  chunk/retry dead ends, and doc-verify's own gates after the free tier declined
  (daily cap reached, no OpenRouter key) all write `chain_exhausted`, because in
  each case the request truly got no answer;
- **the terminal marker belongs to whoever owns the ladder**: `chain_post` passes
  `record_exhausted=False` to `call_fallback()` (both flags are honoured now) and
  records `chain_exhausted` itself only when a non-truncation failure leaves no
  recovery — and doc-verify records it from its own chunk/retry dead-ends via
  `record_chain_exhausted()`. Writing it at the rung made a successfully recovered
  document page "both tiers failed, the user got no answer";
- **a retry must change the request**: `frequency_penalty` is threaded through
  `call()`/`call_fallback()`/`call_deepseek()`, so the anti-repetition retry is a
  different request instead of a byte-identical resend of a prompt the model
  already looped on;
- **a capped answer is not a transport failure**: `ChainResult.finish_reason` is
  carried through so a caller that OWNS truncation recovery (doc-verify chunks a
  long document, or retries once with an anti-repetition penalty) still gets to
  run it. `chain_post` passes `finish_reason: length` instead of raising, and the
  partial answer is still never validated or cached;
- **the audit label is the model that ANSWERED**: `judge._post_chain` writes the
  serving tier's model into `JudgeResult.model` (and its tier into `.provider`)
  before returning, and `judge_many` builds every per-claim result from the call's
  own served model — a subscription-authored batch decision must never be recorded
  as the configured paid fallback;
- **a cap that stops the retry is a dead path too**: when the first paid attempt is
  charged and unusable and that charge fills doc-verify's daily cap, the retry's
  cap exit records `chain_exhausted` — no extraction reached the user;
- **provenance is reported, never invented**: `TierAttempt.model` falls back to
  the requested id for the audit label, but `meta["model_reported"]` (surfaced as
  `ChainResult.model_reported`) carries ONLY what the provider said. A caller
  whose cache is keyed by model must use the reported one — otherwise an
  unknown-origin answer is replayed for 24 h as if the pinned model produced it;
- **the metered tier runs the model the caller pinned**: `_paid_chain(key, model)`
  passes the caller's model (`CREDIT_DOC_VERIFY_MODEL` / `Extractor(model=…)`)
  into `ModelChain(fallback_model=…)`, so the answer, the cache key and the audit
  label are the same model — an unpriced pin is refused with that reason;
- **an empty answer is not an answer**: `call_subscription` marks an empty (or
  whitespace-only) text result `bad_answer`, including a strict `{"text": ""}`
  wrapper that unwraps to nothing, so the chain moves on instead of serving an
  unusable reply;
- **unlimited mode still books its reservation**: `MODEL_CHAIN_DAILY_USD=0` keeps
  the `reserve` row (via `admit`) so the later `settle` releases something real —
  otherwise the day's total went negative and a re-enabled cap read it as
  headroom;
- **an unpriced model is REFUSED, not priced at a guess**: `PRICE_USD_PER_TOKEN`
  holds a ceiling for every model the metered tier may run (the fallback, plus the
  pinned `x-ai/grok-4.3` and `openai/gpt-6-luna` a caller can select). A model
  with no ceiling cannot be bounded against the cap, so the metered tier returns
  `skipped / unpriced model …` and names both fixes (add the price, or set
  `MODEL_CHAIN_UNPRICED_MAX_USD`). Pricing a frontier model at fallback rates is
  exactly how the cap stops being a cap;
- **only a row that could have charged counts**: an `ok` row without a price is
  counted at the reservation, while `skipped`/`error` rows and the
  `chain_exhausted` marker charge nothing and are not billed (counting them
  invented $0.10 of spend per unserved request and could lock the tier out);
- **an unpriced or malformed charging row never reads as free**: a response with
  no `usage.cost` is booked at the reservation with `meta.cost_estimated` — for a
  served-but-unusable answer (`bad_answer`: truncated, unparseable) as well as a
  good one, because the provider billed the tokens either way — and a ledger line
  that will not parse makes the day's total UNKNOWN (fail closed) rather than
  quietly smaller; a transport failure (429/5xx/timeout) consumed nothing and
  costs nothing;

Live read after a deploy (read-only, no writes, no model calls of its own):

```bash
python3 scripts/model-chain-watchdog.py --canary    # +15m, then +60m
```

Both tiers were also called once by hand on node-8 before the PR (read-only,
the chain's own ledger row plus one $0 subscription call):

```
[model-chain] surface=canary-primary-first step=canary tier=subscription model=gpt-6-sol outcome=ok latency_ms=6384   cost $0.0
[model-chain] surface=canary-fallback      step=canary tier=subscription ... outcome=error (simulated outage)
[model-chain] surface=canary-fallback      step=canary tier=deepseek     model=deepseek/deepseek-v4.1-flash-1017 outcome=ok latency_ms=481  cost $0.000053
```
